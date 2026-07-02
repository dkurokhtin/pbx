# pbx Э1 — status + манифест pack: план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Команда `pbx status [проект] [--json]` (сводка: ветка, dirty, дрейф от последнего pack, свежесть архива) + манифест `<проект>.meta` от pack + апгрейды scan/log + пункт меню.

**Architecture:** Один bash-файл; манифест — bash `KEY=value` в DIST_DIR; сбор данных — внутренняя `status_collect` (ST_*-глобали), поверх неё таблица и ручная JSON-сборка. Спека: `docs/superpowers/specs/2026-07-02-pbx-status-design.md`.

**Tech Stack:** bash ≥ 5, git, du/date/sed. Никаких новых зависимостей (jq НЕТ — JSON руками).

## Global Constraints

- Файл `pbx` — ОДИН самодостаточный bash-скрипт.
- Plain-вывод существующих команд не меняется: meta-строка pack — TTY-only (`ui_dim`); ветка в scan — TTY-only; в log/collect_diag — только ДОБАВЛЕНИЕ строк с существующими префиксами `[repo]`/`[archive]`. Исключение (осознанное, по спеке): в help добавляется строка новой команды status.
- JSON-контракт (спека §4): плоские объекты, фиксированный порядок ключей; сентинели: неизвестная строка `""`, неизвестное число `-1`, `drift ∈ {"exact","heuristic","none"}`; при `--json` в stdout — только JSON.
- Дисциплина `set -euo pipefail`: `read`/арифметика по правилам UI-секции; функции сбора заканчиваются `return 0`; `local x; x="$(...)"` двумя операторами.
- `git`-вызовы всегда с `2>/dev/null` и fallback — orphan-репо без коммитов (живой кейс suba) не должен ничего ронять.
- Тесты: `bash _tests/test_pbx.sh` из корня репо → `FAIL=0`.
- Ветка: `feature/pbx-status` (создаётся в Task 1). Правки в месте (без worktree).
- Репо: `/mnt/c/Users/darkl/Claude/Projects/Pybotx`.

---

### Task 1: Манифест `<проект>.meta` в `cmd_pack`

**Files:**
- Modify: `pbx` (новая функция `write_pack_meta` перед `cmd_pack`; вставка в `cmd_pack` после `tar`)
- Test: `_tests/test_pbx.sh`

**Interfaces:**
- Produces: `write_pack_meta <project> <src> <meta-path>` — пишет атомарно (`.tmp`→`mv`), best-effort (не роняет pack); формат: `PBX_META_VERSION=1`, `PACKED_AT=<epoch>`, `COMMIT=<sha|->`, `BRANCH=<ветка|->`, `DIRTY_AT_PACK=<N|->`.
- Produces: файл `DIST_DIR/<проект>.meta` — его читают Task 2 (`status_collect`) и Task 4 (log).

- [ ] **Step 1: Создать ветку**

```bash
cd /mnt/c/Users/darkl/Claude/Projects/Pybotx
git checkout -b feature/pbx-status
```

- [ ] **Step 2: Написать падающие тесты**

В `_tests/test_pbx.sh` после `test_pack_e2e_registry` добавить функции:

```bash
# --- pack: манифест .meta ------------------------------------------------------
test_pack_writes_meta_git() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"; DIST_DIR="$ws/_dist"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  mkdir -p "$ws/proj/src"; echo hi > "$ws/proj/src/a.txt"
  ( cd "$ws/proj" && git init -q . && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm init && echo dirty >> src/a.txt ) >/dev/null 2>&1
  cmd_pack proj >/dev/null 2>&1
  local meta="$ws/_dist/proj.meta" m
  if [[ -f "$meta" ]]; then ok "meta: файл создан"; else bad "meta: файл не создан"; fi
  m="$(cat "$meta" 2>/dev/null)"
  assert_has "meta: версия"     "$m" "PBX_META_VERSION=1"
  assert_has "meta: COMMIT"     "$m" "COMMIT=$(git -C "$ws/proj" rev-parse HEAD)"
  assert_has "meta: BRANCH"     "$m" "BRANCH=$(git -C "$ws/proj" branch --show-current)"
  assert_has "meta: DIRTY=1"    "$m" "DIRTY_AT_PACK=1"
  assert_has "meta: PACKED_AT"  "$m" "PACKED_AT="
  rm -rf "$ws" "$reg"
}

test_pack_writes_meta_nongit() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"; DIST_DIR="$ws/_dist"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  mkdir -p "$ws/proj/src"; echo hi > "$ws/proj/src/a.txt"
  cmd_pack proj >/dev/null 2>&1
  local m; m="$(cat "$ws/_dist/proj.meta" 2>/dev/null)"
  assert_has "meta(не-git): COMMIT=-" "$m" "COMMIT=-"
  assert_has "meta(не-git): BRANCH=-" "$m" "BRANCH=-"
  assert_has "meta(не-git): DIRTY=-"  "$m" "DIRTY_AT_PACK=-"
  rm -rf "$ws" "$reg"
}
```

Регистрация в блоке вызовов после `test_pack_e2e_registry`:

```bash
test_pack_writes_meta_git
test_pack_writes_meta_nongit
```

- [ ] **Step 3: Прогнать — падают** (meta-файл не создаётся)

Run: `bash _tests/test_pbx.sh 2>&1 | tail -5`
Expected: FAIL ≥ 2, причины «meta: файл не создан» и пустые assert_has.

- [ ] **Step 4: Реализация**

4a. Перед `# ---- pack ---` (перед комментарием секции pack) вставить:

```bash
# ---- meta: манифест последней упаковки ---------------------------------------
# DIST_DIR/<проект>.meta, bash-формат KEY=value (jq нет). Пишется атомарно
# (.tmp → mv), best-effort: сбой записи меты НЕ роняет pack — архив важнее.
# Читатели: pbx status (дрейф по коммитам), pbx log, этапы Э2/Э3.
write_pack_meta() {
  local project="$1" src="$2" out_meta="$3"
  local commit='-' branch='-' dirty='-'
  if [[ -e "$src/.git" ]]; then
    commit="$(git -C "$src" rev-parse HEAD 2>/dev/null || echo '-')"
    branch="$(git -C "$src" branch --show-current 2>/dev/null || true)"
    [[ -n "$branch" ]] || branch='-'
    dirty="$(git -C "$src" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  fi
  {
    printf '# pbx meta: проект %s, автогенерация pack\n' "$project"
    printf 'PBX_META_VERSION=1\n'
    printf 'PACKED_AT=%s\n' "$(date +%s)"
    printf 'COMMIT=%s\n' "$commit"
    printf 'BRANCH=%s\n' "$branch"
    printf 'DIRTY_AT_PACK=%s\n' "$dirty"
  } > "$out_meta.tmp" 2>/dev/null && mv "$out_meta.tmp" "$out_meta" 2>/dev/null \
    || c_warn "⚠️  Не удалось записать мету: $out_meta"
  return 0
}
```

4b. В `cmd_pack` после строки `tar ...` и ПЕРЕД `ui_dim "размер: ..."` вставить:

```bash
  local meta="$DIST_DIR/$project.meta"
  write_pack_meta "$project" "$SRC" "$meta"
```

и после строки `ui_dim "размер: ..."` (перед `c_green "✅ Архив готов..."`):

```bash
  if [[ -f "$meta" ]]; then
    local mcommit mbranch
    mcommit="$(sed -n 's/^COMMIT=//p' "$meta")"
    mbranch="$(sed -n 's/^BRANCH=//p' "$meta")"
    if [[ "$mcommit" != '-' && -n "$mcommit" ]]; then
      ui_dim "meta: ${mcommit:0:7} @ $mbranch"
    fi
  fi
```

- [ ] **Step 5: Прогнать — зелёные**, особо убедиться: `test_pack_plain_invariant` зелёный БЕЗ правок (meta-строка TTY-only, запись меты молчалива).

Run: `bash _tests/test_pbx.sh 2>&1 | tail -3` → `FAIL=0`

- [ ] **Step 6: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(pack): манифест <проект>.meta рядом с архивом (коммит/ветка/dirty/время)"
```

---

### Task 2: `status_collect` — сбор данных проекта + дрейф

**Files:**
- Modify: `pbx` (новая секция `# ---- status ---` после секции meta/pack, перед `forge_push`)
- Test: `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: `load_config` (SRC/REPO/DIST_DIR уже резолвлены вызывающим), мета из Task 1.
- Produces: `status_collect <project>` — заполняет глобали (сентинели: строка `''`, число `-1`):
  `ST_NAME ST_SRC ST_SRC_EXISTS ST_GIT ST_BRANCH ST_DIRTY ST_UPSTREAM ST_AHEAD ST_BEHIND ST_ARCHIVE ST_ARCHIVE_EXISTS ST_ARCHIVE_MTIME ST_ARCHIVE_SIZE ST_META_COMMIT ST_META_BRANCH ST_META_PACKED_AT ST_META_DIRTY ST_DRIFT ST_UNPACKED ST_DIRTY_NOW ST_STALE ST_REPO ST_REPO_EXISTS`.
  Булевы — строки `true`/`false`; `ST_DRIFT` ∈ exact|heuristic|none.
  Семантика `ST_STALE=true`: нужен новый pack — SRC есть, а архива нет; ЛИБО (exact) unpacked>0 или dirty_now>0; ЛИБО (heuristic) архив старее последнего коммита или dirty_now>0. Для не-git с архивом — false (дрейф неизвестен).

- [ ] **Step 1: Написать падающие тесты**

После meta-тестов Task 1 добавить:

```bash
# --- status_collect: дрейф ------------------------------------------------------
# Общая фикстура: git-проект в WORKSPACE + pack. Возвращает пути через глобали
# SC_WS/SC_REG (вызывающий обязан rm -rf и unset).
_mk_status_fixture() {
  SC_WS="$(make_ws)"; WORKSPACE="$SC_WS"; DIST_DIR="$SC_WS/_dist"
  SC_REG="$(make_ws)"; PBX_REGISTRY_DIR="$SC_REG"
  mkdir -p "$SC_WS/proj/src"; echo hi > "$SC_WS/proj/src/a.txt"
  ( cd "$SC_WS/proj" && git init -q . && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm init ) >/dev/null 2>&1
}

test_status_collect_exact_clean() {
  _mk_status_fixture
  cmd_pack proj >/dev/null 2>&1
  load_config proj; status_collect proj
  assert_eq "exact-clean: drift"    "$ST_DRIFT"    "exact"
  assert_eq "exact-clean: unpacked" "$ST_UNPACKED" "0"
  assert_eq "exact-clean: dirty"    "$ST_DIRTY_NOW" "0"
  assert_eq "exact-clean: stale"    "$ST_STALE"    "false"
  rm -rf "$SC_WS" "$SC_REG"
}

test_status_collect_exact_drift() {
  _mk_status_fixture
  cmd_pack proj >/dev/null 2>&1
  ( cd "$SC_WS/proj" && echo more >> src/a.txt && git commit -qam second \
    && echo uncommitted >> src/a.txt ) >/dev/null 2>&1
  load_config proj; status_collect proj
  assert_eq "exact-drift: drift"     "$ST_DRIFT"     "exact"
  assert_eq "exact-drift: +1 коммит" "$ST_UNPACKED"  "1"
  assert_eq "exact-drift: dirty=1"   "$ST_DIRTY_NOW" "1"
  assert_eq "exact-drift: stale"     "$ST_STALE"     "true"
  rm -rf "$SC_WS" "$SC_REG"
}

test_status_collect_heuristic() {
  _mk_status_fixture
  cmd_pack proj >/dev/null 2>&1
  rm -f "$SC_WS/_dist/proj.meta"                       # меты нет → эвристика
  touch -d '2000-01-01' "$SC_WS/_dist/proj.tar.gz"     # архив «старый»
  load_config proj; status_collect proj
  assert_eq "heuristic: drift" "$ST_DRIFT" "heuristic"
  assert_eq "heuristic: stale (архив старее коммита)" "$ST_STALE" "true"
  rm -rf "$SC_WS" "$SC_REG"
}

test_status_collect_nongit_and_noarchive() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"; DIST_DIR="$ws/_dist"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  mkdir -p "$ws/plainproj"; echo x > "$ws/plainproj/f.txt"
  load_config plainproj; status_collect plainproj
  assert_eq "не-git: git=false"      "$ST_GIT"    "false"
  assert_eq "не-git: branch пуст"    "$ST_BRANCH" ""
  assert_eq "не-git: dirty=-1"       "$ST_DIRTY"  "-1"
  assert_eq "нет архива: stale=true" "$ST_STALE"  "true"
  assert_eq "нет архива: drift=none" "$ST_DRIFT"  "none"
  rm -rf "$ws" "$reg"
}

test_status_collect_orphan_repo() {
  # живой кейс suba: git init без единого коммита
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"; DIST_DIR="$ws/_dist"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  mkdir -p "$ws/orph"; ( cd "$ws/orph" && git init -q . && echo x > f.txt && git add f.txt ) >/dev/null 2>&1
  load_config orph
  local rc=0
  status_collect orph || rc=$?
  assert_eq "orphan: не падает"   "$rc"      "0"
  assert_eq "orphan: git=true"    "$ST_GIT"  "true"
  assert_eq "orphan: ahead=-1"    "$ST_AHEAD" "-1"
  rm -rf "$ws" "$reg"
}

test_status_collect_upstream_ahead() {
  local base; base="$(make_ws)"; WORKSPACE="$base"; DIST_DIR="$base/_dist"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  git init -q --bare "$base/remote.git"
  mkdir -p "$base/proj"
  ( cd "$base/proj" && git init -q . && git config user.email t@t && git config user.name t \
    && git remote add origin "$base/remote.git" \
    && echo a > f.txt && git add -A && git commit -qm one && git push -qu origin HEAD \
    && echo b >> f.txt && git commit -qam two ) >/dev/null 2>&1
  load_config proj; status_collect proj
  assert_eq "upstream: ahead=1"  "$ST_AHEAD"  "1"
  assert_eq "upstream: behind=0" "$ST_BEHIND" "0"
  assert_has "upstream: имя"     "$ST_UPSTREAM" "origin/"
  rm -rf "$base" "$reg"
}
```

Регистрация после `test_pack_writes_meta_nongit`:

```bash
test_status_collect_exact_clean
test_status_collect_exact_drift
test_status_collect_heuristic
test_status_collect_nongit_and_noarchive
test_status_collect_orphan_repo
test_status_collect_upstream_ahead
```

- [ ] **Step 2: Прогнать — падают** (`status_collect: command not found`)

- [ ] **Step 3: Реализация** — после секции meta (после `write_pack_meta`) вставить:

```bash
# ---- status: сбор данных одного проекта ---------------------------------------
# Заполняет ST_*-глобали. Вызывать ПОСЛЕ load_config (берёт SRC/REPO/DIST_DIR).
# Сентинели: строка '' (неизвестно), число -1; булевы — строки true/false.
# ST_STALE=true ⇔ нужен новый pack: нет архива при живом SRC; (exact) есть
# неупакованные коммиты или dirty; (heuristic) архив старее коммита или dirty.
status_collect() {
  local project="$1"
  ST_NAME="$project"
  ST_SRC="$SRC"; ST_SRC_EXISTS=false; ST_GIT=false
  ST_BRANCH=''; ST_DIRTY=-1; ST_UPSTREAM=''; ST_AHEAD=-1; ST_BEHIND=-1
  ST_ARCHIVE="$DIST_DIR/$project.tar.gz"; ST_ARCHIVE_EXISTS=false
  ST_ARCHIVE_MTIME=-1; ST_ARCHIVE_SIZE=''
  ST_META_COMMIT=''; ST_META_BRANCH=''; ST_META_PACKED_AT=-1; ST_META_DIRTY=-1
  ST_DRIFT='none'; ST_UNPACKED=-1; ST_DIRTY_NOW=-1; ST_STALE=false
  ST_REPO="$REPO"; ST_REPO_EXISTS=false

  [[ -d "$ST_SRC" ]] && ST_SRC_EXISTS=true
  [[ -d "$ST_REPO" ]] && ST_REPO_EXISTS=true

  if [[ "$ST_SRC_EXISTS" == true && -e "$ST_SRC/.git" ]]; then
    ST_GIT=true
    ST_BRANCH="$(git -C "$ST_SRC" branch --show-current 2>/dev/null || true)"
    [[ -n "$ST_BRANCH" ]] || ST_BRANCH='HEAD'
    # dirty без пайпа под pipefail: сбой git (битый .git) НЕ роняет сбор —
    # присваивание в условии if не триггерит set -e; grep -c сам печатает 0
    local st_out=''
    if st_out="$(git -C "$ST_SRC" status --porcelain 2>/dev/null)"; then
      ST_DIRTY="$(printf '%s' "$st_out" | grep -c . || true)"
    fi
    ST_DIRTY_NOW="$ST_DIRTY"
    ST_UPSTREAM="$(git -C "$ST_SRC" rev-parse --abbrev-ref '@{u}' 2>/dev/null || true)"
    if [[ -n "$ST_UPSTREAM" ]]; then
      local lr
      lr="$(git -C "$ST_SRC" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null || true)"
      if [[ -n "$lr" ]]; then
        ST_BEHIND="${lr%%$'\t'*}"
        ST_AHEAD="${lr##*$'\t'}"
      fi
    fi
  fi

  if [[ -f "$ST_ARCHIVE" ]]; then
    ST_ARCHIVE_EXISTS=true
    ST_ARCHIVE_MTIME="$(date -r "$ST_ARCHIVE" +%s 2>/dev/null || echo -1)"
    ST_ARCHIVE_SIZE="$(du -h "$ST_ARCHIVE" 2>/dev/null | awk '{print $1}')"
  fi

  local meta="$DIST_DIR/$project.meta"
  if [[ -f "$meta" ]]; then
    ST_META_COMMIT="$(sed -n 's/^COMMIT=//p' "$meta")"
    ST_META_BRANCH="$(sed -n 's/^BRANCH=//p' "$meta")"
    ST_META_PACKED_AT="$(sed -n 's/^PACKED_AT=//p' "$meta")"
    ST_META_DIRTY="$(sed -n 's/^DIRTY_AT_PACK=//p' "$meta")"
    [[ "$ST_META_COMMIT" == '-' ]] && ST_META_COMMIT=''
    [[ "$ST_META_BRANCH" == '-' ]] && ST_META_BRANCH=''
    [[ "$ST_META_DIRTY" == '-' || -z "$ST_META_DIRTY" ]] && ST_META_DIRTY=-1
    [[ -n "$ST_META_PACKED_AT" ]] || ST_META_PACKED_AT=-1
  fi

  # дрейф от последнего pack
  if [[ "$ST_GIT" == true && "$ST_ARCHIVE_EXISTS" == true ]]; then
    if [[ -n "$ST_META_COMMIT" ]] \
       && git -C "$ST_SRC" cat-file -e "$ST_META_COMMIT^{commit}" 2>/dev/null; then
      ST_DRIFT='exact'
      ST_UNPACKED="$(git -C "$ST_SRC" rev-list --count "$ST_META_COMMIT..HEAD" 2>/dev/null || echo -1)"
      if [[ "$ST_UNPACKED" != -1 && "$ST_UNPACKED" -gt 0 ]] || [[ "$ST_DIRTY_NOW" -gt 0 ]]; then
        ST_STALE=true
      fi
    else
      ST_DRIFT='heuristic'
      local last_ct
      last_ct="$(git -C "$ST_SRC" log -1 --format=%ct 2>/dev/null || echo -1)"
      if [[ "$last_ct" != -1 && "$ST_ARCHIVE_MTIME" != -1 && "$last_ct" -gt "$ST_ARCHIVE_MTIME" ]]; then
        ST_STALE=true
      fi
      [[ "$ST_DIRTY_NOW" -gt 0 ]] && ST_STALE=true
    fi
  fi
  if [[ "$ST_SRC_EXISTS" == true && "$ST_ARCHIVE_EXISTS" == false ]]; then
    ST_STALE=true
  fi
  return 0
}
```

- [ ] **Step 4: Прогнать — зелёные** → `FAIL=0`

- [ ] **Step 5: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(status): status_collect — сбор состояния проекта и дрейф от последнего pack"
```

---

### Task 3: `cmd_status` — таблица + `--json` + диспетчер + help

**Files:**
- Modify: `pbx` (после `status_collect`: `_json_str`, `status_drift_label`, `status_json`, `cmd_status`; диспетчер `main()`; обе ветки `cmd_help`)
- Test: `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: `status_collect` (ST_*), `load_config`, `list_projects`, `valid_project`, `ui_section`, `ui_dim`, `C_*`, `strip_cr`, `die`.
- Produces: `cmd_status [проект] [--json]`; `_json_str <s>` (экранирование `\` и `"`); JSON-схема из спеки §4 с фиксированным порядком ключей.

- [ ] **Step 1: Написать падающие тесты**

```bash
# --- cmd_status -----------------------------------------------------------------
test_status_json_valid_and_pure() {
  _mk_status_fixture
  cmd_pack proj >/dev/null 2>&1
  local out; out="$(cmd_status --json 2>/dev/null)"
  assert_has "json: начинается с [" "${out:0:1}" "["
  assert_has "json: имя проекта"    "$out" '"name":"proj"'
  assert_has "json: drift exact"    "$out" '"drift":"exact"'
  assert_has "json: git true"       "$out" '"git":true'
  if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
      ok "json: валиден (python3 json.load)"
    else
      bad "json: НЕ валиден (python3 json.load)"
    fi
  fi
  rm -rf "$SC_WS" "$SC_REG"
}

test_status_json_sentinels_nongit() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"; DIST_DIR="$ws/_dist"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  mkdir -p "$ws/plainproj"
  local out; out="$(cmd_status plainproj --json 2>/dev/null)"
  assert_has "json-сентинели: git false"  "$out" '"git":false'
  assert_has "json-сентинели: branch \"\"" "$out" '"branch":""'
  assert_has "json-сентинели: dirty -1"   "$out" '"dirty":-1'
  assert_has "json-сентинели: drift none" "$out" '"drift":"none"'
  rm -rf "$ws" "$reg"
}

test_status_table_pipe_no_ansi() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  mkdir -p "$ws/alpha"
  local out; out="$(PBX_WORKSPACE="$ws" PBX_REGISTRY_DIR="$reg" bash "$PBX" status 2>&1)"
  assert_no  "status в пайпе: без ANSI" "$out" $'\033'
  assert_has "status в пайпе: заголовок" "$out" "Статус проектов"
  assert_has "status в пайпе: строка проекта" "$out" "alpha"
  rm -rf "$ws" "$reg"
}

test_status_unknown_project_dies() {
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  local rc=0
  ( cmd_status "no-such-proj-$$" ) >/dev/null 2>&1 || rc=$?
  assert_eq "status: неизвестный проект → ошибка" "$rc" "1"
  rm -rf "$reg" "$ws"
}
```

Регистрация после `test_status_collect_upstream_ahead`:

```bash
test_status_json_valid_and_pure
test_status_json_sentinels_nongit
test_status_table_pipe_no_ansi
test_status_unknown_project_dies
```

- [ ] **Step 2: Прогнать — падают** (`cmd_status: command not found`)

- [ ] **Step 3: Реализация** — после `status_collect` вставить:

```bash
# экранирование строки для ручной JSON-сборки (jq в системе нет)
_json_str() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }

# человекочитаемая метка дрейфа по ST_* текущего проекта
status_drift_label() {
  if [[ "$ST_SRC_EXISTS" == false ]]; then printf 'нет SRC'; return 0; fi
  if [[ "$ST_ARCHIVE_EXISTS" == false ]]; then printf 'нет архива'; return 0; fi
  case "$ST_DRIFT" in
    exact)
      local s=''
      [[ "$ST_UNPACKED" != -1 && "$ST_UNPACKED" -gt 0 ]] && s="+${ST_UNPACKED} коммит."
      if [[ "$ST_DIRTY_NOW" != -1 && "$ST_DIRTY_NOW" -gt 0 ]]; then
        s="${s:+$s, }${ST_DIRTY_NOW} файл. правок"
      fi
      if [[ -n "$s" ]]; then printf '%s' "$s"; else printf '%s упаковано' "$G_OK"; fi
      ;;
    heuristic)
      if [[ "$ST_STALE" == true ]]; then printf '~протух'; else printf '~ок'; fi
      ;;
    none)
      printf 'не git — неизвестен'
      ;;
  esac
  return 0
}

# JSON-массив статусов (схема — спека §4; порядок ключей фиксирован)
status_json() {
  local p first=1
  printf '['
  for p in "$@"; do
    load_config "$p"
    status_collect "$p"
    if (( first )); then first=0; else printf ','; fi
    printf '\n  {"name":"%s","src":"%s","src_exists":%s,"git":%s,' \
      "$(_json_str "$ST_NAME")" "$(_json_str "$ST_SRC")" "$ST_SRC_EXISTS" "$ST_GIT"
    printf '"branch":"%s","dirty":%s,"upstream":"%s","ahead":%s,"behind":%s,' \
      "$(_json_str "$ST_BRANCH")" "$ST_DIRTY" "$(_json_str "$ST_UPSTREAM")" "$ST_AHEAD" "$ST_BEHIND"
    printf '"archive":"%s","archive_exists":%s,"archive_mtime":%s,"archive_size":"%s",' \
      "$(_json_str "$ST_ARCHIVE")" "$ST_ARCHIVE_EXISTS" "$ST_ARCHIVE_MTIME" "$(_json_str "$ST_ARCHIVE_SIZE")"
    printf '"meta_commit":"%s","meta_branch":"%s","meta_packed_at":%s,"meta_dirty":%s,' \
      "$(_json_str "$ST_META_COMMIT")" "$(_json_str "$ST_META_BRANCH")" "$ST_META_PACKED_AT" "$ST_META_DIRTY"
    printf '"drift":"%s","unpacked_commits":%s,"dirty_now":%s,"stale":%s,' \
      "$ST_DRIFT" "$ST_UNPACKED" "$ST_DIRTY_NOW" "$ST_STALE"
    printf '"repo":"%s","repo_exists":%s}' "$(_json_str "$ST_REPO")" "$ST_REPO_EXISTS"
  done
  printf '\n]\n'
  return 0
}

cmd_status() {
  local project='' json=0 a
  for a in "$@"; do
    a="$(strip_cr "$a")"
    case "$a" in
      --json) json=1 ;;
      -*) die "Неизвестный флаг: $a (ожидается --json)" ;;
      *) [[ -n "$project" ]] && die "Лишний аргумент: $a (проект указывается один)"; project="$a" ;;
    esac
  done
  [[ -n "$project" ]] && valid_project "$project"

  local -a names=()
  if [[ -n "$project" ]]; then names=("$project"); else mapfile -t names < <(list_projects); fi

  if (( json )); then
    status_json ${names[@]+"${names[@]}"}
    return 0
  fi

  ui_section "Статус проектов" "🔵 Статус проектов:"
  if (( ${#names[@]} == 0 )); then
    c_warn "  (проектов не найдено)"
    return 0
  fi
  local p drift b color reset
  for p in "${names[@]}"; do
    load_config "$p"
    status_collect "$p"
    drift="$(status_drift_label)"
    b="$ST_BRANCH"; [[ -z "$b" ]] && b='—'
    if (( ${#b} > 24 )); then b="${b:0:23}…"; fi
    local dirty_disp="$ST_DIRTY"; [[ "$dirty_disp" == -1 ]] && dirty_disp='—'
    local arch_disp='—'
    if [[ "$ST_ARCHIVE_EXISTS" == true ]]; then
      arch_disp="$ST_ARCHIVE_SIZE $(date -d "@$ST_ARCHIVE_MTIME" '+%d.%m %H:%M' 2>/dev/null || echo '?')"
    fi
    color=''; reset=''
    if (( UI_COLOR_OUT )); then
      reset="$C_RESET"
      if [[ "$ST_STALE" == true ]]; then color="$C_YELLOW"
      elif [[ "$drift" == "$G_OK "* ]]; then color="$C_GREEN"
      else color="$C_DIM"; fi
    fi
    printf '  %-14s %-24s %5s  %-14s %s%s%s\n' \
      "$p" "$b" "$dirty_disp" "$arch_disp" "$color" "$drift" "$reset"
    if [[ "$ST_REPO_EXISTS" == true && -e "$ST_REPO/.git" ]]; then
      local rb rstate
      rb="$(git -C "$ST_REPO" branch --show-current 2>/dev/null || echo '?')"
      if [[ -n "$(git -C "$ST_REPO" status --porcelain 2>/dev/null)" ]]; then rstate='dirty'; else rstate='clean'; fi
      ui_dim "repo: $ST_REPO — $rb ($rstate)"
    fi
  done
  return 0
}
```

- [ ] **Step 4: Диспетчер и help**

4a. В `main()` в case добавить строку (после `log)`):

```bash
    status|st)          cmd_status "$@" ;;
```

4b. В `cmd_help`, plain-ветка (квотированный heredoc): после строки про `pbx log ...` вставить:

```
  pbx status  [проект] [--json]                 сводка: ветка, dirty, дрейф от последнего pack, свежесть архива
```

4c. В `cmd_help`, TTY-ветка: после строки про `pbx log` вставить:

```
  ${C_CYAN}pbx status${C_RESET}  [проект] [--json]        ${C_DIM}сводка: ветка, dirty, дрейф от последнего pack${C_RESET}
```

- [ ] **Step 5: Прогнать — зелёные** (в т.ч. `test_help_plain_invariant` — он проверяет подстроки, добавление строки его не ломает) → `FAIL=0`

- [ ] **Step 6: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(status): команда pbx status — таблица TTY/plain и --json (контракт для ИИ)"
```

---

### Task 4: Апгрейды scan (ветка, TTY) и log (upstream + мета)

**Files:**
- Modify: `pbx` (`cmd_scan` — вывод кандидатов; `collect_diag` — блоки `[repo]` и `[archive]`)
- Test: `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: `UI_COLOR_OUT`, `C_DIM/C_RESET`, мета из Task 1.
- Produces: только вывод; форматы строк см. шаги.

- [ ] **Step 1: Написать тесты** (scan-инвариант — страховочная сетка, зелёный сразу; log-строки — падающие)

```bash
# --- scan/log: апгрейды Э1 -------------------------------------------------------
test_scan_plain_no_branch_tail() {
  local ws; ws="$(make_ws)"; local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  mk_repo "$ws/proj" "git@h:/proj.git"
  local out; out="$(cmd_scan --repo "$ws" 2>&1)"
  assert_has "scan plain: строка кандидата прежняя" "$out" "+ proj → REPO=$ws/proj"
  assert_no  "scan plain: без хвоста ветки"          "$out" "["
  rm -rf "$ws" "$reg"
}

test_log_upstream_and_meta_lines() {
  local base; base="$(make_ws)"
  local repo="$base/repo" src="$base/src"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  local dist="$base/_dist"; DIST_DIR="$dist"; mkdir -p "$dist"
  git init -q --bare "$base/remote.git"
  git init -q "$repo"
  ( cd "$repo" && git config user.email t@t && git config user.name t \
    && git remote add origin "$base/remote.git" \
    && git checkout -q -b dev && echo x > a.txt && git add -A && git commit -qm init \
    && git push -qu origin dev ) >/dev/null 2>&1
  mkdir -p "$src"; echo y > "$src/a.txt"
  # мета: как пишет pack
  printf 'PBX_META_VERSION=1\nPACKED_AT=1700000000\nCOMMIT=abc1234\nBRANCH=dev\nDIRTY_AT_PACK=0\n' \
    > "$dist/proj.meta"
  tar -C "$(dirname "$src")" -czf "$dist/proj.tar.gz" "$(basename "$src")"
  printf 'SRC=%s\nREPO=%s\nBASE_BRANCH=dev\nTARGET_BRANCH=dev\nFORGE=none\n' "$src" "$repo" > "$reg/proj.conf"

  local out; out="$(cmd_log proj 2>&1)"
  assert_has "log: строка upstream"      "$out" "upstream=origin/dev"
  assert_has "log: ahead/behind"         "$out" "ahead=0 behind=0"
  assert_has "log: meta-строка"          "$out" "meta: commit=abc1234 branch=dev"
  assert_has "log: старые строки целы"   "$out" "[config]"
  cd "$HERE"; rm -rf "$base" "$reg"
}
```

Регистрация после `test_status_unknown_project_dies`:

```bash
test_scan_plain_no_branch_tail
test_log_upstream_and_meta_lines
```

- [ ] **Step 2: Прогнать** — scan-тест зелёный (сетка), log-тест падает.

- [ ] **Step 3: Реализация**

3a. В `cmd_scan`: в объявление локалей добавить `br`; заменить ветку печати кандидата:

```bash
    if [[ "$dry" -eq 1 ]]; then
      if (( UI_COLOR_OUT )); then
        br="$(git -C "$path" branch --show-current 2>/dev/null || true)"
        printf '\033[32m  + %s → %s=%s (dry-run)\033[0m%s\n' "$name" "$field" "$path" \
          "${br:+ ${C_DIM}[$br]${C_RESET}}"
      else
        c_green "  + $name → $field=$path (dry-run)"
      fi
    else
      printf '# Реестр pbx (scan): проект %s\n%s=%s%s\n' "$name" "$field" "$path" "$forge" > "$f"
      if (( UI_COLOR_OUT )); then
        br="$(git -C "$path" branch --show-current 2>/dev/null || true)"
        printf '\033[32m  + %s → %s=%s\033[0m%s\n' "$name" "$field" "$path" \
          "${br:+ ${C_DIM}[$br]${C_RESET}}"
      else
        c_green "  + $name → $field=$path"
      fi
    fi
```

3b. В `collect_diag`, после строки `printf '[repo]    branch=%s remote=%s\n' ...` вставить:

```bash
        local up ab ahead='—' behind='—'
        up="$(git -C "$REPO" rev-parse --abbrev-ref '@{u}' 2>/dev/null || echo '—')"
        if [[ "$up" != '—' ]]; then
          ab="$(git -C "$REPO" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null || true)"
          if [[ -n "$ab" ]]; then behind="${ab%%$'\t'*}"; ahead="${ab##*$'\t'}"; fi
        fi
        printf '[repo]    upstream=%s ahead=%s behind=%s\n' "$up" "$ahead" "$behind"
```

3c. В `collect_diag`, внутри ветки `if [[ -f "$arch" ]]` после существующей `printf '[archive] %s size=...'` вставить:

```bash
        local metaf="$DIST_DIR/$project.meta"
        if [[ -f "$metaf" ]]; then
          printf '[archive] meta: commit=%s branch=%s packed_at=%s\n' \
            "$(sed -n 's/^COMMIT=//p' "$metaf")" \
            "$(sed -n 's/^BRANCH=//p' "$metaf")" \
            "$(date -d "@$(sed -n 's/^PACKED_AT=//p' "$metaf")" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '—')"
        fi
```

- [ ] **Step 4: Прогнать — зелёные** (в т.ч. все старые scan/log-тесты: добавления не меняют существующих строк) → `FAIL=0`

- [ ] **Step 5: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(scan,log): ветка кандидата в scan (TTY) + upstream/meta в диагностике log"
```

---

### Task 5: Меню + README

**Files:**
- Modify: `pbx` (`cmd_menu`: пункт status), `README.md`, `_tests/test_pbx.sh` (обновить `test_menu_exit_item`, новый тест)

**Interfaces:**
- Consumes: `cmd_status`, `menu_pause`, массив `items` и case в `cmd_menu` (Task 8 фичи v2).

- [ ] **Step 1: Обновить/написать тесты**

1a. В `test_menu_exit_item` заменить `printf '8\n'` на `printf '9\n'` (пункт «выход» сдвигается на 9-е место) и текст ассерта на «меню: выбор «выход» (9) → rc=0».

1b. Новый тест после `test_menu_cancel_returns_cleanly`:

```bash
test_menu_status_returns_to_menu() {
  local ws; ws="$(make_ws)"
  local reg; reg="$(make_ws)"
  mkdir -p "$ws/proj"
  # 4 = status → вывод → Enter (menu_pause) → 9 = выход
  local out
  out="$( ( printf '4\n\n9\n' | {
      source "$PBX"
      WORKSPACE="$ws"; PBX_REGISTRY_DIR="$reg"; UI_TTY=1
      TERM=xterm main
    } ) 2>&1 )" || true
  assert_has "меню: status вызван" "$out" "Статус проектов"
  # заголовок меню дважды: до status и после возврата (доказательство возврата)
  assert_eq "меню: после status снова меню" \
    "$(printf '%s' "$out" | grep -c 'что делаем')" "2"
  rm -rf "$ws" "$reg"
}
```

Регистрация после `test_menu_cancel_returns_cleanly`: `test_menu_status_returns_to_menu`.

- [ ] **Step 2: Прогнать — падают** (нет пункта status; exit-тест на 9 падает, пока пунктов 8)

- [ ] **Step 3: Реализация** — в `cmd_menu`:

Массив `items` заменить на:

```bash
  local -a items=(
    'pack    — упаковать проект в архив'
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

case заменить на:

```bash
    case "$idx" in
      0) if menu_project_flow pack;    then return 0; fi ;;
      1) if menu_project_flow deliver; then return 0; fi ;;
      2) menu_project_flow log || true ;;
      3) cmd_status; menu_pause ;;
      4) cmd_list; menu_pause ;;
      5) c_blue "🔵 Синтаксис: pbx scan (--repo|--src) [каталог] [--dry-run]"; return 0 ;;
      6) c_blue "🔵 Синтаксис: pbx add <имя> [путь-SRC]"; return 0 ;;
      7) cmd_help; menu_pause ;;
      8) return 0 ;;
    esac
```

- [ ] **Step 4: README** — после раздела «Интерактивное меню» добавить:

```markdown
## Статус проектов

`pbx status` — сводка по всем проектам: ветка, незакоммиченные правки, что не
упаковано с последнего `pack`, свежесть архива. `pbx status <проект>` — по
одному, `pbx status --json` — машиночитаемо (для ИИ-агентов и скриптов).

`pack` теперь пишет рядом с архивом манифест `<проект>.meta` (коммит, ветка,
время упаковки) — по нему `status` считает дрейф точно, по коммитам; без
манифеста дрейф оценивается эвристикой (помечается `~`).
```

- [ ] **Step 5: Прогнать всё + smoke** → `FAIL=0`; вручную: `bash pbx status` в терминале (таблица по живым 6 проектам, включая не-git и orphan), `bash pbx status --json | python3 -m json.tool | head`, `bash pbx` → меню → status → Enter → выход.

- [ ] **Step 6: Commit**

```bash
git add pbx _tests/test_pbx.sh README.md
git commit -m "feat(menu),docs: пункт status в меню + раздел в README"
```

---

## Порядок и зависимости

Task 1 → Task 2 → Task 3 → {Task 4, Task 5 — независимы} .

## После завершения

Финальное ревью всей ветки (opus) → фиксы → merge `feature/pbx-status` в `main` + push (dkurokhtin/pbx). Ручной перенос обновлённого `pbx` на ноут; там `pbx status` покажет зеркальную картину (REPO-строки).
