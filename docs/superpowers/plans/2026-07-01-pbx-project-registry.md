# pbx — реестр проектов: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Научить `pbx` паковать/доставлять проекты, лежащие вне единого `WORKSPACE`, через реестр `~/.config/pbx/projects/<имя>.conf`, не сломав текущую WORKSPACE-модель.

**Architecture:** `load_config` дополнительно источит реестровый файл и финализирует два пути — `SRC` (что паковать здесь) и `REPO` (куда доставлять), с fallback на `$WORKSPACE/<имя>` и `$PROJECTS_ROOT/<имя>`. `pack` пакует из `SRC`, `deliver` синкает в `REPO`. Базовые pack-excludes становятся рекурсивными (любой глубины). Добавляется команда `pbx add`. README переписывается под инструмент, легаси-скрипты удаляются.

**Tech Stack:** Bash (WSL), tar/rsync/git/gh. Тесты — чистый bash (`_tests/test_pbx.sh`), 41 тест уже есть.

## Global Constraints

- Целевой bash-файл один: `pbx`. Легаси `pack.sh`/`update.sh` — в этом плане УДАЛЯЮТСЯ (Task 6), до этого не трогать.
- Сохранить `set -euo pipefail`; все новые функции set-e/set-u-безопасны (заканчиваются детерминированным статусом, при необходимости `return 0`).
- Никаких новых внешних зависимостей (tar/rsync/git/gh/coreutils уже есть).
- Все пользовательские сообщения — на русском, в стиле существующих (`c_blue/c_green/c_warn/die`).
- Поведение Pybotx-проектов БЕЗ реестра не меняется (fallback `$WORKSPACE/<имя>`, `$PROJECTS_ROOT/<имя>`).
- Реестр: каталог `$PBX_REGISTRY_DIR` (дефолт `${XDG_CONFIG_HOME:-$HOME/.config}/pbx/projects`), файлы `<имя>.conf`, bash-source.
- Пути даны от корня репо = `/mnt/c/Users/darkl/Claude/Projects/Pybotx`.

## Файловая структура

- Modify: `pbx` — настройки, `load_config`, `pack_exclude_args`, `cmd_pack`, `cmd_deliver`, `list_projects`, `valid_project`, `cmd_help`, диспетчер; добавить `cmd_add`.
- Modify: `_tests/test_pbx.sh` — изоляция реестра в харнессе; новые тесты; правка тестов excludes.
- Rewrite: `README.md` — описание инструмента `pbx`.
- Delete: `pack.sh`, `update.sh`; правка `.gitignore`.

## Ключевые интерфейсы

- Глобал `PBX_REGISTRY_DIR` — каталог реестра.
- `load_config <имя>` — дополнительно источит `$PBX_REGISTRY_DIR/<имя>.conf`, устанавливает глобалы `SRC`, `REPO` (строки; с fallback), плюс прежние `BASE_BRANCH/TARGET_BRANCH/DEFAULT_ENV/FORGE/EXTRA_*`; чистит CRLF во всех скалярах включая `SRC`/`REPO`; `return 0`.
- `pack_exclude_args` — БЕЗ аргумента; печатает безымянные (нерекурсивно-якорные) `--exclude=…` (`node_modules`, `.git`, `.venv`, `__pycache__`, `.claude`, `CLAUDE.md`, `.pbx.conf`, `*.pyc`) + `EXTRA_PACK_EXCLUDES`; `return 0`.
- `list_projects` — печатает объединение (`$PBX_REGISTRY_DIR/*.conf` без `.conf`) ∪ (подпапки `$WORKSPACE`), `sort -u`.
- `valid_project <имя>` — валиден, если есть `$PBX_REGISTRY_DIR/<имя>.conf` ИЛИ `$WORKSPACE/<имя>`.
- `cmd_add <имя> [SRC]` — создаёт реестровый файл.

---

## Task 1: `PBX_REGISTRY_DIR` + разрешение `SRC`/`REPO` в `load_config`

**Files:**
- Modify: `pbx:30` (после `PBX_IGNORE_DIRS`), `pbx:47-73` (`load_config`)
- Modify: `_tests/test_pbx.sh` (изоляция реестра в харнессе + тесты)

**Interfaces:**
- Consumes: `WORKSPACE`, `PROJECTS_ROOT`.
- Produces: глобал `PBX_REGISTRY_DIR`; `load_config <имя>` дополнительно устанавливает `SRC`, `REPO`.

- [ ] **Step 1: Изолировать реестр в тест-харнессе** — чтобы тесты НЕ читали реальный `~/.config/pbx/projects`.

В `_tests/test_pbx.sh` сразу после строки `set +eo pipefail   # ...` (там, где выключается errexit после `source "$PBX"`) добавить:

```bash
# Изоляция: тесты не должны видеть реальный реестр пользователя
PBX_REGISTRY_DIR="$(mktemp -d)"   # пустой каталог по умолчанию
```

- [ ] **Step 2: Написать падающие тесты** — добавить в `_tests/test_pbx.sh` рядом с другими `load_config`-тестами:

```bash
# --- Task 1: реестр SRC/REPO -------------------------------------------------
test_registry_src_repo() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"; PROJECTS_ROOT="/root"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  unset PBX_BASE_BRANCH PBX_TARGET_BRANCH PBX_DEFAULT_ENV PBX_FORGE
  printf 'SRC=/home/me/sup\nREPO=/root/sup\nTARGET_BRANCH=dev\n' > "$reg/sup.conf"
  load_config "sup"
  assert_eq "реестр: SRC"           "$SRC"           "/home/me/sup"
  assert_eq "реестр: REPO"          "$REPO"          "/root/sup"
  assert_eq "реестр: TARGET_BRANCH" "$TARGET_BRANCH" "dev"
  rm -rf "$ws" "$reg"
}

test_registry_fallback() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"; PROJECTS_ROOT="/srv"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"   # пуст → нет записи
  mkdir -p "$ws/foo"
  load_config "foo"
  assert_eq "fallback: SRC = WORKSPACE/foo"      "$SRC"  "$ws/foo"
  assert_eq "fallback: REPO = PROJECTS_ROOT/foo" "$REPO" "/srv/foo"
  rm -rf "$ws" "$reg"
}

test_registry_crlf() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  printf 'SRC=/home/me/sup\r\nREPO=/root/sup\r\n' > "$reg/sup.conf"
  load_config "sup"
  assert_eq "реестр: SRC без CR"  "$SRC"  "/home/me/sup"
  assert_eq "реестр: REPO без CR" "$REPO" "/root/sup"
  rm -rf "$ws" "$reg"
}

test_registry_src_repo
test_registry_fallback
test_registry_crlf
```

- [ ] **Step 3: Запустить — убедиться, что падает**

Run: `bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh`
Expected: FAIL — `SRC`/`REPO` не устанавливаются (unbound под `set -u` внутри теста → ассерты падают/ошибка). Прочие тесты проходят.

- [ ] **Step 4: Реализовать в `pbx`**

4a. После строки `pbx:30` (`PBX_IGNORE_DIRS=…`) добавить:

```bash
# Каталог реестра проектов (имя → SRC/REPO + пер-проектные ключи):
PBX_REGISTRY_DIR="${PBX_REGISTRY_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/pbx/projects}"
```

4b. Заменить тело `load_config` (`pbx:47-73`) на:

```bash
load_config() {
  local project="${1:-}"
  # 1) встроенные дефолты
  BASE_BRANCH="dev"; TARGET_BRANCH="dev"; DEFAULT_ENV="dev"; FORGE="gitlab"
  EXTRA_PACK_EXCLUDES=(); EXTRA_SYNC_EXCLUDES=()
  SRC=""; REPO=""
  # 2) глобальный конфиг
  [[ -f "$WORKSPACE/.pbx.conf" ]] && source "$WORKSPACE/.pbx.conf"
  # 3) реестр проекта (центральный)
  [[ -n "$project" && -f "$PBX_REGISTRY_DIR/$project.conf" ]] && \
    source "$PBX_REGISTRY_DIR/$project.conf"
  # 4) в-проекте (SRC уже мог задаться реестром; иначе WORKSPACE/<имя>)
  local src_guess="${SRC:-$WORKSPACE/$project}"
  [[ -n "$project" && -f "$src_guess/.pbx.conf" ]] && source "$src_guess/.pbx.conf"
  # 5) env-override (всегда побеждает)
  [[ -n "${PBX_BASE_BRANCH:-}"   ]] && BASE_BRANCH="$PBX_BASE_BRANCH"
  [[ -n "${PBX_TARGET_BRANCH:-}" ]] && TARGET_BRANCH="$PBX_TARGET_BRANCH"
  [[ -n "${PBX_DEFAULT_ENV:-}"   ]] && DEFAULT_ENV="$PBX_DEFAULT_ENV"
  [[ -n "${PBX_FORGE:-}"         ]] && FORGE="$PBX_FORGE"
  # 6) финализация путей (fallback)
  SRC="${SRC:-$WORKSPACE/$project}"
  REPO="${REPO:-$PROJECTS_ROOT/$project}"
  # 7) защита от CRLF (конфиги на /mnt/c часто с \r), включая SRC/REPO
  local __v __i
  for __v in BASE_BRANCH TARGET_BRANCH DEFAULT_ENV FORGE SRC REPO; do
    printf -v "$__v" '%s' "${!__v//$'\r'/}"
  done
  for __i in "${!EXTRA_PACK_EXCLUDES[@]}"; do EXTRA_PACK_EXCLUDES[$__i]="${EXTRA_PACK_EXCLUDES[$__i]//$'\r'/}"; done
  for __i in "${!EXTRA_SYNC_EXCLUDES[@]}"; do EXTRA_SYNC_EXCLUDES[$__i]="${EXTRA_SYNC_EXCLUDES[$__i]//$'\r'/}"; done
  return 0
}
```

- [ ] **Step 5: Запустить — убедиться, что проходит**

Run: `bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh`
Expected: PASS по Task 1 (`реестр: SRC/REPO/…`, `fallback: …`, `реестр: SRC/REPO без CR`); прежние `load_config`-тесты (`test_defaults` и т.д.) — тоже PASS (реестр в харнессе пуст). `FAIL=0`.

- [ ] **Step 6: Коммит**

```bash
cd /mnt/c/Users/darkl/Claude/Projects/Pybotx && \
git add pbx _tests/test_pbx.sh && \
git commit -m "feat: PBX_REGISTRY_DIR + разрешение SRC/REPO в load_config"
```

---

## Task 2: Рекурсивные excludes + `cmd_pack` пакует из `SRC`

**Files:**
- Modify: `pbx:111-123` (`pack_exclude_args`), `pbx:139-153` (`cmd_pack`)
- Modify: `_tests/test_pbx.sh` (правка тестов excludes + новый e2e из SRC/реестра)

**Interfaces:**
- Consumes: `SRC`, `EXTRA_PACK_EXCLUDES` (из `load_config`).
- Produces: `pack_exclude_args` (без аргумента, безымянные excludes); `cmd_pack` пакует дерево `SRC`.

- [ ] **Step 1: Обновить/добавить тесты** — в `_tests/test_pbx.sh`:

(1a) Заменить `test_pack_excludes` и `test_pack_excludes_empty` на версии с безымянными excludes и вызовом `pack_exclude_args` без аргумента:

```bash
test_pack_excludes() {
  EXTRA_PACK_EXCLUDES=("dist" "coverage")
  local out; out="$(pack_exclude_args)"
  assert_has "pack: node_modules"       "$out" "--exclude=node_modules"
  assert_has "pack: .git"               "$out" "--exclude=.git"
  assert_has "pack: .pbx.conf исключён" "$out" "--exclude=.pbx.conf"
  assert_has "pack: pyc"                "$out" "--exclude=*.pyc"
  assert_has "pack: extra dist"         "$out" "--exclude=dist"
  assert_has "pack: extra coverage"     "$out" "--exclude=coverage"
  assert_no  "pack: без префикса имени" "$out" "--exclude=proj/"
  EXTRA_PACK_EXCLUDES=()
}
test_pack_excludes_empty() {
  EXTRA_PACK_EXCLUDES=()
  local out; out="$(pack_exclude_args)"
  assert_has "pack(empty): node_modules" "$out" "--exclude=node_modules"
}
```

(1b) В `test_exclude_builders_errexit_safe` заменить прямой вызов `pack_exclude_args proj` на `pack_exclude_args` (без аргумента). Строка внутри `bash -c` станет: `a="$(pack_exclude_args)"; b="$(sync_exclude_args)";`.

(1c) Добавить e2e-тест для реестрового проекта с вложенным `node_modules`:

```bash
test_pack_e2e_registry() {
  local base; base="$(make_ws)"
  local src="$base/sup"; local reg; reg="$(make_ws)"
  WORKSPACE="$base"; PBX_REGISTRY_DIR="$reg"; DIST_DIR="$base/_dist"
  unset PBX_TARGET_BRANCH PBX_FORGE
  mkdir -p "$src/sup-frontend/src" "$src/sup-frontend/node_modules" "$src/.git"
  echo "app"  > "$src/sup-frontend/src/app.js"
  echo "junk" > "$src/sup-frontend/node_modules/x.js"
  echo "g"    > "$src/.git/config"
  printf 'SRC=%s\n' "$src" > "$reg/sup.conf"

  cmd_pack "sup" >/dev/null 2>&1

  local list; list="$(tar -tzf "$base/_dist/sup.tar.gz")"
  assert_has "e2e-reg: есть sup-frontend/src/app.js" "$list" "sup/sup-frontend/src/app.js"
  assert_no  "e2e-reg: нет вложенного node_modules"  "$list" "node_modules"
  assert_no  "e2e-reg: нет .git"                     "$list" "sup/.git"
  rm -rf "$base" "$reg"
}
```

(1d) Добавить вызовы `test_pack_e2e_registry` в список вызовов (рядом с `test_pack_e2e`).

- [ ] **Step 2: Запустить — убедиться, что падает**

Run: `bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh`
Expected: FAIL — старая `pack_exclude_args` печатает `--exclude=proj/…` и требует аргумент; `test_pack_e2e_registry` падает (cmd_pack ещё пакует из `$WORKSPACE/<имя>`, а не из `SRC`).

- [ ] **Step 3: Реализовать в `pbx`**

3a. Заменить `pack_exclude_args` (`pbx:111-123`) на безымянную рекурсивную версию:

```bash
# Аргументы --exclude для tar. GNU tar не якорит паттерны → имя без пути
# исключает совпадения на любой глубине (node_modules в sup-frontend/ и т.п.).
pack_exclude_args() {
  local e
  local base=( node_modules .git .venv __pycache__ .claude CLAUDE.md .pbx.conf )
  for e in "${base[@]}"; do printf -- '--exclude=%s\n' "$e"; done
  printf -- '--exclude=%s\n' '*.pyc'
  for e in "${EXTRA_PACK_EXCLUDES[@]:-}"; do
    [[ -n "$e" ]] && printf -- '--exclude=%s\n' "$e"
  done
  return 0
}
```

3b. Заменить `cmd_pack` (`pbx:139-153`) на версию, пакующую из `SRC`:

```bash
cmd_pack() {
  local project; project="$(strip_cr "${1:?Использование: pbx pack <проект>}")"
  valid_project "$project"
  load_config "$project"
  [[ -d "$SRC" ]] || die "Нет исходников: $SRC"
  mkdir -p "$DIST_DIR"
  local out="$DIST_DIR/$project.tar.gz"

  c_blue "🔵 Упаковка $project ($SRC) → $out"
  local excludes; mapfile -t excludes < <(pack_exclude_args)
  tar -C "$(dirname "$SRC")" "${excludes[@]}" -czf "$out" "$(basename "$SRC")"

  c_green "✅ Архив готов: $out"
  PBX_LAST_ARCHIVE="$out"   # для ship
}
```

- [ ] **Step 4: Запустить — убедиться, что проходит**

Run: `bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh`
Expected: PASS — обновлённые `test_pack_excludes*`, `test_pack_e2e` (WORKSPACE-проект, `SRC=$WORKSPACE/proj`), `test_pack_e2e_registry`, `test_exclude_builders_errexit_safe`. `FAIL=0`.

- [ ] **Step 5: Коммит**

```bash
cd /mnt/c/Users/darkl/Claude/Projects/Pybotx && \
git add pbx _tests/test_pbx.sh && \
git commit -m "feat: рекурсивные excludes + cmd_pack пакует из SRC"
```

---

## Task 3: `cmd_deliver` доставляет в `REPO`

**Files:**
- Modify: `pbx:181-250` (`cmd_deliver` — вызвать `load_config` первым, использовать `$REPO`)
- Modify: `_tests/test_pbx.sh` (интеграционный тест deliver)

**Interfaces:**
- Consumes: `REPO`, `BASE_BRANCH`, `TARGET_BRANCH`, `FORGE`, `SRC` — из `load_config`.
- Produces: `deliver` синкает архив в `$REPO` и делает git-операции там.

- [ ] **Step 1: Написать падающий интеграционный тест** — в `_tests/test_pbx.sh`:

```bash
# --- Task 3: deliver в REPO из реестра (bare remote, FORGE=none) -------------
test_deliver_uses_repo() {
  local base; base="$(make_ws)"
  local remote="$base/remote.git" repo="$base/repo" src="$base/src"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  local dist="$base/_dist"; DIST_DIR="$dist"; mkdir -p "$dist"
  unset PBX_BASE_BRANCH PBX_TARGET_BRANCH PBX_FORGE

  git init -q --bare "$remote"
  git init -q "$repo"
  ( cd "$repo" \
    && git config user.email t@t && git config user.name t \
    && git remote add origin "$remote" \
    && git checkout -q -b dev \
    && echo old > file.txt && git add -A && git commit -q -m init \
    && git push -q -u origin dev ) >/dev/null 2>&1

  # источник с новым содержимым; архив как делает pack (один корневой каталог)
  mkdir -p "$src"; echo new > "$src/file.txt"; echo add > "$src/added.txt"
  tar -C "$(dirname "$src")" -czf "$dist/proj.tar.gz" "$(basename "$src")"

  printf 'SRC=%s\nREPO=%s\nBASE_BRANCH=dev\nTARGET_BRANCH=dev\nFORGE=none\n' \
    "$src" "$repo" > "$reg/proj.conf"

  cmd_deliver "proj" "feature/T-1" "тест" "$dist/proj.tar.gz" >/dev/null 2>&1

  assert_eq "deliver: файл синкнут в REPO" "$(cat "$repo/file.txt")" "new"
  assert_has "deliver: added.txt в REPO"   "$(ls "$repo")" "added.txt"
  local pushed; pushed="$(git -C "$remote" branch --list feature/T-1)"
  assert_has "deliver: ветка запушена в remote" "$pushed" "feature/T-1"
  rm -rf "$base" "$reg"
}
test_deliver_uses_repo
```

- [ ] **Step 2: Запустить — убедиться, что падает**

Run: `bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh`
Expected: FAIL — `cmd_deliver` использует `$PROJECTS_ROOT/proj` (не `$repo`), `.git`-проверка падает/`die` → файл не синкнут, ветка не запушена.

- [ ] **Step 3: Реализовать в `pbx`** — привести начало `cmd_deliver` к виду (вызвать `load_config` ПЕРВЫМ, взять `repo="$REPO"`).

Найти в `cmd_deliver` (`pbx:181-250`) блок разбора аргументов и определения `repo`. Заменить участок от конца разбора аргументов до `cd "$repo"` на:

```bash
  # Windows-путь → WSL (для archive)
  if command -v wslpath >/dev/null 2>&1 && [[ "$archive" == *:\\* || "$archive" == *:/* ]]; then
    archive="$(wslpath -u "$archive")"
  fi

  load_config "$project"
  local repo="$REPO"

  [[ -f "$archive" ]] || die "Архив не найден: $archive (сначала: pbx pack $project)"
  # Проверка конвенции ветки — предупреждаем, но не блокируем
  [[ "$branch" =~ ^(feature|fix|hotfix|bugfix|chore)/ ]] \
    || c_warn "⚠️  Ветка '$branch' не по конвенции feature/PROJ-123-… — продолжаю как есть."
  [[ -d "$repo/.git" ]] || die "Не git-репозиторий: $repo"

  cd "$repo"
```

(Порядок остального тела `cmd_deliver` — `git config core.fileMode false`, checkout/pull, распаковка во временную папку, rsync через `sync_exclude_args`, ветка/коммит/`forge_push`, сообщение — НЕ меняется. Если `load_config`/`archive`-нормализация уже присутствовали ниже — удалить их дубликаты, оставив единственный вызов из блока выше. Значение `archive` по умолчанию `$DIST_DIR/$project.tar.gz` сохраняется в разборе аргументов, как раньше.)

- [ ] **Step 4: Запустить — убедиться, что проходит**

Run: `bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh`
Expected: PASS — `test_deliver_uses_repo` (`файл синкнут`, `added.txt`, `ветка запушена`); все прежние тесты зелёные. `FAIL=0`.

- [ ] **Step 5: Коммит**

```bash
cd /mnt/c/Users/darkl/Claude/Projects/Pybotx && \
git add pbx _tests/test_pbx.sh && \
git commit -m "feat: cmd_deliver доставляет в REPO (реестр) + интеграционный тест"
```

---

## Task 4: `list_projects` — объединение реестра и WORKSPACE; `valid_project`

**Files:**
- Modify: `pbx:82-100` (`valid_project`, `list_projects`)
- Modify: `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: `PBX_REGISTRY_DIR`, `WORKSPACE`, `PBX_IGNORE_DIRS`.
- Produces: `list_projects` (реестр ∪ WORKSPACE, `sort -u`); `valid_project` (реестр ИЛИ WORKSPACE).

- [ ] **Step 1: Написать падающие тесты** — в `_tests/test_pbx.sh`:

```bash
# --- Task 4: list_projects объединение + valid_project ----------------------
test_list_union() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  unset PBX_IGNORE_DIRS
  mkdir -p "$ws/ws-proj" "$ws/_dist" "$ws/docs"
  : > "$reg/reg-proj.conf"; : > "$reg/ws-proj.conf"   # ws-proj есть и там, и там → без дублей
  local out; out="$(list_projects)"
  assert_has "union: реестровый reg-proj" "$out" "reg-proj"
  assert_has "union: workspace ws-proj"   "$out" "ws-proj"
  assert_no  "union: нет _dist"           "$out" "_dist"
  assert_no  "union: нет docs"            "$out" "docs"
  assert_eq  "union: ws-proj без дублей"  "$(echo "$out" | grep -c '^ws-proj$')" "1"
  rm -rf "$ws" "$reg"
}
test_list_union
```

- [ ] **Step 2: Запустить — убедиться, что падает**

Run: `bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh`
Expected: FAIL — `list_projects` не видит реестр (`reg-proj` отсутствует), возможны дубли `ws-proj`.

- [ ] **Step 3: Реализовать в `pbx`**

3a. Заменить `list_projects` (`pbx:91-100`) на объединение:

```bash
# Проекты = (реестр $PBX_REGISTRY_DIR/*.conf) ∪ (подпапки WORKSPACE, кроме служебных).
list_projects() {
  local ignore=" ${PBX_IGNORE_DIRS:-docs} " d name
  {
    if [[ -d "$PBX_REGISTRY_DIR" ]]; then
      for d in "$PBX_REGISTRY_DIR"/*.conf; do
        [[ -f "$d" ]] || continue
        printf '%s\n' "$(basename "$d" .conf)"
      done
    fi
    for d in "$WORKSPACE"/*/; do
      [[ -d "$d" ]] || continue
      name="$(basename "$d")"
      [[ "$name" == _* || "$name" == .* ]] && continue
      [[ "$ignore" == *" $name "* ]] && continue
      printf '%s\n' "$name"
    done
  } | sort -u
}
```

3b. Заменить `valid_project` (`pbx:82-90`) на реестр-осведомлённую версию:

```bash
valid_project() {
  local p="$1"
  [[ -f "$PBX_REGISTRY_DIR/$p.conf" ]] && return 0
  [[ -d "$WORKSPACE/$p" ]] && return 0
  c_red "❌ Проект не найден: $p"
  c_warn "   Есть: $(list_projects | paste -sd', ' -)"
  exit 1
}
```

- [ ] **Step 4: Запустить — убедиться, что проходит**

Run: `bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh`
Expected: PASS — `test_list_union` (реестр+ws, без дублей, без `_dist`/`docs`); `test_list_projects` (прежний) тоже PASS. `FAIL=0`.

- [ ] **Step 5: Коммит**

```bash
cd /mnt/c/Users/darkl/Claude/Projects/Pybotx && \
git add pbx _tests/test_pbx.sh && \
git commit -m "feat: list_projects = реестр ∪ WORKSPACE; valid_project учитывает реестр"
```

---

## Task 5: Команда `pbx add` + справка

**Files:**
- Modify: `pbx` (добавить `cmd_add` перед `cmd_help`; ветка `add)` в `main`; секция про реестр/add в `cmd_help`)
- Modify: `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: `PBX_REGISTRY_DIR`.
- Produces: `cmd_add <имя> [SRC]` — создаёт `$PBX_REGISTRY_DIR/<имя>.conf`.

- [ ] **Step 1: Написать падающие тесты** — в `_tests/test_pbx.sh`:

```bash
# --- Task 5: pbx add --------------------------------------------------------
test_add_creates_entry() {
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  local src; src="$(make_ws)"
  cmd_add "myproj" "$src" >/dev/null 2>&1
  assert_has "add: файл создан" "$(ls "$reg")" "myproj.conf"
  assert_has "add: SRC записан"  "$(cat "$reg/myproj.conf")" "SRC=$src"
  rm -rf "$reg" "$src"
}
test_add_refuses_overwrite() {
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  local src; src="$(make_ws)"
  printf 'SRC=old\n' > "$reg/myproj.conf"
  local rc=0
  ( cmd_add "myproj" "$src" ) >/dev/null 2>&1 || rc=$?
  assert_eq "add: не перезаписывает (ненулевой код)" "$rc" "1"
  assert_has "add: старое содержимое цело" "$(cat "$reg/myproj.conf")" "SRC=old"
  rm -rf "$reg" "$src"
}
test_add_creates_entry
test_add_refuses_overwrite
```

- [ ] **Step 2: Запустить — убедиться, что падает**

Run: `bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh`
Expected: FAIL — `cmd_add: command not found`.

- [ ] **Step 3: Реализовать в `pbx`**

3a. Добавить `cmd_add` перед `cmd_help`:

```bash
# ---- add -------------------------------------------------------------------
# Завести проект в реестр: $PBX_REGISTRY_DIR/<имя>.conf с SRC.
cmd_add() {
  local name src
  name="$(strip_cr "${1:?Использование: pbx add <имя> [путь-SRC]}")"
  src="$(strip_cr "${2:-$PWD}")"
  [[ -d "$src" ]] || die "Нет папки исходников: $src"
  src="$(cd "$src" && pwd)"
  mkdir -p "$PBX_REGISTRY_DIR"
  local f="$PBX_REGISTRY_DIR/$name.conf"
  [[ -e "$f" ]] && die "Уже в реестре: $f (отредактируй вручную)"
  cat > "$f" <<EOF
# Реестр pbx: проект $name
SRC=$src
# REPO=/root/$name       # цель доставки (иначе \$PROJECTS_ROOT/$name)
# BASE_BRANCH=dev
# TARGET_BRANCH=dev      # master-MR обычно вручную перед релизом
# FORGE=gitlab           # gitlab | github | none
EOF
  c_green "✅ Проект '$name' в реестре: $f"
  c_blue  "   SRC=$src — при необходимости отредактируй $f"
}
```

3b. В `main` (`pbx:321…`, `case`) добавить ветку рядом с `pack)`:

```bash
    add)                require_wsl; cmd_add "$@" ;;
```

3c. В `cmd_help` (heredoc) добавить строку команды `add` (рядом с `pack`):

```
  pbx add     <имя> [путь]                      завести проект в реестр (SRC=путь|$PWD)
```

и добавить секцию про реестр после секции про пер-проектный конфиг:

```
Реестр проектов ($PBX_REGISTRY_DIR, свой на каждой машине):
  <имя>.conf: SRC=<путь к исходникам здесь>   REPO=<git-репо для deliver>
  плюс BASE_BRANCH/TARGET_BRANCH/DEFAULT_ENV/FORGE/EXTRA_*.
  Проект берётся из реестра, иначе из $WORKSPACE/<имя> (SRC) и $PROJECTS_ROOT/<имя> (REPO).
```

- [ ] **Step 4: Запустить — убедиться, что проходит**

Run: `bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh`
Expected: PASS — `test_add_creates_entry`, `test_add_refuses_overwrite`; всё зелёное. `FAIL=0`.

- [ ] **Step 5: Ручная проверка**

Run: `/mnt/c/Users/darkl/Claude/Projects/Pybotx/pbx help`
Expected: в справке есть `pbx add`, секция «Реестр проектов», переменная `PBX_REGISTRY_DIR` не обязана быть в env-списке, но реестр описан.

- [ ] **Step 6: Коммит**

```bash
cd /mnt/c/Users/darkl/Claude/Projects/Pybotx && \
git add pbx _tests/test_pbx.sh && \
git commit -m "feat: команда pbx add + справка о реестре"
```

---

## Task 6: README под инструмент + удаление легаси-скриптов

**Files:**
- Rewrite: `README.md`
- Delete: `pack.sh`, `update.sh`
- Modify: `.gitignore` (убрать строки `!/pack.sh`, `!/update.sh`)

**Interfaces:** нет (документация + чистка).

- [ ] **Step 1: Переписать `README.md`** — заменить содержимое целиком на описание инструмента:

```markdown
# pbx — CLI доставки проектов

Единый bash-инструмент: упаковать проект, доставить архив в git-репозиторий и
создать MR/PR. Один и тот же `pbx` работает на обеих машинах: разработка и `pack`
на рабочей машине, `deliver` — там, где лежит git-репозиторий и есть доступ к
git-хосту. Копирование архива между машинами — вручную (scp/общая папка).

## Команды

    pbx add     <имя> [путь]                       завести проект в реестр (SRC=путь|$PWD)
    pbx list                                        показать проекты (реестр ∪ WORKSPACE)
    pbx pack    <имя>                               упаковать SRC в _dist/<имя>.tar.gz
    pbx deliver <имя> <ветка> <сообщение> [архив]   распаковать в REPO, ветка, коммит, MR/PR
    pbx deploy  <имя> [env]                         делегирует scripts/deploy.sh проекта
    pbx ship    <имя> <ветка> <сообщение> [env]     pack → deliver → deploy
    pbx help

## Реестр проектов

Проекты описываются в `$PBX_REGISTRY_DIR` (дефолт `~/.config/pbx/projects/`),
один файл `<имя>.conf` на проект — свой на каждой машине:

    SRC=/home/me/sup          # что паковать на ЭТОЙ машине (корень репо)
    REPO=/root/sup            # куда доставлять (иначе $PROJECTS_ROOT/<имя>)
    TARGET_BRANCH=dev         # + BASE_BRANCH / DEFAULT_ENV / FORGE / EXTRA_*

Если проекта нет в реестре — fallback: `SRC=$WORKSPACE/<имя>`, `REPO=$PROJECTS_ROOT/<имя>`.

## Слои настроек (побеждает верхний)

    встроенные дефолты → $WORKSPACE/.pbx.conf → реестр <имя>.conf → <SRC>/.pbx.conf → env PBX_*

## Переменные окружения

    PBX_WORKSPACE  PBX_PROJECTS_ROOT  PBX_DIST_DIR  PBX_REGISTRY_DIR
    PBX_BASE_BRANCH  PBX_TARGET_BRANCH  PBX_DEFAULT_ENV  PBX_FORGE  PBX_IGNORE_DIRS

## Рабочий процесс (двухмашинный)

    # рабочая машина
    pbx add sup /home/me/sup
    pbx pack sup                       # → _dist/sup.tar.gz (без node_modules/.git)
    scp _dist/sup.tar.gz work:/root/_dist/

    # машина с репозиторием
    pbx deliver sup feature/PROJ-123-fix "Починить X"

## FORGE

`gitlab` (push -o merge_request.*), `github` (`gh pr create`), `none` (просто push).

## Тесты

    bash _tests/test_pbx.sh

Пример конфига — `docs/superpowers/pbx.conf.example`.
```

- [ ] **Step 2: Удалить легаси-скрипты и почистить `.gitignore`**

```bash
cd /mnt/c/Users/darkl/Claude/Projects/Pybotx && \
git rm -q pack.sh update.sh
```

Затем в `.gitignore` удалить две строки:

```
!/pack.sh
!/update.sh
```

- [ ] **Step 3: Проверка — тесты и справка целы, репо чист**

Run:
```bash
bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh | tail -1
/mnt/c/Users/darkl/Claude/Projects/Pybotx/pbx help >/dev/null && echo "help OK"
cd /mnt/c/Users/darkl/Claude/Projects/Pybotx && git ls-files
```
Expected: `Итог: PASS=<N> FAIL=0`; `help OK`; `git ls-files` НЕ содержит `pack.sh`/`update.sh`, содержит обновлённый `README.md`.

- [ ] **Step 4: Коммит**

```bash
cd /mnt/c/Users/darkl/Claude/Projects/Pybotx && \
git add README.md .gitignore && \
git commit -m "docs: README под инструмент pbx; удалены легаси pack.sh/update.sh"
```

---

## Self-Review (выполнено при написании плана)

- **Покрытие спека:**
  - Реестр `$PBX_REGISTRY_DIR/<имя>.conf`, поля SRC/REPO/пер-проектные → Task 1. ✅ (крит. 1 частично — файл; создание в Task 5)
  - Разрешение SRC/REPO + fallback + env + CRLF → Task 1 (`test_registry_*`). ✅ (крит. 4)
  - `pack` из SRC + рекурсивные excludes → Task 2 (`test_pack_excludes*`, `test_pack_e2e_registry`). ✅ (крит. 2, 5)
  - Pybotx без реестра работает как раньше → Task 2 (`test_pack_e2e` на WORKSPACE-проекте). ✅ (крит. 3)
  - `deliver` в REPO → Task 3 (`test_deliver_uses_repo`). ✅ (крит. 7)
  - `list_projects` объединение → Task 4 (`test_list_union`). ✅ (крит. 6)
  - `pbx add` (+ отказ перезаписи) → Task 5. ✅ (крит. 1)
  - `set -e`/легаси/поведение без реестра → Global Constraints + Task 6 удаляет легаси, тесты зелёные. ✅ (крит. 8)
- **Плейсхолдеров нет** (TBD/TODO/«обработать ошибки») — весь код приведён.
- **Согласованность имён:** `PBX_REGISTRY_DIR`, `SRC`, `REPO`, `load_config`, `pack_exclude_args` (без арг.), `cmd_pack`, `cmd_deliver`, `list_projects`, `valid_project`, `cmd_add` — единообразны во всех задачах и тестах.
- **Замечание:** харнесс-изоляция реестра (Task 1 Step 1) критична — без неё `list_projects`/`load_config`-тесты читали бы реальный `~/.config/pbx/projects`. Учтено.
