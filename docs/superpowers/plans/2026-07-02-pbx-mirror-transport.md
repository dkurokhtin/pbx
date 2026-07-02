# pbx Э2 — git-транспорт через зеркала: план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `pbx push <проект> [ветка]` (снапшот рабочего дерева SRC → ветка личного GitHub-зеркала) и `pbx deliver ... --mirror` (доставка из зеркала существующим rsync/guard-путём); MIRROR= в реестре; пункт меню; README.

**Architecture:** Механики проверены research-агентами вживую (гонки, потери данных в отвергнутых вариантах). Снапшот — теневой индекс + commit-tree parent-chain, push без --force. Доставка — вариант В: fetch+archive наполняет тот же tmp, что раньше наполнял архив; rsync-ядро/guard/trap deliver НЕ меняются. Спека: `docs/superpowers/specs/2026-07-02-pbx-mirror-transport-design.md`. Проверенный код-референс: `.superpowers/sdd/e2-push-code.md`, `.superpowers/sdd/e2-deliver-code.md` (адаптирован в тасках ниже — таски самодостаточны).

**Tech Stack:** bash ≥ 5, git (fetch/commit-tree/write-tree/archive), tar, rsync, timeout. Без новых зависимостей.

## Global Constraints

- Файл `pbx` — ОДИН самодостаточный bash-скрипт.
- **SRC неприкосновенен**: push не меняет HEAD/index/staging/stash/`.git/config` SRC (никаких `git remote add`; допустимый след — только `.git/FETCH_HEAD`).
- **deliver без `--mirror` работает байт-в-байт как раньше** (архивный путь — регресс-тест обязателен); guard, rsync-ядро, trap, тексты, коды возврата cmd_deliver не ослабляются и не переписываются — меняется ТОЛЬКО источник наполнения tmp при `--mirror`.
- Все сетевые git-вызовы: `GIT_TERMINAL_PROMPT=0` + `timeout 30` (не виснуть на промпте/чёрной дыре) + понятная ошибка.
- **Валидация SHA** (`_pbx_is_sha`) перед КАЖДЫМ push: пустой src-ref в refspec = УДАЛЕНИЕ ветки на remote (воспроизведено).
- Pathspec-исключения: только длинная форма `:(glob,exclude)`, обе глоб-формы `**/имя` и `**/имя/**` (короткая `:!` падает на `__pycache__`; без `**/` вложенные node_modules утекают — воспроизведено).
- Тесты: ВСЕ сетевые операции — на локальных bare-репо (пути как URL); НИКАКИХ обращений к реальному GitHub.
- Дисциплина set -euo pipefail (read с ||, `local x; x=$(...)` раздельно, функции с return 0, dirty-подсчёт без пайпа).
- Прогон: `cd /mnt/c/Users/darkl/Claude/Projects/Pybotx && bash _tests/test_pbx.sh` → FAIL=0.
- Ветка: `feature/pbx-mirror-transport` (создаётся в Task 1). Правки в месте.

---

### Task 1: `pack_exclude_pathspecs`, `_pbx_is_sha`, MIRROR в конфиге

**Files:**
- Modify: `pbx` (load_config: дефолт/env/CRLF для MIRROR; новая секция `# ---- push ---` после секции status, перед forge_push)
- Test: `_tests/test_pbx.sh`

**Interfaces:**
- Produces: `MIRROR` — ключ конфига (слои как у всех: дефолт `''` → конфиги → env `PBX_MIRROR`; CRLF-strip).
- Produces: `pack_exclude_pathspecs()` — stdout: по ДВЕ строки на каждое имя из `pack_exclude_args()` (кроме `.git`): `:(glob,exclude)**/<имя>` и `:(glob,exclude)**/<имя>/**`.
- Produces: `_pbx_is_sha <строка>` — rc 0 ⇔ полный 40-hex SHA.

- [ ] **Step 1: Создать ветку**

```bash
cd /mnt/c/Users/darkl/Claude/Projects/Pybotx
git checkout -b feature/pbx-mirror-transport
```

- [ ] **Step 2: Написать падающие тесты**

В `_tests/test_pbx.sh` после `test_pad_helpers_multibyte` (и его регистрации — соответственно) добавить:

```bash
# --- Э2: pathspec-исключения, SHA-валидация, MIRROR ------------------------------
test_pack_exclude_pathspecs_forms() {
  EXTRA_PACK_EXCLUDES=()
  local out; out="$(pack_exclude_pathspecs)"
  assert_has "pathspec: длинная форма node_modules"    "$out" ":(glob,exclude)**/node_modules"
  assert_has "pathspec: содержимое node_modules"       "$out" ":(glob,exclude)**/node_modules/**"
  assert_has "pathspec: __pycache__ длинной формой"    "$out" ":(glob,exclude)**/__pycache__"
  assert_no  "pathspec: .git не эмитится"              "$out" "**/.git"
  assert_no  "pathspec: короткой формы :! нет"         "$out" ":!"
}

test_pack_exclude_pathspecs_extra() {
  EXTRA_PACK_EXCLUDES=("dist")
  local out; out="$(pack_exclude_pathspecs)"
  assert_has "pathspec: EXTRA dist"            "$out" ":(glob,exclude)**/dist"
  assert_has "pathspec: EXTRA dist содержимое" "$out" ":(glob,exclude)**/dist/**"
  EXTRA_PACK_EXCLUDES=()
}

test_pbx_is_sha() {
  local rc=0
  _pbx_is_sha "0123456789abcdef0123456789abcdef01234567" || rc=$?
  assert_eq "sha: валидный 40-hex → 0" "$rc" "0"
  rc=0; _pbx_is_sha "" || rc=$?
  assert_eq "sha: пустая строка → 1" "$rc" "1"
  rc=0; _pbx_is_sha "abc" || rc=$?
  assert_eq "sha: короткая → 1" "$rc" "1"
  rc=0; _pbx_is_sha "0123456789ABCDEF0123456789abcdef01234567" || rc=$?
  assert_eq "sha: верхний регистр → 1" "$rc" "1"
}

test_load_config_mirror() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  unset PBX_MIRROR
  mkdir -p "$ws/proj"
  printf 'MIRROR=git@github.com:me/proj.git\r\n' > "$reg/proj.conf"   # с CRLF
  load_config proj
  assert_eq "MIRROR из реестра, без CR" "$MIRROR" "git@github.com:me/proj.git"
  PBX_MIRROR="https://x/y.git" load_config proj
  assert_eq "env PBX_MIRROR побеждает" "$MIRROR" "https://x/y.git"
  unset PBX_MIRROR
  load_config nonexistent-proj-xyz
  assert_eq "MIRROR дефолт — пусто" "$MIRROR" ""
  rm -rf "$ws" "$reg"
}
```

Регистрация (после `test_pad_helpers_multibyte`):

```bash
test_pack_exclude_pathspecs_forms
test_pack_exclude_pathspecs_extra
test_pbx_is_sha
test_load_config_mirror
```

- [ ] **Step 3: Прогнать — падают** (`pack_exclude_pathspecs: command not found`; MIRROR unbound/пуст)

- [ ] **Step 4: Реализация**

4a. В `load_config`: в шаге «1) встроенные дефолты» к строке `SRC=""; REPO=""` добавить `MIRROR=""`; в шаге env-override добавить строку:

```bash
  [[ -n "${PBX_MIRROR:-}"       ]] && MIRROR="$PBX_MIRROR"
```

и в CRLF-цикле `for __v in BASE_BRANCH TARGET_BRANCH FORGE SRC REPO` добавить `MIRROR` в список.

4b. Новая секция ПОСЛЕ секции status (после `cmd_status`), перед `# ---- deliver` или `forge_push` (по фактическому порядку файла — сразу после status-функций):

```bash
# =============================================================================
#  push (Э2): снапшот РАБОЧЕГО ДЕРЕВА SRC → ветка личного GitHub-зеркала.
#  Механика проверена вживую (см. спеку §4): теневой индекс поверх КОПИИ
#  реального, commit-tree с parent-chain, push БЕЗ --force.
#  SRC (HEAD/индекс/staging/stash/.git/config) не трогаем НИГДЕ.
# =============================================================================

# Транслирует pack_exclude_args() (единственный источник истины об исключениях)
# в git-pathspec той же unanchored-семантики, что tar --exclude.
# ВАЖНО (воспроизведено): короткая форма ':!ИМЯ' падает fatal-ом на именах с
# ведущим '_' (__pycache__: "Unimplemented pathspec magic '_'") — только длинная
# ':(glob,exclude)'. Без '**/' матч только на верхнем уровне (вложенные
# node_modules утекли бы) — нужны ОБЕ формы: '**/ИМЯ' и '**/ИМЯ/**'.
pack_exclude_pathspecs() {
  local line name
  while IFS= read -r line; do
    [[ "$line" == --exclude=* ]] || continue
    name="${line#--exclude=}"
    [[ -n "$name" ]] || continue
    [[ "$name" == ".git" ]] && continue   # git add сам никогда не тронет .git
    printf ':(glob,exclude)**/%s\n' "$name"
    printf ':(glob,exclude)**/%s/**\n' "$name"
  done < <(pack_exclude_args)
  return 0
}

# Полный 40-hex SHA? Перед КАЖДЫМ push обязательна: пустой src-ref в refspec
# (git push M "":refs/heads/B) — это синтаксис УДАЛЕНИЯ ветки на remote.
_pbx_is_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
```

- [ ] **Step 5: Прогнать — зелёные** → `FAIL=0`

- [ ] **Step 6: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(push): pathspec-трансляция pack-excludes, SHA-валидация, MIRROR в конфиге"
```

---

### Task 2: `snapshot_tree` — дерево рабочего дерева через теневой индекс

**Files:**
- Modify: `pbx` (секция push, после `_pbx_is_sha`)
- Test: `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: `pack_exclude_pathspecs`, `_pbx_is_sha`, `c_warn` (Task 1).
- Produces: `snapshot_tree <SRC>` — stdout: SHA дерева (write-tree) текущего рабочего дерева (staged+unstaged+untracked, минус excludes, с уважением .gitignore для untracked); rc≠0 + c_warn при сбое. SRC не мутируется.

- [ ] **Step 1: Написать падающие тесты**

```bash
# --- Э2: snapshot_tree -------------------------------------------------------------
# Фикстура: git-репо с .gitignore(*.log), staged+unstaged+untracked правками,
# вложенным node_modules, tracked-но-ignored файлом с правкой (реальный кейс).
_mk_snapshot_fixture() {
  SN_SRC="$(make_ws)"
  ( cd "$SN_SRC" \
    && git init -q . && git config user.email t@t && git config user.name t \
    && printf '*.log\n' > .gitignore \
    && mkdir -p app sub/nested/node_modules/pkg node_modules/x .claude \
    && echo base > tracked.txt && echo code > app/main.py \
    && echo old > important.log && git add -f important.log \
    && echo ctx > CLAUDE.md && echo s > .claude/cfg \
    && echo junk1 > node_modules/x/j.js && echo junk2 > sub/nested/node_modules/pkg/j.js \
    && git add .gitignore tracked.txt app/main.py \
    && git commit -qm init \
    && echo staged >> tracked.txt && git add tracked.txt \
    && echo unstaged >> app/main.py \
    && echo brandnew > sub/nested/new.txt \
    && echo edited >> important.log \
    && echo noise > debug.log ) >/dev/null 2>&1
}

test_snapshot_tree_contents() {
  _mk_snapshot_fixture
  local tree; tree="$(cd "$SN_SRC" && snapshot_tree "$SN_SRC")"
  local rc=$?; assert_eq "snapshot: rc=0" "$rc" "0"
  local files; files="$(git -C "$SN_SRC" ls-tree -r --name-only "$tree")"
  assert_has "snapshot: staged-правка"        "$files" "tracked.txt"
  assert_has "snapshot: unstaged-файл"        "$files" "app/main.py"
  assert_has "snapshot: untracked-файл"       "$files" "sub/nested/new.txt"
  assert_has "snapshot: tracked-но-ignored"   "$files" "important.log"
  assert_no  "snapshot: без node_modules"     "$files" "node_modules"
  assert_no  "snapshot: без CLAUDE.md"        "$files" "CLAUDE.md"
  assert_no  "snapshot: без .claude"          "$files" ".claude"
  assert_no  "snapshot: gitignored untracked отфильтрован" "$files" "debug.log"
  # содержимое, не только имена: правки реально в дереве
  assert_has "snapshot: правка staged в дереве" \
    "$(git -C "$SN_SRC" cat-file -p "$tree:tracked.txt")" "staged"
  assert_has "snapshot: правка tracked-ignored в дереве" \
    "$(git -C "$SN_SRC" cat-file -p "$tree:important.log")" "edited"
  rm -rf "$SN_SRC"
}

test_snapshot_tree_src_untouched() {
  _mk_snapshot_fixture
  local head0 status0 index_before
  head0="$(git -C "$SN_SRC" rev-parse HEAD)"
  status0="$(git -C "$SN_SRC" status --porcelain)"   # status может освежить index (racy-git) — снимаем копию ПОСЛЕ него
  index_before="$(make_ws)/index.bin"
  cp "$SN_SRC/.git/index" "$index_before"
  snapshot_tree "$SN_SRC" >/dev/null
  # cmp — ПЕРВЫМ (до любых git status, которые сами трогают index)
  if cmp -s "$index_before" "$SN_SRC/.git/index"; then
    ok "SRC: .git/index байт-в-байт прежний"
  else
    bad "SRC: .git/index ИЗМЕНЁН"
  fi
  assert_eq "SRC: HEAD не тронут"   "$(git -C "$SN_SRC" rev-parse HEAD)" "$head0"
  assert_eq "SRC: status не тронут" "$(git -C "$SN_SRC" status --porcelain)" "$status0"
  assert_eq "SRC: stash пуст" "$(git -C "$SN_SRC" stash list)" ""
  rm -rf "$SN_SRC" "$(dirname "$index_before")"
}

test_snapshot_tree_orphan_src() {
  local src; src="$(make_ws)"
  ( cd "$src" && git init -q . && echo x > f.txt ) >/dev/null 2>&1
  local tree rc=0
  tree="$( (cd "$src" && snapshot_tree "$src") )" || rc=$?
  assert_eq "orphan SRC: rc=0" "$rc" "0"
  assert_has "orphan SRC: файл в дереве" \
    "$(git -C "$src" ls-tree -r --name-only "$tree")" "f.txt"
  rm -rf "$src"
}
```

Регистрация после `test_load_config_mirror`: `test_snapshot_tree_contents`, `test_snapshot_tree_src_untouched`, `test_snapshot_tree_orphan_src`.

- [ ] **Step 2: Прогнать — падают** (`snapshot_tree: command not found`)

- [ ] **Step 3: Реализация** — в секцию push после `_pbx_is_sha`:

```bash
# snapshot_tree <SRC> → SHA дерева (write-tree) ТЕКУЩЕГО рабочего дерева SRC
# (staged+unstaged+untracked минус excludes). Весь монтаж — в теневом индексе
# (GIT_INDEX_FILE); реальный .git/index только ЧИТАЕТСЯ (cp).
# Грабли (обе воспроизведены):
#  - существующий ПУСТОЙ файл индекса → fatal "index file smaller than expected";
#    отсутствующий путь — ок. Поэтому mktemp → сразу rm -f.
#  - теневой индекс сеем КОПИЕЙ реального: с пустым индексом файл, трекнутый ДО
#    появления его паттерна в .gitignore, с незакоммиченной правкой — молча
#    теряет правку (git add -A считает его новым untracked и режет по ignore).
#    Untracked-мусор при этом по-прежнему фильтруется .gitignore — осознанное
#    отличие от pack (секреты не уезжают в личное зеркало; спека §2.1 п.4).
snapshot_tree() {
  local src="$1"
  local real_index tmp_index
  real_index="$(git -C "$src" rev-parse --git-path index 2>/dev/null || true)"
  [[ -n "$real_index" ]] || { c_warn "snapshot: не git-репозиторий: $src"; return 1; }
  [[ "$real_index" == /* ]] || real_index="$src/$real_index"

  tmp_index="$(mktemp -t pbx-push-index.XXXXXX)" || { c_warn "snapshot: mktemp не удался"; return 1; }
  if [[ -f "$real_index" ]]; then
    cp -- "$real_index" "$tmp_index" \
      || { rm -f "$tmp_index"; c_warn "snapshot: не удалось скопировать индекс"; return 1; }
  else
    rm -f "$tmp_index"   # свежий репо без коммитов — старт с пустого индекса
  fi

  local -a pathspecs=(".")
  local ps
  while IFS= read -r ps; do pathspecs+=("$ps"); done < <(pack_exclude_pathspecs)

  # вывод git ловим в переменные: warning на stderr не должен испортить $tree
  local add_out
  if ! add_out="$(GIT_INDEX_FILE="$tmp_index" git -C "$src" add -A -- "${pathspecs[@]}" 2>&1)"; then
    rm -f "$tmp_index"
    c_warn "snapshot: git add в теневой индекс не удался: $add_out"
    return 1
  fi

  local tree
  if ! tree="$(GIT_INDEX_FILE="$tmp_index" git -C "$src" write-tree 2>/dev/null)"; then
    rm -f "$tmp_index"
    c_warn "snapshot: write-tree не удался"
    return 1
  fi
  rm -f "$tmp_index"
  _pbx_is_sha "$tree" || { c_warn "snapshot: write-tree вернул не SHA ('$tree')"; return 1; }
  printf '%s\n' "$tree"
  return 0
}
```

- [ ] **Step 4: Прогнать — зелёные** → `FAIL=0`

- [ ] **Step 5: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(push): snapshot_tree — дерево рабочего дерева через теневой индекс, SRC нетронут"
```

---

### Task 3: `push_snapshot` + `cmd_push` + диспетчер/help

**Files:**
- Modify: `pbx` (секция push после snapshot_tree; `main()` case; обе ветки `cmd_help`; `cmd_add` — подсказка MIRROR)
- Test: `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: `snapshot_tree`, `_pbx_is_sha`, `MIRROR` (Tasks 1–2), `ui_section/ui_kv`, `valid_project`, `load_config`, `strip_cr`, `die`, `c_*`.
- Produces: `push_snapshot <SRC> <MIRROR> <ветка> <проект>` — stdout: SHA снапшот-коммита; ПУСТОЙ stdout + rc=0 = «изменений нет»; rc≠0 = ошибка. `cmd_push <проект> [ветка]` (дефолт ветки — текущая ветка SRC).

- [ ] **Step 1: Написать падающие тесты**

```bash
# --- Э2: push_snapshot / cmd_push (зеркало = локальный bare) -----------------------
_mk_push_fixture() {
  PU_BASE="$(make_ws)"
  PU_SRC="$PU_BASE/src"; PU_MIRROR="$PU_BASE/mirror.git"
  git init -q --bare "$PU_MIRROR"
  mkdir -p "$PU_SRC"
  ( cd "$PU_SRC" && git init -q . && git config user.email t@t && git config user.name t \
    && echo v1 > f.txt && git add -A && git commit -qm init \
    && echo v2-uncommitted >> f.txt ) >/dev/null 2>&1
}

test_push_snapshot_first_and_ff() {
  _mk_push_fixture
  local sha1 sha2
  sha1="$( (cd "$PU_SRC" && push_snapshot "$PU_SRC" "$PU_MIRROR" "feature/T-1" proj) 2>/dev/null )"
  if _pbx_is_sha "$sha1"; then ok "push: первый снапшот запушен"; else bad "push: первый снапшот не SHA: '$sha1'"; fi
  assert_has "push: ветка создана в зеркале" \
    "$(git -C "$PU_MIRROR" branch --list 'feature/T-1')" "feature/T-1"
  assert_has "push: незакоммиченная правка в снапшоте" \
    "$(git -C "$PU_MIRROR" show "feature/T-1:f.txt")" "v2-uncommitted"
  # второй снапшот с новой правкой — fast-forward (parent-chain), БЕЗ force
  ( cd "$PU_SRC" && echo v3 >> f.txt ) >/dev/null 2>&1
  sha2="$( (cd "$PU_SRC" && push_snapshot "$PU_SRC" "$PU_MIRROR" "feature/T-1" proj) 2>/dev/null )"
  if _pbx_is_sha "$sha2"; then ok "push: второй снапшот запушен"; else bad "push: второй не SHA"; fi
  assert_has "push: parent-chain (первый — предок второго)" \
    "$(git -C "$PU_MIRROR" rev-list "feature/T-1")" "$sha1"
  rm -rf "$PU_BASE"
}

test_push_snapshot_no_changes() {
  _mk_push_fixture
  ( cd "$PU_SRC" && push_snapshot "$PU_SRC" "$PU_MIRROR" "feature/T-2" proj ) >/dev/null 2>&1
  local n_before; n_before="$(git -C "$PU_MIRROR" rev-list --count 'feature/T-2')"
  local out rc=0
  out="$( (cd "$PU_SRC" && push_snapshot "$PU_SRC" "$PU_MIRROR" "feature/T-2" proj) 2>/dev/null )" || rc=$?
  assert_eq "push: без изменений rc=0"        "$rc"  "0"
  assert_eq "push: без изменений stdout пуст" "$out" ""
  assert_eq "push: без изменений — новых коммитов в зеркале нет" \
    "$(git -C "$PU_MIRROR" rev-list --count 'feature/T-2')" "$n_before"
  rm -rf "$PU_BASE"
}

test_push_snapshot_concurrent_commit_survives() {
  _mk_push_fixture
  ( cd "$PU_SRC" && push_snapshot "$PU_SRC" "$PU_MIRROR" "feature/T-3" proj ) >/dev/null 2>&1
  # «конкурент» двигает ветку зеркала
  local other; other="$(make_ws)"
  git clone -q "$PU_MIRROR" "$other/clone" 2>/dev/null
  ( cd "$other/clone" && git config user.email o@o && git config user.name o \
    && git checkout -q feature/T-3 && echo alien > alien.txt && git add -A \
    && git commit -qm alien && git push -q origin feature/T-3 ) >/dev/null 2>&1
  # наш следующий снапшот должен пройти И сохранить чужой коммит достижимым
  ( cd "$PU_SRC" && echo v4 >> f.txt ) >/dev/null 2>&1
  local sha; sha="$( (cd "$PU_SRC" && push_snapshot "$PU_SRC" "$PU_MIRROR" "feature/T-3" proj) 2>/dev/null )"
  if _pbx_is_sha "$sha"; then ok "push: после чужого коммита прошёл"; else bad "push: не прошёл после чужого коммита"; fi
  assert_has "push: чужой коммит достижим (не потерян)" \
    "$(git -C "$PU_MIRROR" log --format=%s 'feature/T-3')" "alien"
  rm -rf "$PU_BASE" "$other"
}

test_cmd_push_requires_mirror() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  mkdir -p "$ws/proj"; ( cd "$ws/proj" && git init -q . ) >/dev/null 2>&1
  local rc=0
  ( cmd_push proj ) >/dev/null 2>&1 || rc=$?
  assert_eq "cmd_push: без MIRROR → die" "$rc" "1"
  rm -rf "$ws" "$reg"
}

test_cmd_push_default_branch_is_src_branch() {
  _mk_push_fixture
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  printf 'SRC=%s\nMIRROR=%s\n' "$PU_SRC" "$PU_MIRROR" > "$reg/proj.conf"
  ( cd "$PU_SRC" && git checkout -qb feature/T-55 ) >/dev/null 2>&1
  ( cmd_push proj ) >/dev/null 2>&1
  assert_has "cmd_push: дефолт ветки = текущая ветка SRC" \
    "$(git -C "$PU_MIRROR" branch --list 'feature/T-55')" "feature/T-55"
  rm -rf "$PU_BASE" "$ws" "$reg"
}
```

Регистрация после снапшот-тестов Task 2 (5 функций по порядку).

- [ ] **Step 2: Прогнать — падают** (`push_snapshot: command not found`)

- [ ] **Step 3: Реализация** — в секцию push после `snapshot_tree`:

```bash
# push_snapshot <SRC> <MIRROR> <ветка> <проект>
# Снапшот-коммит с parent-chain [tip ветки зеркала (fetch→FETCH_HEAD), SRC HEAD]
# → push БЕЗ --force (fast-forward по построению). Гонка → штатный отказ git →
# bounded retry (3). Пустой снапшот (дерево == дереву tip) → rc=0, stdout пуст.
# MIRROR — сырой URL/путь: git remote в SRC НЕ регистрируем (.git/config чист).
push_snapshot() {
  local src="$1" mirror="$2" branch="$3" project="${4:-project}"
  [[ -e "$src/.git" ]] || { c_warn "push: не git-репозиторий: $src"; return 1; }

  local tree
  tree="$(snapshot_tree "$src")" || return 1
  _pbx_is_sha "$tree" || { c_warn "push: битое дерево — отмена, ничего не пушу"; return 1; }

  local src_head orig_branch
  src_head="$(git -C "$src" rev-parse -q --verify HEAD 2>/dev/null || true)"
  orig_branch="$(git -C "$src" branch --show-current 2>/dev/null || true)"
  [[ -n "$orig_branch" ]] || orig_branch="(detached)"

  local attempt max_attempts=3
  for attempt in $(seq 1 "$max_attempts"); do
    # tip ветки зеркала: fetch (не ls-remote — объект нужен локально для -p);
    # FETCH_HEAD — служебный файл, постоянных refs в SRC не остаётся.
    local remote_tip=""
    if GIT_TERMINAL_PROMPT=0 timeout 30 git -C "$src" fetch -q "$mirror" "$branch" 2>/dev/null; then
      remote_tip="$(git -C "$src" rev-parse -q --verify FETCH_HEAD 2>/dev/null || true)"
    fi

    # пустой снапшот: дерево не отличается от дерева tip — пушить нечего
    if _pbx_is_sha "$remote_tip"; then
      local remote_tree
      remote_tree="$(git -C "$src" rev-parse -q --verify "$remote_tip^{tree}" 2>/dev/null || true)"
      if [[ "$remote_tree" == "$tree" ]]; then
        c_warn "push: изменений нет — снапшот совпадает с '$branch' на зеркале."
        return 0
      fi
    fi

    local -a parent_args=()
    _pbx_is_sha "$remote_tip" && parent_args+=(-p "$remote_tip")
    _pbx_is_sha "$src_head"   && parent_args+=(-p "$src_head")
    # без единого parent — валидный root-коммит (свежий SRC без коммитов)

    local msg commit_sha
    msg="$(printf 'pbx push: снапшот %s\n\nsource-branch: %s\nsource-commit: %s\nmirror-parent: %s\n' \
      "$project" "$orig_branch" "${src_head:-—}" "${remote_tip:-—}")"
    if ! commit_sha="$(git -C "$src" commit-tree "$tree" ${parent_args[@]+"${parent_args[@]}"} -m "$msg" 2>&1)"; then
      c_warn "push: commit-tree не удался: $commit_sha"
      return 1
    fi
    # КРИТИЧНО: пустой src-ref в refspec = УДАЛЕНИЕ ветки на remote.
    if ! _pbx_is_sha "$commit_sha"; then
      c_warn "push: commit-tree вернул не SHA ('$commit_sha') — отмена (пуш пустого ref удалил бы ветку!)"
      return 1
    fi

    local out
    if out="$(GIT_TERMINAL_PROMPT=0 timeout 30 git -C "$src" push "$mirror" "$commit_sha:refs/heads/$branch" 2>&1)"; then
      printf '%s\n' "$commit_sha"
      return 0
    fi
    c_warn "push: попытка $attempt/$max_attempts отклонена (гонка на зеркале?):"
    printf '%s\n' "$out" >&2
  done
  c_warn "push: не удалось за $max_attempts попыток"
  return 1
}

cmd_push() {
  local project; project="$(strip_cr "${1:?Использование: pbx push <проект> [ветка]}")"
  PBX_CURRENT_PROJECT="$project"
  valid_project "$project"
  load_config "$project"
  [[ -e "$SRC/.git" ]] || die "SRC не git-репозиторий: $SRC"
  [[ -n "${MIRROR:-}" ]] || die "Не задан MIRROR для '$project'. Добавь MIRROR=git@github.com:<user>/<repo>.git в $PBX_REGISTRY_DIR/$project.conf"

  local branch; branch="$(strip_cr "${2:-}")"
  if [[ -z "$branch" ]]; then
    branch="$(git -C "$SRC" branch --show-current 2>/dev/null || true)"
    [[ -n "$branch" ]] || die "Не удалось определить текущую ветку SRC — укажи ветку явно: pbx push $project <ветка>"
  fi

  ui_section "Push $project → зеркало" "🔵 Push $project → $MIRROR ($branch)"
  ui_kv MIRROR "$MIRROR"
  ui_kv BRANCH "$branch"
  local sha
  sha="$(push_snapshot "$SRC" "$MIRROR" "$branch" "$project")" || die "pbx push не удался (см. вывод выше)"
  if [[ -z "$sha" ]]; then
    return 0   # «изменений нет» — push_snapshot уже сообщил
  fi
  c_green "✅ $project: снапшот рабочего дерева ушёл в зеркало веткой '$branch' (${sha:0:7})"
  ui_summary "$branch" "$MIRROR" "снапшот ${sha:0:7} (вкл. незакоммиченное)"
  return 0
}
```

- [ ] **Step 4: Диспетчер, help, add-подсказка**

4a. `main()` case, после `pack)`:

```bash
    push)               require_wsl; cmd_push "$@" ;;
```

4b. help plain-heredoc, после строки `pbx pack`:

```
  pbx push    <проект> [ветка]                  снапшот рабочего дерева SRC → ветка личного зеркала (MIRROR)
```

help TTY-heredoc, после строки pack:

```
  ${C_CYAN}pbx push${C_RESET}    <проект> [ветка]        ${C_DIM}снапшот рабочего дерева → ветка зеркала (MIRROR)${C_RESET}
```

4c. В `cmd_add` heredoc-шаблон конфига: после строки `# REPO=...` добавить:

```
# MIRROR=git@github.com:<user>/$name.git   # личное зеркало для pbx push/deliver --mirror
```

- [ ] **Step 5: Прогнать — зелёные** → `FAIL=0`

- [ ] **Step 6: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(push): pbx push — снапшот в зеркало с parent-chain, без --force, с retry"
```

---

### Task 4: `deliver --mirror` — источник из зеркала

**Files:**
- Modify: `pbx` (`cmd_deliver`: разбор флага `--mirror`; условный блок наполнения tmp)
- Test: `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: `MIRROR` из конфига; существующий cmd_deliver-путь (rsync/guard/forge_push) — НЕ переписывается.
- Produces: `cmd_deliver <проект> <ветка> <сообщение> [--mirror] [--yes]` — при `--mirror` архив не нужен; ветка зеркала = <ветка> доставки.

- [ ] **Step 1: Написать падающие тесты**

```bash
# --- Э2: deliver --mirror ------------------------------------------------------------
_mk_mirror_deliver_fixture() {
  MD_BASE="$(make_ws)"
  MD_REMOTE="$MD_BASE/gitlab.git"; MD_MIRROR="$MD_BASE/mirror.git"
  MD_REPO="$MD_BASE/repo"; MD_SRC="$MD_BASE/src"
  MD_REG="$(make_ws)"; PBX_REGISTRY_DIR="$MD_REG"
  DIST_DIR="$MD_BASE/_dist"; mkdir -p "$DIST_DIR"
  git init -q --bare "$MD_REMOTE"; git init -q --bare "$MD_MIRROR"
  git init -q "$MD_REPO"
  ( cd "$MD_REPO" && git config user.email t@t && git config user.name t \
    && git remote add origin "$MD_REMOTE" && git checkout -q -b dev \
    && echo keep > file.txt && echo role > roles.txt && echo ci > .gitlab-ci.yml \
    && git add -A && git commit -qm init && git push -qu origin dev ) >/dev/null 2>&1
  # SRC: правка file.txt, УДАЛЕНИЕ roles.txt, новый new.txt (+ незакоммиченное)
  mkdir -p "$MD_SRC"
  ( cd "$MD_SRC" && git init -q . && git config user.email t@t && git config user.name t \
    && echo changed > file.txt && echo fresh > new.txt \
    && git add -A && git commit -qm snap \
    && echo more >> new.txt ) >/dev/null 2>&1
  ( cd "$MD_SRC" && push_snapshot "$MD_SRC" "$MD_MIRROR" "feature/M-1" proj ) >/dev/null 2>&1
  printf 'SRC=%s\nREPO=%s\nMIRROR=%s\nBASE_BRANCH=dev\nTARGET_BRANCH=dev\nFORGE=none\n' \
    "$MD_SRC" "$MD_REPO" "$MD_MIRROR" > "$MD_REG/proj.conf"
}

test_deliver_mirror_e2e() {
  _mk_mirror_deliver_fixture
  ( cmd_deliver proj "feature/M-1" "mirror-доставка" --mirror --yes </dev/null ) >/dev/null 2>&1
  assert_eq  "mirror-deliver: правка доехала"    "$(cat "$MD_REPO/file.txt")" "changed"
  assert_has "mirror-deliver: новый файл доехал (с незакоммиченным)" "$(cat "$MD_REPO/new.txt")" "more"
  [[ -f "$MD_REPO/roles.txt" ]] && bad "mirror-deliver: удаление НЕ отражено" || ok "mirror-deliver: удаление отражено"
  assert_eq  "mirror-deliver: .gitlab-ci.yml жив (sync-exclude)" "$(cat "$MD_REPO/.gitlab-ci.yml")" "ci"
  assert_has "mirror-deliver: ветка запушена" \
    "$(git -C "$MD_REMOTE" branch --list 'feature/M-1')" "feature/M-1"
  cd "$HERE"; rm -rf "$MD_BASE" "$MD_REG"
}

test_deliver_mirror_guard_fail_closed() {
  _mk_mirror_deliver_fixture
  local rc=0
  ( cmd_deliver proj "feature/M-2" "msg" --mirror </dev/null ) >/dev/null 2>&1 || rc=$?
  # снапшот удаляет roles.txt → guard обязан прервать без --yes в non-TTY
  assert_eq "mirror-guard: прерывание без --yes (rc=1)" "$rc" "1"
  assert_eq "mirror-guard: ветка НЕ запушена" \
    "$(git -C "$MD_REMOTE" branch --list 'feature/M-2')" ""
  cd "$HERE"; rm -rf "$MD_BASE" "$MD_REG"
}

test_deliver_mirror_requires_mirror_conf() {
  local base; base="$(make_ws)"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  git init -q "$base/repo"
  printf 'SRC=%s\nREPO=%s\nFORGE=none\n' "$base/src" "$base/repo" > "$reg/proj.conf"
  local rc=0
  ( cmd_deliver proj "feature/M-3" "msg" --mirror --yes </dev/null ) >/dev/null 2>&1 || rc=$?
  assert_eq "mirror-deliver: без MIRROR → die" "$rc" "1"
  cd "$HERE"; rm -rf "$base" "$reg"
}

test_deliver_archive_path_regression() {
  # архивный путь БЕЗ --mirror работает как раньше (существующий
  # test_deliver_uses_repo остаётся главным регрессом; этот — smoke, что
  # флаг --mirror не влияет на разбор прочих аргументов)
  local rc=0
  ( cmd_deliver ) >/dev/null 2>&1 || rc=$?
  assert_eq "deliver без аргументов по-прежнему ошибка использования" "$rc" "1"
}
```

Регистрация после push-тестов Task 3 (4 функции).

- [ ] **Step 2: Прогнать — падают** (флаг --mirror неизвестен → уходит в позиционные аргументы → «Архив не найден» вместо mirror-пути)

- [ ] **Step 3: Реализация** — в `cmd_deliver`:

3a. В цикле разбора флагов (где обрабатывается `--yes|-y`) добавить ветку:

```bash
      --mirror) from_mirror=1 ;;
```

и инициализацию `local from_mirror=0` рядом с `local assume_yes=...`.

3b. Проверку архива сделать условной. Существующий блок:

```bash
  [[ -f "$archive" ]] || die "Архив не найден: $archive (сначала: pbx pack $project)"
```

заменить на:

```bash
  if [[ "$from_mirror" == 1 ]]; then
    [[ -n "${MIRROR:-}" ]] || die "Не задан MIRROR для '$project' (нужен для --mirror). Добавь MIRROR=... в $PBX_REGISTRY_DIR/$project.conf"
  else
    [[ -f "$archive" ]] || die "Архив не найден: $archive (сначала: pbx pack $project)"
  fi
```

3c. Блок распаковки. Существующий `case "$archive" in ... esac` обернуть:

```bash
  if [[ "$from_mirror" == 1 ]]; then
    # Источник — ветка зеркала (Э2, вариант В): наполняем ту же tmp-директорию,
    # что раньше наполнял архив; дальше НЕТРОНУТЫЙ rsync/guard-путь.
    c_blue "🔵 Забираю '$branch' из зеркала"
    if ! GIT_TERMINAL_PROMPT=0 timeout 30 git fetch -q "$MIRROR" "$branch" 2>/dev/null; then
      die "Не удалось получить '$branch' из зеркала ($MIRROR). Проверь PAT/ключ и срок действия, либо используй архивный путь."
    fi
    git archive FETCH_HEAD | tar -x -C "$tmp" \
      || die "Не удалось развернуть снапшот из FETCH_HEAD"
  else
    case "$archive" in
      *.zip)          unzip -q "$archive" -d "$tmp" ;;
      *.tar.gz|*.tgz) tar -xzf "$archive" -C "$tmp" ;;
      *.tar)          tar -xf "$archive" -C "$tmp" ;;
      *) die "Неизвестный формат архива: $archive" ;;
    esac
  fi
```

Примечание: fetch выполняется ПОСЛЕ `cd "$repo"` и checkout/pull BASE (сетевые
креды те же, FETCH_HEAD пишется в REPO). `git archive` кладёт содержимое без
корневой папки → существующая проверка «единственный корневой каталог» отработает
ветвью `inner="$tmp"` — менять её не нужно.

3d. В help обе ветки: строку deliver дополнить `[--mirror]` (plain:
`pbx deliver <проект> <ветка> <сообщение> [архив] [--yes] [--mirror]`; TTY аналогично).

- [ ] **Step 4: Прогнать — зелёные**, особо: `test_deliver_uses_repo`, `test_deliver_guard_blocks_deletions`, `test_deliver_guard_plain_invariant`, `test_menu_deliver_guard_fail_closed` (архивный путь) — без правок. → `FAIL=0`

- [ ] **Step 5: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(deliver): --mirror — источник из ветки зеркала тем же rsync/guard-путём"
```

---

### Task 5: Меню (push-пункт), README, MIRROR в домашний реестр

**Files:**
- Modify: `pbx` (`cmd_menu`: items + case; `menu_project_flow`: ветка push), `README.md`, `_tests/test_pbx.sh` (перенумерация цифровых вводов)
- Modify: `~/.config/pbx/projects/{vnd,rbp,sup}.conf` (домашний реестр — вне git-репо)

**Interfaces:**
- Consumes: `cmd_push`, `menu_select`, `menu_pause`, существующие flow.
- Produces: пункты меню: pack(1) push(2) deliver(3) log(4) status(5) list(6) scan(7) add(8) help(9) выход(10).

- [ ] **Step 1: Обновить/добавить тесты**

1a. Перенумерация цифровых вводов существующих меню-тестов:
- `test_menu_exit_item`: `printf '9\n'` → `'10\n'` (текст ассерта «(10)»).
- `test_menu_deliver_guard_fail_closed`: `printf '2\n1\n...'` → `printf '3\n1\n...'` (deliver теперь 3-й).
- `test_menu_status_returns_to_menu`: `printf '4\n\n9\n'` → `printf '5\n\n10\n'`.
- `test_menu_pack_e2e`: без изменений (pack остаётся 1-м).

1b. Новый тест после `test_menu_status_returns_to_menu`:

```bash
test_menu_push_flow() {
  _mk_push_fixture
  local ws; ws="$(make_ws)"
  local reg; reg="$(make_ws)"
  printf 'SRC=%s\nMIRROR=%s\n' "$PU_SRC" "$PU_MIRROR" > "$reg/proj.conf"
  ( cd "$PU_SRC" && git checkout -qb feature/T-77 ) >/dev/null 2>&1
  # 2 = push → 1 = проект → Enter на ветке (дефолт: текущая ветка SRC)
  ( printf '2\n1\n\n' | {
      source "$PBX"
      WORKSPACE="$ws"; PBX_REGISTRY_DIR="$reg"; UI_TTY=1
      TERM=xterm main
    } ) >/dev/null 2>&1 || true
  assert_has "меню: push создал ветку в зеркале" \
    "$(git -C "$PU_MIRROR" branch --list 'feature/T-77')" "feature/T-77"
  rm -rf "$PU_BASE" "$ws" "$reg"
}
```

Регистрация после `test_menu_status_returns_to_menu`.

- [ ] **Step 2: Прогнать — падают** (перенумерованные тесты и push-флоу)

- [ ] **Step 3: Реализация**

3a. `cmd_menu` items:

```bash
  local -a items=(
    'pack    — упаковать проект в архив'
    'push    — снапшот рабочего дерева в зеркало'
    'deliver — доставить архив в репо (ветка + MR)'
    'log     — диагностика проекта'
    'status  — сводка по проектам'
    'list    — список проектов'
    'scan    — заполнить реестр (подсказка)'
    'add     — добавить проект (подсказка)'
    'help    — справка'
    'выход'
  )
```

case:

```bash
    case "$idx" in
      0) if menu_project_flow pack;    then return 0; fi ;;
      1) if menu_project_flow push;    then return 0; fi ;;
      2) if menu_project_flow deliver; then return 0; fi ;;
      3) menu_project_flow log || true ;;
      4) cmd_status; menu_pause ;;
      5) cmd_list; menu_pause ;;
      6) c_blue "🔵 Синтаксис: pbx scan (--repo|--src) [каталог] [--dry-run]"; return 0 ;;
      7) c_blue "🔵 Синтаксис: pbx add <имя> [путь-SRC]"; return 0 ;;
      8) cmd_help; menu_pause ;;
      9) return 0 ;;
    esac
```

3b. `menu_project_flow`: в case action добавить ветку (после `pack)`):

```bash
    push)
      local cur_branch=''
      cur_branch="$(git -C "$SRC" branch --show-current 2>/dev/null || true)"
      if [[ -t 0 ]]; then
        read -e -r -i "$cur_branch" -p "Ветка зеркала: " branch || return 1
      else
        printf 'Ветка зеркала: ' >&2
        IFS= read -r branch || return 1
      fi
      branch="$(strip_cr "$branch")"
      [[ -n "$branch" ]] || branch="$cur_branch"
      if [[ -z "$branch" ]]; then
        c_warn "(ветка не определена — отмена)"
        return 1
      fi
      cmd_push "$project" "$branch"
      return 0
      ;;
```

Внимание: `menu_project_flow` использует `load_config` только внутри cmd_*; для
дефолта ветки нужен SRC → добавить `load_config "$project"` первой строкой ветки
push) перед `cur_branch=...` (cmd_push потом перечитает конфиг сам — идемпотентно).

- [ ] **Step 4: README**

После раздела «Статус проектов» добавить:

```markdown
## Транспорт через личное GitHub-зеркало

Вместо ручного переноса архива: дома `pbx push <проект> [ветка]` — снапшот
рабочего дерева SRC (включая незакоммиченное) уезжает коммитом в ветку личного
зеркала (ключ `MIRROR=` в реестре). На ноуте `pbx deliver <проект> <ветка>
<сообщение> --mirror` — та же доставка с тем же guard, но источник — ветка
зеркала, а не архив. Архивный путь никуда не делся — работает без `--mirror`.

Отличие от pack: снапшот уважает `.gitignore` SRC — gitignored-файлы
(например `.env`) в зеркало НЕ уезжают (архив их тащил). История снапшотов в
зеркале сохраняется (parent-chain), `--force` не используется.

Auth ноута (root): рекомендован HTTPS + fine-grained PAT (скоуп — только
зеркала, Contents Read/Write, срок ~90 дней) через `git credential-cache`
или `~/.git-credentials` (600). Токен НЕ вписывать в URL реестра. При
отсутствии/протухании токена pbx падает с понятной ошибкой, не виснет.
```

В список переменных окружения добавить `PBX_MIRROR`.

- [ ] **Step 5: MIRROR в домашний реестр** (вне git; идемпотентно)

```bash
grep -q '^MIRROR=' ~/.config/pbx/projects/vnd.conf 2>/dev/null || printf 'MIRROR=git@github.com:dkurokhtin/vnd.git\n' >> ~/.config/pbx/projects/vnd.conf
grep -q '^MIRROR=' ~/.config/pbx/projects/rbp.conf 2>/dev/null || printf 'MIRROR=git@github.com:dkurokhtin/rbp.git\n' >> ~/.config/pbx/projects/rbp.conf
grep -q '^MIRROR=' ~/.config/pbx/projects/sup.conf 2>/dev/null || printf 'MIRROR=git@github.com:dkurokhtin/SUP.git\n' >> ~/.config/pbx/projects/sup.conf
```

- [ ] **Step 6: Прогнать всё + smoke** → `FAIL=0`; `bash pbx status` (реестр цел после дописи MIRROR); `bash pbx help | grep push`; `bash pbx </dev/null` → help.

- [ ] **Step 7: Commit**

```bash
git add pbx _tests/test_pbx.sh README.md
git commit -m "feat(menu),docs: пункт push в меню, README-раздел транспорта, MIRROR в реестре дома"
```

---

## Порядок и зависимости

Task 1 → Task 2 → Task 3 → Task 4 → Task 5 (deliver-фикстура Task 4 использует push_snapshot из Task 3; меню-тест Task 5 использует пуш-фикстуру Task 3).

## После завершения

Финальное ревью всей ветки (opus; особое внимание: SRC-неприкосновенность на живом vnd read-only проверкой, deliver-регресс, сетевые таймауты) → фиксы → merge в main + push. НАПОМНИТЬ пользователю: реальный push в настоящие зеркала — только руками после его проверки; на ноуте — прописать MIRROR в реестре и настроить PAT (README-раздел).
