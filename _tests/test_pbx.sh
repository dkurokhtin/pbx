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
test_source_no_run() {
  local out; out="$(bash -c 'source "'"$PBX"'"' 2>&1)"
  assert_eq "source не запускает main (пустой вывод)" "$out" ""
}

# --- Task 2: load_config ----------------------------------------------------
test_defaults() {
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  unset PBX_BASE_BRANCH PBX_TARGET_BRANCH PBX_DEFAULT_ENV PBX_FORGE
  mkdir -p "$ws/proj"
  load_config "proj"
  assert_eq "дефолт BASE_BRANCH"   "$BASE_BRANCH"   "dev"
  assert_eq "дефолт TARGET_BRANCH" "$TARGET_BRANCH" "dev"
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
  unset PBX_BASE_BRANCH PBX_DEFAULT_ENV PBX_FORGE
  mkdir -p "$ws/proj"
  printf 'TARGET_BRANCH=bbb\n' > "$ws/proj/.pbx.conf"
  PBX_TARGET_BRANCH=ccc load_config "proj"
  assert_eq "env перебивает проектный конфиг" "$TARGET_BRANCH" "ccc"
  unset PBX_TARGET_BRANCH
  rm -rf "$ws"
}

test_load_config_crlf() {
  local ws; ws="$(make_ws)"; mkdir -p "$ws/proj"; WORKSPACE="$ws"
  unset PBX_FORGE PBX_TARGET_BRANCH PBX_BASE_BRANCH PBX_DEFAULT_ENV
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
  out="$(env -u PBX_FORGE -u PBX_BASE_BRANCH -u PBX_TARGET_BRANCH -u PBX_DEFAULT_ENV \
        bash -c 'set -euo pipefail; source "'"$PBX"'"; WORKSPACE="'"$ws"'"; load_config proj; echo REACHED' 2>&1)"
  assert_eq "load_config не падает под set -e (нет PBX_FORGE)" "$out" "REACHED"
  rm -rf "$ws"
}

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

  cmd_deliver "proj" "feature/T-1" "тест" "$dist/proj.tar.gz" >/dev/null 2>&1
  assert_eq "deliver снял RETURN-trap (ship не упадёт)" "$(trap -p RETURN)" ""

  assert_eq "deliver: файл синкнут в REPO" "$(cat "$repo/file.txt")" "new"
  assert_has "deliver: added.txt в REPO"   "$(ls "$repo")" "added.txt"
  local pushed; pushed="$(git -C "$remote" branch --list feature/T-1)"
  assert_has "deliver: ветка запушена в remote" "$pushed" "feature/T-1"
  cd "$HERE"   # cmd_deliver сделал cd "$repo" в текущем шелле — вернуться перед rm -rf
  rm -rf "$base" "$reg"
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

test_source_no_run
test_repo_remote_url
test_scan_whole_repo
test_scan_container_one
test_scan_container_multi
test_scan_skips_nongit_and_noremote
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
test_pack_excludes
test_pack_excludes_empty
test_sync_excludes
test_exclude_builders_errexit_safe
test_pack_e2e
test_pack_e2e_registry
test_deliver_uses_repo
test_add_creates_entry
test_add_refuses_overwrite
test_valid_project_registry_elsewhere

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
