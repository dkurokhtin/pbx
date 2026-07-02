# pbx Э3 — обратный поток корп-состояния: план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `pbx snapshot [проект]` (ноут: снимок состояния корп-репо → служебная ветка `pbx/state` зеркала) и `pbx corp [проект] [--json]` (дом: чтение снимка до подготовки доставки); `meta_update` с push-метой; MIRROR/push-инфо в status; пункты меню; README.

**Architecture:** Все механики проверены research-агентами вживую, два структурных утверждения — адверсариально (не-утечка корп-истории; shallow-чтение). Снапшот — mktree + commit-tree c parent-chain ТОЛЬКО из `pbx/state`, push без --force. Чтение дома — одноразовый tmp-репо + `fetch --depth 1` + `cat-file blob`. Спека: `docs/superpowers/specs/2026-07-02-pbx-corp-state-design.md`. Код-референс: `.superpowers/sdd/e3-research.md` (адаптирован в тасках — таски самодостаточны).

**Tech Stack:** bash ≥ 5 (ассоциативные массивы в meta_update), git (ls-remote/hash-object/mktree/commit-tree/for-each-ref/rev-list), timeout. Без новых зависимостей; python3 в тестах — только под `command -v`-гардом.

## Global Constraints

- Файл `pbx` — ОДИН самодостаточный bash-скрипт.
- **КОРП-РЕПО неприкосновенен**: snapshot не меняет worktree/index/HEAD/refs REPO (допустимый след — `.git/FETCH_HEAD` и unreferenced-объекты, как у Э2 в SRC).
- **НИКАКИХ родителей из корп-истории у state-коммитов**: push считает reachability — корп-родитель утащил бы ВСЮ историю корп-репо в личное зеркало (воспроизведено: 16 объектов вместо 6, содержимое корп-файлов читается из зеркала). Родитель — только tip `pbx/state` (или root-коммит).
- **Валидация SHA** (`_pbx_is_sha`) перед КАЖДЫМ push; назначение push — ПОЛНЫМ refname `refs/heads/pbx/state` (короткое падает «not a full refname» на несуществующей ветке).
- `commit-tree` — с явными `GIT_AUTHOR_*`/`GIT_COMMITTER_*` (user.name корп-репо не предполагается).
- Различение «ветки нет» / «зеркало недоступно» — ТОЛЬКО `ls-remote` (rc=0+пустой stdout / rc≠0); fetch даёт rc=128 в обоих случаях.
- Retry push — только при rc=1 + `[rejected]` в stderr (rc=128 — недоступность, не ретраить); перед КАЖДЫМ ретраем свежий `fetch` (новый tip иначе отсутствует в odb → commit-tree fatal).
- Все сетевые git-вызовы: `GIT_TERMINAL_PROMPT=0` + `timeout 30`.
- printf-формат ВСЕГДА литеральный (`printf '%s' "$var"` — сабжект с `%` иначе ломает вывод); строки в state.json — только через `_json_str_v2`.
- TSV: свободный текст — ТОЛЬКО последним полем; средние поля не пусты (сентинель `-`); чтение — `while IFS=$'\t' read -r … || [[ -n $поле1 ]]`.
- Тесты: ВСЕ сетевые операции — на локальных bare-репо (пути/file://); НИКАКИХ обращений к реальному GitHub.
- Дисциплина set -euo pipefail (read с `||`, `local x; x=$(...)` раздельно, функции с `return 0`, счёт через `grep -c . || true`).
- Plain-инварианты существующих команд не задеты (новые dim-строки — через ui_dim, молчащий в plain).
- Прогон: `cd /mnt/c/Users/darkl/Claude/Projects/Pybotx && bash _tests/test_pbx.sh` → FAIL=0.
- Ветка: `feature/pbx-corp-state` (создаётся в Task 1). Правки в месте.

---

### Task 1: `meta_update` + `write_pack_meta` на её основе + push-мета в `cmd_push`

**Files:**
- Modify: `pbx` (секция `# ---- meta`, строки ~243-269: новая `meta_update` ПЕРЕД `write_pack_meta`; тело `write_pack_meta` переписывается; `cmd_push` ~строка 689: запись push-меты после успешного пуша)
- Test: `_tests/test_pbx.sh`

**Interfaces:**
- Produces: `meta_update <файл> KEY=VALUE…` — мерж ключей в meta-файл: существующие обновляются на месте (порядок строк и `#`-шапка сохраняются), новые — в конец; файла нет → создаётся с шапкой `# pbx meta: проект <basename без .meta>, автогенерация pbx`; атомарно (tmp+mv), best-effort (warn, rc=0 всегда); CRLF чистится в аргументах И строках файла; `\n` в значении → пробел; ключи только `[A-Za-z0-9_]+` (кривой — warn+пропуск; ни одного валидного — файл не трогается).
- Produces: push-ключи в `$DIST_DIR/<проект>.meta`: `PUSHED_AT` (epoch), `PUSH_BRANCH`, `PUSH_COMMIT` (sha снапшот-коммита), `PUSH_SOURCE_COMMIT` (HEAD SRC на момент пуша; `-` если нет).
- Consumes: `strip_cr`, `c_warn`, `cmd_push`/`push_snapshot` (Э2), `_mk_push_fixture` (тесты Э2).

- [ ] **Step 1: Создать ветку**

```bash
cd /mnt/c/Users/darkl/Claude/Projects/Pybotx
git checkout -b feature/pbx-corp-state
```

- [ ] **Step 2: Написать падающие тесты**

В `_tests/test_pbx.sh` после `test_cmd_push_default_branch_is_src_branch` добавить:

```bash
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
```

В блок регистрации тестов в конце файла (после `test_cmd_push_default_branch_is_src_branch`) добавить в том же порядке:

```bash
test_meta_update_creates_with_header
test_meta_update_merge_preserves_order
test_meta_update_value_with_equals
test_meta_update_bad_keys_skipped
test_meta_update_crlf_normalized
test_pack_meta_survives_push_keys
test_cmd_push_writes_push_meta
```

- [ ] **Step 3: Прогнать тесты — убедиться, что новые падают**

Run: `bash _tests/test_pbx.sh 2>&1 | tail -3`
Expected: `FAIL>0` (meta_update: command not found; push-мета отсутствует), все старые зелёные.

- [ ] **Step 4: Реализация**

В `pbx`, секция `# ---- meta`, ПЕРЕД `write_pack_meta` вставить:

```bash
# meta_update <файл> KEY=VALUE… — мерж ключей в meta-файл (KEY=value, sed-читатели).
# Существующие ключи обновляются НА МЕСТЕ (порядок строк и #-шапка сохраняются),
# новые дописываются в конец. Атомарно (tmp+mv), best-effort: сбой → warn, rc=0.
# CRLF чистится и в аргументах, и в строках файла (мета с /mnt/c бывает CRLF —
# без чистки ключ «COMMIT\r» задваивается; воспроизведено). \n в значении →
# пробел; ключи только [A-Za-z0-9_]+ (кривой — warn и пропуск, файл не трогаем).
meta_update() {
  local file="$1"; shift
  local proj; proj="$(basename "$file" .meta)"
  local -a keys=()
  local -A vals=()
  local kv key val
  for kv in "$@"; do
    kv="$(strip_cr "$kv")"
    kv="${kv//$'\n'/ }"
    case "$kv" in
      *=*) ;;
      *) c_warn "⚠️  meta_update: пропущен аргумент без '=': '$kv'"; continue ;;
    esac
    key="${kv%%=*}"; val="${kv#*=}"
    case "$key" in
      ''|*[!A-Za-z0-9_]*) c_warn "⚠️  meta_update: плохой ключ '$key' — пропущен"; continue ;;
    esac
    [[ -v vals[$key] ]] || keys+=("$key")
    vals[$key]="$val"
  done
  (( ${#keys[@]} )) || { c_warn "⚠️  meta_update: нет валидных пар KEY=VALUE для $file"; return 0; }

  local -a out=()
  local -A written=()
  local line lk
  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      case "$line" in
        ''|'#'*) out+=("$line"); continue ;;
      esac
      lk="${line%%=*}"
      if [[ -v vals[$lk] ]]; then
        out+=("$lk=${vals[$lk]}"); written[$lk]=1
      else
        out+=("$line")
      fi
    done < "$file"
  else
    out+=("# pbx meta: проект $proj, автогенерация pbx")
  fi
  for key in "${keys[@]}"; do
    [[ -v written[$key] ]] && continue
    out+=("$key=${vals[$key]}")
  done
  local tmp="$file.tmp"
  # Редиректы обрабатываются слева направо: ошибку открытия $tmp глушит ТОЛЬКО
  # группа { …; } 2>/dev/null (иначе она просочится раньше подавления).
  if { printf '%s\n' "${out[@]}" > "$tmp"; } 2>/dev/null && mv -f "$tmp" "$file" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  c_warn "⚠️  Не удалось записать мету: $file"
  return 0
}
```

Тело `write_pack_meta` заменить (сигнатура и сбор значений прежние, запись — через meta_update):

```bash
write_pack_meta() {
  local project="$1" src="$2" out_meta="$3"
  local commit='-' branch='-' dirty='-'
  local st_out=''
  if [[ -e "$src/.git" ]]; then
    commit="$(git -C "$src" rev-parse HEAD 2>/dev/null || echo '-')"
    branch="$(git -C "$src" branch --show-current 2>/dev/null || true)"
    [[ -n "$branch" ]] || branch='-'
    if st_out="$(git -C "$src" status --porcelain 2>/dev/null)"; then
      dirty="$(printf '%s' "$st_out" | grep -c . || true)"
    fi
  fi
  meta_update "$out_meta" \
    "PBX_META_VERSION=1" \
    "PACKED_AT=$(date +%s)" \
    "COMMIT=$commit" \
    "BRANCH=$branch" \
    "DIRTY_AT_PACK=$dirty"
  return 0
}
```

В `cmd_push` после успешного пуша — сразу ПЕРЕД строкой `c_green "✅ $project: снапшот…"` — вставить:

```bash
  mkdir -p "$DIST_DIR" 2>/dev/null || true
  local src_head; src_head="$(git -C "$SRC" rev-parse -q --verify HEAD 2>/dev/null || echo '-')"
  meta_update "$DIST_DIR/$project.meta" \
    "PUSHED_AT=$(date +%s)" \
    "PUSH_BRANCH=$branch" \
    "PUSH_COMMIT=$sha" \
    "PUSH_SOURCE_COMMIT=$src_head"
```

- [ ] **Step 5: Прогнать тесты**

Run: `bash _tests/test_pbx.sh 2>&1 | tail -3`
Expected: `FAIL=0` (старая шапка «автогенерация pack» существующих meta-файлов сохраняется meta_update-ом — шапка не перезаписывается).

- [ ] **Step 6: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(meta): meta_update — мерж ключей; write_pack_meta на её основе; push-мета в cmd_push"
```

---

### Task 2: `_json_str_v2` + сбор корп-состояния + генерация state-файлов

**Files:**
- Modify: `pbx` (новая секция `# ---- corp-state (Э3)` ПОСЛЕ `cmd_push`, ПЕРЕД `forge_push`; `_json_str_v2` — рядом с `_json_str`, строка ~390)
- Test: `_tests/test_pbx.sh`

**Interfaces:**
- Produces: `_json_str_v2 <строка>` — JSON-экранирование: `\\`, `\"`, `\t`, `\n`, `\r`, остальные C0 вычищаются; порядок замен — backslash ПЕРВЫМ.
- Produces: глобали `PBX_STATE_BRANCH="pbx/state"`, `CORP_BRANCH_PREFIXES=(feature fix hotfix bugfix chore)`.
- Produces: `corp_collect_state <REPO> <BASE>` — заполняет `CS_*`: `CS_REPO CS_BASE_BRANCH CS_FETCH_OK(true|false) CS_BASE_REF("origin/<BASE>"|"") CS_ORIGIN CS_CURRENT_BRANCH CS_DIRTY(-1|N) CS_IN_MERGE(true|false) CS_BASE_SHA CS_BASE_DATE(epoch|-1) CS_BASE_SUBJ CS_LOG(TSV-строки sha7/date/subject) CS_BRANCHES(TSV-строки name/where/sha7/ahead/behind/last_date/shortstat, с завершающим \n) CS_BRANCHES_TOTAL`. Сетевые сбои НЕ фатальны (fetch_ok=false). rc=0 всегда.
- Produces: `corp_state_files <каталог> <проект>` — пишет `state.json`, `state.env`, `branches.tsv`, `log.tsv` из `CS_*`. rc=0.
- Consumes: `strip_cr`, `c_warn`, `pad` (Э1).

- [ ] **Step 1: Написать падающие тесты**

В `_tests/test_pbx.sh` после тестов Task 1 добавить:

```bash
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
```

Регистрация (в конец блока, после тестов Task 1):

```bash
test_json_str_v2_escapes
test_corp_collect_state_branches
test_corp_collect_state_no_base
test_corp_collect_state_fetch_fail
test_corp_collect_state_detached_and_merge
test_corp_state_files_json_valid
```

- [ ] **Step 2: Прогнать — убедиться в падении**

Run: `bash _tests/test_pbx.sh 2>&1 | tail -3`
Expected: FAIL>0 (`_json_str_v2: command not found`, `corp_collect_state: command not found`).

- [ ] **Step 3: Реализация**

В `pbx` сразу после `_json_str` (строка ~390) добавить:

```bash
# JSON-экранирование для corp-state: + управляющие символы (сырой таб в сабжекте
# ломает JSON — воспроизведено). ПОРЯДОК ЗАМЕН КРИТИЧЕН: backslash первым.
# _json_str остаётся для status_json (совместимость поверхности Э1).
_json_str_v2() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//[$'\x01'-$'\x08\x0b\x0c\x0e'-$'\x1f']/}"
  printf '%s' "$s"
}
```

После `cmd_push` (перед `forge_push`) — новая секция:

```bash
# =============================================================================
#  corp-state (Э3): обратный поток — состояние корп-репо через служебную
#  ветку pbx/state личного зеркала. Механики проверены вживую (спека §4-6,
#  референс .superpowers/sdd/e3-research.md).
#  КРИТИЧНО: у state-коммитов НЕТ родителей из корп-истории — push считает
#  reachability и утащил бы ВСЮ историю корп-репо в зеркало (воспроизведено).
# =============================================================================

# Имя служебной ветки состояния в зеркале (захардкожено — спека §2.1 п.2).
PBX_STATE_BRANCH="pbx/state"
# Префиксы «доставленных» веток (конвенция deliver).
CORP_BRANCH_PREFIXES=(feature fix hotfix bugfix chore)

# corp_collect_state <REPO> <BASE> — заполняет CS_*-глобали состоянием корп-репо.
# Только чтение. Сетевые сбои НЕ фатальны: CS_FETCH_OK=false, сбор продолжается
# по последним известным remote-refs (проверено вживую).
corp_collect_state() {
  local repo="$1" base="$2"
  CS_REPO="$repo"; CS_BASE_BRANCH="$base"
  CS_FETCH_OK=true; CS_BASE_REF=''; CS_ORIGIN=''; CS_CURRENT_BRANCH=''
  CS_DIRTY=-1; CS_IN_MERGE=false
  CS_BASE_SHA=''; CS_BASE_DATE=-1; CS_BASE_SUBJ=''
  CS_LOG=''; CS_BRANCHES=''; CS_BRANCHES_TOTAL=0

  if ! GIT_TERMINAL_PROMPT=0 timeout 30 git -C "$repo" fetch -q origin --prune 2>/dev/null; then
    CS_FETCH_OK=false
  fi
  CS_ORIGIN="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
  CS_CURRENT_BRANCH="$(git -C "$repo" branch --show-current 2>/dev/null || true)"
  local st_out=''
  if st_out="$(git -C "$repo" status --porcelain 2>/dev/null)"; then
    CS_DIRTY="$(printf '%s' "$st_out" | grep -c . || true)"
  fi
  local mh
  mh="$(git -C "$repo" rev-parse --git-path MERGE_HEAD 2>/dev/null || true)"
  if [[ -n "$mh" ]]; then
    [[ "$mh" == /* ]] || mh="$repo/$mh"
    [[ -e "$mh" ]] && CS_IN_MERGE=true
  fi

  if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$base" 2>/dev/null; then
    CS_BASE_REF="origin/$base"
    local tip rest
    tip="$(git -C "$repo" log -1 "$CS_BASE_REF" --format=$'%H\t%ct\t%s' 2>/dev/null || true)"
    if [[ -n "$tip" ]]; then
      CS_BASE_SHA="${tip%%$'\t'*}"
      rest="${tip#*$'\t'}"
      CS_BASE_DATE="${rest%%$'\t'*}"
      CS_BASE_SUBJ="${rest#*$'\t'}"
    fi
    CS_LOG="$(git -C "$repo" log "$CS_BASE_REF" -20 --format=$'%h\t%cs\t%s' 2>/dev/null || true)"
  fi

  # доставленные ветки: origin/<префиксы>/* + local-only тех же префиксов;
  # паттерн без /* работает как префикс всей иерархии (проверено)
  local -a rpat=() lpat=()
  local p
  for p in "${CORP_BRANCH_PREFIXES[@]}"; do
    rpat+=("refs/remotes/origin/$p"); lpat+=("refs/heads/$p")
  done
  local remote_list local_list merged=''
  remote_list="$(git -C "$repo" for-each-ref --sort=-committerdate \
    --format=$'%(refname:lstrip=3)\tremote\t%(objectname:short)\t%(committerdate:unix)\t%(committerdate:short)' \
    "${rpat[@]}" 2>/dev/null || true)"
  local_list="$(git -C "$repo" for-each-ref --sort=-committerdate \
    --format=$'%(refname:short)\tlocal\t%(objectname:short)\t%(committerdate:unix)\t%(committerdate:short)' \
    "${lpat[@]}" 2>/dev/null || true)"
  merged="$remote_list"
  local line b
  if [[ -n "$local_list" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      b="${line%%$'\t'*}"
      git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$b" 2>/dev/null && continue
      if [[ -n "$merged" ]]; then merged+=$'\n'"$line"; else merged="$line"; fi
    done <<< "$local_list"
  fi
  if [[ -n "$merged" ]]; then
    merged="$(printf '%s\n' "$merged" | sort -t$'\t' -k4,4nr)"
  fi
  CS_BRANCHES_TOTAL="$(printf '%s' "$merged" | grep -c . || true)"
  local capped
  capped="$(printf '%s' "$merged" | head -30)"

  local name where sha7 cdu cds ref behind ahead shortstat lr
  while IFS=$'\t' read -r name where sha7 cdu cds || [[ -n "$name" ]]; do
    [[ -n "$name" ]] || continue
    if [[ "$where" == remote ]]; then ref="origin/$name"; else ref="$name"; fi
    behind='-'; ahead='-'; shortstat='-'
    if [[ -n "$CS_BASE_REF" ]]; then
      # порядок вывода rev-list --left-right: СЛЕВА behind (только в BASE),
      # СПРАВА ahead (только в ветке) — доказано на фикстуре (спека §5)
      lr="$(git -C "$repo" rev-list --left-right --count "$CS_BASE_REF...$ref" 2>/dev/null || true)"
      if [[ -n "$lr" ]]; then behind="${lr%%$'\t'*}"; ahead="${lr##*$'\t'}"; fi
      # three-dot = от merge-base; влитая ветка → пустой stdout, rc=0 → '-'
      shortstat="$(git -C "$repo" diff --shortstat "$CS_BASE_REF...$ref" 2>/dev/null | sed 's/^ *//' || true)"
      [[ -n "$shortstat" ]] || shortstat='-'
    fi
    CS_BRANCHES+="${name}"$'\t'"${where}"$'\t'"${sha7}"$'\t'"${ahead}"$'\t'"${behind}"$'\t'"${cds}"$'\t'"${shortstat}"$'\n'
  done <<< "$capped"
  return 0
}

# corp_state_files <каталог> <проект> — записать 4 state-файла из CS_*-глобалей.
# state.json — однострочный (corp --json встраивает его сырым); state.env —
# KEY=value (читатели sed, НЕ source; значения строго однострочные); TSV —
# свободный текст последним полем, средние поля не пусты (сентинель '-').
corp_state_files() {
  local dir="$1" project="$2"
  local gen_at host
  gen_at="$(date +%s)"
  host="$(hostname 2>/dev/null || echo '-')"

  printf '%s' "$CS_BRANCHES" > "$dir/branches.tsv"
  if [[ -n "$CS_LOG" ]]; then printf '%s\n' "$CS_LOG" > "$dir/log.tsv"; else : > "$dir/log.tsv"; fi

  # значения state.env строго однострочные: обрезка до первой строки
  # (перевод строки в значении инжектит фейковый ключ — воспроизведено)
  local subj_env="${CS_BASE_SUBJ%%$'\n'*}"
  {
    printf '# pbx corp-state: проект %s, автогенерация snapshot\n' "$project"
    printf 'PBX_STATE_VERSION=1\n'
    printf 'PROJECT=%s\n' "$project"
    printf 'GENERATED_AT=%s\n' "$gen_at"
    printf 'HOST=%s\n' "$host"
    printf 'REPO=%s\n' "$CS_REPO"
    printf 'FETCH_OK=%s\n' "$CS_FETCH_OK"
    printf 'ORIGIN=%s\n' "$CS_ORIGIN"
    printf 'BASE_BRANCH=%s\n' "$CS_BASE_BRANCH"
    printf 'BASE_REF=%s\n' "$CS_BASE_REF"
    printf 'CURRENT_BRANCH=%s\n' "$CS_CURRENT_BRANCH"
    printf 'DIRTY=%s\n' "$CS_DIRTY"
    printf 'IN_MERGE=%s\n' "$CS_IN_MERGE"
    printf 'BASE_SHA=%s\n' "${CS_BASE_SHA:--}"
    printf 'BASE_DATE=%s\n' "$CS_BASE_DATE"
    printf 'BASE_SUBJECT=%s\n' "${subj_env:--}"
    printf 'BRANCHES_TOTAL=%s\n' "$CS_BRANCHES_TOTAL"
  } > "$dir/state.env"

  {
    printf '{'
    printf '"schema":1'
    printf ',"project":"%s"' "$(_json_str_v2 "$project")"
    printf ',"generated_at":%s' "$gen_at"
    printf ',"host":"%s"' "$(_json_str_v2 "$host")"
    printf ',"repo":"%s"' "$(_json_str_v2 "$CS_REPO")"
    printf ',"fetch_ok":%s' "$CS_FETCH_OK"
    printf ',"origin":"%s"' "$(_json_str_v2 "$CS_ORIGIN")"
    printf ',"base_branch":"%s"' "$(_json_str_v2 "$CS_BASE_BRANCH")"
    printf ',"base_ref":"%s"' "$(_json_str_v2 "$CS_BASE_REF")"
    printf ',"current_branch":"%s"' "$(_json_str_v2 "$CS_CURRENT_BRANCH")"
    printf ',"dirty":%s' "$CS_DIRTY"
    printf ',"in_merge":%s' "$CS_IN_MERGE"
    if [[ -n "$CS_BASE_SHA" ]]; then
      printf ',"base":{"sha":"%s","date":%s,"subject":"%s"}' \
        "$CS_BASE_SHA" "$CS_BASE_DATE" "$(_json_str_v2 "$CS_BASE_SUBJ")"
    else
      printf ',"base":null'
    fi
    printf ',"log":['
    local first=1 sha7 cdate subj
    if [[ -n "$CS_LOG" ]]; then
      while IFS=$'\t' read -r sha7 cdate subj || [[ -n "$sha7" ]]; do
        [[ -n "$sha7" ]] || continue
        if (( first )); then first=0; else printf ','; fi
        printf '{"sha7":"%s","date":"%s","subject":"%s"}' \
          "$sha7" "$cdate" "$(_json_str_v2 "$subj")"
      done <<< "$CS_LOG"
    fi
    printf ']'
    printf ',"branches":['
    first=1
    local bname bwhere bsha7 bahead bbehind bdate bstat aj bj
    if [[ -n "$CS_BRANCHES" ]]; then
      while IFS=$'\t' read -r bname bwhere bsha7 bahead bbehind bdate bstat || [[ -n "$bname" ]]; do
        [[ -n "$bname" ]] || continue
        if (( first )); then first=0; else printf ','; fi
        aj="$bahead"; [[ "$aj" == '-' ]] && aj=null
        bj="$bbehind"; [[ "$bj" == '-' ]] && bj=null
        printf '{"name":"%s","where":"%s","sha7":"%s","ahead":%s,"behind":%s,"last_date":"%s","shortstat":"%s"}' \
          "$(_json_str_v2 "$bname")" "$bwhere" "$bsha7" "$aj" "$bj" "$bdate" "$(_json_str_v2 "$bstat")"
      done <<< "$CS_BRANCHES"
    fi
    printf ']'
    printf ',"branches_total":%s' "$CS_BRANCHES_TOTAL"
    printf '}\n'
  } > "$dir/state.json"
  return 0
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `bash _tests/test_pbx.sh 2>&1 | tail -3`
Expected: FAIL=0.

- [ ] **Step 5: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(corp-state): _json_str_v2, сбор корп-состояния (CS_*), генерация state-файлов"
```

---

### Task 3: `snapshot_push` + `cmd_snapshot` + диспетчер/help

**Files:**
- Modify: `pbx` (секция corp-state после `corp_state_files`; диспетчер `main()`; `cmd_help` — обе формы)
- Test: `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: `corp_collect_state`, `corp_state_files`, `PBX_STATE_BRANCH` (Task 2); `_pbx_is_sha` (Э2); `meta_update` НЕ нужна (snapshot мету не пишет).
- Produces: `snapshot_push <REPO> <MIRROR> <проект>` — stdout: sha снапшот-коммита; rc=1 — ошибка. Использует `BASE_BRANCH` из load_config.
- Produces: `cmd_snapshot [проект]` — один проект (die при отсутствии REPO-git/MIRROR) или обход всех (скип без пометки об ошибке; exit 1 только если попытки были и ВСЕ упали).
- Produces: `snapshot` в диспетчере и help.

- [ ] **Step 1: Написать падающие тесты**

После тестов Task 2 добавить:

```bash
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
```

Регистрация (после тестов Task 2):

```bash
test_snapshot_creates_state_no_leak
test_snapshot_second_is_fast_forward
test_snapshot_fetch_fail_flag
test_snapshot_mirror_unreachable_dies
test_snapshot_no_mirror_dies
test_snapshot_all_mode_summary
test_snapshot_race_alien_survives
test_snapshot_cli_dispatch_and_help
```

- [ ] **Step 2: Прогнать — убедиться в падении**

Run: `bash _tests/test_pbx.sh 2>&1 | tail -3`
Expected: FAIL>0 (`cmd_snapshot: command not found`).

- [ ] **Step 3: Реализация**

В секцию corp-state после `corp_state_files` добавить:

```bash
# snapshot_push <REPO> <MIRROR> <проект> — собрать состояние корп-репо и
# закоммитить в ветку PBX_STATE_BRANCH зеркала. stdout: sha коммита; rc=1 — сбой.
# КОРП-РЕПО не трогается: файлы во внешнем mktemp, блобы hash-object -w
# (только object db), дерево mktree (без индекса), у коммита НЕТ корп-родителей.
snapshot_push() {
  local repo="$1" mirror="$2" project="$3"
  [[ -e "$repo/.git" ]] || { c_warn "snapshot: не git-репозиторий: $repo"; return 1; }

  # ls-remote различает «ветки нет» (rc=0, пусто) и «репо недоступен» (rc≠0);
  # fetch даёт rc=128 в обоих случаях — не годится (проверено).
  local ls_out ls_rc=0
  ls_out="$(GIT_TERMINAL_PROMPT=0 timeout 30 git -C "$repo" ls-remote "$mirror" "refs/heads/$PBX_STATE_BRANCH" 2>/dev/null)" || ls_rc=$?
  if (( ls_rc != 0 )); then
    c_warn "snapshot: зеркало недоступно: $mirror (VPN/PAT/URL?)"
    return 1
  fi

  corp_collect_state "$repo" "$BASE_BRANCH"
  [[ "$CS_FETCH_OK" == true ]] \
    || c_warn "⚠️  fetch origin не удался — снимок по последним известным remote-refs (fetch_ok=false)"

  local tmpd; tmpd="$(mktemp -d -t pbx-state.XXXXXX)" || { c_warn "snapshot: mktemp не удался"; return 1; }
  corp_state_files "$tmpd" "$project"

  # блобы: пути ТОЛЬКО абсолютные (git -C делает chdir — относительный путь
  # скрипта не найдётся); mktree: TAB перед именем обязателен (иначе fatal).
  local f b tree_in=''
  for f in state.json state.env branches.tsv log.tsv; do
    if ! b="$(git -C "$repo" hash-object -w "$tmpd/$f" 2>/dev/null)"; then
      rm -rf "$tmpd"; c_warn "snapshot: hash-object не удался ($f)"; return 1
    fi
    tree_in+="100644 blob ${b}"$'\t'"${f}"$'\n'
  done
  rm -rf "$tmpd"
  local tree
  tree="$(printf '%s' "$tree_in" | git -C "$repo" mktree 2>/dev/null)" \
    || { c_warn "snapshot: mktree не удался"; return 1; }
  _pbx_is_sha "$tree" || { c_warn "snapshot: mktree вернул не SHA ('$tree')"; return 1; }

  local branch_exists=0
  [[ -n "$ls_out" ]] && branch_exists=1

  local attempt max_attempts=3
  for attempt in $(seq 1 "$max_attempts"); do
    # свежий fetch ОБЯЗАТЕЛЕН перед каждым commit-tree: после чужого push
    # новый tip отсутствует в локальном odb (fatal 'not a valid object')
    local remote_tip=""
    if (( branch_exists )); then
      if GIT_TERMINAL_PROMPT=0 timeout 30 git -C "$repo" fetch -q "$mirror" "$PBX_STATE_BRANCH" 2>/dev/null; then
        remote_tip="$(git -C "$repo" rev-parse -q --verify FETCH_HEAD 2>/dev/null || true)"
      fi
    fi
    local -a parent_args=()
    _pbx_is_sha "$remote_tip" && parent_args+=(-p "$remote_tip")
    # КРИТИЧНО: никаких родителей из корп-истории — push утащил бы её в зеркало.

    local msg commit_sha
    msg="$(printf 'pbx snapshot: %s @ %s\n\nbase: %s\nfetch_ok: %s\n' \
      "$project" "$(hostname 2>/dev/null || echo '-')" "${CS_BASE_REF:-—}" "$CS_FETCH_OK")"
    if ! commit_sha="$(GIT_AUTHOR_NAME=pbx GIT_AUTHOR_EMAIL=pbx@local \
        GIT_COMMITTER_NAME=pbx GIT_COMMITTER_EMAIL=pbx@local \
        git -C "$repo" commit-tree "$tree" ${parent_args[@]+"${parent_args[@]}"} -m "$msg" 2>&1)"; then
      c_warn "snapshot: commit-tree не удался: $commit_sha"; return 1
    fi
    # КРИТИЧНО: пустой src-ref в refspec = УДАЛЕНИЕ ветки на remote.
    if ! _pbx_is_sha "$commit_sha"; then
      c_warn "snapshot: commit-tree вернул не SHA ('$commit_sha') — отмена (пуш пустого ref удалил бы ветку!)"
      return 1
    fi
    # назначение — ПОЛНЫЙ refname (короткое падает на несуществующей ветке)
    local out push_rc=0
    out="$(GIT_TERMINAL_PROMPT=0 timeout 30 git -C "$repo" push "$mirror" \
      "$commit_sha:refs/heads/$PBX_STATE_BRANCH" 2>&1)" || push_rc=$?
    if (( push_rc == 0 )); then
      printf '%s\n' "$commit_sha"
      return 0
    fi
    # ретрай осмыслен только при отклонении (rc=1 + [rejected]); rc=128 — недоступность
    if (( push_rc != 1 )) || [[ "$out" != *"[rejected]"* ]]; then
      c_warn "snapshot: push не удался (rc=$push_rc):"
      printf '%s\n' "$out" >&2
      return 1
    fi
    c_warn "snapshot: попытка $attempt/$max_attempts отклонена (гонка на зеркале?)"
    branch_exists=1   # после отклонения ветка точно есть — в ретрае фетчим tip
  done
  c_warn "snapshot: не удалось за $max_attempts попыток"
  return 1
}

cmd_snapshot() {
  local project; project="$(strip_cr "${1:-}")"
  if [[ -n "$project" ]]; then
    PBX_CURRENT_PROJECT="$project"
    valid_project "$project"
    load_config "$project"
    [[ -e "$REPO/.git" ]] || die "REPO не git-репозиторий: $REPO"
    [[ -n "${MIRROR:-}" ]] || die "Не задан MIRROR для '$project'. Добавь MIRROR=git@github.com:<user>/<repo>.git в $PBX_REGISTRY_DIR/$project.conf"
    ui_section "Снимок $project" "🔵 Снимок состояния $project ($REPO) → $MIRROR ($PBX_STATE_BRANCH)"
    ui_kv REPO "$REPO"
    ui_kv MIRROR "$MIRROR"
    ui_kv BASE "$BASE_BRANCH"
    local sha
    sha="$(snapshot_push "$REPO" "$MIRROR" "$project")" || die "pbx snapshot не удался (см. вывод выше)"
    c_green "✅ $project: состояние корп-репо ушло в зеркало ('$PBX_STATE_BRANCH', ${sha:0:7})"
    return 0
  fi

  # без аргумента: все проекты реестра с REPO-git и MIRROR
  ui_section "Снимок корп-состояния" "🔵 Снимок корп-состояния (все проекты):"
  local -a names=()
  mapfile -t names < <(list_projects)
  if (( ${#names[@]} == 0 )); then
    c_warn "  (проектов не найдено)"
    return 0
  fi
  local p snapped=0 skipped=0 failed=0 sha
  for p in "${names[@]}"; do
    load_config "$p"
    if [[ ! -e "$REPO/.git" || -z "${MIRROR:-}" ]]; then
      ui_dim "  $p — пропуск (нет REPO-git или MIRROR)"
      skipped=$((skipped+1))
      continue
    fi
    sha=''
    if sha="$(snapshot_push "$REPO" "$MIRROR" "$p")"; then
      c_green "  ✅ $p: снимок ${sha:0:7}"
      snapped=$((snapped+1))
    else
      c_warn "  ❌ $p: снимок не удался"
      failed=$((failed+1))
    fi
  done
  c_blue "🔵 Итог: $snapped снято, $skipped пропущено, $failed с ошибками"
  if (( failed > 0 && snapped == 0 )); then return 1; fi
  return 0
}
```

В диспетчере `main()` после строки `push)` добавить:

```bash
    snapshot)           cmd_snapshot "$@" ;;
```

В `cmd_help`, plain-форма — после строки `pbx push …`:

```
  pbx snapshot [проект]                         НОУТ: снимок состояния корп-репо (ветки, лог, ahead/behind) → ветка pbx/state зеркала (MIRROR)
```

Цветная форма — после строки push:

```
  ${C_CYAN}pbx snapshot${C_RESET} [проект]              ${C_DIM}ноут: снимок корп-состояния → ветка pbx/state зеркала${C_RESET}
```

- [ ] **Step 4: Прогнать тесты**

Run: `bash _tests/test_pbx.sh 2>&1 | tail -3`
Expected: FAIL=0.

- [ ] **Step 5: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(snapshot): pbx snapshot — снимок корп-состояния в служебную ветку зеркала (mktree, без корп-родителей)"
```

---

### Task 4: `corp_read_state` + `cmd_corp` (+ `--json`) + диспетчер/help

**Files:**
- Modify: `pbx` (секция corp-state после `cmd_snapshot`; диспетчер; help — обе формы)
- Test: `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: `PBX_STATE_BRANCH`, `snapshot_push` (фикстуры тестов), `_json_str_v2`, `pad`, `menu_pause` НЕ нужен (только в Task 5).
- Produces: `corp_read_state <MIRROR> <каталог>` — забирает 4 state-файла из tip `pbx/state` (одноразовый tmp-репо, `fetch --depth 1`, `cat-file blob`); отсутствующий в дереве файл → пустой файл в каталоге. rc: 0 — ок; 2 — снимка ещё нет; 3 — зеркало недоступно/сбой.
- Produces: `corp_render_project <проект> <каталог>` — человекочитаемая секция (возраст/протухание >24ч, fetch_ok, base, dirty/in_merge, ветки, лог ≤10). rc=0.
- Produces: `corp_json <проект>…` — JSON-массив `{"project":…,"available":true,"state":<сырой state.json>}` | `{"project":…,"available":false,"reason":"no-mirror|no-snapshot|mirror-unreachable|empty-state"}`.
- Produces: `cmd_corp [проект] [--json]`; `corp` в диспетчере и help.

- [ ] **Step 1: Написать падающие тесты**

После тестов Task 3 добавить:

```bash
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
```

Регистрация (после тестов Task 3):

```bash
test_corp_read_state_rc_semantics
test_cmd_corp_renders_state
test_cmd_corp_no_snapshot_message
test_cmd_corp_unreachable_message
test_cmd_corp_stale_and_fetchfail_warns
test_cmd_corp_json_valid
test_cmd_corp_tmp_cleanup
test_cmd_corp_cli_dispatch_and_help
```

- [ ] **Step 2: Прогнать — убедиться в падении**

Run: `bash _tests/test_pbx.sh 2>&1 | tail -3`
Expected: FAIL>0 (`corp_read_state: command not found`).

- [ ] **Step 3: Реализация**

В секцию corp-state после `cmd_snapshot` добавить:

```bash
# corp_read_state <MIRROR> <каталог> — забрать state-файлы из tip pbx/state.
# Одноразовый tmp-репо + shallow fetch (только tip, не история снимков) +
# cat-file blob (без checkout). rc: 0 ок; 2 снимка ещё нет; 3 недоступно/сбой.
corp_read_state() {
  local mirror="$1" dest="$2"
  local ls_out ls_rc=0
  ls_out="$(GIT_TERMINAL_PROMPT=0 timeout 30 git ls-remote "$mirror" "refs/heads/$PBX_STATE_BRANCH" 2>/dev/null)" || ls_rc=$?
  (( ls_rc == 0 )) || return 3
  [[ -n "$ls_out" ]] || return 2
  local tmp; tmp="$(mktemp -d -t pbx-corp-read.XXXXXX)" || return 3
  if ! git init -q "$tmp" 2>/dev/null; then rm -rf "$tmp"; return 3; fi
  if ! GIT_TERMINAL_PROMPT=0 timeout 30 git -C "$tmp" fetch -q --depth 1 "$mirror" "$PBX_STATE_BRANCH" 2>/dev/null; then
    rm -rf "$tmp"; return 3
  fi
  local f
  for f in state.json state.env branches.tsv log.tsv; do
    # отсутствующий в дереве файл (снимок старой схемы) → пустой файл
    git -C "$tmp" cat-file blob "FETCH_HEAD:$f" > "$dest/$f" 2>/dev/null || : > "$dest/$f"
  done
  rm -rf "$tmp"
  return 0
}

# corp_render_project <проект> <каталог> — человекочитаемая секция состояния.
corp_render_project() {
  local p="$1" d="$2"
  local gen_at host fetch_ok base_ref base_sha base_subj cur dirty in_merge btotal
  gen_at="$(sed -n 's/^GENERATED_AT=//p' "$d/state.env")"
  host="$(sed -n 's/^HOST=//p' "$d/state.env")"
  fetch_ok="$(sed -n 's/^FETCH_OK=//p' "$d/state.env")"
  base_ref="$(sed -n 's/^BASE_REF=//p' "$d/state.env")"
  base_sha="$(sed -n 's/^BASE_SHA=//p' "$d/state.env")"
  base_subj="$(sed -n 's/^BASE_SUBJECT=//p' "$d/state.env")"
  cur="$(sed -n 's/^CURRENT_BRANCH=//p' "$d/state.env")"
  dirty="$(sed -n 's/^DIRTY=//p' "$d/state.env")"
  in_merge="$(sed -n 's/^IN_MERGE=//p' "$d/state.env")"
  btotal="$(sed -n 's/^BRANCHES_TOTAL=//p' "$d/state.env")"

  local now=0 age_h=-1 age_str='возраст неизвестен'
  now="$(date +%s)"
  if [[ "$gen_at" =~ ^[0-9]+$ ]]; then
    age_h=$(( (now - gen_at) / 3600 ))
    if (( age_h < 1 )); then age_str="меньше часа назад"; else age_str="${age_h} ч назад"; fi
  fi
  c_blue "— $p: снимок с ${host:--}, $age_str"
  if (( age_h > 24 )); then
    c_warn "  ⚠️  снимок протух (>24 ч) — обнови на ноуте: pbx snapshot $p"
  fi
  if [[ "$fetch_ok" != true ]]; then
    c_warn "  ⚠️  ноут снимал без связи с gitlab (fetch_ok=false) — данные могут отставать"
  fi
  if [[ -n "$base_ref" ]]; then
    printf '  %s: %s %s\n' "$base_ref" "${base_sha:0:7}" "$base_subj"
  else
    c_warn "  ⚠️  базовая ветка не найдена на origin (снимок без ahead/behind)"
  fi
  local merge_note=''
  if [[ "$in_merge" == true ]]; then merge_note=', НЕЗАВЕРШЁННЫЙ MERGE'; fi
  printf '  корп-репо: ветка %s, правок %s%s\n' "${cur:--}" "${dirty:-?}" "$merge_note"
  if [[ -s "$d/branches.tsv" ]]; then
    printf '  доставленные ветки (%s):\n' "${btotal:-?}"
    local name where sha7 ahead behind last_date shortstat
    while IFS=$'\t' read -r name where sha7 ahead behind last_date shortstat || [[ -n "$name" ]]; do
      [[ -n "$name" ]] || continue
      printf '    %s %s  +%s/-%s  %s\n' \
        "$(pad "$name" 34)" "$(pad "$where" 6)" "$ahead" "$behind" "$last_date"
    done < "$d/branches.tsv"
  else
    printf '  доставленных веток нет\n'
  fi
  if [[ -s "$d/log.tsv" ]]; then
    printf '  последние коммиты %s:\n' "${base_ref:-базы}"
    local i=0 lsha ldate lsubj
    while IFS=$'\t' read -r lsha ldate lsubj || [[ -n "$lsha" ]]; do
      [[ -n "$lsha" ]] || continue
      printf '    %s %s %s\n' "$lsha" "$ldate" "$lsubj"
      i=$((i+1))
      if (( i >= 10 )); then break; fi
    done < "$d/log.tsv"
  fi
  return 0
}

# corp_json <проект>… — JSON-массив состояний; state.json встраивается СЫРЫМ
# (мы его и сгенерировали — парс не нужен).
corp_json() {
  local p first=1 d rc reason
  printf '['
  for p in "$@"; do
    load_config "$p"
    if (( first )); then first=0; else printf ','; fi
    if [[ -z "${MIRROR:-}" ]]; then
      printf '\n  {"project":"%s","available":false,"reason":"no-mirror"}' "$(_json_str_v2 "$p")"
      continue
    fi
    d="$(mktemp -d -t pbx-corp-read.XXXXXX)"
    rc=0
    corp_read_state "$MIRROR" "$d" || rc=$?
    if (( rc == 0 )) && [[ -s "$d/state.json" ]]; then
      printf '\n  {"project":"%s","available":true,"state":' "$(_json_str_v2 "$p")"
      cat "$d/state.json"
      printf '}'
    else
      case "$rc" in
        2) reason="no-snapshot" ;;
        3) reason="mirror-unreachable" ;;
        *) reason="empty-state" ;;
      esac
      printf '\n  {"project":"%s","available":false,"reason":"%s"}' "$(_json_str_v2 "$p")" "$reason"
    fi
    rm -rf "$d"
  done
  printf '\n]\n'
  return 0
}

cmd_corp() {
  local project='' json=0 a
  for a in "$@"; do
    a="$(strip_cr "$a")"
    case "$a" in
      --json) json=1 ;;
      -*) die "Неизвестный флаг: $a (ожидается --json)" ;;
      *) [[ -n "$project" ]] && die "Лишний аргумент: $a (проект указывается один)"; project="$a" ;;
    esac
  done
  if [[ -n "$project" ]]; then
    PBX_CURRENT_PROJECT="$project"
    valid_project "$project"
    if (( ! json )); then
      load_config "$project"
      [[ -n "${MIRROR:-}" ]] || die "Не задан MIRROR для '$project'. Добавь MIRROR=git@github.com:<user>/<repo>.git в $PBX_REGISTRY_DIR/$project.conf"
    fi
  fi

  local -a names=()
  if [[ -n "$project" ]]; then
    names=("$project")
  else
    local p
    while IFS= read -r p; do
      load_config "$p"
      [[ -n "${MIRROR:-}" ]] && names+=("$p")
    done < <(list_projects)
  fi

  if (( json )); then
    corp_json ${names[@]+"${names[@]}"}
    return 0
  fi

  ui_section "Корп-состояние" "🔵 Корп-состояние проектов:"
  if (( ${#names[@]} == 0 )); then
    c_warn "  (проектов с MIRROR не найдено — задай MIRROR= в реестре)"
    return 0
  fi
  local rc d
  local pr
  for pr in "${names[@]}"; do
    load_config "$pr"
    d="$(mktemp -d -t pbx-corp-read.XXXXXX)"
    rc=0
    corp_read_state "$MIRROR" "$d" || rc=$?
    case "$rc" in
      0) corp_render_project "$pr" "$d" ;;
      2) c_warn "  $pr: снимка ещё нет — запусти на ноуте: pbx snapshot $pr" ;;
      *) c_warn "  $pr: зеркало недоступно ($MIRROR) — VPN/PAT/URL?" ;;
    esac
    rm -rf "$d"
  done
  return 0
}
```

В диспетчере после `snapshot)`:

```bash
    corp)               cmd_corp "$@" ;;
```

В `cmd_help`, plain-форма — после строки snapshot:

```
  pbx corp    [проект] [--json]                 ДОМ: показать снимок корп-состояния из зеркала (возраст, dev-tip, ветки); --json — для ИИ
```

Цветная форма — после snapshot:

```
  ${C_CYAN}pbx corp${C_RESET}    [проект] [--json]       ${C_DIM}дом: корп-состояние из зеркала (для ИИ: --json)${C_RESET}
```

- [ ] **Step 4: Прогнать тесты**

Run: `bash _tests/test_pbx.sh 2>&1 | tail -3`
Expected: FAIL=0.

- [ ] **Step 5: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(corp): pbx corp — чтение корп-состояния дома (shallow tmp-репо, --json для ИИ)"
```

---

### Task 5: status (MIRROR/push-инфо), меню (2 пункта), README

**Files:**
- Modify: `pbx` (`status_collect` ~строка 310; `status_json` ~строка 421; `cmd_status` ~строка 495; `cmd_menu` items+case ~строка 1368)
- Modify: `README.md` (раздел после транспорта Э2)
- Test: `_tests/test_pbx.sh` (новые тесты + обновление цифровых вводов меню)

**Interfaces:**
- Consumes: push-мета из Task 1 (`PUSHED_AT/PUSH_BRANCH/PUSH_COMMIT/PUSH_SOURCE_COMMIT`), `cmd_snapshot` (Task 3), `cmd_corp` (Task 4).
- Produces: `ST_MIRROR ST_PUSH_BRANCH ST_PUSH_COMMIT ST_PUSHED_AT(-1|epoch) ST_PUSH_SOURCE` в `status_collect`; JSON-ключи `"mirror","push_branch","push_commit","pushed_at"` В КОНЦЕ объекта (порядок прежних не меняется); dim-строка `mirror: …` в человекочитаемом status.
- Produces: пункты меню `snapshot` (индекс 3, цифра 4; пишущая → выход) и `corp` (индекс 4, цифра 5; read-only → menu_pause); «выход» — цифра 12.

- [ ] **Step 1: Написать падающие тесты + обновить цифровые вводы меню**

Обновить существующие меню-тесты (нумерация сдвинулась: log 4→6, status 5→7, выход 10→12):

- `test_menu_exit_item`: `printf '10\n'` → `printf '12\n'`; текст ассерта «(10)» → «(12)».
- `test_menu_status_returns_to_menu`: `printf '5\n\n10\n'` → `printf '7\n\n12\n'`; комментарий «5 = status … 10 = выход» → «7 = status … 12 = выход».

(`test_menu_pack_e2e` `1\n1\n`, `test_menu_push_flow` `2\n1\n\n`, `test_menu_deliver_guard_fail_closed` `3\n1\n…` — НЕ меняются: pack/push/deliver остались 1/2/3.)

Новые тесты (после тестов Task 4):

```bash
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
```

Регистрация (после тестов Task 4):

```bash
test_status_json_mirror_and_push_keys
test_status_json_mirror_sentinels
test_menu_snapshot_runs_and_exits
test_menu_corp_returns_to_menu
```

- [ ] **Step 2: Прогнать — убедиться в падении**

Run: `bash _tests/test_pbx.sh 2>&1 | tail -3`
Expected: FAIL>0 (нет json-ключей mirror; меню: цифра 4 — это пока log; обновлённые exit/status-тесты падают до перенумерации).

- [ ] **Step 3: Реализация**

`status_collect` — в блок инициализации (после `ST_REPO=…`) добавить:

```bash
  ST_MIRROR="${MIRROR:-}"
  ST_PUSH_BRANCH=''; ST_PUSH_COMMIT=''; ST_PUSHED_AT=-1; ST_PUSH_SOURCE=''
```

Там же, в блок чтения меты (`if [[ -f "$meta" ]]; then …`) добавить перед `fi`:

```bash
    ST_PUSH_BRANCH="$(sed -n 's/^PUSH_BRANCH=//p' "$meta")"
    ST_PUSH_COMMIT="$(sed -n 's/^PUSH_COMMIT=//p' "$meta")"
    ST_PUSHED_AT="$(sed -n 's/^PUSHED_AT=//p' "$meta")"
    ST_PUSH_SOURCE="$(sed -n 's/^PUSH_SOURCE_COMMIT=//p' "$meta")"
    [[ -n "$ST_PUSHED_AT" ]] || ST_PUSHED_AT=-1
```

`status_json` — последний printf объекта заменить с

```bash
    printf '"repo":"%s","repo_exists":%s}' "$(_json_str "$ST_REPO")" "$ST_REPO_EXISTS"
```

на

```bash
    printf '"repo":"%s","repo_exists":%s,' "$(_json_str "$ST_REPO")" "$ST_REPO_EXISTS"
    printf '"mirror":"%s","push_branch":"%s","push_commit":"%s","pushed_at":%s}' \
      "$(_json_str "$ST_MIRROR")" "$(_json_str "$ST_PUSH_BRANCH")" \
      "$(_json_str "$ST_PUSH_COMMIT")" "$ST_PUSHED_AT"
```

`cmd_status` — в цикле, после блока `if [[ "$ST_REPO_EXISTS" == true …]]` добавить:

```bash
    if [[ -n "$ST_MIRROR" ]]; then
      local mline="mirror: $ST_MIRROR"
      if [[ -n "$ST_PUSH_COMMIT" ]]; then
        local when='?'
        if [[ "$ST_PUSHED_AT" =~ ^[0-9]+$ ]]; then
          when="$(date -d "@$ST_PUSHED_AT" '+%d.%m %H:%M' 2>/dev/null || echo '?')"
        fi
        mline+=" (push: ${ST_PUSH_BRANCH:--} @ ${ST_PUSH_COMMIT:0:7}, $when"
        local head_now=''
        if [[ "$ST_GIT" == true ]]; then
          head_now="$(git -C "$ST_SRC" rev-parse HEAD 2>/dev/null || true)"
        fi
        if [[ -n "$ST_PUSH_SOURCE" && -n "$head_now" && "$ST_PUSH_SOURCE" != "$head_now" ]]; then
          mline+=", SRC ушёл вперёд"
        fi
        mline+=")"
      fi
      ui_dim "$mline"
    fi
```

`cmd_menu` — массив items заменить на:

```bash
  local -a items=(
    'pack    — упаковать проект в архив'
    'push    — снапшот рабочего дерева в зеркало'
    'deliver — доставить архив в репо (ветка + MR)'
    'snapshot — снимок корп-состояния в зеркало (ноут)'
    'corp    — корп-состояние проектов (дом)'
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
      1) if menu_project_flow push;    then return 0; fi ;;
      2) if menu_project_flow deliver; then return 0; fi ;;
      3) cmd_snapshot || true; return 0 ;;
      4) cmd_corp || true; menu_pause ;;
      5) menu_project_flow log || true ;;
      6) cmd_status; menu_pause ;;
      7) cmd_list; menu_pause ;;
      8) c_blue "🔵 Синтаксис: pbx scan (--repo|--src) [каталог] [--dry-run]"; return 0 ;;
      9) c_blue "🔵 Синтаксис: pbx add <имя> [путь-SRC]"; return 0 ;;
      10) cmd_help; menu_pause ;;
      11) return 0 ;;
    esac
```

В `README.md` после раздела про транспорт Э2 добавить:

```markdown
## Обратный поток: состояние корп-репозиториев (Э3)

Дом не видит корп-GitLab. Чтобы планировать доставку по фактам (страховка от
«устаревший снимок молча откатывает чужую работу», класс SUP-2603):

- **Ноут, конец дня:** `pbx snapshot` — снимает состояние всех корп-реп
  (ветки, лог dev, ahead/behind доставленных веток) в 4 маленьких файла и
  коммитит их в служебную ветку `pbx/state` личного зеркала (MIRROR).
  Git-объекты корп-истории в зеркало НЕ уезжают — только текстовые метаданные
  (sha, сабжекты, имена веток).
- **Дом, перед доставкой:** `pbx corp [проект]` — показывает снимок: возраст,
  верхушку dev, доставленные ветки с ahead/behind. Для ИИ-агента:
  `pbx corp <проект> --json`.

Auth — тот же, что для транспорта (SSH дома, HTTPS+PAT на ноуте, см. выше).
Снимок старше 24 ч помечается протухшим. Без VPN на ноуте снимок делается по
последним известным remote-refs с пометкой `fetch_ok=false`.
```

- [ ] **Step 4: Прогнать тесты**

Run: `bash _tests/test_pbx.sh 2>&1 | tail -3`
Expected: FAIL=0 (включая обновлённые меню-тесты).

- [ ] **Step 5: Commit**

```bash
git add pbx _tests/test_pbx.sh README.md
git commit -m "feat(status,menu),docs: MIRROR и push-инфо в status, пункты snapshot/corp в меню, README про обратный поток"
```

---

## Порядок и зависимости

Task 1 → независим. Task 2 → независим (после 1 для чистоты истории). Task 3 → требует Task 2 (`corp_collect_state`, `corp_state_files`, `PBX_STATE_BRANCH`). Task 4 → требует Task 3 (фикстуры тестов сеют снимок через `cmd_snapshot`). Task 5 → требует Task 1 (push-мета) и 3-4 (пункты меню). Выполнять строго 1→2→3→4→5.

## Известные ограничения (осознанные, в леджер)

- Пункты меню 10-12 (help/выход/…) недоступны ЦИФРОЙ в raw-режиме (`[1-9]`) —
  предсуществующее ограничение menu_select (леджер Э2 [T5-minor]); стрелки работают.
- `pbx corp` читает только tip `pbx/state` (история снимков не используется — спека §10).
- Устаревшие push-ключи в meta после нового pack — данные, не баг: детект «SRC ушёл вперёд» в status.

## После завершения

1. Полный прогон: `bash _tests/test_pbx.sh` → FAIL=0 (ожидаемо ~340+ PASS).
2. Финальное ревью (opus) по чек-листу спеки §12; фиксы → ре-ревью.
3. Merge: `git checkout main && git merge --no-ff feature/pbx-corp-state -m "Merge: Э3 — обратный поток корп-состояния (pbx snapshot / pbx corp)" && bash _tests/test_pbx.sh && git branch -d feature/pbx-corp-state && git push origin main`.
4. Обновить память (`project_pbx_delivery.md`): Э3 done, Э4 next.
5. За пользователем: первый живой `pbx snapshot` на ноуте (после переноса pbx + MIRROR+PAT в ноутовский реестр) и `pbx corp vnd` дома.
