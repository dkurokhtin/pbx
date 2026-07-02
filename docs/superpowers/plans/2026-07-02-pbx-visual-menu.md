# pbx v2 — визуал + интерактивное меню: план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Добавить в bash-скрипт `pbx` гейтированную палитру, рестайл вывода команд и интерактивное меню со стрелками при вызове голого `pbx`, не меняя plain-вывод и поведение для ИИ-агентов.

**Architecture:** Один bash-файл; вся новизна — в размеченной UI-секции перед `# ---- диспетчер ---`. Меню — тонкий сборщик argv поверх существующих `cmd_*` (guard и логика не дублируются). Спека: `docs/superpowers/specs/2026-07-02-pbx-visual-menu-design.md`.

**Tech Stack:** bash ≥ 5 (builtins: read/printf/stty/trap), git, tar, rsync. Никаких новых зависимостей.

## Global Constraints

- Файл `pbx` остаётся ОДНИМ самодостаточным bash-скриптом (перенос = копирование).
- **Байтовый инвариант plain-режима:** при non-TTY/`NO_COLOR`/`TERM=dumb` вывод каждой команды равен сегодняшнему тексту минус ANSI-коды. Исключение (одобрено): `pbx list` в пайпе печатает голые имена по строке.
- Неприкосновенны: эмодзи-маркеры `✅ ❌ 🔵 ⚠️ 🧭 📋` и тексты сообщений; формат `collect_diag`; fail-closed deliver-guard при non-TTY.
- Никакого интерактивного кода на top-level (тесты source-ят скрипт: `test_source_no_run`).
- Дисциплина `set -euo pipefail`: арифметика с возможным нулём — только `x=$((...))` или `(( ... )) || true`; `read` всегда в форме `read ... || fallback`; хелперы, чей последний statement может вернуть ≠0, заканчиваются `return 0`.
- В `printf '%-Ns'` подставлять только Latin-ключи (кириллица ломает выравнивание: паддинг по байтам).
- Тесты: `bash _tests/test_pbx.sh` из корня репо; ожидание в конце: `--- Итог: PASS=<N> FAIL=0 ---`, код возврата 0.
- Рабочая ветка: `feature/pbx-v2-visual-menu` (создаётся в Task 1). Коммит после каждого таска.
- Репо: `/mnt/c/Users/darkl/Claude/Projects/Pybotx`. Правки — в месте (без worktree: домашний pack должен видеть файл).

---

### Task 1: UI-детект, палитра, глифы + гейт цвета в `c_*`

**Files:**
- Modify: `pbx` (функции `c_blue/c_green/c_red/c_warn` ~строки 37–40; новая UI-секция перед `# ---- диспетчер ---`)
- Test: `_tests/test_pbx.sh`

**Interfaces:**
- Produces (top-level переменные, инициализируются при source):
  `UI_COLOR_OUT`, `UI_COLOR_ERR`, `UI_TTY` ∈ {0,1}; `UI_UTF8` ∈ {0,1};
  палитра `C_RESET C_BOLD C_DIM C_BLUE C_GREEN C_RED C_YELLOW C_CYAN C_GREY` (пустые строки при выключенном `UI_COLOR_OUT`);
  глифы `G_PTR G_BAR G_MID G_END G_OK G_NO` и линейка `G_HR` (ASCII-варианты при `UI_UTF8=0`).
- Produces: `c_blue/c_green/c_red/c_warn` — сигнатуры и тексты прежние, цвет условный.

- [ ] **Step 1: Создать ветку**

```bash
cd /mnt/c/Users/darkl/Claude/Projects/Pybotx
git checkout -b feature/pbx-v2-visual-menu
```

- [ ] **Step 2: Написать падающие тесты**

В `_tests/test_pbx.sh` добавить перед строкой `test_source_no_run` (блок вызовов внизу) — сначала функции (рядом с `# --- Task 1 ---`):

```bash
# --- UI: гейт цвета и глифы ---------------------------------------------------
test_color_gated_in_pipe() {
  # stdout не TTY → ANSI-кодов быть не должно ни на stdout, ни на stderr
  local reg; reg="$(make_ws)"
  local out; out="$(PBX_REGISTRY_DIR="$reg" bash "$PBX" list 2>&1)"
  assert_no "пайп: нет ANSI-кодов в list" "$out" $'\033'
  local err; err="$(bash "$PBX" nosuchcmd 2>&1 >/dev/null)" || true
  assert_no "пайп: нет ANSI-кодов на stderr (неизвестная команда)" "$err" $'\033'
  rm -rf "$reg"
}

test_ui_flags_nontty() {
  local out   # 2>/dev/null: при ручном запуске stderr — TTY, иначе UI_COLOR_ERR=1
  out="$(bash -c 'source "'"$PBX"'"; printf "%s %s %s" "$UI_COLOR_OUT" "$UI_COLOR_ERR" "$UI_TTY"' 2>/dev/null)"
  assert_eq "non-TTY: все UI-флаги нули" "$out" "0 0 0"
}

test_glyphs_ascii_fallback() {
  local g
  g="$(LC_ALL=C bash -c 'source "'"$PBX"'"; printf "%s%s%s" "$G_PTR" "$G_OK" "$G_BAR"')"
  assert_eq "LC_ALL=C: ASCII-глифы" "$g" ">*|"
  if locale -a 2>/dev/null | grep -qi 'C.UTF-8\|C.utf8'; then
    g="$(LC_ALL=C.UTF-8 bash -c 'source "'"$PBX"'"; printf "%s" "$G_PTR"')"
    assert_eq "UTF-8: юникод-глиф курсора" "$g" "▸"
  fi
}

test_c_funcs_respect_flags() {
  # механизм гейта: c_* красят строго по UI_COLOR_* (TTY в CI не эмулируем,
  # поэтому проверяем сам рычаг, форсируя флаги)
  local out
  out="$(bash -c 'source "'"$PBX"'"; UI_COLOR_OUT=1; c_blue hi')"
  assert_has "UI_COLOR_OUT=1 → c_blue с ANSI" "$out" $'\033[34m'
  out="$(bash -c 'source "'"$PBX"'"; UI_COLOR_OUT=0; c_blue hi')"
  assert_eq  "UI_COLOR_OUT=0 → c_blue без ANSI" "$out" "hi"
  out="$(bash -c 'source "'"$PBX"'"; UI_COLOR_ERR=1; c_warn hi' 2>&1 >/dev/null)"
  assert_has "UI_COLOR_ERR=1 → c_warn с ANSI"  "$out" $'\033[33m'
}
```

И зарегистрировать в блоке вызовов (после `test_source_no_run`):

```bash
test_color_gated_in_pipe
test_ui_flags_nontty
test_glyphs_ascii_fallback
test_c_funcs_respect_flags
```

- [ ] **Step 3: Прогнать тесты — убедиться, что падают**

Run: `bash _tests/test_pbx.sh 2>&1 | tail -20`
Expected: FAIL ≥ 3 — `нет ANSI-кодов` (сейчас коды безусловные), `UI-флаги` и глифы (переменных ещё нет; при `set -u` подстановки `$UI_COLOR_OUT` дают пустую строку/ошибку — любой из этих исходов считается «тест падает»).

- [ ] **Step 4: Реализация — UI-секция и гейт в `c_*`**

4a. Заменить четыре функции (строки 37–40 файла `pbx`):

```bash
c_blue()  { if (( ${UI_COLOR_OUT:-0} )); then printf '\033[34m%s\033[0m\n' "$*"; else printf '%s\n' "$*"; fi; }
c_green() { if (( ${UI_COLOR_OUT:-0} )); then printf '\033[32m%s\033[0m\n' "$*"; else printf '%s\n' "$*"; fi; }
c_red()   { if (( ${UI_COLOR_ERR:-0} )); then printf '\033[31m%s\033[0m\n' "$*" >&2; else printf '%s\n' "$*" >&2; fi; }
c_warn()  { if (( ${UI_COLOR_ERR:-0} )); then printf '\033[33m%s\033[0m\n' "$*" >&2; else printf '%s\n' "$*" >&2; fi; }
```

4b. Вставить перед `# ---- диспетчер ---`:

```bash
# =============================================================================
#  UI: палитра, глифы, интерактивное меню.
#  ВНИМАНИЕ (set -euo pipefail): арифметика с возможным 0 — только через
#  x=$((...)) или `(( ... )) || true`; read всегда с `|| fallback`.
#  Plain-режим (non-TTY/NO_COLOR/TERM=dumb) обязан быть байт-в-байт равен
#  прежнему выводу минус ANSI — его парсят ИИ-агенты.
# =============================================================================

# ---- детект возможностей (top-level, без вывода и побочных эффектов) --------
UI_COLOR_OUT=0; UI_COLOR_ERR=0; UI_TTY=0; UI_UTF8=0
if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != dumb ]]; then
  [[ -t 1 ]] && UI_COLOR_OUT=1
  [[ -t 2 ]] && UI_COLOR_ERR=1
fi
[[ -t 0 && -t 1 ]] && UI_TTY=1
case "$(locale charmap 2>/dev/null || true)" in UTF-8|utf8) UI_UTF8=1 ;; esac

# ---- палитра (пустые строки при выключенном цвете: printf-шаблоны едины) ----
if (( UI_COLOR_OUT )); then
  C_RESET=$'\033[0m'  C_BOLD=$'\033[1m'   C_DIM=$'\033[2m'
  C_BLUE=$'\033[34m'  C_GREEN=$'\033[32m' C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m' C_CYAN=$'\033[36m' C_GREY=$'\033[90m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_BLUE='' C_GREEN='' C_RED='' C_YELLOW='' C_CYAN='' C_GREY=''
fi

# ---- глифы (ASCII-fallback для не-UTF8 консолей) -----------------------------
if (( UI_UTF8 )); then
  G_PTR='▸' G_BAR='│' G_MID='├' G_END='└' G_OK='✓' G_NO='✗'
  G_HR='──────────────────────────────────────────────'
else
  G_PTR='>' G_BAR='|' G_MID='+' G_END='+' G_OK='*' G_NO='x'
  G_HR='----------------------------------------------'
fi
```

Примечание: `[[ -t 1 ]] && UI_COLOR_OUT=1` на top-level безопасно под `set -e` (провал условия в `&&`-списке не роняет скрипт), но обе строки внутри `if`-блока NO_COLOR — так однозначнее.

- [ ] **Step 5: Прогнать тесты — все зелёные**

Run: `bash _tests/test_pbx.sh 2>&1 | tail -5`
Expected: `FAIL=0`, все прежние тесты тоже зелёные (они захватывают вывод через `$()` → non-TTY → plain-режим, подстроки сохранены).

- [ ] **Step 6: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(ui): палитра и глифы с гейтом NO_COLOR/TTY — plain-вывод без ANSI-кодов"
```

---

### Task 2: Хелперы `ui_section`/`ui_kv`/`ui_dim`/`ui_summary` + рестайл pack

**Files:**
- Modify: `pbx` (UI-секция из Task 1; `cmd_pack` ~строки 228–242)
- Test: `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: `UI_COLOR_OUT`, `C_*`, `G_*`, `G_HR`, `c_blue` (Task 1).
- Produces:
  - `ui_section <TTY-заголовок> [plain-строка]` — TTY: `▸ заголовок` (bold-blue) + dim-линейка; plain: `c_blue "${2:-🔵 $1}"`.
  - `ui_kv <Latin-ключ> <значение>` — TTY-only выровненная пара; в plain — ничего (`return 0`).
  - `ui_dim <текст>` — TTY-only dim-строка; в plain — ничего.
  - `ui_summary <ветка> <MR-цель> <сообщение>` — TTY-only блок `│ ├ └`; в plain — ничего.

- [ ] **Step 1: Написать падающие тесты**

```bash
# --- UI: хелперы и plain-инвариант pack ---------------------------------------
test_ui_helpers_plain_silent() {
  # в plain-режиме TTY-only хелперы молчат и не роняют set -e
  local out
  out="$(bash -c 'set -euo pipefail; source "'"$PBX"'"; ui_kv SRC /x; ui_dim hint; ui_summary b t m; echo REACHED')"
  assert_eq "plain: ui_kv/ui_dim/ui_summary молчат, set -e жив" "$out" "REACHED"
}

test_ui_section_plain_invariant() {
  local out
  out="$(bash -c 'source "'"$PBX"'"; ui_section "Заголовок TTY" "🔵 Полная plain-строка"')"
  assert_eq "plain: ui_section печатает вторую форму" "$out" "🔵 Полная plain-строка"
  out="$(bash -c 'source "'"$PBX"'"; ui_section "Обновляю dev"')"
  assert_eq "plain: ui_section по умолчанию 🔵 + заголовок" "$out" "🔵 Обновляю dev"
}

test_pack_plain_invariant() {
  # байтовый инвариант: вывод pack в non-TTY идентичен прежнему (без ANSI)
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"; DIST_DIR="$ws/_dist"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  mkdir -p "$ws/proj/src"; echo hi > "$ws/proj/src/a.txt"
  local out; out="$(cmd_pack proj 2>&1)"
  local expected
  expected="$(printf '🔵 Упаковка proj (%s) → %s\n✅ Архив готов: %s' \
    "$ws/proj" "$ws/_dist/proj.tar.gz" "$ws/_dist/proj.tar.gz")"
  assert_eq "pack: plain-вывод байт-в-байт" "$out" "$expected"
  rm -rf "$ws" "$reg"
}
```

Регистрация: `test_ui_helpers_plain_silent`, `test_ui_section_plain_invariant`, `test_pack_plain_invariant` — после `test_c_funcs_respect_flags`.

- [ ] **Step 2: Прогнать — падают** (`ui_section: command not found` и т.п.)

Run: `bash _tests/test_pbx.sh 2>&1 | tail -10`

- [ ] **Step 3: Реализация**

3a. В UI-секцию после глифов:

```bash
# ---- статические UI-хелперы --------------------------------------------------
# ui_section <TTY-заголовок> [plain-строка]
# TTY: стилизованная шапка; plain: ровно прежняя строка (по умолчанию "🔵 <заголовок>").
ui_section() {
  if (( UI_COLOR_OUT )); then
    printf '\n%s%s %s%s\n%s%s%s\n' "$C_BOLD$C_BLUE" "$G_PTR" "$1" "$C_RESET" "$C_GREY" "$G_HR" "$C_RESET"
  else
    c_blue "${2:-🔵 $1}"
  fi
}

# ui_kv <Latin-ключ> <значение> — только TTY-украшение (в plain строк не добавляем).
ui_kv() {
  (( UI_COLOR_OUT )) || return 0
  printf '  %s%-8s%s %s\n' "$C_DIM" "$1" "$C_RESET" "$2"
}

# ui_dim <текст> — второстепенная dim-строка, только TTY.
ui_dim() {
  (( UI_COLOR_OUT )) || return 0
  printf '  %s%s%s\n' "$C_DIM" "$*" "$C_RESET"
}

# ui_summary <ветка> <MR-цель> <сообщение> — итоговый блок доставки, только TTY.
ui_summary() {
  (( UI_COLOR_OUT )) || return 0
  printf ' %s%s%s ветка      %s\n' "$C_GREY" "$G_MID" "$C_RESET" "$1"
  printf ' %s%s%s MR →       %s\n' "$C_GREY" "$G_MID" "$C_RESET" "$2"
  printf ' %s%s%s сообщение  %s\n' "$C_GREY" "$G_END" "$C_RESET" "$3"
}
```

3b. В `cmd_pack` заменить строку `c_blue "🔵 Упаковка $project ($SRC) → $out"` на:

```bash
  ui_section "Упаковка $project" "🔵 Упаковка $project ($SRC) → $out"
  ui_kv SRC "$SRC"
  ui_kv OUT "$out"
```

и после строки `tar ...` перед `c_green "✅ Архив готов: $out"` добавить:

```bash
  ui_dim "размер: $(du -h "$out" | awk '{print $1}')"
```

- [ ] **Step 4: Прогнать тесты — зелёные** (в т.ч. прежние `test_pack_e2e*`)

Run: `bash _tests/test_pbx.sh 2>&1 | tail -5` → `FAIL=0`

- [ ] **Step 5: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(ui): ui_section/ui_kv/ui_dim/ui_summary + рестайл pack (plain-инвариант)"
```

---

### Task 3: Рестайл deliver и deliver-guard

**Files:**
- Modify: `pbx` (`cmd_deliver`: строки с `c_blue "🔵 Обновляю..."`, `c_blue "🔵 Синхронизирую..."`, `c_blue "📋 Будет закоммичено..."`, guard-блок удалений, финальные `c_green`)
- Test: `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: `ui_section`, `ui_summary`, `UI_COLOR_ERR`, `C_*` (Tasks 1–2).
- Produces: только визуальные изменения; сигнатура и коды возврата `cmd_deliver` прежние.

- [ ] **Step 1: Написать падающий тест plain-инварианта guard**

```bash
test_deliver_guard_plain_invariant() {
  # тексты guard в plain неизменны и без ANSI (протокол агентов)
  local base; base="$(make_ws)"
  local remote="$base/remote.git" repo="$base/repo" src="$base/src"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  local dist="$base/_dist"; DIST_DIR="$dist"; mkdir -p "$dist"
  unset PBX_BASE_BRANCH PBX_TARGET_BRANCH PBX_FORGE PBX_ASSUME_YES
  git init -q --bare "$remote"; git init -q "$repo"
  ( cd "$repo" && git config user.email t@t && git config user.name t \
    && git remote add origin "$remote" && git checkout -q -b dev \
    && echo keep > file.txt && echo role > roles.txt \
    && git add -A && git commit -q -m init && git push -q -u origin dev ) >/dev/null 2>&1
  mkdir -p "$src"; echo keep > "$src/file.txt"   # снимок без roles.txt → удаление
  tar -C "$(dirname "$src")" -czf "$dist/proj.tar.gz" "$(basename "$src")"
  printf 'SRC=%s\nREPO=%s\nBASE_BRANCH=dev\nTARGET_BRANCH=dev\nFORGE=none\n' \
    "$src" "$repo" > "$reg/proj.conf"

  local out
  out="$( ( cmd_deliver "proj" "feature/T-8" "msg" "$dist/proj.tar.gz" </dev/null 2>&1 ) )" || true
  assert_has "guard plain: строка 📋"            "$out" "📋 Будет закоммичено в 'feature/T-8' → MR в 'dev' (git diff --cached --stat):"
  assert_has "guard plain: заголовок удалений"   "$out" "⚠️  БУДУТ УДАЛЕНЫ файлы из 'dev'"
  assert_has "guard plain: имя удаляемого файла" "$out" "- roles.txt"
  assert_no  "guard plain: без ANSI"             "$out" $'\033'
  cd "$HERE"; rm -rf "$base" "$reg"
}
```

Регистрация после `test_deliver_guard_blocks_deletions`.

- [ ] **Step 2: Прогнать** — этот тест сейчас ЗЕЛЁНЫЙ (c_* уже гейтированы в Task 1): он — страховочная сетка рефакторинга. Убедиться: `FAIL=0`.

- [ ] **Step 3: Реализация рестайла**

3a. `c_blue "🔵 Обновляю $BASE_BRANCH"` → `ui_section "Обновляю $BASE_BRANCH"`

3b. `c_blue "🔵 Синхронизирую файлы в $repo"` → `ui_section "Синхронизирую файлы в $repo"`

3c. `c_blue "📋 Будет закоммичено в '$branch' → MR в '$TARGET_BRANCH' (git diff --cached --stat):"` →

```bash
  ui_section "Изменения к доставке" \
    "📋 Будет закоммичено в '$branch' → MR в '$TARGET_BRANCH' (git diff --cached --stat):"
  ui_kv BRANCH "$branch"
  ui_kv TARGET "$TARGET_BRANCH"
```

3d. В guard-блоке удалений — TTY-only счётчик ПЕРЕД существующим `c_warn "⚠️  БУДУТ УДАЛЕНЫ..."` (тексты c_warn не менять):

```bash
  if [[ -n "$deleted" ]]; then
    if (( UI_COLOR_ERR )); then
      local ndel; ndel="$(printf '%s\n' "$deleted" | wc -l | tr -d ' ')"
      printf '\033[1;31m%s удалений: %s\033[0m\n' "$G_NO" "$ndel" >&2
    fi
    c_warn "⚠️  БУДУТ УДАЛЕНЫ файлы из '$BASE_BRANCH' (частая причина — устаревший снимок + rsync --delete):"
    while IFS= read -r f; do c_warn "     - $f"; done <<< "$deleted"
  fi
```

3e. Промпт подтверждения — bold в TTY (текст прежний):

```bash
  local ans="" prompt="Проверь список выше. Продолжить коммит и пуш MR? [y/N] "
  if (( UI_COLOR_ERR )); then prompt=$'\033[1m'"$prompt"$'\033[0m'; fi
  read -r -p "$prompt" ans
```

3f. После финальных `c_green "✅ ..."` (обе ветки case FORGE) добавить одной строкой после case:

```bash
  ui_summary "$branch" "$TARGET_BRANCH" "${msg%%$'\n'*}"
```

- [ ] **Step 4: Прогнать тесты — зелёные**

Run: `bash _tests/test_pbx.sh 2>&1 | tail -5` → `FAIL=0` (включая `test_deliver_uses_repo`, `test_deliver_guard_blocks_deletions`, новый инвариант).

- [ ] **Step 5: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(ui): рестайл deliver и guard — счётчик удалений, сводка, plain неизменен"
```

---

### Task 4: `pbx list` — TTY-таблица, в пайпе голые имена

**Files:**
- Modify: `pbx` (`cmd_list` ~строки 192–197)
- Test: `_tests/test_pbx.sh`
- Аудит потребителей: `~/.claude/hooks/pbx_deliver_reminder.py` (grep на `pbx list`)

**Interfaces:**
- Consumes: `ui_section`, `list_projects`, `load_config`, `C_*`, `G_OK/G_NO` .
- Produces: `cmd_list` — пайп: имена по строке (без маркеров/заголовка на stdout); TTY: таблица.

- [ ] **Step 1: Написать падающий тест**

```bash
test_list_pipe_bare_names() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  unset PBX_IGNORE_DIRS
  mkdir -p "$ws/alpha" "$ws/beta"
  local out; out="$(cmd_list 2>/dev/null)"
  assert_eq "list в пайпе: голые имена по строке" "$out" "$(printf 'alpha\nbeta')"
  rm -rf "$ws" "$reg"
}
```

Регистрация после `test_list_union`.

- [ ] **Step 2: Прогнать — падает** (сейчас в выводе `🔵 Проекты...` и `  • alpha`).

- [ ] **Step 3: Реализация — заменить `cmd_list` целиком**

```bash
cmd_list() {
  # Пайп/агенты: стабильный machine-readable формат — голые имена по строке.
  if (( ! UI_COLOR_OUT )); then
    list_projects
    return 0
  fi
  # TTY: таблица со статусами. load_config мутирует глобали — cmd_list терминальна.
  ui_section "Проекты (реестр ∪ WORKSPACE)"
  local p mark arch info any=0
  while IFS= read -r p; do
    any=1
    load_config "$p"
    if [[ -d "$SRC" ]]; then mark="${C_GREEN}${G_OK}${C_RESET}"; else mark="${C_RED}${G_NO}${C_RESET}"; fi
    arch="$DIST_DIR/$p.tar.gz"
    if [[ -f "$arch" ]]; then
      info="$(du -h "$arch" 2>/dev/null | awk '{print $1}'), $(date -r "$arch" '+%d.%m %H:%M' 2>/dev/null || echo '?')"
    else
      info="—"
    fi
    printf '  %-16s SRC %s  %sархив:%s %s\n' "$p" "$mark" "$C_DIM" "$C_RESET" "$info"
  done < <(list_projects)
  (( any )) || c_warn "  (проектов не найдено)"
  return 0
}
```

- [ ] **Step 4: Аудит потребителей формата**

Run: `grep -rn 'pbx list\|pbx ls' ~/.claude/hooks/ _tests/ 2>/dev/null`
Expected: в `pbx_deliver_reminder.py` вызовов `pbx list` нет (хук матчит текст промпта). Если найдётся потребитель, парсящий `  • имя`, — поправить его в этом же таске.

- [ ] **Step 5: Прогнать тесты — зелёные** (`test_list_projects`/`test_list_union` работают с `list_projects` напрямую — не задеты; `test_scan_then_list` тоже).

- [ ] **Step 6: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(list): TTY-таблица со статусами; в пайпе — голые имена (machine-readable)"
```

---

### Task 5: Рестайл help (TTY-стили, plain-heredoc неизменен)

**Files:**
- Modify: `pbx` (`cmd_help` ~строки 535–577)
- Test: `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: `UI_COLOR_OUT`, `C_*`.
- Produces: `cmd_help` — plain: прежний квотированный heredoc байт-в-байт; TTY: стилизованная версия.

- [ ] **Step 1: Написать падающий тест… который здесь — регрессионный (plain уже верен): фиксируем инвариант**

```bash
test_help_plain_invariant() {
  local out; out="$(bash "$PBX" help 2>&1)"
  assert_has "help plain: шапка"        "$out" "pbx — доставка проектов Pybotx (WSL)"
  assert_has "help plain: команда pack" "$out" "pbx pack    <проект>"
  assert_has "help plain: реестр"       "$out" "Реестр проектов"
  assert_no  "help plain: без ANSI"     "$out" $'\033'
}
```

Регистрация после `test_list_pipe_bare_names`. Прогнать: зелёный (сетка).

- [ ] **Step 2: Реализация — обернуть `cmd_help`**

Существующий `cat <<'EOF' ... EOF` оставить как ветку plain. Сверху добавить TTY-ветку (НЕквотированный heredoc: `$C_*` раскрываются; литеральные `$` экранированы как `\$`, бэктики как `\``):

```bash
cmd_help() {
  if (( ! UI_COLOR_OUT )); then
    cat <<'EOF'
… (существующий текст справки, без изменений) …
EOF
    return 0
  fi
  cat <<EOF
${C_BOLD}pbx${C_RESET} — доставка проектов Pybotx (WSL)

${C_BOLD}Команды${C_RESET}
  ${C_CYAN}pbx pack${C_RESET}    <проект>                ${C_DIM}упаковать в _dist/<проект>.tar.gz${C_RESET}
  ${C_CYAN}pbx deliver${C_RESET} <проект> <ветка> <сообщение> [архив] [--yes]
                                          ${C_DIM}распаковать в репо, ветка от BASE_BRANCH, MR/PR в TARGET_BRANCH${C_RESET}
                                          ${C_DIM}перед коммитом показывает changeset и просит подтверждения${C_RESET}
  ${C_CYAN}pbx log${C_RESET}     [проект]                ${C_DIM}диагностика для ИИ-агента → stdout + _dist/pbx-<проект>.log${C_RESET}
  ${C_CYAN}pbx add${C_RESET}     <имя> [путь]            ${C_DIM}завести проект в реестр (SRC=путь|\$PWD)${C_RESET}
  ${C_CYAN}pbx scan${C_RESET}    (--repo|--src) [каталог] [--dry-run]  ${C_DIM}заполнить реестр из найденных репо${C_RESET}
  ${C_CYAN}pbx list${C_RESET}                            ${C_DIM}показать проекты (реестр ∪ WORKSPACE)${C_RESET}
  ${C_CYAN}pbx${C_RESET}                                 ${C_DIM}интерактивное меню (в терминале; PBX_NO_MENU=1 — отключить)${C_RESET}

${C_BOLD}Примеры${C_RESET}
  pbx pack sup
  pbx deliver sup feature/SUBA-2147-fix-name "Описание изменений"
  pbx log sup

${C_BOLD}Окружение${C_RESET}  ${C_DIM}PBX_WORKSPACE PBX_PROJECTS_ROOT PBX_DIST_DIR PBX_BASE_BRANCH${C_RESET}
            ${C_DIM}PBX_TARGET_BRANCH PBX_FORGE PBX_ASSUME_YES PBX_NO_MENU${C_RESET}

${C_DIM}Конфиги и реестр: подробности в plain-справке (pbx help | cat) и README.${C_RESET}
EOF
}
```

- [ ] **Step 3: Прогнать тесты — зелёные**; глазами проверить TTY-вид: `bash pbx help` в терминале.

- [ ] **Step 4: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(help): стилизованная TTY-справка; plain-heredoc неизменен"
```

---

### Task 6: `menu_select_plain` — нумерованный fallback

**Files:**
- Modify: `pbx` (UI-секция)
- Test: `_tests/test_pbx.sh`

**Interfaces:**
- Produces: `menu_select_plain <заголовок> <пункт...>` — список и промпт в **stderr**; выбранный индекс (0-based) в stdout; rc=0 выбор, rc=130 отмена (`q`/EOF).

- [ ] **Step 1: Падающие тесты**

```bash
# --- меню: plain-fallback ------------------------------------------------------
test_menu_select_plain_choice() {
  local out rc=0
  out="$(printf '2\n' | { source "$PBX"; menu_select_plain "t" alpha beta gamma; })" || rc=$?
  assert_eq "plain-меню: выбор 2 → индекс 1" "$out" "1"
  assert_eq "plain-меню: rc=0" "$rc" "0"
}
test_menu_select_plain_cancel() {
  local out rc=0
  out="$(printf 'q\n' | { source "$PBX"; menu_select_plain "t" a b; })" || rc=$?
  assert_eq "plain-меню: q → отмена rc=130" "$rc" "130"
  assert_eq "plain-меню: stdout пуст при отмене" "$out" ""
}
test_menu_select_plain_eof() {
  local rc=0
  ( source "$PBX"; menu_select_plain "t" a b </dev/null >/dev/null 2>&1 ) || rc=$?
  assert_eq "plain-меню: EOF → 130 (не виснет)" "$rc" "130"
}
test_menu_select_plain_invalid_then_valid() {
  local out
  out="$(printf 'x\n9\n1\n' | { source "$PBX"; menu_select_plain "t" a b; } 2>/dev/null)"
  assert_eq "plain-меню: мусор/вне диапазона переспрашивается" "$out" "0"
}
```

Регистрация после `test_help_plain_invariant`.

- [ ] **Step 2: Прогнать — падают** (`menu_select_plain: command not found`).

- [ ] **Step 3: Реализация** (в UI-секцию):

```bash
# ---- интерактивное меню -------------------------------------------------------
# menu_select_plain <заголовок> <пункт...> — нумерованный fallback без raw-режима.
# Список/промпт в stderr; индекс (0-based) в stdout; rc: 0 выбор, 130 отмена/EOF.
menu_select_plain() {
  local title="$1"; shift
  local -a opts=("$@")
  local n=${#opts[@]} i choice
  printf '%s\n' "$title" >&2
  for i in "${!opts[@]}"; do printf '  %d) %s\n' "$((i+1))" "${opts[i]}" >&2; done
  while :; do
    printf 'Выбор [1-%d, q — отмена]: ' "$n" >&2
    IFS= read -r choice || return 130
    choice="$(strip_cr "$choice")"
    [[ "$choice" == q ]] && return 130
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )); then
      printf '%s\n' "$((choice-1))"
      return 0
    fi
  done
}
```

- [ ] **Step 4: Прогнать — зелёные.**

- [ ] **Step 5: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(menu): menu_select_plain — нумерованный fallback (stderr-рисование, индекс в stdout)"
```

---

### Task 7: raw-обвязка + `menu_select` со стрелками

**Files:**
- Modify: `pbx` (UI-секция, после `menu_select_plain`)
- Test: `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: `menu_select_plain` (Task 6), `C_*`, `G_PTR`, `G_HR`.
- Produces:
  - `ui_raw_on` (rc≠0 = raw недоступен) / `ui_raw_off` (идемпотентна; восстанавливает stty и курсор; безопасна как EXIT-trap).
  - `menu_select <заголовок> <пункт...>` — контракт как у `menu_select_plain`; при недоступном raw сам падает в plain-вариант.

- [ ] **Step 1: Падающие тесты** (raw в CI недоступен — тестируем контракт и fallback):

```bash
test_menu_select_falls_back_to_plain() {
  # stdin — пайп → stty провалится → должен отработать plain-путь
  local out rc=0
  out="$(printf '1\n' | { source "$PBX"; menu_select "t" one two; } 2>/dev/null)" || rc=$?
  assert_eq "menu_select: fallback в plain, выбор 1 → 0" "$out" "0"
  assert_eq "menu_select: rc=0" "$rc" "0"
}
test_ui_raw_off_idempotent() {
  local out
  out="$(bash -c 'set -euo pipefail; source "'"$PBX"'"; ui_raw_off; ui_raw_off; echo REACHED' 2>/dev/null)"
  assert_eq "ui_raw_off дважды не падает под set -e" "$out" "REACHED"
}
```

Регистрация после plain-меню-тестов.

- [ ] **Step 2: Прогнать — падают.**

- [ ] **Step 3: Реализация**

```bash
# ---- raw-режим терминала -------------------------------------------------------
# Ctrl+C/Ctrl+Z читаем байтами (-isig): отмена = данные, не сигнал.
UI_STTY_SAVED=''
ui_raw_on() {
  UI_STTY_SAVED="$(stty -g 2>/dev/null)" || { UI_STTY_SAVED=''; return 1; }
  [[ -n "$UI_STTY_SAVED" ]] || return 1
  if ! stty -echo -icanon -isig min 1 time 0 2>/dev/null; then
    stty "$UI_STTY_SAVED" 2>/dev/null || true
    UI_STTY_SAVED=''
    return 1
  fi
  printf '\033[?25l' >&2   # спрятать курсор
  return 0
}
ui_raw_off() {
  if [[ -n "${UI_STTY_SAVED:-}" ]]; then
    stty "$UI_STTY_SAVED" 2>/dev/null || true
    UI_STTY_SAVED=''
    printf '\033[?25h' >&2   # показать курсор
  fi
  return 0
}

# menu_select <заголовок> <пункт...> — стрелочное меню.
# Рисует в stderr; индекс в stdout; rc: 0 выбор, 130 отмена.
# Клавиши: ↑/↓ (ESC[A/B и ESCOA/B), k/j, 1-9 — прыжок+выбор, Enter, Esc/q/Ctrl+C.
menu_select() {
  local title="$1"; shift
  local -a opts=("$@")
  local n=${#opts[@]} cur=0 drawn=0 key seq i
  (( n > 0 )) || return 130
  if ! ui_raw_on; then
    menu_select_plain "$title" "${opts[@]}"
    return $?
  fi
  while :; do
    if (( drawn )); then printf '\033[%dA' "$((n+2))" >&2; fi
    drawn=1
    printf '\r\033[K%s%s%s\n' "$C_BOLD$C_BLUE" "$title" "$C_RESET" >&2
    printf '\r\033[K%s%s%s\n' "$C_GREY" "$G_HR" "$C_RESET" >&2
    for i in "${!opts[@]}"; do
      if (( i == cur )); then
        printf '\r\033[K %s%s %s%s\n' "$C_BOLD$C_CYAN" "$G_PTR" "${opts[i]}" "$C_RESET" >&2
      else
        printf '\r\033[K   %s\n' "${opts[i]}" >&2
      fi
    done
    IFS= read -rsn1 key || { ui_raw_off; return 130; }
    case "$key" in
      $'\x1b')                                  # ESC: стрелка или голый Esc
        seq=''
        IFS= read -rsn1 -t 0.05 seq || true
        if [[ "$seq" == '[' || "$seq" == 'O' ]]; then
          IFS= read -rsn1 -t 0.05 seq || true
          case "$seq" in
            A) cur=$(( (cur - 1 + n) % n )) ;;
            B) cur=$(( (cur + 1) % n )) ;;
          esac
        else
          ui_raw_off; return 130                 # голый Esc = отмена
        fi
        ;;
      k) cur=$(( (cur - 1 + n) % n )) ;;
      j) cur=$(( (cur + 1) % n )) ;;
      [1-9])
        if (( key <= n )); then
          cur=$((key - 1))
          ui_raw_off
          printf '%s\n' "$cur"
          return 0
        fi
        ;;
      q|$'\x03'|$'\x04')                         # q / Ctrl+C / Ctrl+D
        ui_raw_off; return 130
        ;;
      ''|$'\n'|$'\r')                            # Enter
        ui_raw_off
        printf '%s\n' "$cur"
        return 0
        ;;
    esac
  done
}
```

- [ ] **Step 4: Прогнать тесты — зелёные.** Ручная проверка в терминале: `bash -c 'source ./pbx; menu_select "тест" раз два три; echo "→ $?"'` — стрелки/j·k/цифры/Enter/Esc, курсор восстановлен.

- [ ] **Step 5: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(menu): menu_select — стрелочное меню на read -rsn1 с raw-обвязкой и fallback"
```

---

### Task 8: Экраны меню (`cmd_menu`) + гейт в `main()`

**Files:**
- Modify: `pbx` (UI-секция: `cmd_menu`, `menu_project_flow`, `menu_pause`; диспетчер `main()` ~строки 580–592)
- Test: `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: `menu_select` (Task 7), `list_projects`, `cmd_pack/cmd_deliver/cmd_log/cmd_list/cmd_help`, `strip_cr`, `ui_dim`, `c_blue/c_warn`, `UI_TTY`.
- Produces:
  - `cmd_menu` — цикл главного меню; ставит `trap 'ui_raw_off' EXIT`.
  - `menu_project_flow <pack|deliver|log>` — rc=0 «выйти из меню», rc=1 «вернуться в меню».
  - `main()` — гейт: argv пуст ∧ `UI_TTY` ∧ `TERM` ∉ {dumb, unknown, ""} ∧ `-z PBX_NO_MENU` → `cmd_menu`, иначе `cmd_help`.

- [ ] **Step 1: Падающие тесты**

```bash
# --- меню: гейт и e2e -----------------------------------------------------------
test_menu_gate_nontty_help() {
  local out rc=0
  out="$(bash "$PBX" </dev/null 2>&1)" || rc=$?
  assert_eq "гейт: non-TTY голый pbx → rc=0"  "$rc" "0"
  assert_has "гейт: non-TTY голый pbx → help" "$out" "pbx — доставка проектов Pybotx"
}
test_menu_gate_no_menu_env() {
  local out   # TERM=xterm: гейт не должен отпасть по TERM — проверяем именно PBX_NO_MENU
  out="$(printf '' | { source "$PBX"; UI_TTY=1; TERM=xterm PBX_NO_MENU=1 main; } 2>&1)"
  assert_has "гейт: PBX_NO_MENU=1 → help даже при UI_TTY=1" "$out" "pbx — доставка проектов Pybotx"
}
test_menu_exit_item() {
  # UI_TTY=1 + plain-fallback меню: пункт «выход» (8) завершает без действий
  local rc=0
  ( printf '8\n' | { source "$PBX"; UI_TTY=1; TERM=xterm main; } >/dev/null 2>&1 ) || rc=$?
  assert_eq "меню: выбор «выход» → rc=0" "$rc" "0"
}
test_menu_pack_e2e() {
  local ws; ws="$(make_ws)"
  local reg; reg="$(make_ws)"
  mkdir -p "$ws/proj/src"; echo hi > "$ws/proj/src/a.txt"
  # 1 = pack; затем 1 = первый проект; plain-фолбэк меню читает пайп
  ( printf '1\n1\n' | {
      source "$PBX"
      WORKSPACE="$ws"; DIST_DIR="$ws/_dist"; PBX_REGISTRY_DIR="$reg"; UI_TTY=1
      TERM=xterm main
    } ) >/dev/null 2>&1 || true
  assert_has "меню e2e: pack создал архив" "$(ls "$ws/_dist" 2>/dev/null)" "proj.tar.gz"
  rm -rf "$ws" "$reg"
}
test_menu_cancel_returns_cleanly() {
  local rc=0
  ( printf 'q\n' | { source "$PBX"; UI_TTY=1; TERM=xterm main; } >/dev/null 2>&1 ) || rc=$?
  assert_eq "меню: отмена на первом экране → rc=0" "$rc" "0"
}
```

Регистрация после raw-тестов Task 7. Все — в субшеллах `( … )`, чтобы `trap EXIT` из `cmd_menu` не жил в шелле тестового харнесса.

- [ ] **Step 2: Прогнать — падают** (гейта и `cmd_menu` нет; голый `pbx` сейчас печатает help — первый тест зелёный, остальные красные).

- [ ] **Step 3: Реализация**

3a. В UI-секцию:

```bash
# ---- экраны меню ----------------------------------------------------------------
menu_pause() {
  printf '%s' "Enter — в меню " >&2
  IFS= read -r _ || true
  return 0
}

# menu_project_flow <pack|deliver|log>: выбор проекта → параметры → вызов cmd_*.
# rc=0 — команда выполнена, выйти из меню; rc=1 — вернуться в меню.
menu_project_flow() {
  local action="$1" idx project branch msg
  local -a projects=()
  mapfile -t projects < <(list_projects)
  if (( ${#projects[@]} == 0 )); then
    c_warn "(проектов не найдено — заведи: pbx add / pbx scan)"
    return 1
  fi
  idx="$(menu_select "Проект:" "${projects[@]}")" || return 1
  project="${projects[idx]}"
  case "$action" in
    pack)
      cmd_pack "$project"
      return 0
      ;;
    log)
      cmd_log "$project"
      menu_pause
      return 1
      ;;
    deliver)
      if [[ -t 0 ]]; then
        read -e -r -i "feature/" -p "Ветка: " branch || return 1
      else
        printf 'Ветка: ' >&2
        IFS= read -r branch || return 1
      fi
      branch="$(strip_cr "$branch")"
      if [[ -z "$branch" || "$branch" == "feature/" ]]; then
        c_warn "(ветка не задана — отмена)"
        return 1
      fi
      printf 'Сообщение коммита: ' >&2
      IFS= read -r msg || return 1
      msg="$(strip_cr "$msg")"
      if [[ -z "$msg" ]]; then
        c_warn "(сообщение пустое — отмена)"
        return 1
      fi
      ui_dim "→ pbx deliver $project $branch \"$msg\""
      cmd_deliver "$project" "$branch" "$msg"
      return 0
      ;;
  esac
  return 1
}

cmd_menu() {
  trap 'ui_raw_off' EXIT          # страховка: терминал не остаётся в raw при любом выходе
  local idx
  local -a items=(
    'pack    — упаковать проект в архив'
    'deliver — доставить архив в репо (ветка + MR)'
    'log     — диагностика проекта'
    'list    — список проектов'
    'scan    — заполнить реестр (подсказка)'
    'add     — добавить проект (подсказка)'
    'help    — справка'
    'выход'
  )
  while :; do
    idx="$(menu_select "pbx — что делаем?" "${items[@]}")" || { printf '\n' >&2; return 0; }
    case "$idx" in
      0) if menu_project_flow pack;    then return 0; fi ;;
      1) if menu_project_flow deliver; then return 0; fi ;;
      2) menu_project_flow log || true ;;
      3) cmd_list; menu_pause ;;
      4) c_blue "🔵 Синтаксис: pbx scan (--repo|--src) [каталог] [--dry-run]"; return 0 ;;
      5) c_blue "🔵 Синтаксис: pbx add <имя> [путь-SRC]"; return 0 ;;
      6) cmd_help; menu_pause ;;
      7) return 0 ;;
    esac
  done
}
```

3b. Заменить `main()` (диспетчер):

```bash
main() {
  if (( $# == 0 )); then
    if (( UI_TTY )) && [[ -z "${PBX_NO_MENU:-}" ]] \
       && [[ -n "${TERM:-}" && "${TERM:-}" != dumb && "${TERM:-}" != unknown ]]; then
      cmd_menu
    else
      cmd_help
    fi
    return 0
  fi
  local cmd="$1"; shift || true
  case "$cmd" in
    pack)               require_wsl; cmd_pack "$@" ;;
    deliver|update)     require_wsl; cmd_deliver "$@" ;;
    add)                require_wsl; cmd_add "$@" ;;
    scan)               require_wsl; cmd_scan "$@" ;;
    log)                cmd_log "$@" ;;
    list|ls)            cmd_list ;;
    help|-h|--help)     cmd_help ;;
    *) c_red "Неизвестная команда: $cmd"; echo; cmd_help; exit 1 ;;
  esac
}
```

Внимание: `pack/deliver/log` в меню вызываются БЕЗ `require_wsl` — меню доступно только человеку в терминале; при желании добавить `require_wsl` первой строкой `cmd_menu` (предупреждение, не блок) — сделать именно так.

- [ ] **Step 4: Прогнать тесты — зелёные** (в т.ч. e2e меню-pack). Ручная проверка: `bash pbx` в терминале — пройти стрелками pack→проект, Esc-отмены, Ctrl+C, `PBX_NO_MENU=1 bash pbx` → help.

- [ ] **Step 5: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(menu): экраны меню и гейт в main() — pack/deliver/log/list через меню"
```

---

### Task 9: README, чек-лист терминалов, финальный прогон

**Files:**
- Modify: `README.md`
- Create: `docs/superpowers/checklists/2026-07-02-pbx-menu-terminals.md`
- (опционально) Regenerate: `docs/pbx-demo.svg` — если найдётся генератор `make_cast.py`

**Interfaces:**
- Consumes: всё предыдущее; поведение уже стабильно.

- [ ] **Step 1: README — добавить раздел про меню**

После раздела с командами (искать заголовок про команды/использование) добавить:

```markdown
## Интерактивное меню

Голый `pbx` в терминале открывает меню: стрелки ↑/↓ (или j/k, или цифры),
Enter — выбрать, Esc/q — отмена. Пункты pack/deliver/log ведут через выбор
проекта; deliver дальше спросит ветку (подставит `feature/`) и сообщение —
и выполнит обычный `pbx deliver` со всеми страховками (guard остаётся).

Меню включается только когда stdin и stdout — терминал. Скрипты и ИИ-агенты
ничего не заметят: `pbx` без аргументов в пайпе печатает справку, как раньше.
Отключить насовсем: `PBX_NO_MENU=1`.

Цвет теперь гейтирован: в пайпе/редиректе вывод — чистый plain-текст
(соблюдается `NO_COLOR`, `TERM=dumb`).
```

В таблицу/список переменных окружения README (если есть) добавить `PBX_NO_MENU`.

- [ ] **Step 2: Чек-лист ручной проверки терминалов**

Создать `docs/superpowers/checklists/2026-07-02-pbx-menu-terminals.md`:

```markdown
# pbx-меню: ручной чек-лист терминалов

Для каждого терминала: `bash pbx` (или `pbx` после установки симлинка).

| Проверка | Windows Terminal (WSL) | VS Code terminal | ssh → ноут |
|---|---|---|---|
| Меню открывается, стрелки ↑/↓ работают | | | |
| j/k и цифры 1-9 работают | | | |
| Enter выбирает, Esc и q отменяют | | | |
| Ctrl+C в меню: выход, терминал не сломан (echo работает, курсор виден) | | | |
| deliver-флоу: ветка с подстановкой feature/, сообщение, guard показан | | | |
| `pbx | cat` → справка без ANSI-кодов, не виснет | | | |
| `PBX_NO_MENU=1 pbx` → справка | | | |
| Глифы читаемы (▸ │ ✓); если кракозябры — проверить `locale charmap` | | | |
```

- [ ] **Step 3: Демо (опционально)**

Run: `find /mnt/c/Users/darkl/Claude/Projects/Pybotx -maxdepth 2 -name 'make_cast.py'`
- Если найден: добавить в сценарий кадры меню (заставка меню + выбор pack), затем `python3 make_cast.py && npx svg-term-cli --in demo.cast --out docs/pbx-demo.svg --window` (как в прошлой генерации). Если хвост инструментов не собирается — пропустить без блокировки задачи.
- Если не найден: пропустить, README-скрин остаётся прежним.

- [ ] **Step 4: Финальный полный прогон + ручной smoke**

```bash
bash _tests/test_pbx.sh 2>&1 | tail -3     # ожидание: FAIL=0
bash pbx list | cat                         # голые имена, без ANSI
bash pbx </dev/null                         # help, мгновенно
```

Ручной прогон меню по чек-листу минимум в одном терминале (Windows Terminal).

- [ ] **Step 5: Commit**

```bash
git add README.md docs/superpowers/checklists/2026-07-02-pbx-menu-terminals.md docs/pbx-demo.svg 2>/dev/null || git add README.md docs/superpowers/checklists/2026-07-02-pbx-menu-terminals.md
git commit -m "docs: меню в README + чек-лист ручной проверки терминалов"
```

---

## Порядок и зависимости

Task 1 → Task 2 → {Task 3, Task 4, Task 5 — независимы, любой порядок} → Task 6 → Task 7 → Task 8 → Task 9.

## После завершения

Ветка `feature/pbx-v2-visual-menu` — слить в `main` и запушить (репо личный, dkurokhtin/pbx). Перенос на ноут — вручную скопировать обновлённый `pbx` в root, как заведено. Напомнить пользователю про ручную проверку меню на ноуте (ssh-строка чек-листа).
