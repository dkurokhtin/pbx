# Pybotx — рабочее пространство

Окружение для разработки eXpress-ботов и SmartApp'ов команды rt-dc на едином стеке
(FastAPI + pybotx + SQLModel + Svelte 5).

## Главный принцип

**Контекст для агента ≠ код проекта.**

- Скиллы (pybotx, дизайн-система, конвенции) лежат в `Pybotx/.claude/skills/` — это
  **контекст для агента**, общий для всех проектов. В git-репозитории проектов он **НЕ
  коммитится** (под скиллы/дизайн есть отдельные репы).
- Папки проектов (`bot-support-cleaning/`, `smartapp-parking/`) — это **чистые
  репозитории**, как в GitLab. В доставку едет **только код**.

## Структура

```
Pybotx/
├── .claude/skills/            ← скиллы-контекст (НЕ коммитятся в репы)
│   ├── pybotx/                  справочник pybotx / fsm / smartapp-rpc / sdk + BotX API
│   ├── smartapps-ui/            UI-гайд фронтенда (Svelte 5, Skeleton, дизайн-токены)
│   └── team-conventions/        процесс, стек, стиль кода, доступы/админка (Kottster)
├── bot-support-cleaning/      ← чистый репозиторий бота (== GitLab)
├── smartapp-parking/          ← репозиторий SmartApp (== GitLab + текущие правки)
├── _dist/                     ← архивы для доставки (только код)
├── _source/                   ← исходники/референсы (архивы, workflow, дизайн, _trash)
├── update.sh                  ← доставка в GitLab (ветка от dev → MR в master)
└── pack.sh                    ← упаковка проекта в архив (контекст .claude исключается)
```

## Как работать

Открываешь проект (`bot-support-cleaning/` или `smartapp-parking/`) и ведёшь разработку.
Скиллы из `Pybotx/.claude/skills/` подхватываются автоматически и дают агенту контекст по
стеку и конвенциям. В сами репозитории проектов скиллы/доки-контекст не попадают.

## Доставка изменений в GitLab

`pack.sh` собирает архив проекта (без `.claude/`, `node_modules`, `.git`, `__pycache__`),
`update.sh` синхронизирует его в git-репозиторий (`PROJECTS_ROOT=/root`), создаёт ветку от
`dev`, коммитит и пушит MR в `master` (исключая `.git/` и `.gitlab-ci.yml`).

Сигнатура: `./update.sh <проект> <архив> <ветка> <сообщение-коммита>`.
Ветка — по конвенции `feature/PROJ-123-short-description`, коммит — кратко и по делу.

```bash
# 1) упаковать проект в архив (только код)
./pack.sh smartapp-parking
#    → _dist/smartapp-parking.tar.gz

# 2) доставить (на рабочем ноуте в WSL, репозиторий в /root)
cp /mnt/c/Users/darkl/Claude/Projects/Pybotx/_dist/smartapp-parking.tar.gz /root/
./update.sh smartapp-parking /root/smartapp-parking.tar.gz \
    feature/PARK-123-admin-roles-server-defaults \
    "Добавить server-default для admin_roles (id, granted_at, granted_by_huid)"
```

> В GitLab уходит только код проекта. Скиллы и любой агент-контекст (`.claude/`) в
> доставку не включаются. Разовая настройка git на ноуте при «dubious ownership»:
> `git config --global --add safe.directory /root/<project>`.
