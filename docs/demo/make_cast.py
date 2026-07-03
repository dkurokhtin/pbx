#!/usr/bin/env python3
"""Генерация демо-кастов pbx (asciicast v2) ЗАХВАТОМ РЕАЛЬНЫХ СЕССИЙ через pty.

Пять роликов — по одному на фичу (каждый в свой раздел README):
  hero    — меню (12 пунктов, прогулка до corp) → pack → list
  status  — сводка: дрейф от pack, зеркало, «SRC ушёл вперёд»
  mirror  — Э2: pbx push (дом) → pbx deliver --mirror (ноут), без архива
  corp    — Э3: pbx snapshot (ноут) → pbx corp (дом), обе стороны
  guard   — страховка deliver: удаления чужой работы → отказ (fail-closed)

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
    """Меню 12 пунктов (прогулка до corp и обратно) → pack sup → list."""
    ws, reg = fresh('hero/ws', 'hero/reg')
    make_src_tree(ws, 'sup', 'vnd')
    env = env_for(ws, reg)

    new_cast()
    type_cmd('pbx', lead=0.5, prompt=False)
    run_pty(['bash', PBX], env=env, keys=[
        (1.4, b'\x1b[B'),   # ↓ push
        (0.55, b'\x1b[B'),  # ↓ deliver
        (0.55, b'\x1b[B'),  # ↓ snapshot (Э3)
        (0.55, b'\x1b[B'),  # ↓ corp (Э3)
        (1.0, b'\x1b[A'), (0.4, b'\x1b[A'), (0.4, b'\x1b[A'), (0.4, b'\x1b[A'),
        (0.9, b'\r'),       # Enter → выбор проекта
        (1.3, b'\r'),       # Enter → sup (первый)
    ])
    type_cmd('pbx list', lead=1.1)
    run_pty(['bash', PBX, 'list'], keys=[], env=env)
    emit(1.2, '\x1b[1;32m$\x1b[0m ')
    emit(2.0, '\r\n')
    finish_cast(os.path.join(ROOT, 'hero.cast'), 'pbx — меню, pack, list')


def cast_status():
    """Сводка: дрейф от последнего pack + зеркало + «SRC ушёл вперёд»."""
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
    pbx_quiet(['pack', 'sup'], env)          # архив + мета
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
    finish_cast(os.path.join(ROOT, 'status.cast'), 'pbx status — дрейф и зеркало')


def cast_mirror():
    """Э2: pbx push (дом) → pbx deliver --mirror (ноут). Архив не нужен."""
    hsrc, hreg, mdir, gdir, nreg = fresh(
        'm2/src', 'm2/hreg', 'm2/mirror.git', 'm2/gitlab.git', 'm2/nreg')
    # дом: SRC-репо на фиче, широкая правка НЕ закоммичена (уедет в снапшот)
    git('init', '-q', '-b', 'feature/SUP-7-widget', hsrc, cwd=ROOT)
    with open(os.path.join(hsrc, 'app.js'), 'w') as f:
        f.write('console.log("app v1")\n')
    git('add', '-A', cwd=hsrc)
    git('commit', '-qm', 'SUP-7: база', cwd=hsrc)
    with open(os.path.join(hsrc, 'widget.js'), 'w') as f:
        f.write('export const widget = () => "hi"\n')   # незакоммиченное
    git('init', '-q', '--bare', mdir, cwd=ROOT)
    write_conf(hreg, 'sup', SRC=hsrc, MIRROR=mdir)
    henv = env_for(os.path.dirname(hsrc), hreg)
    # «ноут»: корп-gitlab (bare) + рабочий клон на dev
    git('init', '-q', '--bare', gdir, cwd=ROOT)
    nrepo = os.path.join(ROOT, 'm2', 'repo')
    git('init', '-q', '-b', 'dev', nrepo, cwd=ROOT)
    with open(os.path.join(nrepo, 'app.js'), 'w') as f:
        f.write('console.log("app v1")\n')
    git('add', '-A', cwd=nrepo)
    git('commit', '-qm', 'init', cwd=nrepo)
    git('remote', 'add', 'origin', gdir, cwd=nrepo)
    git('push', '-qu', 'origin', 'dev', cwd=nrepo)
    write_conf(nreg, 'sup', REPO=nrepo, MIRROR=mdir, FORGE='none')
    nenv = env_for(os.path.join(ROOT, 'm2'), nreg)

    new_cast()
    comment('# дома (gitlab не виден): рабочее дерево → личное зеркало', lead=0.3)
    type_cmd('pbx push sup', lead=0.6)
    run_pty(['bash', PBX, 'push', 'sup'], keys=[], env=henv)
    comment('# рабочий ноут (видит gitlab): доставка ИЗ зеркала, без архива')
    type_cmd('pbx deliver sup feature/SUP-7-widget "SUP-7: виджет" --mirror --yes')
    run_pty(['bash', PBX, 'deliver', 'sup', 'feature/SUP-7-widget',
             'SUP-7: виджет', '--mirror', '--yes'], keys=[], env=nenv)
    emit(1.4, '\x1b[1;32m$\x1b[0m ')
    emit(2.4, '\r\n')
    finish_cast(os.path.join(ROOT, 'mirror.cast'),
                'pbx push → deliver --mirror (Э2)')


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
    """Страховка deliver: устаревший снимок → удаления чужой работы → отказ."""
    gws, greg, gdir = fresh('g/ws', 'g/reg', 'g/origin.git')
    make_src_tree(gws, 'sup')
    git('init', '-q', '--bare', gdir, cwd=ROOT)
    repo = os.path.join(ROOT, 'g', 'repo')
    git('init', '-q', '-b', 'dev', repo, cwd=ROOT)
    os.makedirs(os.path.join(repo, 'src'))
    with open(os.path.join(repo, 'src', 'app.js'), 'w') as f:
        f.write('console.log("hi from sup")\n')
    with open(os.path.join(repo, 'roles.js'), 'w') as f:
        f.write('// чужая влитая работа (другой MR)\n')
    git('add', '-A', cwd=repo)
    git('commit', '-qm', 'dev: две фичи', cwd=repo)
    git('remote', 'add', 'origin', gdir, cwd=repo)
    git('push', '-qu', 'origin', 'dev', cwd=repo)
    write_conf(greg, 'sup', SRC=os.path.join(gws, 'sup'), REPO=repo, FORGE='none')
    env = env_for(gws, greg)
    pbx_quiet(['pack', 'sup'], env)   # архив из УСТАРЕВШЕГО дома (без roles.js)

    new_cast()
    comment('# архив собран из устаревшего дома — в dev уже влита чужая работа', lead=0.3)
    type_cmd('pbx deliver sup feature/SUP-9-fix "SUP-9: правка формы"', lead=0.6)
    run_pty(['bash', PBX, 'deliver', 'sup', 'feature/SUP-9-fix',
             'SUP-9: правка формы'],
            keys=[(4.5, b'n'), (0.6, b'\r')], env=env)
    emit(1.6, '\x1b[1;32m$\x1b[0m ')
    emit(2.6, '\r\n')
    finish_cast(os.path.join(ROOT, 'guard.cast'),
                'deliver-guard — fail-closed на удалениях')


SCENARIOS = {
    'hero': cast_hero,
    'status': cast_status,
    'mirror': cast_mirror,
    'corp': cast_corp,
    'guard': cast_guard,
}


def main():
    names = sys.argv[1:] or list(SCENARIOS)
    for name in names:
        SCENARIOS[name]()


if __name__ == '__main__':
    main()
