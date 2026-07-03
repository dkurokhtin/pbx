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

# Грузим функции pbx в текущий шелл (main не запустится из-за guard)
source "$PBX"
set +eo pipefail   # source включил errexit из pbx — выключаем для тестов

# Изоляция: тесты не должны видеть реальный реестр пользователя
PBX_REGISTRY_DIR="$(mktemp -d)"   # пустой каталог по умолчанию

# Утилита: создать временный WORKSPACE и вернуть путь
make_ws() { mktemp -d; }

# git-репо с remote (без коммитов достаточно для обнаружения)
mk_repo() { git init -q "$1"; git -C "$1" remote add origin "$2"; }
# git-репо БЕЗ remote (контейнер)
mk_container() { git init -q "$1"; }

# --- Task 1 -----------------------------------------------------------------
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

test_source_no_run() {
  local out; out="$(bash -c 'source "'"$PBX"'"' 2>&1)"
  assert_eq "source не запускает main (пустой вывод)" "$out" ""
}

# --- Task 2: load_config ----------------------------------------------------
test_defaults() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  unset PBX_BASE_BRANCH PBX_TARGET_BRANCH PBX_FORGE
  mkdir -p "$ws/proj"
  load_config "proj"
  assert_eq "дефолт BASE_BRANCH"   "$BASE_BRANCH"   "dev"
  assert_eq "дефолт TARGET_BRANCH" "$TARGET_BRANCH" "dev"
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
  unset PBX_BASE_BRANCH PBX_FORGE
  mkdir -p "$ws/proj"
  printf 'TARGET_BRANCH=bbb\n' > "$ws/proj/.pbx.conf"
  PBX_TARGET_BRANCH=ccc load_config "proj"
  assert_eq "env перебивает проектный конфиг" "$TARGET_BRANCH" "ccc"
  unset PBX_TARGET_BRANCH
  rm -rf "$ws"
}

test_load_config_crlf() {
  local ws; ws="$(make_ws)"; mkdir -p "$ws/proj"; WORKSPACE="$ws"
  unset PBX_FORGE PBX_TARGET_BRANCH PBX_BASE_BRANCH
  printf 'FORGE=github\r\nTARGET_BRANCH=dev\r\n' > "$ws/proj/.pbx.conf"
  load_config "proj"
  assert_eq "CRLF в конфиге: FORGE без CR"         "$FORGE"         "github"
  assert_eq "CRLF в конфиге: TARGET_BRANCH без CR" "$TARGET_BRANCH" "dev"
  rm -rf "$ws"
}

test_load_config_errexit_safe() {
  local ws; ws="$(make_ws)"; mkdir -p "$ws/proj"
  # Запускаем в свежем bash с set -e: load_config без PBX_FORGE не должен ронять скрипт.
  local out
  out="$(env -u PBX_FORGE -u PBX_BASE_BRANCH -u PBX_TARGET_BRANCH \
        bash -c 'set -euo pipefail; source "'"$PBX"'"; WORKSPACE="'"$ws"'"; load_config proj; echo REACHED' 2>&1)"
  assert_eq "load_config не падает под set -e (нет PBX_FORGE)" "$out" "REACHED"
  rm -rf "$ws"
}

# --- Task 1: реестр SRC/REPO -------------------------------------------------
test_registry_src_repo() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"; PROJECTS_ROOT="/root"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  unset PBX_BASE_BRANCH PBX_TARGET_BRANCH PBX_FORGE
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

test_registry_crlf_inproject_layer() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  local src; src="$(make_ws)"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  unset PBX_TARGET_BRANCH
  printf 'SRC=%s\r\n' "$src" > "$reg/proj.conf"          # реестр с CRLF
  printf 'TARGET_BRANCH=fromsrc\n' > "$src/.pbx.conf"     # in-project слой
  load_config "proj"
  assert_eq "CRLF в реестровом SRC: in-project .pbx.conf всё равно применён" "$TARGET_BRANCH" "fromsrc"
  rm -rf "$ws" "$src" "$reg"
}

# --- Task 3: list_projects --------------------------------------------------
test_list_projects() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  unset PBX_IGNORE_DIRS
  mkdir -p "$ws/proj-a" "$ws/proj-b" "$ws/_dist" "$ws/docs" "$ws/.hidden"
  local out; out="$(list_projects)"
  assert_has "list: есть proj-a" "$out" "proj-a"
  assert_has "list: есть proj-b" "$out" "proj-b"
  assert_no  "list: нет _dist"   "$out" "_dist"
  assert_no  "list: нет docs"    "$out" "docs"
  assert_no  "list: нет .hidden" "$out" ".hidden"
  rm -rf "$ws" "$reg"
}

# --- pbx scan: команда ------------------------------------------------------
test_scan_creates_repo_entry() {
  local ws; ws="$(make_ws)"; local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  mk_repo "$ws/proj" "git@gitlab.rt-dc.ru:x/proj.git"
  cmd_scan --repo "$ws" >/dev/null 2>&1
  assert_has "создан proj.conf"  "$(ls "$reg")" "proj.conf"
  assert_has "REPO записан"       "$(cat "$reg/proj.conf")" "REPO=$ws/proj"
  assert_no  "без FORGE (gitlab)" "$(cat "$reg/proj.conf")" "FORGE="
  rm -rf "$ws" "$reg"
}
test_scan_github_forge() {
  local ws; ws="$(make_ws)"; local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  mk_repo "$ws/gh" "git@github.com:me/gh.git"
  cmd_scan --repo "$ws" >/dev/null 2>&1
  assert_has "FORGE=github" "$(cat "$reg/gh.conf")" "FORGE=github"
  rm -rf "$ws" "$reg"
}
test_scan_container_entry() {
  local ws; ws="$(make_ws)"; local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  mk_container "$ws/vnd"; mk_repo "$ws/vnd/vnd_frontend" "git@gitlab.rt-dc.ru:suba/vnd_frontend.git"
  cmd_scan --repo "$ws" >/dev/null 2>&1
  assert_has "vnd.conf → внутренний путь" "$(cat "$reg/vnd.conf")" "REPO=$ws/vnd/vnd_frontend"
  rm -rf "$ws" "$reg"
}
test_scan_skip_existing() {
  local ws; ws="$(make_ws)"; local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  mk_repo "$ws/proj" "git@h:/proj.git"
  printf 'REPO=/custom\n' > "$reg/proj.conf"
  cmd_scan --repo "$ws" >/dev/null 2>&1
  assert_has "существующий не тронут" "$(cat "$reg/proj.conf")" "REPO=/custom"
  rm -rf "$ws" "$reg"
}
test_scan_dry_run() {
  local ws; ws="$(make_ws)"; local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  mk_repo "$ws/proj" "git@h:/proj.git"
  cmd_scan --repo --dry-run "$ws" >/dev/null 2>&1
  assert_eq "dry-run: файл не создан" "$(ls "$reg")" ""
  rm -rf "$ws" "$reg"
}
test_scan_requires_flag() {
  local ws; ws="$(make_ws)"; local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  local rc=0; ( cmd_scan "$ws" ) >/dev/null 2>&1 || rc=$?
  assert_eq "без --repo/--src → ошибка" "$rc" "1"
  rm -rf "$ws" "$reg"
}
test_scan_src_field() {
  local ws; ws="$(make_ws)"; local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  mk_repo "$ws/proj" "git@h:/proj.git"
  cmd_scan --src "$ws" >/dev/null 2>&1
  assert_has "SRC записан" "$(cat "$reg/proj.conf")" "SRC=$ws/proj"
  rm -rf "$ws" "$reg"
}
test_scan_both_flags_die() {
  local ws; ws="$(make_ws)"; local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  local rc=0; ( cmd_scan --repo --src "$ws" ) >/dev/null 2>&1 || rc=$?
  assert_eq "оба флага → die" "$rc" "1"
  rm -rf "$ws" "$reg"
}
test_scan_unknown_dir_die() {
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  local rc=0; ( cmd_scan --repo "/nonexistent-xyz-$$" ) >/dev/null 2>&1 || rc=$?
  assert_eq "неизвестный каталог → die" "$rc" "1"
  rm -rf "$reg"
}
test_scan_default_dir_src() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"; local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  mk_repo "$ws/proj" "git@h:/proj.git"
  cmd_scan --src >/dev/null 2>&1     # без каталога → берёт $WORKSPACE
  assert_has "дефолтный каталог = WORKSPACE" "$(cat "$reg/proj.conf")" "SRC=$ws/proj"
  rm -rf "$ws" "$reg"
}
test_scan_dry_run_no_regdir() {
  local ws; ws="$(make_ws)"; local reg; reg="$(make_ws)/nested"; PBX_REGISTRY_DIR="$reg"  # ещё не существует
  mk_repo "$ws/proj" "git@h:/proj.git"
  local out; out="$(cmd_scan --repo --dry-run "$ws" 2>&1)"
  assert_has "dry-run печатает план" "$out" "proj"
  [[ -d "$reg" ]] && bad "dry-run создал каталог реестра" || ok "dry-run не создал каталог реестра"
  rm -rf "$ws" "$(dirname "$reg")"
}
test_scan_container_cmd_warn() {
  local ws; ws="$(make_ws)"; local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  mk_container "$ws/c"; mk_repo "$ws/c/a" "git@h:/a.git"; mk_repo "$ws/c/b" "git@h:/b.git"
  cmd_scan --repo "$ws" >/dev/null 2>&1
  [[ -e "$reg/c.conf" ]] && bad "неоднозначный контейнер не должен создавать .conf" || ok "неоднозначный контейнер: .conf не создан"
  rm -rf "$ws" "$reg"
}
test_scan_then_list() {
  local ws; ws="$(make_ws)"; WORKSPACE="$(make_ws)"; local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  mk_repo "$ws/proj" "git@h:/proj.git"
  cmd_scan --repo "$ws" >/dev/null 2>&1
  assert_has "pbx list видит scan-проект" "$(list_projects)" "proj"
  rm -rf "$ws" "$WORKSPACE" "$reg"
}
test_scan_errexit_safe() {
  local ws; ws="$(make_ws)"; local reg; reg="$(make_ws)"
  git init -q "$ws/p"; git -C "$ws/p" remote add origin git@h:/p.git
  local out
  out="$(bash -c 'set -euo pipefail; source "'"$PBX"'"; PBX_REGISTRY_DIR="'"$reg"'"; cmd_scan --repo "'"$ws"'" >/dev/null; echo REACHED' 2>&1)"
  assert_eq "cmd_scan не падает под set -e" "$out" "REACHED"
  rm -rf "$ws" "$reg"
}

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

test_list_pipe_bare_names() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  unset PBX_IGNORE_DIRS
  mkdir -p "$ws/alpha" "$ws/beta"
  local out; out="$(cmd_list 2>/dev/null)"
  assert_eq "list в пайпе: голые имена по строке" "$out" "$(printf 'alpha\nbeta')"
  rm -rf "$ws" "$reg"
}

test_help_plain_invariant() {
  local out; out="$(bash "$PBX" help 2>&1)"
  assert_has "help plain: шапка"        "$out" "pbx — доставка проектов Pybotx (WSL)"
  assert_has "help plain: команда pack" "$out" "pbx pack    <проект>"
  assert_has "help plain: реестр"       "$out" "Реестр проектов"
  assert_no  "help plain: без ANSI"     "$out" $'\033'
}

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
test_menu_select_plain_leading_zero() {
  local out err rc=0
  err="$(mktemp)"
  out="$(printf '08\n1\n' | { source "$PBX"; menu_select_plain "t" a b; } 2>"$err")" || rc=$?
  assert_eq "plain-меню: «08» переспрашивается, затем 1 → 0" "$out" "0"
  assert_no "plain-меню: нет octal-ошибки в stderr" "$(cat "$err")" "value too great for base"
  rm -f "$err"
}

# --- Task 7: raw-обвязка + menu_select со стрелками -----------------------
test_menu_select_falls_back_to_plain() {
  # stdin — пайп → stty провалится → должен отработать plain-путь
  local out rc=0
  out="$(printf '1\n' | { source "$PBX"; menu_select "t" one two; } 2>/dev/null)" || rc=$?
  assert_eq "menu_select: fallback в plain, выбор 1 → 0" "$out" "0"
  assert_eq "menu_select: rc=0" "$rc" "0"
}

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
  # UI_TTY=1 + plain-fallback меню: пункт «выход» (12) завершает без действий
  local rc=0
  ( printf '12\n' | { source "$PBX"; UI_TTY=1; TERM=xterm main; } >/dev/null 2>&1 ) || rc=$?
  assert_eq "меню: выбор «выход» (12) → rc=0" "$rc" "0"
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

test_menu_status_returns_to_menu() {
  local ws; ws="$(make_ws)"
  local reg; reg="$(make_ws)"
  mkdir -p "$ws/proj"
  # 7 = status → вывод → Enter (menu_pause) → 12 = выход
  local out
  out="$( ( printf '7\n\n12\n' | {
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

# --- Guard достижим и fail-closed из меню (доставка через меню, вход-пайп) ------
test_menu_deliver_guard_fail_closed() {
  local base; base="$(make_ws)"
  local remote="$base/remote.git" repo="$base/repo" src="$base/src"
  local reg; reg="$(make_ws)"
  local dist="$base/_dist"; mkdir -p "$dist"
  git init -q --bare "$remote"; git init -q "$repo"
  ( cd "$repo" && git config user.email t@t && git config user.name t \
    && git remote add origin "$remote" && git checkout -q -b dev \
    && echo keep > file.txt && echo role > roles.txt \
    && git add -A && git commit -q -m init && git push -q -u origin dev ) >/dev/null 2>&1
  mkdir -p "$src"; echo keep > "$src/file.txt"
  tar -C "$(dirname "$src")" -czf "$dist/proj.tar.gz" "$(basename "$src")"
  printf 'SRC=%s\nREPO=%s\nBASE_BRANCH=dev\nTARGET_BRANCH=dev\nFORGE=none\n' "$src" "$repo" > "$reg/proj.conf"
  local out rc=0
  # 3=deliver → 1=проект → ветка → сообщение; stdin — пайп (plain-fallback), non-TTY guard обязан прервать
  out="$( ( printf '3\n1\nfeature/T-77\nmsg\n' | {
      source "$PBX"
      WORKSPACE="$base/ws-empty"; mkdir -p "$WORKSPACE"
      DIST_DIR="$dist"; PBX_REGISTRY_DIR="$reg"; UI_TTY=1
      TERM=xterm main
    } ) 2>&1 )" || rc=$?
  assert_has "меню→deliver: guard прервал доставку" "$out" "Доставка прервана"
  assert_eq  "меню→deliver: ветка НЕ запушена" "$(git -C "$remote" branch --list feature/T-77)" ""
  cd "$HERE"
  rm -rf "$base" "$reg"
}

test_ui_raw_off_idempotent() {
  local out
  out="$(bash -c 'set -euo pipefail; source "'"$PBX"'"; ui_raw_off; ui_raw_off; echo REACHED' 2>/dev/null)"
  assert_eq "ui_raw_off дважды не падает под set -e" "$out" "REACHED"
}

# --- Task 4: exclude builders ----------------------------------------------
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
test_sync_excludes() {
  EXTRA_SYNC_EXCLUDES=("build")
  local out; out="$(sync_exclude_args)"
  assert_has "sync: .git/"              "$out" "--exclude=.git/"
  assert_has "sync: .gitlab-ci.yml"     "$out" "--exclude=.gitlab-ci.yml"
  assert_has "sync: .pbx.conf исключён" "$out" "--exclude=.pbx.conf"
  assert_has "sync: extra build"        "$out" "--exclude=build"
}

test_exclude_builders_errexit_safe() {
  local out
  out="$(bash -c 'set -euo pipefail; source "'"$PBX"'"; EXTRA_PACK_EXCLUDES=(); EXTRA_SYNC_EXCLUDES=(); a="$(pack_exclude_args)"; b="$(sync_exclude_args)"; echo REACHED' 2>&1)"
  assert_eq "билдеры excludes не падают под set -e (пустые массивы)" "$out" "REACHED"
}

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

test_pack_meta_broken_git_best_effort() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"; DIST_DIR="$ws/_dist"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  mkdir -p "$ws/proj/src"; echo hi > "$ws/proj/src/a.txt"
  : > "$ws/proj/.git"          # битый .git: пустой файл вместо каталога
  local rc=0
  ( cmd_pack proj >/dev/null 2>&1 ) || rc=$?
  assert_eq  "битый .git: pack не падает (best-effort)" "$rc" "0"
  assert_has "битый .git: архив создан" "$(ls "$ws/_dist" 2>/dev/null)" "proj.tar.gz"
  assert_has "битый .git: DIRTY=-"      "$(cat "$ws/_dist/proj.meta" 2>/dev/null)" "DIRTY_AT_PACK=-"
  rm -rf "$ws" "$reg"
}

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

# --- Task 3: cmd_status — таблица + --json + диспетчер + help -----------------
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

test_pad_helpers_multibyte() {
  local out
  out="$(LC_ALL=C.UTF-8 bash -c 'source "'"$PBX"'"; pad "абв…" 8; printf "|"')"
  assert_eq "pad: многобайтовое по символам" "$out" "абв…    |"
  out="$(LC_ALL=C.UTF-8 bash -c 'source "'"$PBX"'"; pad "longer-than-width" 5; printf "|"')"
  assert_eq "pad: длиннее ширины — не режет" "$out" "longer-than-width|"
  out="$(LC_ALL=C.UTF-8 bash -c 'source "'"$PBX"'"; padr "5" 3; printf "|"')"
  assert_eq "padr: правое выравнивание" "$out" "  5|"
}

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

test_snapshot_tree_tracked_excluded_dropped() {
  # I1: закоммиченные excluded-файлы НЕ должны попадать в снапшот
  local src; src="$(make_ws)"
  ( cd "$src" && git init -q . && git config user.email t@t && git config user.name t \
    && printf '*.log\n' > .gitignore \
    && mkdir -p node_modules/pkg __pycache__ \
    && echo ctx > CLAUDE.md && echo conf > .pbx.conf \
    && echo junk > node_modules/pkg/keep.js && echo pyc > app.pyc && echo c > __pycache__/x.txt \
    && echo real > app.js \
    && echo old > important.log && git add -f important.log \
    && git add -A -- . ':(glob,exclude)нет-такого' \
    && git add -f CLAUDE.md .pbx.conf node_modules/pkg/keep.js app.pyc __pycache__/x.txt \
    && git commit -qm init \
    && echo edited >> important.log ) >/dev/null 2>&1
  local tree; tree="$(cd "$src" && snapshot_tree "$src")"
  local files; files="$(git -C "$src" ls-tree -r --name-only "$tree")"
  assert_no  "tracked-excluded: CLAUDE.md выброшен"     "$files" "CLAUDE.md"
  assert_no  "tracked-excluded: .pbx.conf выброшен"     "$files" ".pbx.conf"
  assert_no  "tracked-excluded: node_modules выброшен"  "$files" "node_modules"
  assert_no  "tracked-excluded: *.pyc выброшен"         "$files" "app.pyc"
  assert_no  "tracked-excluded: __pycache__ выброшен"   "$files" "__pycache__"
  assert_has "tracked-excluded: обычный файл на месте"  "$files" "app.js"
  # регресс грабли №2: tracked-ignored с правкой ПО-ПРЕЖНЕМУ в снапшоте
  assert_has "tracked-excluded: important.log цел (грабля №2 не сломана)" "$files" "important.log"
  assert_has "tracked-excluded: правка important.log в дереве" \
    "$(git -C "$src" cat-file -p "$tree:important.log")" "edited"
  rm -rf "$src"
}

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

# --- Э3: meta_update — мерж ключей в .meta ------------------------------------
test_meta_update_creates_with_header() {
  local d; d="$(make_ws)"
  meta_update "$d/proj.meta" "FOO=bar" "BAZ=1"
  assert_has "meta_update: шапка создана"  "$(head -1 "$d/proj.meta")" "# pbx meta: проект proj"
  assert_eq  "meta_update: FOO записан"    "$(sed -n 's/^FOO=//p' "$d/proj.meta")" "bar"
  assert_eq  "meta_update: BAZ записан"    "$(sed -n 's/^BAZ=//p' "$d/proj.meta")" "1"
  rm -rf "$d"
}

test_meta_update_merge_preserves_order() {
  local d; d="$(make_ws)"
  printf '# шапка\nA=1\nB=2\n' > "$d/proj.meta"
  meta_update "$d/proj.meta" "B=22" "C=3"
  assert_eq "meta_update: обновление на месте, новое в конец, шапка цела" \
    "$(cat "$d/proj.meta")" "$(printf '# шапка\nA=1\nB=22\nC=3')"
  rm -rf "$d"
}

test_meta_update_value_with_equals() {
  local d; d="$(make_ws)"
  meta_update "$d/proj.meta" "BRANCH=feature/X-со=знаком"
  assert_eq "meta_update: значение с '=' внутри" \
    "$(sed -n 's/^BRANCH=//p' "$d/proj.meta")" "feature/X-со=знаком"
  rm -rf "$d"
}

test_meta_update_bad_keys_skipped() {
  local d; d="$(make_ws)"
  printf '# шапка\nA=1\n' > "$d/proj.meta"
  local before; before="$(cat "$d/proj.meta")"
  meta_update "$d/proj.meta" "no-equals" "плохой ключ=x" 2>/dev/null
  assert_eq "meta_update: кривые аргументы не трогают файл" "$(cat "$d/proj.meta")" "$before"
  rm -rf "$d"
}

test_meta_update_crlf_normalized() {
  local d; d="$(make_ws)"
  printf '# шапка\r\nA=1\r\n' > "$d/proj.meta"
  meta_update "$d/proj.meta" "A=2"
  assert_eq "meta_update: CRLF-файл — ключ не задвоен" "$(grep -c '^A=' "$d/proj.meta")" "1"
  assert_eq "meta_update: CRLF-файл — значение обновлено" "$(sed -n 's/^A=//p' "$d/proj.meta")" "2"
  rm -rf "$d"
}

test_pack_meta_survives_push_keys() {
  # pack → push-мета → pack: push-ключи выживают, pack-ключи одиночны
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"; DIST_DIR="$ws/_dist"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  mkdir -p "$ws/proj/src"; echo hi > "$ws/proj/src/a.txt"
  cmd_pack proj >/dev/null 2>&1
  meta_update "$DIST_DIR/proj.meta" "PUSHED_AT=123" "PUSH_BRANCH=feature/X" \
    "PUSH_COMMIT=abc" "PUSH_SOURCE_COMMIT=def"
  cmd_pack proj >/dev/null 2>&1
  assert_has "meta: PUSH_BRANCH выжил после pack" \
    "$(cat "$DIST_DIR/proj.meta")" "PUSH_BRANCH=feature/X"
  assert_eq "meta: COMMIT одиночен"    "$(grep -c '^COMMIT=' "$DIST_DIR/proj.meta")" "1"
  assert_eq "meta: PACKED_AT одиночен" "$(grep -c '^PACKED_AT=' "$DIST_DIR/proj.meta")" "1"
  rm -rf "$ws" "$reg"
}

test_cmd_push_writes_push_meta() {
  _mk_push_fixture
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"; DIST_DIR="$ws/_dist"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  printf 'SRC=%s\nMIRROR=%s\n' "$PU_SRC" "$PU_MIRROR" > "$reg/proj.conf"
  ( cd "$PU_SRC" && git checkout -qb feature/M-1 ) >/dev/null 2>&1
  ( cmd_push proj ) >/dev/null 2>&1
  local meta="$DIST_DIR/proj.meta"
  assert_eq "push-мета: PUSH_BRANCH" "$(sed -n 's/^PUSH_BRANCH=//p' "$meta")" "feature/M-1"
  local head; head="$(git -C "$PU_SRC" rev-parse HEAD)"
  assert_eq "push-мета: PUSH_SOURCE_COMMIT = HEAD SRC" \
    "$(sed -n 's/^PUSH_SOURCE_COMMIT=//p' "$meta")" "$head"
  if _pbx_is_sha "$(sed -n 's/^PUSH_COMMIT=//p' "$meta")"; then
    ok "push-мета: PUSH_COMMIT — полный SHA"
  else
    bad "push-мета: PUSH_COMMIT не SHA"
  fi
  rm -rf "$PU_BASE" "$ws" "$reg"
}

# --- Task 4: scan/log апгрейды (ветка кандидата, upstream+мета) -------
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
    && echo old-content > file.txt && git add -A && git commit -q -m init \
    && git push -q -u origin dev ) >/dev/null 2>&1

  # источник с новым содержимым; архив как делает pack (один корневой каталог)
  mkdir -p "$src"; echo new > "$src/file.txt"; echo add > "$src/added.txt"
  tar -C "$(dirname "$src")" -czf "$dist/proj.tar.gz" "$(basename "$src")"

  printf 'SRC=%s\nREPO=%s\nBASE_BRANCH=dev\nTARGET_BRANCH=dev\nFORGE=none\n' \
    "$src" "$repo" > "$reg/proj.conf"

  cmd_deliver "proj" "feature/T-1" "тест" "$dist/proj.tar.gz" --yes >/dev/null 2>&1
  assert_eq "deliver снял RETURN-trap (не течёт в вызывающий шелл)" "$(trap -p RETURN)" ""

  assert_eq "deliver: файл синкнут в REPO" "$(cat "$repo/file.txt")" "new"
  assert_has "deliver: added.txt в REPO"   "$(ls "$repo")" "added.txt"
  local pushed; pushed="$(git -C "$remote" branch --list feature/T-1)"
  assert_has "deliver: ветка запушена в remote" "$pushed" "feature/T-1"
  cd "$HERE"   # cmd_deliver сделал cd "$repo" в текущем шелле — вернуться перед rm -rf
  rm -rf "$base" "$reg"
}

# --- Guard: не дать зеркальной доставке молча снести чужую работу ------------
test_deliver_guard_blocks_deletions() {
  local base; base="$(make_ws)"
  local remote="$base/remote.git" repo="$base/repo" src="$base/src"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  local dist="$base/_dist"; DIST_DIR="$dist"; mkdir -p "$dist"
  unset PBX_BASE_BRANCH PBX_TARGET_BRANCH PBX_FORGE PBX_ASSUME_YES

  git init -q --bare "$remote"
  git init -q "$repo"
  ( cd "$repo" \
    && git config user.email t@t && git config user.name t \
    && git remote add origin "$remote" \
    && git checkout -q -b dev \
    && echo keep > file.txt && echo role > roles.txt \
    && git add -A && git commit -q -m init \
    && git push -q -u origin dev ) >/dev/null 2>&1

  # снимок УСТАРЕЛ: в нём нет roles.txt → rsync --delete удалит его (имитация факапа)
  mkdir -p "$src"; echo keep > "$src/file.txt"
  tar -C "$(dirname "$src")" -czf "$dist/proj.tar.gz" "$(basename "$src")"

  printf 'SRC=%s\nREPO=%s\nBASE_BRANCH=dev\nTARGET_BRANCH=dev\nFORGE=none\n' \
    "$src" "$repo" > "$reg/proj.conf"

  # без --yes и без TTY (stdin </dev/null) → guard должен прервать (rc≠0), НЕ пушить
  local rc=0
  ( cmd_deliver "proj" "feature/T-2" "msg" "$dist/proj.tar.gz" </dev/null >/dev/null 2>&1 ) || rc=$?
  assert_eq "guard: доставка с удалением без --yes прервана (rc=1)" "$rc" "1"
  assert_eq "guard: ветка НЕ запушена при отмене" "$(git -C "$remote" branch --list feature/T-2)" ""

  # с --yes guard пропускает — доставка проходит и пушится (даже с удалением)
  ( cmd_deliver "proj" "feature/T-3" "msg" "$dist/proj.tar.gz" --yes </dev/null >/dev/null 2>&1 )
  assert_has "guard: --yes пропускает доставку (ветка запушена)" \
    "$(git -C "$remote" branch --list feature/T-3)" "feature/T-3"

  cd "$HERE"
  rm -rf "$base" "$reg"
}

# --- Guard plain-инвариант: тексты неизменны без ANSI -------------------------
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

# --- log: диагностика для ИИ-агента -----------------------------------------
test_log_reports_project() {
  local base; base="$(make_ws)"
  local repo="$base/repo" src="$base/src"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  local dist="$base/_dist"; DIST_DIR="$dist"; mkdir -p "$dist"

  git init -q "$repo"
  ( cd "$repo" && git config user.email t@t && git config user.name t \
    && git remote add origin git@h:/proj.git \
    && git checkout -q -b dev && echo x > a.txt && git add -A && git commit -q -m init ) >/dev/null 2>&1
  mkdir -p "$src"; echo y > "$src/a.txt"
  tar -C "$(dirname "$src")" -czf "$dist/proj.tar.gz" "$(basename "$src")"
  printf 'SRC=%s\nREPO=%s\nBASE_BRANCH=dev\nTARGET_BRANCH=dev\nFORGE=none\n' "$src" "$repo" > "$reg/proj.conf"

  local out; out="$(cmd_log proj 2>&1)"
  assert_has "log: секция [config]"      "$out" "[config]"
  assert_has "log: REPO в выводе"        "$out" "$repo"
  assert_has "log: ветка репо"           "$out" "branch=dev"
  assert_has "log: чистый статус помечен" "$out" "(clean)"
  assert_has "log: секция [archive]"     "$out" "[archive]"
  assert_has "log: имя архива"           "$out" "proj.tar.gz"
  assert_has "log: секция [env]"         "$out" "[env]"
  assert_has "log: файл pbx-proj.log"    "$(ls "$dist")" "pbx-proj.log"
  cd "$HERE"; rm -rf "$base" "$reg"
}

test_log_no_project() {
  local base; base="$(make_ws)"
  local dist="$base/_dist"; DIST_DIR="$dist"; mkdir -p "$dist"
  local out; out="$(cmd_log 2>&1)"
  assert_has "log без проекта: [env]"    "$out" "[env]"
  assert_no  "log без проекта: нет [config]" "$out" "[config]"
  assert_has "log без проекта: файл pbx.log" "$(ls "$dist")" "pbx.log"
  cd "$HERE"; rm -rf "$base"
}

test_log_survives_unwritable_dist() {
  # Боевой путь: pbx log запускается напрямую под активным set -e (как на ноуте,
  # где DIST_DIR по умолчанию = несуществующий home-путь). Реальный подпроцесс,
  # а не $()-обёртка — иначе set -e маскируется и баг не воспроизводится.
  local base; base="$(make_ws)"
  local reg; reg="$(make_ws)"
  printf 'SRC=%s\nREPO=%s\nBASE_BRANCH=dev\nTARGET_BRANCH=dev\nFORGE=none\n' "$base/src" "$base/repo" > "$reg/proj.conf"
  local out rc=0
  out="$(PBX_DIST_DIR=/proc/nonexistent/_dist PBX_REGISTRY_DIR="$reg" HOME="$base" \
         bash "$PBX" log proj 2>&1)" || rc=$?
  assert_eq  "log: не падает при недоступном DIST_DIR (rc=0)" "$rc" "0"
  assert_has "log: отчёт в stdout всё равно есть"            "$out" "[config]"
  rm -rf "$base" "$reg"
}

test_die_writes_diag() {
  local base; base="$(make_ws)"
  local repo="$base/repo"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  local dist="$base/_dist"; DIST_DIR="$dist"; mkdir -p "$dist"
  unset PBX_BASE_BRANCH PBX_TARGET_BRANCH PBX_FORGE

  git init -q "$repo" >/dev/null 2>&1
  printf 'SRC=%s\nREPO=%s\nBASE_BRANCH=dev\nTARGET_BRANCH=dev\nFORGE=none\n' "$base/src" "$repo" > "$reg/proj.conf"
  # архив НЕ создаём → deliver резолвит проект, выставит PBX_CURRENT_PROJECT, потом die "Архив не найден"
  local rc=0
  ( cmd_deliver "proj" "feature/T-9" "msg" "$dist/proj.tar.gz" --yes </dev/null >/dev/null 2>&1 ) || rc=$?
  assert_eq  "die: команда упала (rc=1)"  "$rc" "1"
  assert_has "die: лог-файл создан"       "$(ls "$dist" 2>/dev/null)" "pbx-proj.log"
  assert_has "die: причина ОШИБКА в логе" "$(cat "$dist/pbx-proj.log" 2>/dev/null)" "ОШИБКА"
  assert_has "die: [config] в логе"       "$(cat "$dist/pbx-proj.log" 2>/dev/null)" "[config]"
  cd "$HERE"; rm -rf "$base" "$reg"
}

# --- Task 5: forge_push -----------------------------------------------------
test_forge_gitlab() {
  CALLS="$(mktemp)"; FORGE="gitlab"; TARGET_BRANCH="master"
  forge_push "feature/X-1" "мой коммит"
  local out; out="$(cat "$CALLS")"
  assert_has "gitlab: merge_request.create" "$out" "merge_request.create"
  assert_has "gitlab: target=master"        "$out" "merge_request.target=master"
  assert_has "gitlab: push origin ветка"    "$out" "origin feature/X-1"
  rm -f "$CALLS"
}
test_forge_gitlab_multiline_title() {
  CALLS="$(mktemp)"; FORGE="gitlab"; TARGET_BRANCH="dev"
  forge_push "feature/X-9" "$(printf 'заголовок\nтело строка 2\nтело строка 3')"
  local out; out="$(cat "$CALLS")"
  assert_has "gitlab multiline: title = первая строка" "$out" "merge_request.title=заголовок"
  assert_no  "gitlab multiline: тела строк нет в push-опциях" "$out" "тело строка 2"
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
# --- Э4: pbx ctx — вердикт дом↔корп -------------------------------------------
# Фикстура: corp-фикстура + домашний SRC (клон origin, отстаёт на 1 коммит) +
# state-каталог со снимком корп-состояния. Глобали: + CTX_SRC, CTX_STATE
_mk_ctx_fixture() {
  _mk_corp_fixture
  CTX_SRC="$CE_BASE/src"
  # Дом = клон origin, затем отмотка на 1 коммит назад + очистка рефлога
  ( git clone -q "$CE_ORIGIN" "$CTX_SRC" 2>/dev/null \
    && cd "$CTX_SRC" && git config user.email t@t && git config user.name t \
    && git checkout -q dev && git reset -q --hard HEAD~1 \
    && git reflog expire --expire=now --all 2>/dev/null \
    && git gc -q 2>/dev/null ) >/dev/null 2>&1
  CTX_STATE="$(make_ws)"
  corp_collect_state "$CE_REPO" dev
  corp_state_files "$CTX_STATE" proj
}

# Минимальный набор ST_*-глобалей для ctx_compare (без status_collect)
_ctx_st_defaults() {
  ST_SRC="$CTX_SRC"; ST_GIT=true
  ST_PUSH_COMMIT=''; ST_PUSH_SOURCE=''
  ST_ARCHIVE_EXISTS=false; ST_STALE=false
}

test_ctx_compare_unknown_cases() {
  _mk_ctx_fixture; _ctx_st_defaults
  ctx_compare "$CTX_STATE" 4
  assert_eq  "ctx: rc=4 → unknown"        "$CTX_VERDICT" "unknown"
  assert_has "ctx: причина no_mirror"     "$CTX_REASONS" "no_mirror"
  ctx_compare "$CTX_STATE" 2
  assert_eq  "ctx: rc=2 → unknown"        "$CTX_VERDICT" "unknown"
  assert_has "ctx: причина no_snapshot"   "$CTX_REASONS" "no_snapshot"
  ctx_compare "$CTX_STATE" 3
  assert_eq  "ctx: rc=3 → unknown"        "$CTX_VERDICT" "unknown"
  assert_has "ctx: причина mirror_unreachable" "$CTX_REASONS" "mirror_unreachable"
  ST_GIT=false
  ctx_compare "$CTX_STATE" 0
  assert_eq  "ctx: SRC не git → unknown"  "$CTX_VERDICT" "unknown"
  assert_has "ctx: причина src_not_git"   "$CTX_REASONS" "src_not_git"
  assert_has "ctx: corp-поля заполнены и при unknown" "$CTX_BASE_SHA" "$(git -C "$CE_REPO" rev-parse origin/dev)"
  rm -rf "$CE_BASE" "$CTX_STATE"
}

test_ctx_compare_behind_danger() {
  _mk_ctx_fixture; _ctx_st_defaults
  ctx_compare "$CTX_STATE" 0
  assert_eq  "ctx: дом отстал → danger"   "$CTX_VERDICT" "danger"
  assert_has "ctx: причина home_behind_corp" "$CTX_REASONS" "home_behind_corp"
  assert_eq  "ctx: behind_n = 1"          "$CTX_BEHIND_N" "1"
  rm -rf "$CE_BASE" "$CTX_STATE"
}

test_ctx_compare_ok_when_home_has_tip() {
  _mk_ctx_fixture; _ctx_st_defaults
  ( cd "$CTX_SRC" && git fetch -q origin && git reset -q --hard origin/dev ) >/dev/null 2>&1
  ctx_compare "$CTX_STATE" 0
  assert_eq "ctx: дом на tip корп-dev → ok" "$CTX_VERDICT" "ok"
  assert_eq "ctx: behind_n = -1 при ok"     "$CTX_BEHIND_N" "-1"
  rm -rf "$CE_BASE" "$CTX_STATE"
}

test_ctx_compare_unrelated_histories() {
  _mk_ctx_fixture; _ctx_st_defaults
  local alien; alien="$(make_ws)"
  ( git init -q "$alien" && cd "$alien" \
    && git config user.email a@a && git config user.name a \
    && echo x > x.txt && git add -A && git commit -qm alien ) >/dev/null 2>&1
  ST_SRC="$alien"
  ctx_compare "$CTX_STATE" 0
  assert_has "ctx: несвязанные истории → histories_unrelated" "$CTX_REASONS" "histories_unrelated"
  assert_eq  "ctx: unrelated — warn, не danger" "$CTX_VERDICT" "warn"
  rm -rf "$CE_BASE" "$CTX_STATE" "$alien"
}

test_ctx_compare_no_base_warn() {
  _mk_ctx_fixture; _ctx_st_defaults
  sed -i 's/^BASE_SHA=.*/BASE_SHA=-/' "$CTX_STATE/state.env"
  ctx_compare "$CTX_STATE" 0
  assert_has "ctx: нет base в снимке → no_base" "$CTX_REASONS" "no_base"
  assert_eq  "ctx: no_base — warn"              "$CTX_VERDICT" "warn"
  rm -rf "$CE_BASE" "$CTX_STATE"
}

test_ctx_compare_snapshot_stale_and_no_vpn() {
  _mk_ctx_fixture; _ctx_st_defaults
  ( cd "$CTX_SRC" && git fetch -q origin && git reset -q --hard origin/dev ) >/dev/null 2>&1
  sed -i "s/^GENERATED_AT=.*/GENERATED_AT=$(( $(date +%s) - 90000 ))/" "$CTX_STATE/state.env"
  sed -i 's/^FETCH_OK=.*/FETCH_OK=false/' "$CTX_STATE/state.env"
  ctx_compare "$CTX_STATE" 0
  assert_has "ctx: снимок >24ч → snapshot_stale" "$CTX_REASONS" "snapshot_stale"
  assert_has "ctx: fetch_ok=false → snapshot_no_vpn" "$CTX_REASONS" "snapshot_no_vpn"
  assert_eq  "ctx: два warn → вердикт warn" "$CTX_VERDICT" "warn"
  rm -rf "$CE_BASE" "$CTX_STATE"
}

test_ctx_compare_repo_dirty_and_merge() {
  _mk_ctx_fixture; _ctx_st_defaults
  ( cd "$CTX_SRC" && git fetch -q origin && git reset -q --hard origin/dev ) >/dev/null 2>&1
  sed -i 's/^DIRTY=.*/DIRTY=3/'        "$CTX_STATE/state.env"
  sed -i 's/^IN_MERGE=.*/IN_MERGE=true/' "$CTX_STATE/state.env"
  ctx_compare "$CTX_STATE" 0
  assert_has "ctx: REPO dirty → repo_dirty"      "$CTX_REASONS" "repo_dirty"
  assert_has "ctx: REPO in merge → repo_in_merge" "$CTX_REASONS" "repo_in_merge"
  rm -rf "$CE_BASE" "$CTX_STATE"
}

test_ctx_compare_push_and_pack_stale() {
  _mk_ctx_fixture; _ctx_st_defaults
  ( cd "$CTX_SRC" && git fetch -q origin && git reset -q --hard origin/dev ) >/dev/null 2>&1
  ST_PUSH_COMMIT="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  ST_PUSH_SOURCE="0000000000000000000000000000000000000000"   # != HEAD SRC
  ST_ARCHIVE_EXISTS=true; ST_STALE=true
  ctx_compare "$CTX_STATE" 0
  assert_has "ctx: push отстаёт → push_stale" "$CTX_REASONS" "push_stale"
  assert_has "ctx: архив протух → pack_stale" "$CTX_REASONS" "pack_stale"
  assert_eq  "ctx: warn-вердикт"              "$CTX_VERDICT" "warn"
  rm -rf "$CE_BASE" "$CTX_STATE"
}

test_ctx_compare_push_fresh_silent() {
  _mk_ctx_fixture; _ctx_st_defaults
  ( cd "$CTX_SRC" && git fetch -q origin && git reset -q --hard origin/dev ) >/dev/null 2>&1
  ST_PUSH_COMMIT="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  ST_PUSH_SOURCE="$(git -C "$CTX_SRC" rev-parse HEAD)"
  ctx_compare "$CTX_STATE" 0
  assert_no "ctx: push свежий — молчит" "$CTX_REASONS" "push_stale"
  assert_eq "ctx: ok"                   "$CTX_VERDICT" "ok"
  rm -rf "$CE_BASE" "$CTX_STATE"
}

test_ctx_compare_undelivered_info() {
  _mk_ctx_fixture; _ctx_st_defaults
  ( cd "$CTX_SRC" && git fetch -q origin && git reset -q --hard origin/dev ) >/dev/null 2>&1
  ctx_compare "$CTX_STATE" 0
  # фикстура: feature/AAA-1 имеет ahead=1 над dev
  assert_has "ctx: недоставленная ветка в списке" "$CTX_UNDELIVERED" "feature/AAA-1"
  assert_has "ctx: info-причина undelivered_branches" "$CTX_REASONS" "undelivered_branches"
  assert_eq  "ctx: info не поднимает вердикт" "$CTX_VERDICT" "ok"
  rm -rf "$CE_BASE" "$CTX_STATE"
}

test_ctx_compare_danger_beats_warn() {
  _mk_ctx_fixture; _ctx_st_defaults    # дом отстал (danger)
  sed -i 's/^FETCH_OK=.*/FETCH_OK=false/' "$CTX_STATE/state.env"
  ctx_compare "$CTX_STATE" 0
  assert_eq "ctx: danger побеждает warn" "$CTX_VERDICT" "danger"
  rm -rf "$CE_BASE" "$CTX_STATE"
}

test_cmd_ctx_renders_verdict() {
  _mk_ctx_fixture
  # зеркало со снимком: реюз snap-фикстуры вручную
  local mirror="$CE_BASE/mirror.git"; git init -q --bare "$mirror"
  local reg; reg="$(make_ws)"
  printf 'SRC=%s\nREPO=%s\nMIRROR=%s\n' "$CTX_SRC" "$CE_REPO" "$mirror" > "$reg/proj.conf"
  local ws; ws="$(make_ws)"
  local out rc=0
  # снимок в зеркало (на «ноуте»), затем ctx (на «дому»)
  out="$(PBX_REGISTRY_DIR="$reg" WORKSPACE="$ws" DIST_DIR="$ws/_dist" bash "$PBX" snapshot proj 2>&1)" || rc=$?
  assert_eq "ctx-фикстура: snapshot rc=0" "$rc" "0"
  rc=0
  out="$(PBX_REGISTRY_DIR="$reg" WORKSPACE="$ws" DIST_DIR="$ws/_dist" bash "$PBX" ctx proj 2>&1)" || rc=$?
  assert_eq  "ctx: rc=0"                    "$rc" "0"
  assert_has "ctx: вердикт danger в выводе" "$out" "danger"
  assert_has "ctx: причина отставания"      "$out" "отстал"
  rm -rf "$CE_BASE" "$CTX_STATE" "$reg" "$ws"
}

test_cmd_ctx_render_glyphs() {
  # глифы вердикта — контракт рендера: 🔴-маркер и ✗/!-префиксы причин
  _mk_ctx_fixture
  local mirror="$CE_BASE/mirror.git"; git init -q --bare "$mirror"
  local reg; reg="$(make_ws)"
  printf 'SRC=%s\nREPO=%s\nMIRROR=%s\n' "$CTX_SRC" "$CE_REPO" "$mirror" > "$reg/proj.conf"
  local ws; ws="$(make_ws)"
  ( PBX_REGISTRY_DIR="$reg" WORKSPACE="$ws" DIST_DIR="$ws/_dist" bash "$PBX" snapshot proj ) >/dev/null 2>&1
  local out
  out="$(PBX_REGISTRY_DIR="$reg" WORKSPACE="$ws" DIST_DIR="$ws/_dist" bash "$PBX" ctx proj 2>&1)"
  assert_has "ctx-глифы: 🔴 у danger-проекта"        "$out" "🔴 proj"
  assert_has "ctx-глифы: ✗-префикс danger-причины"  "$out" "✗"
  # обновление дома + пересоздание снимка → warn, без ✗
  ( cd "$CTX_SRC" && git fetch -q origin && git reset -q --hard origin/dev ) >/dev/null 2>&1
  ( PBX_REGISTRY_DIR="$reg" WORKSPACE="$ws" DIST_DIR="$ws/_dist" bash "$PBX" snapshot proj ) >/dev/null 2>&1
  out="$(PBX_REGISTRY_DIR="$reg" WORKSPACE="$ws" DIST_DIR="$ws/_dist" bash "$PBX" ctx proj 2>&1)"
  assert_no  "ctx-глифы: нет 🔴 после обновления"    "$out" "🔴 proj"
  assert_no  "ctx-глифы: нет ✗ после обновления"     "$out" "✗"
  rm -rf "$CE_BASE" "$CTX_STATE" "$reg" "$ws"
}

test_cmd_ctx_no_mirror_dies_plain() {
  _mk_ctx_fixture
  local reg; reg="$(make_ws)"
  printf 'SRC=%s\n' "$CTX_SRC" > "$reg/proj.conf"
  local out rc=0
  out="$(PBX_REGISTRY_DIR="$reg" bash "$PBX" ctx proj 2>&1)" || rc=$?
  assert_eq  "ctx: явный проект без MIRROR → die" "$rc" "1"
  assert_has "ctx: подсказка про MIRROR"          "$out" "MIRROR"
  rm -rf "$CE_BASE" "$CTX_STATE" "$reg"
}

test_cmd_ctx_all_skips_no_mirror() {
  _mk_ctx_fixture
  local mirror="$CE_BASE/mirror.git"; git init -q --bare "$mirror"
  local reg; reg="$(make_ws)"
  printf 'SRC=%s\nREPO=%s\nMIRROR=%s\n' "$CTX_SRC" "$CE_REPO" "$mirror" > "$reg/proj.conf"
  printf 'SRC=%s\n' "$CTX_SRC" > "$reg/nomirror.conf"
  local ws; ws="$(make_ws)"
  ( PBX_REGISTRY_DIR="$reg" WORKSPACE="$ws" DIST_DIR="$ws/_dist" bash "$PBX" snapshot proj ) >/dev/null 2>&1
  local out rc=0
  out="$(PBX_REGISTRY_DIR="$reg" WORKSPACE="$ws" DIST_DIR="$ws/_dist" bash "$PBX" ctx 2>&1)" || rc=$?
  assert_eq  "ctx all: rc=0"                     "$rc" "0"
  assert_has "ctx all: проект с MIRROR обработан" "$out" "proj"
  assert_no  "ctx all: без MIRROR не в обходе"    "$out" "nomirror"
  rm -rf "$CE_BASE" "$CTX_STATE" "$reg" "$ws"
}

test_cmd_ctx_unknown_flag_dies() {
  local out rc=0
  out="$(bash "$PBX" ctx --nope 2>&1)" || rc=$?
  assert_eq  "ctx: неизвестный флаг → die" "$rc" "1"
  assert_has "ctx: сообщение о флаге"      "$out" "Неизвестный флаг"
}

test_cmd_ctx_in_help() {
  local out
  out="$(bash "$PBX" help 2>/dev/null)"
  assert_has "help: pbx ctx упомянут" "$out" "pbx ctx"
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

test_valid_project_registry_elsewhere() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"           # WORKSPACE пуст
  local src; src="$(make_ws)"                          # SRC вне WORKSPACE
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  printf 'SRC=%s\n' "$src" > "$reg/elsewhere.conf"     # проект только в реестре; $WORKSPACE/elsewhere НЕ существует
  local rc=0
  ( valid_project "elsewhere" ) >/dev/null 2>&1 || rc=$?
  assert_eq "valid_project принимает реестровый проект вне WORKSPACE" "$rc" "0"
  local rc2=0
  ( valid_project "nonexistent-xyz" ) >/dev/null 2>&1 || rc2=$?
  assert_eq "valid_project отвергает неизвестный проект" "$rc2" "1"
  rm -rf "$ws" "$src" "$reg"
}

# --- pbx scan: обнаружение --------------------------------------------------
test_repo_remote_url() {
  local ws; ws="$(make_ws)"
  mk_repo "$ws/a" "git@gitlab.rt-dc.ru:x/a.git"
  mk_container "$ws/b"
  assert_eq "remote есть"  "$(repo_remote_url "$ws/a")" "git@gitlab.rt-dc.ru:x/a.git"
  assert_eq "remote пусто" "$(repo_remote_url "$ws/b")" ""
  assert_eq "не git пусто" "$(repo_remote_url "$ws/nope")" ""
  rm -rf "$ws"
}
test_scan_whole_repo() {
  local ws; ws="$(make_ws)"
  mk_repo "$ws/proj" "git@gitlab.rt-dc.ru:x/proj.git"
  local out; out="$(scan_candidates "$ws")"
  assert_has "whole: OK proj" "$out" "$(printf 'OK\tproj\t%s/proj\tgit@gitlab.rt-dc.ru:x/proj.git' "$ws")"
  rm -rf "$ws"
}
test_scan_container_one() {
  local ws; ws="$(make_ws)"
  mk_container "$ws/vnd"
  mk_repo "$ws/vnd/vnd_frontend" "git@gitlab.rt-dc.ru:suba/vnd_frontend.git"
  local out; out="$(scan_candidates "$ws")"
  assert_has "container→inner под именем vnd" "$out" "$(printf 'OK\tvnd\t%s/vnd/vnd_frontend' "$ws")"
  rm -rf "$ws"
}
test_scan_container_multi() {
  local ws; ws="$(make_ws)"
  mk_container "$ws/c"
  mk_repo "$ws/c/a" "git@h:/a.git"; mk_repo "$ws/c/b" "git@h:/b.git"
  local out; out="$(scan_candidates "$ws")"
  assert_has "multi→WARN" "$out" "$(printf 'WARN\tc\t')"
  assert_no  "multi→не OK" "$out" "$(printf 'OK\tc\t')"
  rm -rf "$ws"
}
test_scan_skips_nongit_and_noremote() {
  local ws; ws="$(make_ws)"
  mkdir -p "$ws/plain"                 # не git
  mk_container "$ws/empty"             # git без remote, без внутренних репо
  local out; out="$(scan_candidates "$ws")"
  assert_no "plain пропущен" "$out" "plain"
  assert_no "empty пропущен" "$out" "empty"
  rm -rf "$ws"
}
test_scan_plain_container_one() {
  local ws; ws="$(make_ws)"
  mkdir -p "$ws/sup"                    # обычный каталог, НЕ git
  mk_repo "$ws/sup/sup-frontend" "git@gitlab.rt-dc.ru:suba/sup-frontend.git"
  local out; out="$(scan_candidates "$ws")"
  assert_has "plain-контейнер→inner под именем sup" "$out" "$(printf 'OK\tsup\t%s/sup/sup-frontend' "$ws")"
  rm -rf "$ws"
}
test_scan_deep_nesting() {
  local ws; ws="$(make_ws)"
  mkdir -p "$ws/sup/apps"               # два обычных (не git) уровня
  mk_repo "$ws/sup/apps/frontend" "git@gitlab.rt-dc.ru:suba/frontend.git"
  local out; out="$(scan_candidates "$ws")"
  assert_has "вложенность >1 уровня находится" "$out" "$(printf 'OK\tsup\t%s/sup/apps/frontend' "$ws")"
  rm -rf "$ws"
}
test_scan_plain_container_multi() {
  local ws; ws="$(make_ws)"
  mkdir -p "$ws/c"
  mk_repo "$ws/c/a" "git@h:/a.git"; mk_repo "$ws/c/b" "git@h:/b.git"
  local out; out="$(scan_candidates "$ws")"
  assert_has "plain-контейнер с 2 репо→WARN" "$out" "$(printf 'WARN\tc\t')"
  assert_no  "plain-контейнер с 2 репо→не OK" "$out" "$(printf 'OK\tc\t')"
  rm -rf "$ws"
}
test_scan_no_descend_into_repo() {
  local ws; ws="$(make_ws)"
  mkdir -p "$ws/c"
  mk_repo "$ws/c/app" "git@h:/app.git"
  mk_repo "$ws/c/app/vendor" "git@h:/vendor.git"   # репо ВНУТРИ уже найденного
  local out; out="$(scan_candidates "$ws")"
  assert_has "не спускаемся внутрь репо: c→app" "$out" "$(printf 'OK\tc\t%s/c/app' "$ws")"
  assert_no  "вложенный vendor не считается вторым репо" "$out" "WARN"
  rm -rf "$ws"
}

# --- Э3: _json_str_v2 и сбор корп-состояния ------------------------------------
test_json_str_v2_escapes() {
  assert_eq "v2: кавычки"     "$(_json_str_v2 'a"b')" 'a\"b'
  assert_eq "v2: бэкслеш"     "$(_json_str_v2 'a\b')" 'a\\b'
  assert_eq "v2: таб"         "$(_json_str_v2 $'a\tb')" 'a\tb'
  assert_eq "v2: CR"          "$(_json_str_v2 $'a\rb')" 'a\rb'
  assert_eq "v2: LF"          "$(_json_str_v2 $'a\nb')" 'a\nb'
  assert_eq "v2: \\ первым (нет двойного экрана)" "$(_json_str_v2 '\')" '\\'
  assert_eq "v2: C0 вычищаются" "$(_json_str_v2 $'a\x01b')" 'ab'
}

# Фикстура Э3: bare-«gitlab» + рабочий REPO. Ветки: feature/AAA-1 (remote,
# ahead 1 / behind 1), fix/BBB-2 (remote-only, влита: ahead 0 / behind 1),
# feature/CCC-3 (local-only). Глобали: CE_BASE, CE_ORIGIN, CE_REPO.
_mk_corp_fixture() {
  CE_BASE="$(mktemp -d)"
  CE_ORIGIN="$CE_BASE/origin.git"; CE_REPO="$CE_BASE/repo"
  git init -q --bare "$CE_ORIGIN"
  git init -q -b dev "$CE_REPO"
  ( cd "$CE_REPO" \
    && git config user.email t@t && git config user.name t \
    && git remote add origin "$CE_ORIGIN" \
    && echo base > f.txt && git add -A && git commit -qm 'первый: "кавычки" и \бэкслеш' \
    && echo more >> f.txt && git commit -qam 'второй: 100% кириллица' \
    && git push -qu origin dev \
    && git checkout -qb feature/AAA-1 \
    && echo feat > feat.txt && git add -A && git commit -qm 'фича AAA' \
    && git push -q origin feature/AAA-1 \
    && git checkout -q dev \
    && git checkout -qb fix/BBB-2 && git checkout -q dev \
    && git push -q origin fix/BBB-2 \
    && git branch -q -D fix/BBB-2 \
    && git checkout -qb feature/CCC-3 \
    && echo c3 > c3.txt && git add -A && git commit -qm 'локальная CCC' \
    && git checkout -q dev \
    && echo newer >> f.txt && git commit -qam 'третий dev-коммит' \
    && git push -q origin dev ) >/dev/null 2>&1
}

test_corp_collect_state_branches() {
  _mk_corp_fixture
  corp_collect_state "$CE_REPO" dev
  assert_eq  "collect: fetch_ok"            "$CS_FETCH_OK" "true"
  assert_eq  "collect: base_ref"            "$CS_BASE_REF" "origin/dev"
  assert_has "collect: сабжект верхушки"    "$CS_BASE_SUBJ" "третий dev-коммит"
  assert_eq  "collect: total=3"             "$CS_BRANCHES_TOTAL" "3"
  local aaa; aaa="$(printf '%s' "$CS_BRANCHES" | grep '^feature/AAA-1')"
  assert_has "collect: AAA remote"          "$aaa" $'\tremote\t'
  assert_eq  "collect: AAA ahead=1 behind=1" "$(printf '%s' "$aaa" | cut -f4,5)" $'1\t1'
  local bbb; bbb="$(printf '%s' "$CS_BRANCHES" | grep '^fix/BBB-2')"
  assert_eq  "collect: влитая BBB ahead=0"  "$(printf '%s' "$bbb" | cut -f4)" "0"
  assert_eq  "collect: влитая BBB shortstat='-'" "$(printf '%s' "$bbb" | cut -f7)" "-"
  local ccc; ccc="$(printf '%s' "$CS_BRANCHES" | grep '^feature/CCC-3')"
  assert_has "collect: CCC local-only"      "$ccc" $'\tlocal\t'
  rm -rf "$CE_BASE"
}

test_corp_collect_state_no_base() {
  _mk_corp_fixture
  corp_collect_state "$CE_REPO" nosuchbase
  assert_eq "collect: base_ref пуст без базы" "$CS_BASE_REF" ""
  assert_eq "collect: base_sha пуст"          "$CS_BASE_SHA" ""
  assert_eq "collect: лог пуст"               "$CS_LOG" ""
  local aaa; aaa="$(printf '%s' "$CS_BRANCHES" | grep '^feature/AAA-1')"
  assert_eq "collect: ahead='-' без базы"     "$(printf '%s' "$aaa" | cut -f4)" "-"
  rm -rf "$CE_BASE"
}

test_corp_collect_state_fetch_fail() {
  _mk_corp_fixture
  ( cd "$CE_REPO" && git remote set-url origin "$CE_BASE/nope.git" )
  corp_collect_state "$CE_REPO" dev
  assert_eq "collect: fetch_ok=false при сбое origin" "$CS_FETCH_OK" "false"
  assert_eq "collect: старые remote-refs живы" "$CS_BASE_REF" "origin/dev"
  rm -rf "$CE_BASE"
}

test_corp_collect_state_detached_and_merge() {
  _mk_corp_fixture
  ( cd "$CE_REPO" && git checkout -q "$(git rev-parse dev)" ) >/dev/null 2>&1
  corp_collect_state "$CE_REPO" dev
  assert_eq "collect: detached HEAD → current_branch пуст" "$CS_CURRENT_BRANCH" ""
  # незавершённый merge имитируем маркером MERGE_HEAD (детект — по его наличию)
  ( cd "$CE_REPO" && git checkout -q dev && git rev-parse dev > .git/MERGE_HEAD )
  corp_collect_state "$CE_REPO" dev
  assert_eq "collect: MERGE_HEAD → in_merge=true" "$CS_IN_MERGE" "true"
  rm -rf "$CE_BASE"
}

test_corp_collect_state_branch_cap() {
  _mk_corp_fixture
  # 35 доп. remote-веток: total считает все (35 + AAA + BBB + local-only CCC = 38),
  # в список попадают только 30 самых свежих (cap head -30, регресс SIGPIPE-фикса)
  ( cd "$CE_REPO" \
    && for i in $(seq 1 35); do git branch "feature/CAP-$i" >/dev/null; done \
    && git push -q origin $(for i in $(seq 1 35); do printf 'refs/heads/feature/CAP-%s:refs/heads/feature/CAP-%s ' "$i" "$i"; done) ) >/dev/null 2>&1
  corp_collect_state "$CE_REPO" dev
  assert_eq "cap: branches_total считает все ветки" "$CS_BRANCHES_TOTAL" "38"
  assert_eq "cap: в списке ровно 30 строк" "$(printf '%s' "$CS_BRANCHES" | grep -c .)" "30"
  rm -rf "$CE_BASE"
}

test_corp_state_files_json_valid() {
  _mk_corp_fixture
  # гадкий сабжект: таб + кавычки + % + бэкслеш + кириллица
  ( cd "$CE_REPO" && git commit -qam "$(printf 'га\tдкий: "q" 100%% \\x')" --allow-empty \
    && git push -q origin dev ) >/dev/null 2>&1
  corp_collect_state "$CE_REPO" dev
  local d; d="$(make_ws)"
  corp_state_files "$d" proj
  local f
  for f in state.json state.env branches.tsv log.tsv; do
    if [[ -f "$d/$f" ]]; then ok "state-файл есть: $f"; else bad "нет файла: $f"; fi
  done
  if command -v python3 >/dev/null 2>&1; then
    if python3 -m json.tool "$d/state.json" >/dev/null 2>&1; then
      ok "state.json валиден (json.tool, гадкие сабжекты)"
    else
      bad "state.json НЕ валиден"
    fi
  fi
  assert_eq  "state.env: PROJECT"       "$(sed -n 's/^PROJECT=//p' "$d/state.env")" "proj"
  assert_has "state.env: BASE_SUBJECT"  "$(sed -n 's/^BASE_SUBJECT=//p' "$d/state.env")" "дкий"
  assert_has "log.tsv: сабжект последним, таб внутри выжил" \
    "$(head -1 "$d/log.tsv" | cut -f3-)" "дкий"
  assert_eq  "branches.tsv: 7 полей у AAA" \
    "$(grep '^feature/AAA-1' "$d/branches.tsv" | awk -F'\t' '{print NF}')" "7"
  rm -rf "$CE_BASE" "$d"
}

# --- Э3: pbx snapshot — снимок корп-состояния в pbx/state зеркала ----------------
# Фикстура: corp-фикстура + bare-зеркало + реестр. Глобали: + CE_MIRROR, SN_REG
_mk_snap_fixture() {
  _mk_corp_fixture
  CE_MIRROR="$CE_BASE/mirror.git"
  git init -q --bare "$CE_MIRROR"
  SN_REG="$(make_ws)"
  printf 'REPO=%s\nMIRROR=%s\n' "$CE_REPO" "$CE_MIRROR" > "$SN_REG/proj.conf"
  PBX_REGISTRY_DIR="$SN_REG"
}

test_snapshot_creates_state_no_leak() {
  _mk_snap_fixture
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  local st_before idx_before
  st_before="$(git -C "$CE_REPO" status --porcelain)"
  idx_before="$(sha1sum "$CE_REPO/.git/index" | cut -d' ' -f1)"
  local rc=0
  ( cmd_snapshot proj ) >/dev/null 2>&1 || rc=$?
  assert_eq "snapshot: rc=0" "$rc" "0"
  if git -C "$CE_MIRROR" show-ref --verify --quiet refs/heads/pbx/state; then
    ok "snapshot: ветка pbx/state создана в зеркале"
  else
    bad "snapshot: ветки pbx/state нет в зеркале"
  fi
  local files; files="$(git -C "$CE_MIRROR" ls-tree --name-only pbx/state | sort | paste -sd' ' -)"
  assert_eq "snapshot: 4 state-файла в дереве" "$files" "branches.tsv log.tsv state.env state.json"
  # КЛЮЧЕВОЕ: корп-история НЕ утекла в зеркало
  local corp_head; corp_head="$(git -C "$CE_REPO" rev-parse HEAD)"
  if git -C "$CE_MIRROR" cat-file -e "$corp_head" 2>/dev/null; then
    bad "snapshot: КОРП-КОММИТ УТЁК В ЗЕРКАЛО ($corp_head)"
  else
    ok "snapshot: корп-история в зеркало не утекла"
  fi
  # корп-репо не тронут
  assert_eq "snapshot: worktree не тронут" "$(git -C "$CE_REPO" status --porcelain)" "$st_before"
  assert_eq "snapshot: индекс бит-в-бит"   "$(sha1sum "$CE_REPO/.git/index" | cut -d' ' -f1)" "$idx_before"
  # содержимое валидно
  if command -v python3 >/dev/null 2>&1; then
    if git -C "$CE_MIRROR" cat-file blob pbx/state:state.json | python3 -m json.tool >/dev/null 2>&1; then
      ok "snapshot: state.json из зеркала валиден"
    else
      bad "snapshot: state.json из зеркала НЕ валиден"
    fi
  fi
  assert_has "snapshot: ветка AAA в branches.tsv" \
    "$(git -C "$CE_MIRROR" cat-file blob pbx/state:branches.tsv)" "feature/AAA-1"
  rm -rf "$CE_BASE" "$SN_REG" "$ws"
}

test_snapshot_second_is_fast_forward() {
  _mk_snap_fixture
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  ( cmd_snapshot proj ) >/dev/null 2>&1
  local tip1; tip1="$(git -C "$CE_MIRROR" rev-parse refs/heads/pbx/state)"
  ( cmd_snapshot proj ) >/dev/null 2>&1
  local tip2; tip2="$(git -C "$CE_MIRROR" rev-parse refs/heads/pbx/state)"
  if [[ "$tip1" != "$tip2" ]] && git -C "$CE_MIRROR" merge-base --is-ancestor "$tip1" "$tip2"; then
    ok "snapshot: второй — fast-forward (parent-chain)"
  else
    bad "snapshot: второй не ff (tip1=$tip1 tip2=$tip2)"
  fi
  rm -rf "$CE_BASE" "$SN_REG" "$ws"
}

test_snapshot_fetch_fail_flag() {
  _mk_snap_fixture
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  ( cd "$CE_REPO" && git remote set-url origin "$CE_BASE/nope.git" )
  local out rc=0
  out="$( ( cmd_snapshot proj ) 2>&1 )" || rc=$?
  assert_eq  "snapshot: сбой fetch origin не фатален (rc=0)" "$rc" "0"
  assert_has "snapshot: предупреждение fetch_ok=false" "$out" "fetch_ok=false"
  assert_has "snapshot: FETCH_OK=false в state.env зеркала" \
    "$(git -C "$CE_MIRROR" cat-file blob pbx/state:state.env)" "FETCH_OK=false"
  rm -rf "$CE_BASE" "$SN_REG" "$ws"
}

test_snapshot_mirror_unreachable_dies() {
  _mk_snap_fixture
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  printf 'REPO=%s\nMIRROR=%s\n' "$CE_REPO" "$CE_BASE/nope.git" > "$SN_REG/proj.conf"
  local out rc=0
  out="$( ( cmd_snapshot proj ) 2>&1 )" || rc=$?
  assert_eq  "snapshot: недоступное зеркало → rc=1" "$rc" "1"
  assert_has "snapshot: понятное сообщение" "$out" "недоступно"
  rm -rf "$CE_BASE" "$SN_REG" "$ws"
}

test_snapshot_no_mirror_dies() {
  _mk_snap_fixture
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  printf 'REPO=%s\n' "$CE_REPO" > "$SN_REG/proj.conf"
  local out rc=0
  out="$( ( cmd_snapshot proj ) 2>&1 )" || rc=$?
  assert_eq  "snapshot: без MIRROR → die" "$rc" "1"
  assert_has "snapshot: подсказка про MIRROR" "$out" "MIRROR"
  rm -rf "$CE_BASE" "$SN_REG" "$ws"
}

test_snapshot_all_mode_summary() {
  _mk_snap_fixture
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  # второй проект без MIRROR — должен быть пропущен, не уронив обход
  printf 'REPO=%s\n' "$CE_REPO" > "$SN_REG/proj2.conf"
  local out rc=0
  out="$( ( cmd_snapshot ) 2>&1 )" || rc=$?
  assert_eq  "snapshot all: rc=0" "$rc" "0"
  assert_has "snapshot all: сводка" "$out" "1 снято, 1 пропущено, 0 с ошибками"
  rm -rf "$CE_BASE" "$SN_REG" "$ws"
}

test_snapshot_race_alien_survives() {
  _mk_snap_fixture
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  ( cmd_snapshot proj ) >/dev/null 2>&1
  # чужой снапшот-коммит поверх pbx/state (другая машина)
  local ad; ad="$(mktemp -d)"
  ( git init -q "$ad" && cd "$ad" \
    && git config user.email a@a && git config user.name a \
    && git fetch -q "$CE_MIRROR" pbx/state \
    && git checkout -q -b alien FETCH_HEAD \
    && echo alien > alien.txt && git add -A && git commit -qm alien \
    && git push -q "$CE_MIRROR" alien:refs/heads/pbx/state ) >/dev/null 2>&1
  local alien; alien="$(git -C "$CE_MIRROR" rev-parse refs/heads/pbx/state)"
  ( cmd_snapshot proj ) >/dev/null 2>&1
  if git -C "$CE_MIRROR" merge-base --is-ancestor "$alien" refs/heads/pbx/state; then
    ok "snapshot: чужой коммит цел после нашего (parent-chain)"
  else
    bad "snapshot: чужой коммит потерян"
  fi
  rm -rf "$CE_BASE" "$SN_REG" "$ws" "$ad"
}

test_snapshot_cli_dispatch_and_help() {
  _mk_snap_fixture
  local ws; ws="$(make_ws)"
  local out rc=0
  out="$(PBX_REGISTRY_DIR="$SN_REG" PBX_WORKSPACE="$ws" bash "$PBX" snapshot proj 2>&1)" || rc=$?
  assert_eq  "CLI: pbx snapshot проходит" "$rc" "0"
  assert_has "CLI: итоговый баннер" "$out" "✅ proj"
  assert_has "help: команда snapshot" "$(bash "$PBX" help 2>&1)" "pbx snapshot"
  rm -rf "$CE_BASE" "$SN_REG" "$ws"
}

# --- Э3: pbx corp — чтение корп-состояния дома -----------------------------------
test_corp_read_state_rc_semantics() {
  _mk_snap_fixture
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  local d rc
  # rc=2: зеркало есть, снимка нет
  d="$(make_ws)"; rc=0
  corp_read_state "$CE_MIRROR" "$d" || rc=$?
  assert_eq "corp_read: rc=2 без снимка" "$rc" "2"
  # rc=0: после снапшота, файлы на месте
  ( cmd_snapshot proj ) >/dev/null 2>&1
  rc=0; corp_read_state "$CE_MIRROR" "$d" || rc=$?
  assert_eq "corp_read: rc=0 при снимке" "$rc" "0"
  if [[ -s "$d/state.json" && -s "$d/state.env" ]]; then
    ok "corp_read: файлы непустые"
  else
    bad "corp_read: файлы пустые"
  fi
  # rc=3: зеркало недоступно
  rc=0; corp_read_state "$CE_BASE/nope.git" "$d" || rc=$?
  assert_eq "corp_read: rc=3 при недоступном зеркале" "$rc" "3"
  rm -rf "$CE_BASE" "$SN_REG" "$ws" "$d"
}

test_cmd_corp_renders_state() {
  _mk_snap_fixture
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  ( cmd_snapshot proj ) >/dev/null 2>&1
  local out; out="$( ( cmd_corp proj ) 2>&1 )"
  assert_has "corp: секция проекта"    "$out" "proj: снимок"
  assert_has "corp: base_ref"          "$out" "origin/dev"
  assert_has "corp: ветка AAA"         "$out" "feature/AAA-1"
  assert_has "corp: лог dev"           "$out" "третий dev-коммит"
  rm -rf "$CE_BASE" "$SN_REG" "$ws"
}

test_cmd_corp_no_snapshot_message() {
  _mk_snap_fixture
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  local out; out="$( ( cmd_corp proj ) 2>&1 )"
  assert_has "corp: понятное «снимка ещё нет»" "$out" "снимка ещё нет"
  assert_has "corp: подсказка про snapshot"    "$out" "pbx snapshot proj"
  rm -rf "$CE_BASE" "$SN_REG" "$ws"
}

test_cmd_corp_unreachable_message() {
  _mk_snap_fixture
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  printf 'REPO=%s\nMIRROR=%s\n' "$CE_REPO" "$CE_BASE/nope.git" > "$SN_REG/proj.conf"
  local out; out="$( ( cmd_corp proj ) 2>&1 )"
  assert_has "corp: «зеркало недоступно»" "$out" "недоступно"
  rm -rf "$CE_BASE" "$SN_REG" "$ws"
}

test_cmd_corp_stale_and_fetchfail_warns() {
  _mk_snap_fixture
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  # рукотворный протухший снимок с fetch_ok=false (сеем как чужой pbx snapshot)
  local sd; sd="$(mktemp -d)"
  ( git init -q -b pbx/state "$sd" && cd "$sd" \
    && git config user.email p@p && git config user.name p \
    && printf '{"schema":1,"project":"proj","generated_at":123}\n' > state.json \
    && printf 'PBX_STATE_VERSION=1\nPROJECT=proj\nGENERATED_AT=123\nHOST=lap\nFETCH_OK=false\nBASE_REF=origin/dev\nBASE_SHA=abc\nBASE_SUBJECT=x\nCURRENT_BRANCH=dev\nDIRTY=0\nIN_MERGE=false\nBRANCHES_TOTAL=0\n' > state.env \
    && : > branches.tsv && : > log.tsv \
    && git add -A && git commit -qm seed \
    && git push -q "$CE_MIRROR" pbx/state:refs/heads/pbx/state ) >/dev/null 2>&1
  local out; out="$( ( cmd_corp proj ) 2>&1 )"
  assert_has "corp: снимок протух (>24ч)"   "$out" "протух"
  assert_has "corp: warn fetch_ok=false"    "$out" "без связи"
  rm -rf "$CE_BASE" "$SN_REG" "$ws" "$sd"
}

test_cmd_corp_json_valid() {
  _mk_snap_fixture
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  ( cmd_snapshot proj ) >/dev/null 2>&1
  # второй проект без MIRROR — в --json обязан попасть с available:false
  printf 'REPO=%s\n' "$CE_REPO" > "$SN_REG/proj2.conf"
  local out; out="$( ( cmd_corp --json ) 2>/dev/null )"
  assert_has "corp json: available true"   "$out" '"available":true'
  assert_has "corp json: schema из state"  "$out" '"schema":1'
  if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
      ok "corp json: валиден"
    else
      bad "corp json: НЕ валиден"
    fi
  fi
  local out2; out2="$( ( cmd_corp proj2 --json ) 2>/dev/null )"
  assert_has "corp json: без MIRROR → no-mirror" "$out2" '"reason":"no-mirror"'
  rm -rf "$CE_BASE" "$SN_REG" "$ws"
}

test_cmd_corp_tmp_cleanup() {
  _mk_snap_fixture
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  ( cmd_snapshot proj ) >/dev/null 2>&1
  local clean; clean="$(make_ws)"
  ( TMPDIR="$clean" cmd_corp proj ) >/dev/null 2>&1
  assert_eq "corp: tmp-репо убраны" \
    "$(find "$clean" -maxdepth 1 -name 'pbx-corp-read.*' | wc -l | tr -d ' ')" "0"
  rm -rf "$CE_BASE" "$SN_REG" "$ws" "$clean"
}

test_cmd_corp_cli_dispatch_and_help() {
  _mk_snap_fixture
  local ws; ws="$(make_ws)"
  ( cmd_snapshot proj ) >/dev/null 2>&1
  local out rc=0
  out="$(PBX_REGISTRY_DIR="$SN_REG" PBX_WORKSPACE="$ws" bash "$PBX" corp proj 2>&1)" || rc=$?
  assert_eq  "CLI: pbx corp проходит" "$rc" "0"
  assert_has "CLI: секция вывода" "$out" "proj: снимок"
  assert_has "help: команда corp" "$(bash "$PBX" help 2>&1)" "pbx corp"
  rm -rf "$CE_BASE" "$SN_REG" "$ws"
}

# --- Э3: status с MIRROR/push-инфо; меню snapshot/corp ---------------------------
test_status_json_mirror_and_push_keys() {
  _mk_push_fixture
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"; DIST_DIR="$ws/_dist"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  printf 'SRC=%s\nMIRROR=%s\n' "$PU_SRC" "$PU_MIRROR" > "$reg/proj.conf"
  ( cd "$PU_SRC" && git checkout -qb feature/S-1 ) >/dev/null 2>&1
  ( cmd_push proj ) >/dev/null 2>&1
  local out; out="$(cmd_status proj --json 2>/dev/null)"
  assert_has "status json: mirror"      "$out" "\"mirror\":\"$PU_MIRROR\""
  assert_has "status json: push_branch" "$out" '"push_branch":"feature/S-1"'
  if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
      ok "status json: валиден с новыми ключами"
    else
      bad "status json: НЕ валиден"
    fi
  fi
  rm -rf "$PU_BASE" "$ws" "$reg"
}

test_status_json_mirror_sentinels() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"; DIST_DIR="$ws/_dist"
  local reg; reg="$(make_ws)"; PBX_REGISTRY_DIR="$reg"
  mkdir -p "$ws/plainproj"
  local out; out="$(cmd_status plainproj --json 2>/dev/null)"
  assert_has "status json: mirror \"\""     "$out" '"mirror":""'
  assert_has "status json: pushed_at -1"    "$out" '"pushed_at":-1'
  rm -rf "$ws" "$reg"
}

test_menu_snapshot_runs_and_exits() {
  # 4 = snapshot: пишущая команда — прогон и выход из меню
  local ws reg out rc=0; ws="$(make_ws)"; reg="$(make_ws)"
  out="$( ( printf '4\n' | {
      source "$PBX"
      WORKSPACE="$ws"; PBX_REGISTRY_DIR="$reg"; UI_TTY=1
      TERM=xterm main
    } ) 2>&1 )" || rc=$?
  assert_has "меню: snapshot вызван"           "$out" "Снимок корп-состояния"
  assert_eq  "меню: snapshot → выход, rc=0"     "$rc" "0"
  rm -rf "$ws" "$reg"
}

test_menu_corp_returns_to_menu() {
  # 5 = corp (read-only) → Enter (menu_pause) → 12 = выход
  local ws reg out; ws="$(make_ws)"; reg="$(make_ws)"
  out="$( ( printf '5\n\n12\n' | {
      source "$PBX"
      WORKSPACE="$ws"; PBX_REGISTRY_DIR="$reg"; UI_TTY=1
      TERM=xterm main
    } ) 2>&1 )" || true
  assert_has "меню: corp вызван" "$out" "Корп-состояние"
  assert_eq  "меню: после corp снова меню" \
    "$(printf '%s' "$out" | grep -c 'что делаем')" "2"
  rm -rf "$ws" "$reg"
}

test_source_no_run
test_color_gated_in_pipe
test_ui_flags_nontty
test_glyphs_ascii_fallback
test_c_funcs_respect_flags
test_ui_helpers_plain_silent
test_ui_section_plain_invariant
test_pack_plain_invariant
test_repo_remote_url
test_scan_whole_repo
test_scan_container_one
test_scan_container_multi
test_scan_skips_nongit_and_noremote
test_scan_plain_container_one
test_scan_deep_nesting
test_scan_plain_container_multi
test_scan_no_descend_into_repo
test_scan_creates_repo_entry
test_scan_github_forge
test_scan_container_entry
test_scan_skip_existing
test_scan_dry_run
test_scan_requires_flag
test_scan_src_field
test_scan_both_flags_die
test_scan_unknown_dir_die
test_scan_default_dir_src
test_scan_dry_run_no_regdir
test_scan_container_cmd_warn
test_scan_then_list
test_scan_errexit_safe
test_defaults
test_project_over_global
test_env_wins
test_load_config_crlf
test_load_config_errexit_safe
test_registry_src_repo
test_registry_fallback
test_registry_crlf
test_registry_crlf_inproject_layer
test_list_projects
test_list_union
test_list_pipe_bare_names
test_help_plain_invariant
test_menu_select_plain_choice
test_menu_select_plain_cancel
test_menu_select_plain_eof
test_menu_select_plain_invalid_then_valid
test_menu_select_plain_leading_zero
test_menu_select_falls_back_to_plain
test_menu_gate_nontty_help
test_menu_gate_no_menu_env
test_menu_exit_item
test_menu_pack_e2e
test_menu_cancel_returns_cleanly
test_menu_status_returns_to_menu
test_menu_push_flow
test_menu_deliver_guard_fail_closed
test_ui_raw_off_idempotent
test_pack_excludes
test_pack_excludes_empty
test_sync_excludes
test_exclude_builders_errexit_safe
test_pack_e2e
test_pack_e2e_registry
test_pack_writes_meta_git
test_pack_writes_meta_nongit
test_pack_meta_broken_git_best_effort
test_status_collect_exact_clean
test_status_collect_exact_drift
test_status_collect_heuristic
test_status_collect_nongit_and_noarchive
test_status_collect_orphan_repo
test_status_collect_upstream_ahead
test_status_json_valid_and_pure
test_status_json_sentinels_nongit
test_status_table_pipe_no_ansi
test_status_unknown_project_dies
test_pad_helpers_multibyte
test_pack_exclude_pathspecs_forms
test_pack_exclude_pathspecs_extra
test_pbx_is_sha
test_load_config_mirror
test_snapshot_tree_contents
test_snapshot_tree_src_untouched
test_snapshot_tree_orphan_src
test_snapshot_tree_tracked_excluded_dropped
test_push_snapshot_first_and_ff
test_push_snapshot_no_changes
test_push_snapshot_concurrent_commit_survives
test_cmd_push_requires_mirror
test_cmd_push_default_branch_is_src_branch
test_meta_update_creates_with_header
test_meta_update_merge_preserves_order
test_meta_update_value_with_equals
test_meta_update_bad_keys_skipped
test_meta_update_crlf_normalized
test_pack_meta_survives_push_keys
test_cmd_push_writes_push_meta
test_json_str_v2_escapes
test_corp_collect_state_branches
test_corp_collect_state_no_base
test_corp_collect_state_fetch_fail
test_corp_collect_state_detached_and_merge
test_corp_collect_state_branch_cap
test_corp_state_files_json_valid
test_snapshot_creates_state_no_leak
test_snapshot_second_is_fast_forward
test_snapshot_fetch_fail_flag
test_snapshot_mirror_unreachable_dies
test_snapshot_no_mirror_dies
test_snapshot_all_mode_summary
test_snapshot_race_alien_survives
test_snapshot_cli_dispatch_and_help
test_corp_read_state_rc_semantics
test_cmd_corp_renders_state
test_cmd_corp_no_snapshot_message
test_cmd_corp_unreachable_message
test_cmd_corp_stale_and_fetchfail_warns
test_cmd_corp_json_valid
test_cmd_corp_tmp_cleanup
test_cmd_corp_cli_dispatch_and_help
test_status_json_mirror_and_push_keys
test_status_json_mirror_sentinels
test_menu_snapshot_runs_and_exits
test_menu_corp_returns_to_menu
test_scan_plain_no_branch_tail
test_log_upstream_and_meta_lines
test_deliver_uses_repo
test_deliver_guard_blocks_deletions
test_deliver_guard_plain_invariant
test_deliver_mirror_e2e
test_deliver_mirror_guard_fail_closed
test_deliver_mirror_requires_mirror_conf
test_deliver_archive_path_regression
test_log_reports_project
test_log_no_project
test_log_survives_unwritable_dist
test_die_writes_diag
test_add_creates_entry
test_add_refuses_overwrite
test_valid_project_registry_elsewhere
test_ctx_compare_unknown_cases
test_ctx_compare_behind_danger
test_ctx_compare_ok_when_home_has_tip
test_ctx_compare_unrelated_histories
test_ctx_compare_no_base_warn
test_ctx_compare_snapshot_stale_and_no_vpn
test_ctx_compare_repo_dirty_and_merge
test_ctx_compare_push_and_pack_stale
test_ctx_compare_push_fresh_silent
test_ctx_compare_undelivered_info
test_ctx_compare_danger_beats_warn
test_cmd_ctx_renders_verdict
test_cmd_ctx_render_glyphs
test_cmd_ctx_no_mirror_dies_plain
test_cmd_ctx_all_skips_no_mirror
test_cmd_ctx_unknown_flag_dies
test_cmd_ctx_in_help

# Заглушки git/gh — окно теней сведено только к трём forge-тестам ниже.
git() { printf 'git %s\n' "$*" >> "$CALLS"; }
gh()  { printf 'gh %s\n'  "$*" >> "$CALLS"; }
test_forge_gitlab
test_forge_gitlab_multiline_title
test_forge_github
test_forge_none
unset -f git gh

echo "--- Итог: PASS=$PASS FAIL=$FAIL ---"
[[ $FAIL -eq 0 ]]
