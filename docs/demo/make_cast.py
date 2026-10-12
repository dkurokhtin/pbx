#!/usr/bin/env python3
"""Генерация демо-кастов pbx (asciicast v2) ЗАХВАТОМ РЕАЛЬНЫХ СЕССИЙ через pty.

Четыре ролика — по одному на фичу (каждый в свой раздел README):
  hero    — штатный поток Э5: меню pbx → snapshot (ноут) → start + push (дом) → deliver (ноут)
  status  — сводка: последний push в зеркало и отставание SRC
  corp    — Э3: pbx snapshot (ноут) → pbx corp (дом), обе стороны
  guard   — страховка deliver: guard на удалении → «n»; патч не лёг → откат без коммита

Запуск:  python3 docs/demo/make_cast.py            # все ролики → /tmp/pbx-demo/*.cast
         python3 docs/demo/make_cast.py corp guard # выборочно
Рендер:  npx -y svg-term-cli --in /tmp/pbx-demo/hero.cast --out docs/pbx-demo.svg --window

Известные грабли (выстраданы):
  * первый event обязан быть на timestamp 0.0 — иначе стартовый кадр пуст;
  * ENV_ROOT в /tmp/pbx-demo — короткие пути влезают в 76 колонок;
  * LC_ALL=C.utf8 обязателен: без него pbx уходит в ASCII-глифы (> вместо ▸);
  * чистим ТОЛЬКО свои подкаталоги ROOT — рядом лежат инструменты (agg).
"""
import fcntl
import json
import os
import pty
import select
import shutil
import struct
import subprocess
import sys
import termios
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PBX = os.path.join(REPO, 'pbx')
ROOT = '/tmp/pbx-demo'
COLS, ROWS = 76, 22
MAX_GAP = 1.0   # паузы длиннее секунды сжимаем — демо не должно тянуться

ENV_BASE = {
    **{k: v for k, v in os.environ.items() if k in ('PATH', 'HOME')},
    'TERM': 'xterm-256color',
    'LC_ALL': 'C.utf8',
    'COLUMNS': str(COLS),
    'LINES': str(ROWS),
}
GIT_ENV = {
    **ENV_BASE,
    'GIT_AUTHOR_NAME': 'dev', 'GIT_AUTHOR_EMAIL': 'dev@corp',
    'GIT_COMMITTER_NAME': 'dev', 'GIT_COMMITTER_EMAIL': 'dev@corp',
}

events = []   # [t, 'o', data]
T = [0.0]


def new_cast():
    events.clear()
    T[0] = 0.0
    # первый кадр строго на 0.0 И НЕ ПУСТОЙ, иначе постер SVG/GIF — голый фон
    events.append([0.0, 'o', '\x1b[2J\x1b[H\x1b[1;32m$\x1b[0m '])


def emit(delay, data):
    T[0] = round(T[0] + delay, 3)
    events.append([T[0], 'o', data])


def comment(text, lead=1.0):
    emit(lead, '\x1b[2m%s\x1b[0m\r\n' % text)


def type_cmd(cmd, lead=0.8, prompt=True):
    """Фабрикуем только строку приглашения — команда «печатается» посимвольно."""
    if prompt:
        emit(lead, '\x1b[1;32m$\x1b[0m ')
        lead = 0.06
    for ch in cmd:
        emit(0.06 if ch != cmd[0] else lead, ch)
    emit(0.45, '\r\n')


def finish_cast(path, title):
    header = {
        'version': 2, 'width': COLS, 'height': ROWS, 'title': title,
        'env': {'TERM': 'xterm-256color', 'SHELL': '/bin/bash'},
    }
    with open(path, 'w') as f:
        f.write(json.dumps(header, ensure_ascii=False) + '\n')
        for ev in events:
            f.write(json.dumps(ev, ensure_ascii=False) + '\n')
    print('cast: %s (%d events, %.1fs)' % (path, len(events), T[0]))


def run_pty(argv, keys, env):
    """Запустить argv под pty, скормить keys=[(задержка_до, bytes)], собрать вывод."""
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))
    p = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave,
                         env=env, close_fds=True)
    os.close(slave)
    chunks, last, ki = [], time.monotonic(), 0
    next_key = time.monotonic() + (keys[0][0] if keys else 1e9)
    deadline = time.monotonic() + 30          # страховка от зависшего демо
    while time.monotonic() < deadline:
        timeout = max(0.0, min(0.05, next_key - time.monotonic()))
        r, _, _ = select.select([master], [], [], timeout)
        now = time.monotonic()
        if r:
            try:
                data = os.read(master, 65536)
            except OSError:
                break
            if not data:
                break
            chunks.append((now - last, data.decode('utf-8', 'replace')))
            last = now
        if ki < len(keys) and now >= next_key:
            os.write(master, keys[ki][1])
            ki += 1
            next_key = now + (keys[ki][0] if ki < len(keys) else 1e9)
        if p.poll() is not None and not r and ki >= len(keys):
            while True:                        # дочитать хвост после выхода
                r2, _, _ = select.select([master], [], [], 0.1)
                if not r2:
                    break
                try:
                    data = os.read(master, 65536)
                except OSError:
                    break
                if not data:
                    break
                now = time.monotonic()
                chunks.append((now - last, data.decode('utf-8', 'replace')))
                last = now
            break
    os.close(master)
    p.wait()
    for dt, data in chunks:
        emit(min(dt, MAX_GAP), data)


def git(*args, cwd):
    subprocess.run(['git', *args], cwd=cwd, env=GIT_ENV, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def pbx_quiet(args, env):
    subprocess.run(['bash', PBX, *args], env=env, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def fresh(*subs):
    """Пересоздать СВОИ подкаталоги ROOT (инструменты рядом не трогаем)."""
    paths = []
    for sub in subs:
        p = os.path.join(ROOT, sub)
        shutil.rmtree(p, ignore_errors=True)
        os.makedirs(p)
        paths.append(p)
    return paths


def write_conf(reg, name, **kv):
    with open(os.path.join(reg, name + '.conf'), 'w') as f:
        for k, v in kv.items():
            f.write('%s=%s\n' % (k, v))


def env_for(ws, reg):
    return {**ENV_BASE, 'PBX_WORKSPACE': ws, 'PBX_REGISTRY_DIR': reg}


def make_src_tree(ws, *projects):
    for proj in projects:
        os.makedirs(os.path.join(ws, proj, 'src'), exist_ok=True)
        with open(os.path.join(ws, proj, 'src', 'app.js'), 'w') as f:
            f.write('console.log("hi from %s")\n' % proj)


# ---------------------------------------------------------------- сценарии --

def cast_hero():
    """Штатный поток (Э5): snapshot (ноут) → start + push (дом) → deliver (ноут)."""
    base, hreg, nreg, ws = fresh('flow', 'flow-hreg', 'flow-nreg', 'flow-ws')  # ws пустой: в меню/snapshot только sup
    corp = os.path.join(base, 'corp.git')
    mdir = os.path.join(base, 'mirror.git')
    nrepo = os.path.join(base, 'repo')
    hsrc = os.path.join(base, 'src')
    git('init', '-q', '--bare', corp, cwd=ROOT)
    git('init', '-q', '--bare', mdir, cwd=ROOT)
    # ноут: корп-репо на dev
    git('init', '-q', '-b', 'dev', nrepo, cwd=ROOT)
    with open(os.path.join(nrepo, 'app.js'), 'w') as f:
        f.write('console.log("app v1")\n')
    with open(os.path.join(nrepo, 'roles.js'), 'w') as f:
        f.write('export const roles = ["admin"]\n')
    git('add', '-A', cwd=nrepo)
    git('commit', '-qm', 'SUP-1: база', cwd=nrepo)
    git('remote', 'add', 'origin', corp, cwd=nrepo)
    git('push', '-qu', 'origin', 'dev', cwd=nrepo)
    write_conf(nreg, 'sup', REPO=nrepo, MIRROR=mdir, FORGE='none')
    nenv = env_for(ws, nreg)
    # дом: пустой SRC-репо, ветку даст pbx start
    git('init', '-q', hsrc, cwd=ROOT)
    write_conf(hreg, 'sup', SRC=hsrc, MIRROR=mdir)
    henv = env_for(ws, hreg)

    new_cast()
    comment('# ноут (видит корп-gitlab): меню pbx — пункты в порядке потока', lead=0.3)
    type_cmd('pbx', lead=0.6)
    run_pty(['bash', PBX], env=nenv, keys=[
        (1.4, b'\x1b[B'),  # ↓ start
        (0.6, b'\x1b[B'),  # ↓ ctx
        (0.6, b'\x1b[B'),  # ↓ push
        (0.6, b'\x1b[B'),  # ↓ deliver
        (1.0, b'\x1b[A'), (0.35, b'\x1b[A'), (0.35, b'\x1b[A'), (0.35, b'\x1b[A'),
        (0.9, b'\r'),      # Enter → snapshot (корп-dev → corp-dev зеркала)
    ])
    comment('# дом: задача от свежего корпа')
    type_cmd('pbx start sup fix/widget')
    run_pty(['bash', PBX, 'start', 'sup', 'fix/widget'], keys=[], env=henv)
    type_cmd('echo \'export const widget = 1\' > widget.js', lead=1.0)
    with open(os.path.join(hsrc, 'widget.js'), 'w') as f:
        f.write('export const widget = 1\n')
    type_cmd('pbx push sup fix/widget')
    run_pty(['bash', PBX, 'push', 'sup', 'fix/widget'], keys=[], env=henv)
    # тем временем коллега влил своё в корп-dev — патч это не тронет
    tmp = os.path.join(base, 'colleague')
    subprocess.run(['git', 'clone', '-q', '-b', 'dev', corp, tmp], env=GIT_ENV,
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(os.path.join(tmp, 'roles.js'), 'a') as f:
        f.write('roles.push("auditor")\n')
    git('commit', '-qam', 'SUP-2: роль аудитора (чужой MR)', cwd=tmp)
    git('push', '-q', 'origin', 'dev', cwd=tmp)
    comment('# тем временем в корп-dev влили чужой MR — патч его не откатит')
    comment('# ноут: только наш дифф поверх свежего dev → MR', lead=0.6)
    # ≤ 74 символов с приглашением — иначе перенос строки в 76 колонках
    type_cmd('pbx deliver sup feature/SUP-7 "SUP-7: виджет" --from fix/widget')
    run_pty(['bash', PBX, 'deliver', 'sup', 'feature/SUP-7', 'SUP-7: виджет',
             '--from', 'fix/widget'],
            keys=[(3.5, b'y'), (0.6, b'\r')], env=nenv)   # guard: показал дифф → «y»
    emit(1.4, '\x1b[1;32m$\x1b[0m ')
    emit(2.4, '\r\n')
    finish_cast(os.path.join(ROOT, 'hero.cast'),
                'pbx: snapshot → start → push → deliver')


def cast_status():
    """Сводка: последний push в зеркало и отставание SRC (коммит + правки)."""
    ws, reg, mdir = fresh('st/ws', 'st/reg', 'st/mirror.git')
    make_src_tree(ws, 'vnd')
    src = os.path.join(ws, 'sup')
    os.makedirs(src)
    git('init', '-q', '-b', 'feature/SUP-12-search', src, cwd=ROOT)
    with open(os.path.join(src, 'app.js'), 'w') as f:
        f.write('console.log("search v1")\n')
    git('add', '-A', cwd=src)
    git('commit', '-qm', 'SUP-12: каркас поиска', cwd=src)
    git('init', '-q', '--bare', mdir, cwd=ROOT)
    write_conf(reg, 'sup', SRC=src, MIRROR=mdir)
    env = env_for(ws, reg)
    pbx_quiet(['push', 'sup'], env)          # push-мета (ветка → зеркало)
    with open(os.path.join(src, 'index.js'), 'w') as f:
        f.write('export const idx = 1\n')
    git('add', '-A', cwd=src)
    git('commit', '-qm', 'SUP-12: индекс', cwd=src)   # SRC ушёл вперёд пуша
    with open(os.path.join(src, 'app.js'), 'a') as f:
        f.write('// wip\n')                            # dirty

    new_cast()
    type_cmd('pbx status', lead=0.5, prompt=False)
    run_pty(['bash', PBX, 'status'], keys=[], env=env)
    emit(1.4, '\x1b[1;32m$\x1b[0m ')
    emit(2.4, '\r\n')
    finish_cast(os.path.join(ROOT, 'status.cast'), 'pbx status — push и отставание SRC')


def cast_corp():
    """Э3: pbx snapshot на «ноуте» → pbx corp дома. Обе стороны в кадре."""
    corp, mdir, hreg, hws = fresh('e3/corp', 'e3/mirror.git', 'e3/reg', 'e3/ws')
    origin = os.path.join(corp, 'origin.git')
    repo = os.path.join(corp, 'repo')
    creg = os.path.join(corp, 'reg')
    os.makedirs(creg)
    git('init', '-q', '--bare', origin, cwd=ROOT)
    git('init', '-q', '-b', 'dev', repo, cwd=ROOT)
    with open(os.path.join(repo, 'app.py'), 'w') as f:
        f.write('print("sup")\n')
    git('add', '-A', cwd=repo)
    git('commit', '-qm', 'SUP-2598: онбординг — экран приветствия', cwd=repo)
    git('remote', 'add', 'origin', origin, cwd=repo)
    git('push', '-qu', 'origin', 'dev', cwd=repo)
    git('checkout', '-qb', 'feature/SUP-2610-fix-modal', cwd=repo)
    with open(os.path.join(repo, 'modal.py'), 'w') as f:
        f.write('draft = True\n')
    git('add', '-A', cwd=repo)
    git('commit', '-qm', 'SUP-2610: плашка «черновик» при потере сети', cwd=repo)
    git('push', '-q', 'origin', 'feature/SUP-2610-fix-modal', cwd=repo)
    git('checkout', '-q', 'dev', cwd=repo)
    with open(os.path.join(repo, 'roles.py'), 'w') as f:
        f.write('roles = ["admin"]\n')
    git('add', '-A', cwd=repo)
    git('commit', '-qm', 'SUP-2603: ролевая модель — фикс доступа', cwd=repo)
    git('push', '-q', 'origin', 'dev', cwd=repo)
    git('init', '-q', '--bare', mdir, cwd=ROOT)
    write_conf(creg, 'sup', REPO=repo, MIRROR=mdir)
    nenv = env_for(corp, creg)
    make_src_tree(hws, 'sup')
    write_conf(hreg, 'sup', SRC=os.path.join(hws, 'sup'), MIRROR=mdir)
    henv = env_for(hws, hreg)

    new_cast()
    comment('# рабочий ноут (видит корп-gitlab): снимок состояния → зеркало', lead=0.3)
    type_cmd('pbx snapshot sup', lead=0.6)
    run_pty(['bash', PBX, 'snapshot', 'sup'], keys=[], env=nenv)
    comment('# дома (gitlab не виден): картина корп-репо ДО подготовки доставки')
    type_cmd('pbx corp sup')
    run_pty(['bash', PBX, 'corp', 'sup'], keys=[], env=henv)
    emit(1.4, '\x1b[1;32m$\x1b[0m ')
    emit(2.4, '\r\n')
    finish_cast(os.path.join(ROOT, 'corp.cast'),
                'pbx snapshot → pbx corp (Э3, обратный поток)')


def cast_guard():
    """Страховка deliver: guard на удалении → «n»; патч не лёг → откат без коммита."""
    base, hreg, nreg, ws = fresh('gd', 'gd-hreg', 'gd-nreg', 'gd-ws')
    corp = os.path.join(base, 'corp.git')
    mdir = os.path.join(base, 'mirror.git')
    nrepo = os.path.join(base, 'repo')
    hsrc = os.path.join(base, 'src')
    git('init', '-q', '--bare', corp, cwd=ROOT)
    git('init', '-q', '--bare', mdir, cwd=ROOT)
    git('init', '-q', '-b', 'dev', nrepo, cwd=ROOT)
    files = {'app.js': 'export const title = "Заявки"\n',
             'legacy.js': 'export const old = true\n'}
    for name, body in files.items():
        with open(os.path.join(nrepo, name), 'w') as f:
            f.write(body)
    git('add', '-A', cwd=nrepo)
    git('commit', '-qm', 'SUP-1: база', cwd=nrepo)
    git('remote', 'add', 'origin', corp, cwd=nrepo)
    git('push', '-qu', 'origin', 'dev', cwd=nrepo)
    write_conf(nreg, 'sup', REPO=nrepo, MIRROR=mdir, FORGE='none')
    nenv = env_for(ws, nreg)
    git('init', '-q', hsrc, cwd=ROOT)
    write_conf(hreg, 'sup', SRC=hsrc, MIRROR=mdir)
    henv = env_for(ws, hreg)
    # тихая подготовка: snapshot → две задачи дома от corp-dev → push обеих
    pbx_quiet(['snapshot', 'sup'], nenv)
    pbx_quiet(['start', 'sup', 'fix/cleanup'], henv)
    os.remove(os.path.join(hsrc, 'legacy.js'))
    pbx_quiet(['push', 'sup', 'fix/cleanup'], henv)
    git('checkout', '-q', '-f', '-b', 'fix/title', 'refs/remotes/pbx-mirror/corp-dev', cwd=hsrc)
    with open(os.path.join(hsrc, 'app.js'), 'w') as f:
        f.write('export const title = "Мои заявки"\n')
    pbx_quiet(['push', 'sup', 'fix/title'], henv)
    # коллега тем временем поменял ту же строку в корп-dev
    tmp = os.path.join(base, 'colleague')
    subprocess.run(['git', 'clone', '-q', '-b', 'dev', corp, tmp], env=GIT_ENV,
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(os.path.join(tmp, 'app.js'), 'w') as f:
        f.write('export const title = "Заявки ЦОД"\n')
    git('commit', '-qam', 'SUP-2: заголовок (чужой MR)', cwd=tmp)
    git('push', '-q', 'origin', 'dev', cwd=tmp)

    new_cast()
    comment('# ноут: guard показывает, что уедет в MR, удаления — отдельно', lead=0.3)
    type_cmd('pbx deliver sup feature/SUP-8 "SUP-8: чистка" --from fix/cleanup', lead=0.6)
    run_pty(['bash', PBX, 'deliver', 'sup', 'feature/SUP-8', 'SUP-8: чистка',
             '--from', 'fix/cleanup'],
            keys=[(3.8, b'n'), (0.6, b'\r')], env=nenv)
    comment('# в корп-dev уже поменяли ту же строку — патч не ляжет, откат сам')
    type_cmd('pbx deliver sup feature/SUP-9 "SUP-9: заголовок" --from fix/title')
    run_pty(['bash', PBX, 'deliver', 'sup', 'feature/SUP-9', 'SUP-9: заголовок',
             '--from', 'fix/title'], keys=[], env=nenv)
    type_cmd('git status -sb', lead=1.0)
    run_pty(['git', '-C', nrepo, 'status', '-sb'], keys=[], env=GIT_ENV)
    emit(1.6, '\x1b[1;32m$\x1b[0m ')
    emit(2.6, '\r\n')
    finish_cast(os.path.join(ROOT, 'guard.cast'),
                'deliver: guard и откат без коммита')


SCENARIOS = {
    'hero': cast_hero,
    'status': cast_status,
    'corp': cast_corp,
    'guard': cast_guard,
}


def main():
    names = sys.argv[1:] or list(SCENARIOS)
    for name in names:
        SCENARIOS[name]()


if __name__ == '__main__':
    main()
