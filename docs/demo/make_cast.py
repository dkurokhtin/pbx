#!/usr/bin/env python3
"""Генерация демо-каста pbx (asciicast v2) ЗАХВАТОМ РЕАЛЬНОЙ СЕССИИ через pty.

Сцены:
  1. `pbx`      — интерактивное меню: стрелки вниз/вверх, Enter → pack → выбор
                  проекта → настоящая упаковка (ui_section, размер, ✅).
  2. `pbx list` — TTY-таблица проектов (✓ SRC, размер/время архива).

Запуск:  python3 docs/demo/make_cast.py [выход.cast]
Рендер:  npx -y svg-term-cli --in demo.cast --out docs/pbx-demo.svg --window

Известные грабли (выстраданы):
  * первый event обязан быть на timestamp 0.0 — иначе стартовый кадр пуст;
  * ENV_ROOT в /tmp/pbx-demo — короткие пути влезают в 76 колонок;
  * LC_ALL=C.utf8 обязателен: без него pbx уходит в ASCII-глифы (> вместо ▸).
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
WS = os.path.join(ROOT, 'ws')
REG = os.path.join(ROOT, 'reg')
COLS, ROWS = 76, 22
MAX_GAP = 1.0   # паузы длиннее секунды сжимаем — демо не должно тянуться

ENV = {
    **{k: v for k, v in os.environ.items() if k in ('PATH', 'HOME')},
    'PBX_WORKSPACE': WS,
    'PBX_REGISTRY_DIR': REG,
    'TERM': 'xterm-256color',
    'LC_ALL': 'C.utf8',
    'COLUMNS': str(COLS),
    'LINES': str(ROWS),
}

events = []   # [t, 'o', data]
T = [0.0]


def emit(delay, data):
    T[0] = round(T[0] + delay, 3)
    events.append([T[0], 'o', data])


def type_cmd(cmd, lead=0.8):
    """Фабрикуем только строку приглашения — команда «печатается» посимвольно."""
    emit(lead, '\x1b[1;32m$\x1b[0m ')
    for ch in cmd:
        emit(0.06, ch)
    emit(0.45, '\r\n')


def run_pty(argv, keys):
    """Запустить argv под pty, скормить keys=[(задержка_до, bytes)], собрать вывод."""
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))
    p = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave,
                         env=ENV, close_fds=True)
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


def setup_env():
    # чистим ТОЛЬКО ws/reg: в ROOT могут лежать артефакты/инструменты (и cwd!)
    shutil.rmtree(WS, ignore_errors=True)
    shutil.rmtree(REG, ignore_errors=True)
    for proj in ('sup', 'vnd'):
        os.makedirs(os.path.join(WS, proj, 'src'))
        with open(os.path.join(WS, proj, 'src', 'app.js'), 'w') as f:
            f.write('console.log("hi from %s")\n' % proj)
    os.makedirs(REG)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'demo.cast')
    setup_env()

    # первый кадр строго на 0.0 И НЕ ПУСТОЙ: очистка + приглашение сразу,
    # иначе постер GIF/SVG — голый фон (см. грабли в шапке)
    events.append([0.0, 'o', '\x1b[2J\x1b[H\x1b[1;32m$\x1b[0m '])

    # Сцена 1: меню — вниз к log, обратно к pack, Enter; проект sup, Enter
    for ch in 'pbx':
        emit(0.5 if ch == 'p' else 0.07, ch)
    emit(0.45, '\r\n')
    run_pty(['bash', PBX], keys=[
        (1.4, b'\x1b[B'),   # ↓ deliver
        (0.7, b'\x1b[B'),   # ↓ log
        (0.9, b'\x1b[A'),   # ↑ deliver
        (0.5, b'\x1b[A'),   # ↑ pack
        (0.9, b'\r'),       # Enter → выбор проекта
        (1.3, b'\r'),       # Enter → sup (первый)
    ])

    # Сцена 2: таблица list (архив sup уже создан сценой 1 — видна разница)
    type_cmd('pbx list', lead=1.1)
    run_pty(['bash', PBX, 'list'], keys=[])

    emit(1.2, '\x1b[1;32m$\x1b[0m ')
    emit(2.0, '\r\n')

    header = {
        'version': 2, 'width': COLS, 'height': ROWS,
        'title': 'pbx — pack/deliver между машинами',
        'env': {'TERM': 'xterm-256color', 'SHELL': '/bin/bash'},
    }
    with open(out, 'w') as f:
        f.write(json.dumps(header, ensure_ascii=False) + '\n')
        for ev in events:
            f.write(json.dumps(ev, ensure_ascii=False) + '\n')
    print('cast: %s (%d events, %.1fs)' % (out, len(events), T[0]))


if __name__ == '__main__':
    main()
