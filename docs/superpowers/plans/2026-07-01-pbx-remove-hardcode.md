# pbx — убрать хардкод, пер-проектный конфиг: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Убрать оставшийся хардкод из `pbx` и ввести пер-проектный конфиг (ветки/env/forge/excludes), не меняя структуру команд.

**Architecture:** Все настройки резолвятся слоями: встроенные дефолты → глобальный `$WORKSPACE/.pbx.conf` → пер-проектный `$WORKSPACE/<проект>/.pbx.conf` → env `PBX_*` (побеждает). Конфиги — `source`-абельные bash-файлы. Логика выносится в изолированные функции (`load_config`, `list_projects`, `pack_exclude_args`, `sync_exclude_args`, `forge_push`), которые тестируются в отрыве от git-ремоутов; внешние команды в тестах подменяются функциями-заглушками.

**Tech Stack:** Bash (WSL), tar/unzip, rsync, git, gh. Тесты — чистый bash с мини-ассертами (bats недоступен).

## Global Constraints

- Целевой файл — один: `pbx` (в корне `WORKSPACE`). Легаси `pack.sh`/`update.sh` НЕ трогаем.
- Сохранить `set -euo pipefail` в `pbx`.
- Без новых внешних зависимостей: только уже доступные `git`, `rsync`, `tar`, `unzip`, `gh`.
- Все пользовательские сообщения — на русском, в стиле существующих (`c_blue`/`c_green`/`c_warn`/`die`, эмодзи).
- Поведение по умолчанию (без единого конфига) обязано совпадать с текущим: `BASE_BRANCH=dev`, `TARGET_BRANCH=master`, `DEFAULT_ENV=dev`, `FORGE=gitlab`, те же базовые excludes.
- `WORKSPACE` в тестах = временный каталог (`mktemp -d`); реальные проекты пользователя не модифицируются.
- Пути к файлам ниже даны от корня `WORKSPACE` = `/mnt/c/Users/darkl/Claude/Projects/Pybotx`.

## Файловая структура

- Modify: `pbx` — вся логика (функции + диспетчер + справка).
- Create: `_tests/test_pbx.sh` — набор тестов (каталог на `_`, чтобы `list_projects` его игнорировал).
- Create: `docs/superpowers/pbx.conf.example` — образец пер-проектного конфига (справочный, реальные проекты не трогаем).

## Ключевые интерфейсы (что появляется в `pbx`)

Функции и глобалы, на которые опираются задачи ниже (точные имена — соблюдать дословно):

- `load_config <project>` — сбрасывает и заполняет глобалы: `BASE_BRANCH`, `TARGET_BRANCH`, `DEFAULT_ENV`, `FORGE` (строки) и `EXTRA_PACK_EXCLUDES`, `EXTRA_SYNC_EXCLUDES` (массивы). Резолв по слоям (дефолт → глобальный → проектный → env).
- `list_projects` — печатает имена проектов (по одному в строке, `sort`), пропуская `_*`, `.*` и каталоги из `PBX_IGNORE_DIRS` (дефолт `docs`).
- `pack_exclude_args <project>` — печатает аргументы `--exclude=…` для `tar` (по одному в строке).
- `sync_exclude_args` — печатает аргументы `--exclude=…` для `rsync` (по одному в строке).
- `forge_push <branch> <msg>` — пушит ветку и создаёт MR/PR согласно `FORGE` (`gitlab`|`github`|`none`), использует `TARGET_BRANCH`.

---

## Task 1: Тест-харнесс + guard, чтобы `pbx` можно было `source` без запуска

**Files:**
- Create: `_tests/test_pbx.sh`
- Modify: `pbx:227` (замена финального `main "$@"`)

**Interfaces:**
- Consumes: ничего.
- Produces: файл тестов с ассерт-хелперами (`assert_eq`, `assert_has`, `assert_no`, `ok`, `bad`) и переменной `PBX` (путь к скрипту); guard в `pbx`, позволяющий `source "$PBX"` без исполнения `main`.

- [ ] **Step 1: Написать падающий тест** — `_tests/test_pbx.sh`

```bash
#!/usr/bin/env bash
# Тесты для pbx. Запуск: bash _tests/test_pbx.sh
set -uo pipefail   # НЕ -e: коды возврата проверяем сами

HERE="$(cd "$(dirname "$0")" && pwd)"
PBX="$HERE/../pbx"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
assert_eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (ожидал '$3', получил '$2')"; fi; }
assert_has() { case "$2" in *"$3"*) ok "$1";; *) bad "$1 (нет '$3' в: $2)";; esac; }
assert_no()  { case "$2" in *"$3"*) bad "$1 (не должно быть '$3')";; *) ok "$1";; esac; }

# --- Task 1 -----------------------------------------------------------------
test_source_no_run() {
  local out; out="$(bash -c 'source "'"$PBX"'"' 2>&1)"
  assert_eq "source не запускает main (пустой вывод)" "$out" ""
}

test_source_no_run

echo "--- Итог: PASS=$PASS FAIL=$FAIL ---"
[[ $FAIL -eq 0 ]]
```

- [ ] **Step 2: Запустить тест — убедиться, что падает**

Run: `bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh`
Expected: FAIL — `source` запускает `main` → печатается справка → вывод непустой → строка `FAIL source не запускает main`, итог `FAIL=1`, код возврата ≠ 0.

- [ ] **Step 3: Добавить guard в `pbx`**

Заменить последнюю строку `pbx`:

```bash
main "$@"
```

на:

```bash
# Запускаем main только при прямом вызове; при `source` (тесты) — нет.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

- [ ] **Step 4: Запустить тест — убедиться, что проходит**

Run: `bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh`
Expected: PASS — `ok source не запускает main`, итог `PASS=1 FAIL=0`, код возврата 0.

- [ ] **Step 5: Проверить, что обычный запуск не сломан**

Run: `/mnt/c/Users/darkl/Claude/Projects/Pybotx/pbx help`
Expected: печатается справка как раньше (guard срабатывает при прямом вызове).

- [ ] **Step 6: Коммит** (папка `Pybotx` не под git — коммит пропускаем, если `git rev-parse` падает)

```bash
cd /mnt/c/Users/darkl/Claude/Projects/Pybotx && \
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && \
{ git add pbx _tests/test_pbx.sh && git commit -m "test: харнесс pbx + guard для source"; } || \
echo "не git-репо — коммит пропущен"
```

---

## Task 2: `load_config` — слои конфигов и precedence

**Files:**
- Modify: `pbx:21-32` (блок настроек), `pbx` (добавить функцию `load_config` после утилит)
- Modify: `_tests/test_pbx.sh` (добавить тесты + верхнеуровневый `source`)

**Interfaces:**
- Consumes: глобал `WORKSPACE` (уже есть в `pbx`).
- Produces: `load_config <project>` → устанавливает `BASE_BRANCH`, `TARGET_BRANCH`, `DEFAULT_ENV`, `FORGE`, `EXTRA_PACK_EXCLUDES` (array), `EXTRA_SYNC_EXCLUDES` (array).

- [ ] **Step 1: Написать падающие тесты** — добавить в `_tests/test_pbx.sh` перед строкой `test_source_no_run` верхнеуровневую загрузку функций, а после — тесты.

Добавить сразу после блока с `assert_no()`:

```bash
# Грузим функции pbx в текущий шелл (main не запустится из-за guard)
source "$PBX"
set +eo pipefail   # source включил errexit из pbx — выключаем для тестов

# Утилита: создать временный WORKSPACE и вернуть путь
make_ws() { mktemp -d; }
```

Добавить тесты (после `test_source_no_run`, перед итоговой строкой):

```bash
# --- Task 2: load_config ----------------------------------------------------
test_defaults() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  unset PBX_BASE_BRANCH PBX_TARGET_BRANCH PBX_DEFAULT_ENV PBX_FORGE
  mkdir -p "$ws/proj"
  load_config "proj"
  assert_eq "дефолт BASE_BRANCH"   "$BASE_BRANCH"   "dev"
  assert_eq "дефолт TARGET_BRANCH" "$TARGET_BRANCH" "master"
  assert_eq "дефолт DEFAULT_ENV"   "$DEFAULT_ENV"   "dev"
  assert_eq "дефолт FORGE"         "$FORGE"         "gitlab"
  rm -rf "$ws"
}

test_project_over_global() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  unset PBX_TARGET_BRANCH
  mkdir -p "$ws/proj"
  printf 'TARGET_BRANCH=aaa\n' > "$ws/.pbx.conf"
  printf 'TARGET_BRANCH=bbb\n' > "$ws/proj/.pbx.conf"
  load_config "proj"
  assert_eq "проектный конфиг перебивает глобальный" "$TARGET_BRANCH" "bbb"
  rm -rf "$ws"
}

test_env_wins() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  mkdir -p "$ws/proj"
  printf 'TARGET_BRANCH=bbb\n' > "$ws/proj/.pbx.conf"
  PBX_TARGET_BRANCH=ccc load_config "proj"
  assert_eq "env перебивает проектный конфиг" "$TARGET_BRANCH" "ccc"
  unset PBX_TARGET_BRANCH
  rm -rf "$ws"
}

test_defaults
test_project_over_global
test_env_wins
```

- [ ] **Step 2: Запустить — убедиться, что падает**

Run: `bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh`
Expected: FAIL — `load_config: command not found` / ассерты падают (функции ещё нет).

- [ ] **Step 3: Реализовать в `pbx`**

3a. Заменить блок настроек `pbx:21-32` (оставить только глобальные пути; ветки/env/forge уходят в `load_config`):

```bash
# ===== Глобальные настройки (env-override) ==================================
# Где лежат ИСХОДНИКИ (рабочее пространство, видимое из WSL по /mnt/c):
WORKSPACE="${PBX_WORKSPACE:-/mnt/c/Users/darkl/Claude/Projects/Pybotx}"
# Где лежат git-репозитории (== GitLab) на рабочем ноуте:
PROJECTS_ROOT="${PBX_PROJECTS_ROOT:-/root}"
# Куда складывать архивы:
DIST_DIR="${PBX_DIST_DIR:-$WORKSPACE/_dist}"
# Каталоги WORKSPACE, которые НЕ являются проектами (кроме _* и .*):
PBX_IGNORE_DIRS="${PBX_IGNORE_DIRS:-docs}"
# Пер-проектные настройки (BASE_BRANCH/TARGET_BRANCH/DEFAULT_ENV/FORGE и
# excludes) резолвит load_config: дефолт → $WORKSPACE/.pbx.conf →
# $WORKSPACE/<проект>/.pbx.conf → env PBX_*.
# ============================================================================
```

3b. Добавить функцию `load_config` сразу после `strip_cr` (в блоке «утилиты»):

```bash
# Резолв настроек: дефолты → глобальный конфиг → проектный конфиг → env.
load_config() {
  local project="${1:-}"
  # 1) встроенные дефолты
  BASE_BRANCH="dev"
  TARGET_BRANCH="master"
  DEFAULT_ENV="dev"
  FORGE="gitlab"
  EXTRA_PACK_EXCLUDES=()
  EXTRA_SYNC_EXCLUDES=()
  # 2) глобальный конфиг
  [[ -f "$WORKSPACE/.pbx.conf" ]] && source "$WORKSPACE/.pbx.conf"
  # 3) пер-проектный конфиг
  [[ -n "$project" && -f "$WORKSPACE/$project/.pbx.conf" ]] && \
    source "$WORKSPACE/$project/.pbx.conf"
  # 4) env-override (всегда побеждает)
  [[ -n "${PBX_BASE_BRANCH:-}"   ]] && BASE_BRANCH="$PBX_BASE_BRANCH"
  [[ -n "${PBX_TARGET_BRANCH:-}" ]] && TARGET_BRANCH="$PBX_TARGET_BRANCH"
  [[ -n "${PBX_DEFAULT_ENV:-}"   ]] && DEFAULT_ENV="$PBX_DEFAULT_ENV"
  [[ -n "${PBX_FORGE:-}"         ]] && FORGE="$PBX_FORGE"
}
```

- [ ] **Step 4: Запустить — убедиться, что проходит**

Run: `bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh`
Expected: PASS по всем тестам Task 2 (`дефолт …`, `проектный конфиг перебивает глобальный`, `env перебивает проектный конфиг`), `FAIL=0`.

- [ ] **Step 5: Коммит**

```bash
cd /mnt/c/Users/darkl/Claude/Projects/Pybotx && \
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && \
{ git add pbx _tests/test_pbx.sh && git commit -m "feat: load_config со слоями конфига и precedence"; } || \
echo "не git-репо — коммит пропущен"
```

---

## Task 3: `list_projects`, команда `pbx list`, динамическая справка

**Files:**
- Modify: `pbx` (добавить `list_projects`, `cmd_list`; обновить `valid_project`, `cmd_help`, диспетчер)
- Modify: `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: `WORKSPACE`, `PBX_IGNORE_DIRS`.
- Produces: `list_projects` (печатает имена по строкам, `sort`); `cmd_list`; в `cmd_help`/`valid_project` больше нет зашитых имён проектов.

- [ ] **Step 1: Написать падающие тесты** — добавить в `_tests/test_pbx.sh`:

```bash
# --- Task 3: list_projects --------------------------------------------------
test_list_projects() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  unset PBX_IGNORE_DIRS
  mkdir -p "$ws/proj-a" "$ws/proj-b" "$ws/_dist" "$ws/docs" "$ws/.hidden"
  local out; out="$(list_projects)"
  assert_has "list: есть proj-a" "$out" "proj-a"
  assert_has "list: есть proj-b" "$out" "proj-b"
  assert_no  "list: нет _dist"   "$out" "_dist"
  assert_no  "list: нет docs"    "$out" "docs"
  assert_no  "list: нет .hidden" "$out" ".hidden"
  rm -rf "$ws"
}
test_list_projects
```

- [ ] **Step 2: Запустить — убедиться, что падает**

Run: `bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh`
Expected: FAIL — `list_projects: command not found`.

- [ ] **Step 3: Реализовать в `pbx`**

3a. Добавить функции (рядом с `valid_project`):

```bash
# Проекты = подкаталоги WORKSPACE, кроме служебных (_*, .*, PBX_IGNORE_DIRS).
list_projects() {
  local ignore=" ${PBX_IGNORE_DIRS:-docs} " d name
  for d in "$WORKSPACE"/*/; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    [[ "$name" == _* || "$name" == .* ]] && continue
    [[ "$ignore" == *" $name "* ]] && continue
    printf '%s\n' "$name"
  done | sort
}

cmd_list() {
  c_blue "🔵 Проекты в $WORKSPACE:"
  local any=0 p
  while IFS= read -r p; do c_green "  • $p"; any=1; done < <(list_projects)
  [[ "$any" -eq 1 ]] || c_warn "  (проектов не найдено)"
}
```

3b. Обновить `valid_project` — добавить в сообщение об ошибке список проектов:

```bash
valid_project() {
  local p="$1"
  [[ -d "$WORKSPACE/$p" ]] && return 0
  c_red "❌ Нет папки проекта: $WORKSPACE/$p"
  c_warn "   Доступные: $(list_projects | paste -sd', ' -)"
  exit 1
}
```

3c. В `cmd_help` убрать строку `Проекты: bot-support-cleaning | smartapp-parking` из heredoc и добавить строку про `pbx list`. Заменить статичную секцию проектов на подсказку. В heredoc `cmd_help` добавить строку команды:

```
  pbx list                                      показать проекты в WORKSPACE
```

и заменить строку `Проекты: bot-support-cleaning | smartapp-parking` на:

```
Проекты: см. `pbx list`
```

3d. В диспетчере `main` добавить ветку:

```bash
    list|ls)            cmd_list ;;
```

(между `ship)` и `help)`.)

3e. Обновить шапку-комментарий файла (`pbx:17`): строку `#    Проекты: bot-support-cleaning | smartapp-parking` заменить на `#    Проекты: см. pbx list`.

- [ ] **Step 4: Запустить — убедиться, что проходит**

Run: `bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh`
Expected: PASS по тестам Task 3, `FAIL=0`.

- [ ] **Step 5: Проверить команду вручную**

Run: `/mnt/c/Users/darkl/Claude/Projects/Pybotx/pbx list`
Expected: печатает `bot-support-cleaning` и `smartapp-parking` (реальные подкаталоги), без `_dist`/`_source`/`_backlog`/`docs`.

- [ ] **Step 6: Коммит**

```bash
cd /mnt/c/Users/darkl/Claude/Projects/Pybotx && \
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && \
{ git add pbx _tests/test_pbx.sh && git commit -m "feat: авто-обнаружение проектов + pbx list"; } || \
echo "не git-репо — коммит пропущен"
```

---

## Task 4: Билдеры excludes (`pack`/`rsync`) + `.pbx.conf` всегда исключён

**Files:**
- Modify: `pbx` (добавить `pack_exclude_args`, `sync_exclude_args`; переписать `cmd_pack` tar и `cmd_deliver` rsync на них; вызвать `load_config`)
- Modify: `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: `EXTRA_PACK_EXCLUDES`, `EXTRA_SYNC_EXCLUDES` (из `load_config`).
- Produces: `pack_exclude_args <project>` и `sync_exclude_args` (печатают `--exclude=…` по строкам).

- [ ] **Step 1: Написать падающие тесты** — добавить в `_tests/test_pbx.sh`:

```bash
# --- Task 4: exclude builders ----------------------------------------------
test_pack_excludes() {
  EXTRA_PACK_EXCLUDES=("dist" "coverage")
  local out; out="$(pack_exclude_args "proj")"
  assert_has "pack: базовый .git"       "$out" "--exclude=proj/.git"
  assert_has "pack: node_modules"       "$out" "--exclude=proj/node_modules"
  assert_has "pack: .pbx.conf исключён" "$out" "--exclude=proj/.pbx.conf"
  assert_has "pack: pyc"                "$out" "--exclude=*.pyc"
  assert_has "pack: extra dist"         "$out" "--exclude=proj/dist"
  assert_has "pack: extra coverage"     "$out" "--exclude=proj/coverage"
}
test_pack_excludes_empty() {
  EXTRA_PACK_EXCLUDES=()
  local out; out="$(pack_exclude_args "proj")"
  assert_has "pack(empty): базовый .git" "$out" "--exclude=proj/.git"
}
test_sync_excludes() {
  EXTRA_SYNC_EXCLUDES=("build")
  local out; out="$(sync_exclude_args)"
  assert_has "sync: .git/"              "$out" "--exclude=.git/"
  assert_has "sync: .gitlab-ci.yml"     "$out" "--exclude=.gitlab-ci.yml"
  assert_has "sync: .pbx.conf исключён" "$out" "--exclude=.pbx.conf"
  assert_has "sync: extra build"        "$out" "--exclude=build"
}
test_pack_excludes
test_pack_excludes_empty
test_sync_excludes
```

- [ ] **Step 2: Запустить — убедиться, что падает**

Run: `bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh`
Expected: FAIL — `pack_exclude_args: command not found`.

- [ ] **Step 3: Реализовать в `pbx`**

3a. Добавить функции (перед `cmd_pack`):

```bash
# Аргументы --exclude для tar (пути относительно WORKSPACE → с префиксом проекта).
pack_exclude_args() {
  local project="$1" e
  local base=( ".git" ".venv" "node_modules" "front/node_modules" \
               ".claude" "CLAUDE.md" ".pbx.conf" )
  for e in "${base[@]}"; do printf -- '--exclude=%s\n' "$project/$e"; done
  printf -- '--exclude=%s\n' '*/__pycache__'
  printf -- '--exclude=%s\n' '*.pyc'
  for e in "${EXTRA_PACK_EXCLUDES[@]:-}"; do
    [[ -n "$e" ]] && printf -- '--exclude=%s\n' "$project/$e"
  done
}

# Аргументы --exclude для rsync (относительно корня переноса).
sync_exclude_args() {
  local e
  local base=( ".git/" ".gitlab-ci.yml" "CLAUDE.md" ".claude/" ".pbx.conf" )
  for e in "${base[@]}"; do printf -- '--exclude=%s\n' "$e"; done
  for e in "${EXTRA_SYNC_EXCLUDES[@]:-}"; do
    [[ -n "$e" ]] && printf -- '--exclude=%s\n' "$e"
  done
}
```

3b. Переписать `cmd_pack` — вызвать `load_config` и собрать tar через билдер. Заменить тело от `valid_project "$project"` до вызова `tar …`:

```bash
cmd_pack() {
  local project; project="$(strip_cr "${1:?Использование: pbx pack <проект>}")"
  valid_project "$project"
  load_config "$project"
  mkdir -p "$DIST_DIR"
  local out="$DIST_DIR/$project.tar.gz"

  c_blue "🔵 Упаковка $project → $out"
  local excludes; mapfile -t excludes < <(pack_exclude_args "$project")
  tar -C "$WORKSPACE" "${excludes[@]}" -czf "$out" "$project"

  c_green "✅ Архив готов: $out"
  PBX_LAST_ARCHIVE="$out"   # для ship
}
```

3c. В `cmd_deliver` добавить `load_config "$project"` сразу после `[[ -d "$repo/.git" ]] || die …` (до `cd "$repo"`), и заменить блок rsync `rsync -a --delete --exclude=… "$inner"/ "$repo"/` на:

```bash
  c_blue "🔵 Синхронизирую файлы в $repo"
  local syncex; mapfile -t syncex < <(sync_exclude_args)
  rsync -a --delete "${syncex[@]}" "$inner"/ "$repo"/
```

- [ ] **Step 4: Запустить — убедиться, что проходит**

Run: `bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh`
Expected: PASS по тестам Task 4, `FAIL=0`.

- [ ] **Step 5: Коммит**

```bash
cd /mnt/c/Users/darkl/Claude/Projects/Pybotx && \
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && \
{ git add pbx _tests/test_pbx.sh && git commit -m "feat: конфигурируемые excludes для pack/rsync"; } || \
echo "не git-репо — коммит пропущен"
```

---

## Task 5: `forge_push` — универсальность по git-хостам (`gitlab`/`github`/`none`)

**Files:**
- Modify: `pbx` (добавить `forge_push`; заменить inline-push в `cmd_deliver`)
- Modify: `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: `FORGE`, `TARGET_BRANCH` (из `load_config`).
- Produces: `forge_push <branch> <msg>` — пушит и создаёт MR/PR по `FORGE`; неизвестный `FORGE` → `die`.

- [ ] **Step 1: Написать падающие тесты** — добавить в `_tests/test_pbx.sh`. Тесты подменяют `git`/`gh` заглушками-функциями, которые записывают вызовы в файл (`$CALLS`), а затем проверяют содержимое.

```bash
# --- Task 5: forge_push -----------------------------------------------------
CALLS=""
git() { printf 'git %s\n' "$*" >> "$CALLS"; }
gh()  { printf 'gh %s\n'  "$*" >> "$CALLS"; }

test_forge_gitlab() {
  CALLS="$(mktemp)"; FORGE="gitlab"; TARGET_BRANCH="master"
  forge_push "feature/X-1" "мой коммит"
  local out; out="$(cat "$CALLS")"
  assert_has "gitlab: merge_request.create" "$out" "merge_request.create"
  assert_has "gitlab: target=master"        "$out" "merge_request.target=master"
  assert_has "gitlab: push origin ветка"    "$out" "origin feature/X-1"
  rm -f "$CALLS"
}
test_forge_github() {
  CALLS="$(mktemp)"; FORGE="github"; TARGET_BRANCH="main"
  forge_push "feature/X-2" "second"
  local out; out="$(cat "$CALLS")"
  assert_has "github: git push origin" "$out" "git push origin feature/X-2"
  assert_has "github: gh pr create"    "$out" "gh pr create"
  assert_has "github: base main"       "$out" "--base main"
  assert_no  "github: без MR-опций"    "$out" "merge_request.create"
  rm -f "$CALLS"
}
test_forge_none() {
  CALLS="$(mktemp)"; FORGE="none"; TARGET_BRANCH="master"
  forge_push "feature/X-3" "third"
  local out; out="$(cat "$CALLS")"
  assert_has "none: push есть"       "$out" "git push origin feature/X-3"
  assert_no  "none: без MR"          "$out" "merge_request.create"
  assert_no  "none: без gh"          "$out" "gh pr create"
  rm -f "$CALLS"
}
test_forge_gitlab
test_forge_github
test_forge_none
unset -f git gh
```

- [ ] **Step 2: Запустить — убедиться, что падает**

Run: `bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh`
Expected: FAIL — `forge_push: command not found`.

- [ ] **Step 3: Реализовать в `pbx`**

3a. Добавить функцию (перед `cmd_deliver`):

```bash
# Пуш ветки + создание MR/PR согласно FORGE.
forge_push() {
  local branch="$1" msg="$2"
  case "$FORGE" in
    gitlab)
      git push -o merge_request.create \
               -o merge_request.target="$TARGET_BRANCH" \
               -o merge_request.title="$msg" \
               origin "$branch"
      ;;
    github)
      git push origin "$branch"
      gh pr create --base "$TARGET_BRANCH" --head "$branch" \
                   --title "$msg" --body "$msg"
      ;;
    none)
      git push origin "$branch"
      ;;
    *)
      die "Неизвестный FORGE: '$FORGE' (ожидается gitlab|github|none)"
      ;;
  esac
}
```

3b. В `cmd_deliver` заменить блок `git push -o merge_request.create … origin "$branch"` на:

```bash
  forge_push "$branch" "$msg"
```

3c. Обновить финальную строку `cmd_deliver` (сообщение об успехе), чтобы не утверждать «MR» для `none`:

```bash
  case "$FORGE" in
    none) c_green "✅ $project: ветка '$branch' от '$BASE_BRANCH' запушена (без MR/PR) — «$msg».";;
    *)    c_green "✅ $project: ветка '$branch' от '$BASE_BRANCH', MR/PR в '$TARGET_BRANCH' — «$msg».";;
  esac
```

- [ ] **Step 4: Запустить — убедиться, что проходит**

Run: `bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh`
Expected: PASS по тестам Task 5, `FAIL=0`.

- [ ] **Step 5: Коммит**

```bash
cd /mnt/c/Users/darkl/Claude/Projects/Pybotx && \
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && \
{ git add pbx _tests/test_pbx.sh && git commit -m "feat: forge_push (gitlab/github/none)"; } || \
echo "не git-репо — коммит пропущен"
```

---

## Task 6: E2E-тест `pack` + справка о конфиге + образец конфига

**Files:**
- Modify: `pbx` (`cmd_help` — секция про конфиг/FORGE; вызвать `load_config` в `cmd_deploy`/`cmd_ship`)
- Create: `docs/superpowers/pbx.conf.example`
- Modify: `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: всё предыдущее.
- Produces: end-to-end проверка, что `pbx pack` реально создаёт архив без `.pbx.conf`/`node_modules`, но с исходниками.

- [ ] **Step 1: Написать падающий E2E-тест** — добавить в `_tests/test_pbx.sh`:

```bash
# --- Task 6: e2e pack -------------------------------------------------------
test_pack_e2e() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"; DIST_DIR="$ws/_dist"
  unset PBX_TARGET_BRANCH PBX_FORGE
  mkdir -p "$ws/proj/src" "$ws/proj/node_modules"
  echo "print('hi')" > "$ws/proj/src/app.py"
  echo "junk"        > "$ws/proj/node_modules/x.js"
  printf 'TARGET_BRANCH=dev\nEXTRA_PACK_EXCLUDES=("secret")\n' > "$ws/proj/.pbx.conf"
  mkdir -p "$ws/proj/secret"; echo "s" > "$ws/proj/secret/k.txt"

  cmd_pack "proj" >/dev/null 2>&1

  local list; list="$(tar -tzf "$ws/_dist/proj.tar.gz")"
  assert_has "e2e: есть src/app.py"      "$list" "proj/src/app.py"
  assert_no  "e2e: нет node_modules"     "$list" "proj/node_modules"
  assert_no  "e2e: нет .pbx.conf"        "$list" "proj/.pbx.conf"
  assert_no  "e2e: нет extra secret"     "$list" "proj/secret"
  rm -rf "$ws"
}
test_pack_e2e
```

- [ ] **Step 2: Запустить — убедиться, что падает или проходит частично**

Run: `bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh`
Expected: если Task 4 сделан верно — тест уже проходит; если `.pbx.conf`/`secret` попадают в архив — FAIL. Тест фиксирует контракт e2e.

- [ ] **Step 3: Реализовать доводку в `pbx`**

3a. В `cmd_deploy` добавить `load_config "$project"` сразу после `valid`-проверки/до строки с `env="…${2:-$DEFAULT_ENV}"`, чтобы `DEFAULT_ENV` был из конфига. Переписать начало:

```bash
cmd_deploy() {
  local project env
  project="$(strip_cr "${1:?Использование: pbx deploy <проект> [env]}")"
  load_config "$project"
  env="$(strip_cr "${2:-$DEFAULT_ENV}")"
  ...
```

3b. В `cmd_ship` — аналогично: `load_config "$project"` до строки `env="$(strip_cr "${4:-$DEFAULT_ENV}")"`.

3c. В `cmd_help` heredoc добавить секцию про конфиг (после списка env-переменных):

```
Пер-проектный конфиг ($WORKSPACE/<проект>/.pbx.conf, необязателен):
  BASE_BRANCH=dev            от какой ветки ответвляемся
  TARGET_BRANCH=master       куда MR/PR
  DEFAULT_ENV=dev            окружение деплоя
  FORGE=gitlab               gitlab | github | none
  EXTRA_PACK_EXCLUDES=(dist)  доп. исключения упаковки
  EXTRA_SYNC_EXCLUDES=(build) доп. исключения синка
  Слои: дефолт → $WORKSPACE/.pbx.conf → проектный → env PBX_* (env побеждает).
```

- [ ] **Step 4: Создать образец конфига** — `docs/superpowers/pbx.conf.example`:

```bash
# Пример .pbx.conf — положи как <проект>/.pbx.conf (не коммитится, исключён из pack).
# Любой ключ необязателен; незаданное берётся из дефолтов/глобального конфига.

BASE_BRANCH=dev          # от какой ветки ответвляемся
TARGET_BRANCH=dev        # куда нацелен MR/PR (например, parking → dev)
DEFAULT_ENV=test         # окружение деплоя по умолчанию
FORGE=gitlab             # gitlab | github | none

# Доп. исключения (добавляются к встроенным .git/.venv/node_modules/.claude/…):
EXTRA_PACK_EXCLUDES=("dist" "coverage")
EXTRA_SYNC_EXCLUDES=("build")
```

- [ ] **Step 5: Запустить весь набор — убедиться, что всё зелёное**

Run: `bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh`
Expected: PASS по всем задачам (1–6), `FAIL=0`, код возврата 0.

- [ ] **Step 6: Ручная дым-проверка команд, не трогающих ремоут**

Run:
```bash
/mnt/c/Users/darkl/Claude/Projects/Pybotx/pbx help
/mnt/c/Users/darkl/Claude/Projects/Pybotx/pbx list
/mnt/c/Users/darkl/Claude/Projects/Pybotx/pbx pack smartapp-parking
tar -tzf /mnt/c/Users/darkl/Claude/Projects/Pybotx/_dist/smartapp-parking.tar.gz | grep -E '\.pbx\.conf|node_modules' || echo "OK: конфиг и node_modules исключены"
```
Expected: `help` показывает секцию конфига; `list` — реальные проекты; `pack` создаёт архив; `grep` ничего не находит → печатается «OK: …».

- [ ] **Step 7: Коммит**

```bash
cd /mnt/c/Users/darkl/Claude/Projects/Pybotx && \
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && \
{ git add pbx _tests/test_pbx.sh docs/superpowers/pbx.conf.example && \
  git commit -m "feat: справка о конфиге, load_config в deploy/ship, образец .pbx.conf"; } || \
echo "не git-репо — коммит пропущен"
```

---

## Self-Review (выполнено при написании плана)

- **Покрытие спека:**
  - Слои конфигов + precedence → Task 2 (тесты `defaults`/`project_over_global`/`env_wins`). ✅
  - Ключи `BASE/TARGET/DEFAULT_ENV/FORGE/EXTRA_*` → Task 2 + Task 4 + Task 5. ✅
  - `FORGE` gitlab/github/none → Task 5. ✅
  - Базовые excludes сохранены, конфиг добавляет; `.pbx.conf` не уезжает → Task 4 + Task 6 (e2e). ✅
  - Авто-обнаружение проектов + `pbx list` + чистый help → Task 3. ✅
  - Легаси не трогаем, структура команд та же → Global Constraints + правки только внутри `cmd_*`. ✅
  - Критерии приёмки 1–8 из спека → распределены по тестам Task 2/4/5/6 и ручным проверкам. ✅
- **Плейсхолдеры:** нет TBD/TODO; весь код приведён.
- **Согласованность типов/имён:** `load_config`, `list_projects`, `pack_exclude_args`, `sync_exclude_args`, `forge_push`, глобалы `BASE_BRANCH`/`TARGET_BRANCH`/`DEFAULT_ENV`/`FORGE`/`EXTRA_PACK_EXCLUDES`/`EXTRA_SYNC_EXCLUDES` — используются единообразно во всех задачах.
- **Замечание по спеку (критерий 3):** «env перебивает конфиг проекта» проверяется в Task 2 (`test_env_wins`) на `PBX_TARGET_BRANCH`, что соответствует формулировке критерия из спека.
