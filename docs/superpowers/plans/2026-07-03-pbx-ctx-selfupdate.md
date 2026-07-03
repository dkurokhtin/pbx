# pbx Э4 — `pbx ctx` + `pbx self-update` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Автосравнение дом↔корп с вердиктом готовности к доставке (`pbx ctx`) и самообновление pbx на ноуте из GitHub-зеркала (`pbx self-update`).

**Architecture:** ctx — композиция существующих конвейеров: `status_collect` (ST_*-глобали, дом) + `corp_read_state` (state-файлы снимка из ветки `pbx/state` зеркала) → новый чистый слой `ctx_compare` (CTX_*-глобали: вердикт ok/warn/danger/unknown + причины) → render/JSON. self-update — shallow-fetch зеркала pbx во временный каталог, валидация кандидата, атомарная замена `mv`, SHA в `~/.config/pbx/self.rev` через существующий `meta_update`.

**Tech Stack:** bash (один самодостаточный файл `pbx`), git plumbing, тесты — `_tests/test_pbx.sh` (собственный харнесс ok/bad/assert_*).

**Спека:** `docs/superpowers/specs/2026-07-03-pbx-ctx-selfupdate-design.md` — одобрена пользователем.

## Global Constraints

- Один самодостаточный bash-файл `pbx`; jq/curl НЕ появляются.
- Plain-вывод существующих команд не меняется ни на байт; новое в `snapshot` — только TTY-dim (`ui_dim`); в `collect_diag` — только ДОБАВЛЕНИЕ строк.
- JSON-схемы `status --json` (Э1) и `corp --json` (Э3) не трогаются; у ctx собственная схема.
- Все сетевые git-вызовы: `GIT_TERMINAL_PROMPT=0 timeout 30 git …`.
- Сентинели: неизвестная строка `''`, неизвестное число `-1`; булевы — строки `true`/`false`.
- JSON — ручная сборка с `_json_str_v2` (НЕ `_json_str` — тот без управляющих символов).
- Тесты: сетевые операции ТОЛЬКО на локальных bare-репо (file://-семантика путей); каждый тест убирает свои tmp-каталоги; `cmd_*` с die — в сабшелле `( cmd_x )`.
- В тестовых git-фикстурах обязательны `git config user.email`/`user.name`.
- Ветка разработки: `feature/pbx-ctx-selfupdate` от `main`.
- Коммиты — conventional commits на русском, как в истории репо (`feat(ctx): …`, `test(ctx): …`).

## Карта файлов

- Modify: `pbx` — новые функции `ctx_compare`, `_ctx_reason`, `ctx_render_project`, `ctx_json`, `cmd_ctx`, `self_mirror_url`, `self_branch_name`, `cmd_self_update`, `self_update_hint`; правки `cmd_snapshot` (хвост), `collect_diag` (одна строка), `cmd_help` (обе ветки), `cmd_menu` (два пункта), `main` (два кейса).
- Modify: `_tests/test_pbx.sh` — новые тесты + вызовы в конце списка (ПЕРЕД строкой-комментарием `# Заглушки git/gh`).

Размещение в `pbx`: блок ctx — после `corp_json`/`cmd_corp` (~строка 1307, перед `forge_push`); блок self-update — после `cmd_scan` (перед `cmd_help`).

---

### Task 1: `ctx_compare` — ядро: unknown-ветки, парс снимка, сравнение историй

**Files:**
- Modify: `pbx` (после `cmd_corp`, ~строка 1307)
- Test: `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: `corp_read_state <mirror> <dir>` (rc: 0 ок / 2 нет снимка / 3 недоступно), state-файлы `state.env`/`log.tsv`/`branches.tsv`, ST_*-глобали из `status_collect` (`ST_SRC`, `ST_GIT`, `ST_PUSH_COMMIT`, `ST_PUSH_SOURCE`, `ST_ARCHIVE_EXISTS`, `ST_STALE`), `strip_cr`.
- Produces: `ctx_compare <state-dir> <rc>` — rc от corp_read_state ИЛИ `4` (нет MIRROR). Заполняет глобали: `CTX_VERDICT` (ok|warn|danger|unknown), `CTX_BEHIND_N` (int, -1 неизвестно), `CTX_REASONS` (строки `code\tlevel\tmsg\n`), `CTX_SNAPSHOT_AT`, `CTX_FETCH_OK`, `CTX_BASE_BRANCH`, `CTX_BASE_SHA`, `CTX_BASE_DATE`, `CTX_REPO_DIRTY`, `CTX_IN_MERGE`, `CTX_UNDELIVERED` (строки `name\tahead\n`). Хелпер `_ctx_reason <code> <level> <msg>`.

- [ ] **Step 1: Создать ветку**

```bash
cd /mnt/c/Users/darkl/Claude/Projects/Pybotx && git checkout -b feature/pbx-ctx-selfupdate main
```

- [ ] **Step 2: Написать падающие тесты**

В `_tests/test_pbx.sh` после последней тест-функции Э3 (перед списком вызовов) добавить фикстуру и тесты:

```bash
# --- Э4: pbx ctx — вердикт дом↔корп -------------------------------------------
# Фикстура: corp-фикстура + домашний SRC (клон origin, отстаёт на 1 коммит) +
# state-каталог со снимком корп-состояния. Глобали: + CTX_SRC, CTX_STATE
_mk_ctx_fixture() {
  _mk_corp_fixture
  CTX_SRC="$CE_BASE/src"
  git clone -q "$CE_ORIGIN" "$CTX_SRC" 2>/dev/null
  ( cd "$CTX_SRC" && git config user.email t@t && git config user.name t \
    && git checkout -q dev && git reset -q --hard HEAD~1 ) >/dev/null 2>&1
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
```

Добавить вызовы в конец списка тестов (ПЕРЕД строкой `# Заглушки git/gh — окно теней…`):

```bash
test_ctx_compare_unknown_cases
test_ctx_compare_behind_danger
test_ctx_compare_ok_when_home_has_tip
test_ctx_compare_unrelated_histories
test_ctx_compare_no_base_warn
```

- [ ] **Step 3: Запустить тесты — убедиться, что падают**

Run: `bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh 2>&1 | tail -15`
Expected: FAIL>0, ошибки вида `ctx_compare: command not found`.

- [ ] **Step 4: Реализовать ctx_compare в `pbx`**

Вставить после `cmd_corp()` (перед комментарием `# Пуш ветки + создание MR/PR согласно FORGE.`):

```bash
# =============================================================================
#  ctx (Э4): автосравнение дом↔корп с вердиктом готовности к доставке.
#  Композиция живых конвейеров: status_collect (дом) + corp_read_state (снимок
#  pbx/state зеркала) → ctx_compare → вердикт ok/warn/danger/unknown + причины.
# =============================================================================

# Порог свежести снимка (сек) — как в corp_render_project (24 ч).
PBX_CTX_STALE_SEC=86400

# _ctx_reason <code> <level:danger|warn|info> <msg> — причина + эскалация вердикта.
# info вердикт не поднимает; unknown ставится только явно в ctx_compare.
_ctx_reason() {
  CTX_REASONS+="$1"$'\t'"$2"$'\t'"$3"$'\n'
  case "$2" in
    danger) CTX_VERDICT='danger' ;;
    warn)   [[ "$CTX_VERDICT" != danger ]] && CTX_VERDICT='warn' ;;
  esac
  return 0
}

# ctx_compare <state-dir> <rc> — заполняет CTX_*-глобали.
# rc: 0 — state-файлы в каталоге валидны; 2 — снимка нет; 3 — зеркало
# недоступно; 4 — нет MIRROR. Требует ST_* (status_collect) при rc=0.
# Вердикт при сомнении — в сторону строгости (fail-closed).
ctx_compare() {
  local d="$1" rc="$2"
  CTX_VERDICT='ok'; CTX_BEHIND_N=-1; CTX_REASONS=''
  CTX_SNAPSHOT_AT=-1; CTX_FETCH_OK=''; CTX_BASE_BRANCH=''; CTX_BASE_SHA=''
  CTX_BASE_DATE=-1; CTX_REPO_DIRTY=-1; CTX_IN_MERGE=''; CTX_UNDELIVERED=''

  case "$rc" in
    4) _ctx_reason no_mirror warn 'нет MIRROR в реестре — корп-данных нет'
       CTX_VERDICT='unknown'; return 0 ;;
    2) _ctx_reason no_snapshot warn 'снимка ещё нет — запусти на ноуте: pbx snapshot'
       CTX_VERDICT='unknown'; return 0 ;;
    0) ;;
    *) _ctx_reason mirror_unreachable warn 'зеркало недоступно (VPN/PAT/URL?)'
       CTX_VERDICT='unknown'; return 0 ;;
  esac

  # корп-картина из state.env (читатели sed, как corp_render_project)
  CTX_SNAPSHOT_AT="$(sed -n 's/^GENERATED_AT=//p' "$d/state.env")"
  [[ "$CTX_SNAPSHOT_AT" =~ ^[0-9]+$ ]] || CTX_SNAPSHOT_AT=-1
  CTX_FETCH_OK="$(sed -n 's/^FETCH_OK=//p' "$d/state.env")"
  CTX_BASE_BRANCH="$(sed -n 's/^BASE_BRANCH=//p' "$d/state.env")"
  CTX_BASE_SHA="$(sed -n 's/^BASE_SHA=//p' "$d/state.env")"
  [[ "$CTX_BASE_SHA" == '-' ]] && CTX_BASE_SHA=''
  CTX_BASE_DATE="$(sed -n 's/^BASE_DATE=//p' "$d/state.env")"
  [[ "$CTX_BASE_DATE" =~ ^-?[0-9]+$ ]] || CTX_BASE_DATE=-1
  CTX_REPO_DIRTY="$(sed -n 's/^DIRTY=//p' "$d/state.env")"
  [[ "$CTX_REPO_DIRTY" =~ ^-?[0-9]+$ ]] || CTX_REPO_DIRTY=-1
  CTX_IN_MERGE="$(sed -n 's/^IN_MERGE=//p' "$d/state.env")"

  # недоставленное: ветки с ahead>0 (branches.tsv: name where sha7 ahead …)
  local bname bwhere bsha7 bahead _rest
  if [[ -s "$d/branches.tsv" ]]; then
    while IFS=$'\t' read -r bname bwhere bsha7 bahead _rest || [[ -n "$bname" ]]; do
      [[ -n "$bname" ]] || continue
      [[ "$bahead" =~ ^[0-9]+$ ]] || continue
      (( bahead > 0 )) && CTX_UNDELIVERED+="$bname"$'\t'"$bahead"$'\n'
    done < "$d/branches.tsv"
  fi

  if [[ "$ST_GIT" != true ]]; then
    _ctx_reason src_not_git warn 'SRC не git — сравнение историй невозможно'
    CTX_VERDICT='unknown'
    return 0
  fi

  # --- ключевая проверка (SUP-2603): tip корп-dev достижим из дома? ----------
  if [[ -n "$CTX_BASE_SHA" ]]; then
    if ! git -C "$ST_SRC" cat-file -e "$CTX_BASE_SHA^{commit}" 2>/dev/null; then
      # отставание: первый из 20 сокращённых SHA корп-лога, найденный дома
      # (строка 1 = сам tip, уже проверен полным SHA; неоднозначный короткий
      # SHA даёт ошибку cat-file → «не найден» — строгая сторона)
      local n=-1 i=0 lsha _ld _ls
      while IFS=$'\t' read -r lsha _ld _ls || [[ -n "$lsha" ]]; do
        [[ -n "$lsha" ]] || continue
        i=$((i+1))
        (( i == 1 )) && continue
        if git -C "$ST_SRC" cat-file -e "$lsha^{commit}" 2>/dev/null; then
          n=$((i-1)); break
        fi
      done < "$d/log.tsv"
      if (( n > 0 )); then
        CTX_BEHIND_N=$n
        _ctx_reason home_behind_corp danger \
          "дом отстал от корп-dev на $n коммит(ов) — обнови SRC перед доставкой"
      else
        _ctx_reason histories_unrelated warn \
          'не удалось сопоставить истории дом↔корп (отставание >20 или разные репо)'
      fi
    fi
  else
    _ctx_reason no_base warn 'в снимке нет базовой ветки — сравнение недоступно'
  fi

  return 0
}
```

- [ ] **Step 5: Запустить тесты — убедиться, что проходят**

Run: `bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh 2>&1 | tail -5`
Expected: `FAIL=0`.

- [ ] **Step 6: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(ctx): ctx_compare — ядро вердикта дом↔корп (unknown-ветки, сравнение историй, SUP-2603)"
```

---

### Task 2: `ctx_compare` — warn/info-проверки поверх ядра

**Files:**
- Modify: `pbx` (хвост `ctx_compare` из Task 1)
- Test: `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: всё из Task 1; `ST_PUSH_COMMIT`, `ST_PUSH_SOURCE`, `ST_ARCHIVE_EXISTS`, `ST_STALE`, `PBX_CTX_STALE_SEC`.
- Produces: коды причин `snapshot_stale`, `snapshot_no_vpn`, `repo_dirty`, `repo_in_merge`, `push_stale`, `pack_stale`, `undelivered_branches` (info) — добавляются в `CTX_REASONS` тем же `_ctx_reason`.

- [ ] **Step 1: Написать падающие тесты**

```bash
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
```

Вызовы после Task 1-вызовов:

```bash
test_ctx_compare_snapshot_stale_and_no_vpn
test_ctx_compare_repo_dirty_and_merge
test_ctx_compare_push_and_pack_stale
test_ctx_compare_push_fresh_silent
test_ctx_compare_undelivered_info
test_ctx_compare_danger_beats_warn
```

- [ ] **Step 2: Запустить — падают**

Run: `bash _tests/test_pbx.sh 2>&1 | tail -5`
Expected: FAIL>0 (нет причин snapshot_stale и т.д.).

- [ ] **Step 3: Дописать проверки в хвост `ctx_compare`**

Вставить в `ctx_compare` ПЕРЕД финальным `return 0` (после блока сравнения историй):

```bash
  # --- свежесть снимка --------------------------------------------------------
  local now; now="$(date +%s)"
  if [[ "$CTX_SNAPSHOT_AT" != -1 ]] && (( now - CTX_SNAPSHOT_AT > PBX_CTX_STALE_SEC )); then
    _ctx_reason snapshot_stale warn \
      "снимок протух (>24 ч) — обнови на ноуте: pbx snapshot"
  fi
  if [[ -n "$CTX_FETCH_OK" && "$CTX_FETCH_OK" != true ]]; then
    _ctx_reason snapshot_no_vpn warn \
      'снимок делался без связи с gitlab (fetch_ok=false) — корп-данные могут отставать'
  fi

  # --- состояние REPO на ноуте -------------------------------------------------
  if [[ "$CTX_REPO_DIRTY" != -1 ]] && (( CTX_REPO_DIRTY > 0 )); then
    _ctx_reason repo_dirty warn "корп-репо на ноуте грязный ($CTX_REPO_DIRTY правок) — доставка встанет"
  fi
  if [[ "$CTX_IN_MERGE" == true ]]; then
    _ctx_reason repo_in_merge warn 'корп-репо в незавершённом merge — доставка встанет'
  fi

  # --- гигиена транспорта дома --------------------------------------------------
  if [[ -n "$ST_PUSH_COMMIT" && -n "$ST_PUSH_SOURCE" ]]; then
    local head_now
    head_now="$(git -C "$ST_SRC" rev-parse HEAD 2>/dev/null || true)"
    if [[ -n "$head_now" && "$ST_PUSH_SOURCE" != "$head_now" ]]; then
      _ctx_reason push_stale warn \
        'push-снапшот в зеркале отстаёт от SRC — сделай pbx push перед доставкой'
    fi
  fi
  if [[ "$ST_ARCHIVE_EXISTS" == true && "$ST_STALE" == true ]]; then
    _ctx_reason pack_stale warn 'архив протух — сделай pbx pack перед доставкой'
  fi

  # --- информация (вердикт не меняет) -------------------------------------------
  if [[ -n "$CTX_UNDELIVERED" ]]; then
    local u_cnt
    u_cnt="$(printf '%s' "$CTX_UNDELIVERED" | grep -c . || true)"
    _ctx_reason undelivered_branches info \
      "в корп есть недоставленное/невлитое: $u_cnt ветк(и) с ahead>0"
  fi
```

- [ ] **Step 4: Запустить — проходят**

Run: `bash _tests/test_pbx.sh 2>&1 | tail -5`
Expected: `FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(ctx): warn/info-проверки — свежесть снимка, REPO ноута, push/pack, недоставленное"
```

---

### Task 3: `cmd_ctx` + `ctx_render_project` + регистрация (main, help)

**Files:**
- Modify: `pbx` — `ctx_render_project` и `cmd_ctx` после `ctx_compare`; `main()` (~строка 2032, после `corp)`); `cmd_help` (обе ветки)
- Test: `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: `ctx_compare` (Task 1–2), `corp_read_state`, `status_collect`, `load_config`, `valid_project`, `list_projects`, `ui_section`, `pad`, `c_warn`, `c_blue`, `strip_cr`, `die`.
- Produces: команда `pbx ctx [проект] [--json]` (json — Task 4, пока флаг парсится и зовёт заглушку `ctx_json`, которую Task 4 наполнит — НЕТ: json-ветка добавляется в Task 4 целиком, здесь только plain). `ctx_render_project <проект>` — рендер по CTX_*/ST_*-глобалям.

- [ ] **Step 1: Написать падающие тесты**

```bash
test_cmd_ctx_renders_verdict() {
  _mk_ctx_fixture
  # зеркало со снимком: реюз snap-фикстуры вручную
  local mirror="$CE_BASE/mirror.git"; git init -q --bare "$mirror"
  ( PBX_REGISTRY_DIR_SAVE="$PBX_REGISTRY_DIR" )
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
```

Вызовы: после Task 2-вызовов добавить пять имён.

- [ ] **Step 2: Запустить — падают** (`Неизвестная команда: ctx`).

- [ ] **Step 3: Реализовать рендер и команду**

После `ctx_compare` в `pbx`:

```bash
# ctx_render_project <проект> — человекочитаемая секция вердикта (по CTX_*/ST_*).
ctx_render_project() {
  local p="$1"
  local mark
  case "$CTX_VERDICT" in
    ok)      mark='🟢' ;;
    warn)    mark='🟡' ;;
    danger)  mark='🔴' ;;
    *)       mark='⚪' ;;
  esac
  printf '%s %s — %s\n' "$mark" "$p" "$CTX_VERDICT"
  local code level msg
  while IFS=$'\t' read -r code level msg || [[ -n "$code" ]]; do
    [[ -n "$code" ]] || continue
    case "$level" in
      danger) c_red  "    ✗ $msg" ;;
      warn)   c_warn "    ! $msg" ;;
      *)      printf '    · %s\n' "$msg" ;;
    esac
  done <<< "$CTX_REASONS"
  local uname uahead
  if [[ -n "$CTX_UNDELIVERED" ]]; then
    while IFS=$'\t' read -r uname uahead || [[ -n "$uname" ]]; do
      [[ -n "$uname" ]] || continue
      printf '      %s ahead=%s\n' "$(pad "$uname" 34)" "$uahead"
    done <<< "$CTX_UNDELIVERED"
  fi
  return 0
}

# cmd_ctx [проект] [--json] — вердикт готовности к доставке (дом).
cmd_ctx() {
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
    ctx_json ${names[@]+"${names[@]}"}
    return 0
  fi

  ui_section "Вердикт дом↔корп" "🔵 Вердикт дом↔корп:"
  if (( ${#names[@]} == 0 )); then
    c_warn "  (проектов с MIRROR не найдено — задай MIRROR= в реестре)"
    return 0
  fi
  local pr d rc
  for pr in "${names[@]}"; do
    load_config "$pr"
    status_collect "$pr"
    d="$(mktemp -d -t pbx-ctx.XXXXXX)"
    rc=0
    if [[ -z "${MIRROR:-}" ]]; then
      rc=4
    else
      corp_read_state "$MIRROR" "$d" || rc=$?
    fi
    ctx_compare "$d" "$rc"
    ctx_render_project "$pr"
    rm -rf "$d"
  done
  return 0
}
```

ВНИМАНИЕ: `ctx_json` появится в Task 4 — чтобы Task 3 был самодостаточен, добавить ВРЕМЕННУЮ заглушку сразу после `ctx_render_project` (Task 4 её заменит):

```bash
# ctx_json — реализация в Task 4 (Э4); заглушка честно умирает.
ctx_json() { die "ctx --json ещё не реализован"; }
```

В `main()` после строки `corp)               cmd_corp "$@" ;;`:

```bash
    ctx)                cmd_ctx "$@" ;;
```

В `cmd_help` plain-ветку после строки `pbx corp …` добавить:

```
  pbx ctx     [проект] [--json]                 ДОМ: вердикт готовности к доставке (сравнение дом↔корп по снимку); --json — для ИИ
```

В TTY-ветку после строки `${C_CYAN}pbx corp${C_RESET} …`:

```
  ${C_CYAN}pbx ctx${C_RESET}     [проект] [--json]       ${C_DIM}дом: вердикт готовности к доставке (ok/warn/danger)${C_RESET}
```

- [ ] **Step 4: Запустить — проходят**

Run: `bash _tests/test_pbx.sh 2>&1 | tail -5`
Expected: `FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(ctx): pbx ctx — команда, plain/TTY-рендер вердикта, справка"
```

---

### Task 4: `ctx_json` — JSON-контракт для ИИ

**Files:**
- Modify: `pbx` — заменить заглушку `ctx_json`
- Test: `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: `ctx_compare`, `status_collect`, `corp_read_state`, `_json_str_v2`, CTX_*/ST_*-глобали.
- Produces: `ctx_json <проект>…` — JSON-массив на stdout. Схема (порядок ключей фиксирован): `{"name","verdict","behind_n","reasons":[{"code","level","msg"}],"home":{"branch","dirty","head","meta_commit","packed_at","push_commit","pushed_at"},"corp":{...}|null,"compared_at"}`. corp-объект: `{"snapshot_at","fetch_ok","base_branch","base_sha","base_date","repo_dirty","in_merge","undelivered":[{"name","ahead"}]}`; `corp:null` при rc≠0 (unknown-случаи no_mirror/no_snapshot/mirror_unreachable); `fetch_ok`/`in_merge` — false при пустом значении.

- [ ] **Step 1: Написать падающие тесты**

```bash
test_cmd_ctx_json_valid_and_fields() {
  _mk_ctx_fixture
  local mirror="$CE_BASE/mirror.git"; git init -q --bare "$mirror"
  local reg; reg="$(make_ws)"
  printf 'SRC=%s\nREPO=%s\nMIRROR=%s\n' "$CTX_SRC" "$CE_REPO" "$mirror" > "$reg/proj.conf"
  local ws; ws="$(make_ws)"
  ( PBX_REGISTRY_DIR="$reg" WORKSPACE="$ws" DIST_DIR="$ws/_dist" bash "$PBX" snapshot proj ) >/dev/null 2>&1
  local out rc=0
  out="$(PBX_REGISTRY_DIR="$reg" WORKSPACE="$ws" DIST_DIR="$ws/_dist" bash "$PBX" ctx proj --json 2>/dev/null)" || rc=$?
  assert_eq "ctx json: rc=0" "$rc" "0"
  if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "$out" | python3 -m json.tool >/dev/null 2>&1; then
      ok "ctx json: валидный JSON"
    else
      bad "ctx json: НЕ валидный JSON: $out"
    fi
  fi
  assert_has "ctx json: verdict danger"      "$out" '"verdict":"danger"'
  assert_has "ctx json: behind_n=1"          "$out" '"behind_n":1'
  assert_has "ctx json: причина в reasons"   "$out" '"code":"home_behind_corp"'
  assert_has "ctx json: home-блок"           "$out" '"home":{'
  assert_has "ctx json: corp-блок"           "$out" '"snapshot_at":'
  assert_has "ctx json: compared_at"         "$out" '"compared_at":'
  rm -rf "$CE_BASE" "$CTX_STATE" "$reg" "$ws"
}

test_cmd_ctx_json_unknown_corp_null() {
  _mk_ctx_fixture
  local reg; reg="$(make_ws)"
  # без MIRROR: в json-режиме не die, а unknown-запись с corp:null
  printf 'SRC=%s\n' "$CTX_SRC" > "$reg/proj.conf"
  local out rc=0
  out="$(PBX_REGISTRY_DIR="$reg" bash "$PBX" ctx proj --json 2>/dev/null)" || rc=$?
  assert_eq  "ctx json unknown: rc=0"          "$rc" "0"
  assert_has "ctx json unknown: verdict"       "$out" '"verdict":"unknown"'
  assert_has "ctx json unknown: corp:null"     "$out" '"corp":null'
  assert_has "ctx json unknown: код no_mirror" "$out" '"code":"no_mirror"'
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$out" | python3 -m json.tool >/dev/null 2>&1 \
      && ok "ctx json unknown: валиден" || bad "ctx json unknown: НЕ валиден: $out"
  fi
  rm -rf "$CE_BASE" "$CTX_STATE" "$reg"
}

test_cmd_ctx_json_nasty_subjects() {
  _mk_ctx_fixture
  ( cd "$CE_REPO" && git commit -qam "$(printf 'таб\tи "кавычки" 100%%')" --allow-empty \
    && git push -q origin dev ) >/dev/null 2>&1
  local mirror="$CE_BASE/mirror.git"; git init -q --bare "$mirror"
  local reg; reg="$(make_ws)"
  printf 'SRC=%s\nREPO=%s\nMIRROR=%s\n' "$CTX_SRC" "$CE_REPO" "$mirror" > "$reg/proj.conf"
  local ws; ws="$(make_ws)"
  ( PBX_REGISTRY_DIR="$reg" WORKSPACE="$ws" DIST_DIR="$ws/_dist" bash "$PBX" snapshot proj ) >/dev/null 2>&1
  local out
  out="$(PBX_REGISTRY_DIR="$reg" WORKSPACE="$ws" DIST_DIR="$ws/_dist" bash "$PBX" ctx proj --json 2>/dev/null)"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$out" | python3 -m json.tool >/dev/null 2>&1 \
      && ok "ctx json: гадкие сабжекты не ломают JSON" \
      || bad "ctx json: сломан гадкими сабжектами: $out"
  fi
  rm -rf "$CE_BASE" "$CTX_STATE" "$reg" "$ws"
}
```

Вызовы: три имени после Task 3-вызовов.

- [ ] **Step 2: Запустить — падают** (заглушка die).

- [ ] **Step 3: Заменить заглушку реализацией**

```bash
# ctx_json <проект>… — JSON-массив вердиктов (схема — спека Э4 §3.3;
# порядок ключей фиксирован — контракт для ИИ).
ctx_json() {
  local p first=1 d rc
  local now; now="$(date +%s)"
  printf '['
  for p in "$@"; do
    load_config "$p"
    status_collect "$p"
    d="$(mktemp -d -t pbx-ctx.XXXXXX)"
    rc=0
    if [[ -z "${MIRROR:-}" ]]; then
      rc=4
    else
      corp_read_state "$MIRROR" "$d" || rc=$?
    fi
    ctx_compare "$d" "$rc"
    if (( first )); then first=0; else printf ','; fi
    printf '\n  {"name":"%s","verdict":"%s","behind_n":%s,' \
      "$(_json_str_v2 "$p")" "$CTX_VERDICT" "$CTX_BEHIND_N"
    # reasons
    printf '"reasons":['
    local rfirst=1 code level msg
    if [[ -n "$CTX_REASONS" ]]; then
      while IFS=$'\t' read -r code level msg || [[ -n "$code" ]]; do
        [[ -n "$code" ]] || continue
        if (( rfirst )); then rfirst=0; else printf ','; fi
        printf '{"code":"%s","level":"%s","msg":"%s"}' \
          "$code" "$level" "$(_json_str_v2 "$msg")"
      done <<< "$CTX_REASONS"
    fi
    printf '],'
    # home
    local head_now=''
    [[ "$ST_GIT" == true ]] && head_now="$(git -C "$ST_SRC" rev-parse HEAD 2>/dev/null || true)"
    printf '"home":{"branch":"%s","dirty":%s,"head":"%s","meta_commit":"%s","packed_at":%s,"push_commit":"%s","pushed_at":%s},' \
      "$(_json_str_v2 "$ST_BRANCH")" "$ST_DIRTY" "$(_json_str_v2 "$head_now")" \
      "$(_json_str_v2 "$ST_META_COMMIT")" "$ST_META_PACKED_AT" \
      "$(_json_str_v2 "$ST_PUSH_COMMIT")" "$ST_PUSHED_AT"
    # corp (null при unknown-без-данных: rc≠0)
    if (( rc == 0 )); then
      local fok="$CTX_FETCH_OK"; [[ "$fok" == true ]] || fok=false
      local imrg="$CTX_IN_MERGE"; [[ "$imrg" == true ]] || imrg=false
      printf '"corp":{"snapshot_at":%s,"fetch_ok":%s,"base_branch":"%s","base_sha":"%s","base_date":%s,"repo_dirty":%s,"in_merge":%s,' \
        "$CTX_SNAPSHOT_AT" "$fok" "$(_json_str_v2 "$CTX_BASE_BRANCH")" \
        "$(_json_str_v2 "$CTX_BASE_SHA")" "$CTX_BASE_DATE" "$CTX_REPO_DIRTY" "$imrg"
      printf '"undelivered":['
      local ufirst=1 uname uahead
      if [[ -n "$CTX_UNDELIVERED" ]]; then
        while IFS=$'\t' read -r uname uahead || [[ -n "$uname" ]]; do
          [[ -n "$uname" ]] || continue
          if (( ufirst )); then ufirst=0; else printf ','; fi
          printf '{"name":"%s","ahead":%s}' "$(_json_str_v2 "$uname")" "$uahead"
        done <<< "$CTX_UNDELIVERED"
      fi
      printf ']},'
    else
      printf '"corp":null,'
    fi
    printf '"compared_at":%s}' "$now"
    rm -rf "$d"
  done
  printf '\n]\n'
  return 0
}
```

Удалить строку-заглушку `ctx_json() { die "ctx --json ещё не реализован"; }` из Task 3.

- [ ] **Step 4: Запустить — проходят**

Run: `bash _tests/test_pbx.sh 2>&1 | tail -5`
Expected: `FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(ctx): --json — контракт вердикта для ИИ (reasons, home, corp, behind_n)"
```

---

### Task 5: `pbx self-update` — команда целиком

**Files:**
- Modify: `pbx` — блок self-update после `cmd_scan` (перед `# ---- help`); `main()` — кейс `self-update`; `cmd_help` — строка в обе ветки
- Test: `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: `meta_update`, `strip_cr`, `die`, `c_green`, `ui_section`, `ui_kv`, паттерн `GIT_TERMINAL_PROMPT=0 timeout 30`.
- Produces: `SELF_CONF`/`SELF_REV_FILE` (глобали-пути), `self_mirror_url` (stdout URL или пусто), `self_branch_name` (stdout, дефолт `main`), `cmd_self_update [--check]`. `self.rev` — ключи `SELF_SHA`, `UPDATED_AT` (meta_update-формат). Env-override: `PBX_SELF_MIRROR`, `PBX_SELF_BRANCH`.

- [ ] **Step 1: Написать падающие тесты**

```bash
# --- Э4: pbx self-update -------------------------------------------------------
# Фикстура: bare-«зеркало pbx» с файлом pbx на ветке main + «установленная»
# копия скрипта вне git. Глобали: SU_BASE, SU_MIRROR, SU_INSTALLED, SU_CONFDIR
_mk_selfupdate_fixture() {
  SU_BASE="$(mktemp -d)"
  SU_MIRROR="$SU_BASE/pbx-mirror.git"
  git init -q --bare "$SU_MIRROR"
  local work="$SU_BASE/work"
  git init -q -b main "$work"
  ( cd "$work" && git config user.email t@t && git config user.name t \
    && cp "$PBX" pbx && git add -A && git commit -qm 'pbx v1' \
    && git push -q "$SU_MIRROR" main ) >/dev/null 2>&1
  SU_INSTALLED="$SU_BASE/bin/pbx"
  mkdir -p "$SU_BASE/bin"
  cp "$PBX" "$SU_INSTALLED"; chmod +x "$SU_INSTALLED"
  SU_CONFDIR="$SU_BASE/conf"
  mkdir -p "$SU_CONFDIR"
  printf 'SELF_MIRROR=%s\n' "$SU_MIRROR" > "$SU_CONFDIR/self.conf"
}

# запуск установленной копии с подменёнными путями конфига
_run_su() { XDG_CONFIG_HOME="$SU_CONFDIR/xdg" PBX_SELF_MIRROR='' bash "$SU_INSTALLED" "$@"; }

test_selfupdate_no_mirror_dies() {
  _mk_selfupdate_fixture
  local out rc=0
  out="$(XDG_CONFIG_HOME="$SU_BASE/empty-xdg" bash "$SU_INSTALLED" self-update 2>&1)" || rc=$?
  assert_eq  "self-update: без SELF_MIRROR → die" "$rc" "1"
  assert_has "self-update: подсказка про self.conf" "$out" "SELF_MIRROR"
  rm -rf "$SU_BASE"
}

test_selfupdate_first_install_and_rev() {
  _mk_selfupdate_fixture
  mkdir -p "$SU_CONFDIR/xdg/pbx"
  cp "$SU_CONFDIR/self.conf" "$SU_CONFDIR/xdg/pbx/self.conf"
  local out rc=0
  out="$(_run_su self-update 2>&1)" || rc=$?
  assert_eq  "self-update: rc=0" "$rc" "0"
  assert_has "self-update: сообщение об обновлении" "$out" "pbx"
  local want; want="$(git -C "$SU_MIRROR" rev-parse main)"
  assert_eq "self-update: SELF_SHA записан" \
    "$(sed -n 's/^SELF_SHA=//p' "$SU_CONFDIR/xdg/pbx/self.rev")" "$want"
  if [[ -f "$SU_INSTALLED.bak" ]]; then ok "self-update: бэкап создан"; else bad "self-update: нет бэкапа"; fi
  if [[ -x "$SU_INSTALLED" ]]; then ok "self-update: файл исполняемый"; else bad "self-update: потерян +x"; fi
  bash -n "$SU_INSTALLED" && ok "self-update: установленный валиден (bash -n)" || bad "self-update: битый скрипт"
  rm -rf "$SU_BASE"
}

test_selfupdate_idempotent() {
  _mk_selfupdate_fixture
  mkdir -p "$SU_CONFDIR/xdg/pbx"
  cp "$SU_CONFDIR/self.conf" "$SU_CONFDIR/xdg/pbx/self.conf"
  ( _run_su self-update ) >/dev/null 2>&1
  local out rc=0
  out="$(_run_su self-update 2>&1)" || rc=$?
  assert_eq  "self-update: повтор rc=0"    "$rc" "0"
  assert_has "self-update: «уже свежий»"   "$out" "свеж"
  rm -rf "$SU_BASE"
}

test_selfupdate_check_changes_nothing() {
  _mk_selfupdate_fixture
  mkdir -p "$SU_CONFDIR/xdg/pbx"
  cp "$SU_CONFDIR/self.conf" "$SU_CONFDIR/xdg/pbx/self.conf"
  local before; before="$(sha1sum "$SU_INSTALLED" | cut -d' ' -f1)"
  local out rc=0
  out="$(_run_su self-update --check 2>&1)" || rc=$?
  assert_eq "self-update --check: rc=0" "$rc" "0"
  assert_eq "self-update --check: файл не тронут" \
    "$(sha1sum "$SU_INSTALLED" | cut -d' ' -f1)" "$before"
  if [[ -f "$SU_CONFDIR/xdg/pbx/self.rev" ]]; then
    bad "self-update --check: self.rev не должен появляться"
  else
    ok "self-update --check: self.rev не создан"
  fi
  rm -rf "$SU_BASE"
}

test_selfupdate_broken_candidate_untouched() {
  _mk_selfupdate_fixture
  # кладём в зеркало битый скрипт
  local work="$SU_BASE/work"
  ( cd "$work" && printf 'if then fi(\n' > pbx && git commit -qam 'broken' \
    && git push -q "$SU_MIRROR" main ) >/dev/null 2>&1
  mkdir -p "$SU_CONFDIR/xdg/pbx"
  cp "$SU_CONFDIR/self.conf" "$SU_CONFDIR/xdg/pbx/self.conf"
  local before; before="$(sha1sum "$SU_INSTALLED" | cut -d' ' -f1)"
  local out rc=0
  out="$(_run_su self-update 2>&1)" || rc=$?
  assert_eq "self-update: битый кандидат → die" "$rc" "1"
  assert_eq "self-update: установленный не тронут" \
    "$(sha1sum "$SU_INSTALLED" | cut -d' ' -f1)" "$before"
  rm -rf "$SU_BASE"
}

test_selfupdate_git_workspace_refuses() {
  _mk_selfupdate_fixture
  local wt="$SU_BASE/worktree"
  git init -q "$wt"
  cp "$PBX" "$wt/pbx"; chmod +x "$wt/pbx"
  mkdir -p "$SU_CONFDIR/xdg/pbx"
  cp "$SU_CONFDIR/self.conf" "$SU_CONFDIR/xdg/pbx/self.conf"
  local out rc=0
  out="$(XDG_CONFIG_HOME="$SU_CONFDIR/xdg" bash "$wt/pbx" self-update 2>&1)" || rc=$?
  assert_eq  "self-update: git-workspace → die"  "$rc" "1"
  assert_has "self-update: подсказка git pull"   "$out" "git pull"
  rm -rf "$SU_BASE"
}

test_selfupdate_in_help() {
  local out
  out="$(bash "$PBX" help 2>/dev/null)"
  assert_has "help: self-update упомянут" "$out" "self-update"
}
```

Вызовы: семь имён после Task 4-вызовов.

- [ ] **Step 2: Запустить — падают** (`Неизвестная команда: self-update`).

- [ ] **Step 3: Реализовать self-update в `pbx`**

Вставить после `cmd_scan()` (перед `# ---- help`):

```bash
# =============================================================================
#  self-update (Э4): обновление pbx из личного GitHub-зеркала инструмента.
#  Источник: SELF_MIRROR в $SELF_CONF (env PBX_SELF_MIRROR побеждает).
#  Версия установленного: SELF_SHA в $SELF_REV_FILE (meta_update-формат).
# =============================================================================
SELF_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/pbx/self.conf"
SELF_REV_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/pbx/self.rev"

# URL зеркала pbx: env → self.conf; пусто, если не настроен.
self_mirror_url() {
  if [[ -n "${PBX_SELF_MIRROR:-}" ]]; then
    strip_cr "$PBX_SELF_MIRROR"; return 0
  fi
  [[ -f "$SELF_CONF" ]] || return 0
  strip_cr "$(sed -n 's/^SELF_MIRROR=//p' "$SELF_CONF" | head -1)"
  return 0
}

# Ветка зеркала pbx: env → self.conf → main.
self_branch_name() {
  if [[ -n "${PBX_SELF_BRANCH:-}" ]]; then
    strip_cr "$PBX_SELF_BRANCH"; return 0
  fi
  local b=''
  [[ -f "$SELF_CONF" ]] && b="$(sed -n 's/^SELF_BRANCH=//p' "$SELF_CONF" | head -1)"
  strip_cr "${b:-main}"
  return 0
}

cmd_self_update() {
  local check=0 a
  for a in "$@"; do
    a="$(strip_cr "$a")"
    case "$a" in
      --check) check=1 ;;
      *) die "Неизвестный аргумент: $a (ожидается --check)" ;;
    esac
  done

  local mirror branch
  mirror="$(self_mirror_url)"
  branch="$(self_branch_name)"
  [[ -n "$mirror" ]] || die "Не задан SELF_MIRROR. Создай $SELF_CONF со строкой SELF_MIRROR=https://github.com/<user>/pbx.git (или env PBX_SELF_MIRROR)"

  # установленный скрипт (резолв симлинка /usr/local/bin/pbx)
  local self real
  self="${BASH_SOURCE[0]}"
  real="$(readlink -f "$self" 2>/dev/null || echo "$self")"
  # fail-closed: скрипт в git-worktree (дом, рабочая копия) не трогаем
  if [[ "$(git -C "$(dirname "$real")" rev-parse --is-inside-work-tree 2>/dev/null)" == true ]]; then
    die "Это рабочая копия в git ($real) — обновляйся здесь через git pull, не self-update"
  fi

  ui_section "Self-update" "🔵 pbx self-update"
  ui_kv MIRROR "$mirror"
  ui_kv BRANCH "$branch"

  local tmp; tmp="$(mktemp -d -t pbx-selfupd.XXXXXX)" || die "mktemp не удался"
  if ! git init -q "$tmp" 2>/dev/null \
     || ! GIT_TERMINAL_PROMPT=0 timeout 30 git -C "$tmp" fetch -q --depth 1 "$mirror" "$branch" 2>/dev/null; then
    rm -rf "$tmp"
    die "Зеркало pbx недоступно: $mirror ($branch) — VPN/PAT/URL?"
  fi
  local sha
  sha="$(git -C "$tmp" rev-parse FETCH_HEAD 2>/dev/null || true)"
  _pbx_is_sha "$sha" || { rm -rf "$tmp"; die "Не удалось получить SHA из зеркала"; }

  local cur=''
  [[ -f "$SELF_REV_FILE" ]] && cur="$(strip_cr "$(sed -n 's/^SELF_SHA=//p' "$SELF_REV_FILE" | head -1)")"

  if (( check )); then
    c_blue "🔵 установлено: ${cur:-неизвестно}; в зеркале: $sha"
    if [[ "$sha" == "$cur" ]]; then
      c_green "✅ pbx свежий"
    else
      c_warn "⚠️  доступно обновление: pbx self-update"
    fi
    rm -rf "$tmp"
    return 0
  fi

  if [[ "$sha" == "$cur" ]]; then
    c_green "✅ pbx уже свежий (${sha:0:7})"
    rm -rf "$tmp"
    return 0
  fi

  # кандидат: файл pbx из дерева FETCH_HEAD + валидация (fail-closed)
  if ! git -C "$tmp" cat-file blob "FETCH_HEAD:pbx" > "$tmp/pbx.new" 2>/dev/null; then
    rm -rf "$tmp"; die "В зеркале нет файла pbx (ветка $branch)"
  fi
  if ! bash -n "$tmp/pbx.new" 2>/dev/null; then
    rm -rf "$tmp"; die "Кандидат не проходит bash -n — обновление отменено, скрипт не тронут"
  fi
  if ! grep -q '^main() {' "$tmp/pbx.new"; then
    rm -rf "$tmp"; die "Кандидат не похож на pbx (нет диспетчера main) — отменено"
  fi

  cp -- "$real" "$real.bak" 2>/dev/null || { rm -rf "$tmp"; die "Не удалось сделать бэкап $real.bak"; }
  # атомарная замена: staged-файл РЯДОМ (та же ФС) + mv (inode swap —
  # безопасно для исполняющегося bash-скрипта)
  local staged="$real.new.$$"
  if ! { cp -- "$tmp/pbx.new" "$staged" && chmod +x "$staged" && mv -f -- "$staged" "$real"; } 2>/dev/null; then
    rm -f -- "$staged" 2>/dev/null
    rm -rf "$tmp"
    die "Замена $real не удалась (бэкап цел: $real.bak)"
  fi
  rm -rf "$tmp"
  mkdir -p "$(dirname "$SELF_REV_FILE")" 2>/dev/null || true
  meta_update "$SELF_REV_FILE" "SELF_SHA=$sha" "UPDATED_AT=$(date +%s)"
  if [[ -n "$cur" ]]; then
    c_green "✅ pbx обновлён: ${cur:0:7} → ${sha:0:7} (бэкап: $real.bak)"
  else
    c_green "✅ pbx установлен: ${sha:0:7} (бэкап: $real.bak)"
  fi
  return 0
}
```

ГРАБЛЯ для исполнителя: `SELF_CONF`/`SELF_REV_FILE` объявлены top-level — при `source` в тестах они вычисляются от текущего `XDG_CONFIG_HOME`; тесты запускают `bash "$SU_INSTALLED" …` с подменённым `XDG_CONFIG_HOME` — этого достаточно, глобали пересчитаются в новом процессе.

В `main()` после кейса `ctx)`:

```bash
    self-update|selfupdate) cmd_self_update "$@" ;;
```

В `cmd_help` plain-ветку после строки `pbx scan …`:

```
  pbx self-update [--check]                     обновить pbx из зеркала инструмента (SELF_MIRROR в ~/.config/pbx/self.conf); --check — только проверить
```

В TTY-ветку после `${C_CYAN}pbx scan${C_RESET} …`:

```
  ${C_CYAN}pbx self-update${C_RESET} [--check]          ${C_DIM}обновить pbx из зеркала (ноут); --check — только проверить${C_RESET}
```

- [ ] **Step 4: Запустить — проходят**

Run: `bash _tests/test_pbx.sh 2>&1 | tail -5`
Expected: `FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(self-update): pbx self-update — shallow-fetch зеркала, валидация, атомарная замена, self.rev"
```

---

### Task 6: тихая проверка при snapshot + diag-строка + пункты меню

**Files:**
- Modify: `pbx` — `self_update_hint` (после `cmd_self_update`), два вызова в `cmd_snapshot`, строка в `collect_diag`, пункты в `cmd_menu`
- Test: `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: `self_mirror_url`, `self_branch_name`, `SELF_REV_FILE`, `ui_dim` (TTY-only по построению), `cmd_snapshot`, `collect_diag`, `cmd_menu`/`menu_select`.
- Produces: `self_update_hint` — best-effort, всегда rc=0, вывод только TTY. Меню: пункт `ctx` (индекс 5, после corp) и `self-update` (индекс 11, перед help); индексы последующих пунктов сдвигаются, существующие меню-тесты обновляются.

- [ ] **Step 1: Написать падающие тесты**

```bash
test_selfupdate_hint_in_snapshot() {
  _mk_snap_fixture
  local ws; ws="$(make_ws)"; WORKSPACE="$ws"
  # «зеркало pbx» с более свежим SHA, чем в self.rev
  local sm="$CE_BASE/selfmirror.git"
  git init -q --bare "$sm"
  local w="$CE_BASE/sw"
  ( git init -q -b main "$w" && cd "$w" && git config user.email t@t \
    && git config user.name t && cp "$PBX" pbx && git add -A \
    && git commit -qm v2 && git push -q "$sm" main ) >/dev/null 2>&1
  local xdg="$CE_BASE/xdg"; mkdir -p "$xdg/pbx"
  printf 'SELF_MIRROR=%s\n' "$sm" > "$xdg/pbx/self.conf"
  printf 'SELF_SHA=%s\n' "0000000000000000000000000000000000000000" > "$xdg/pbx/self.rev"
  # плейн-режим: подсказки быть НЕ должно (TTY-only), snapshot работает как раньше
  local out rc=0
  out="$(XDG_CONFIG_HOME="$xdg" PBX_REGISTRY_DIR="$SN_REG" WORKSPACE="$ws" bash "$PBX" snapshot proj 2>&1)" || rc=$?
  assert_eq "hint: snapshot rc=0"                    "$rc" "0"
  assert_no "hint: plain-вывод без подсказки (TTY-only)" "$out" "self-update"
  # сам хелпер: под форсированным UI_COLOR_OUT печатает подсказку
  local hint
  hint="$(XDG_CONFIG_HOME="$xdg" bash -c 'source "'"$PBX"'"; UI_COLOR_OUT=1; self_update_hint' 2>/dev/null)"
  assert_has "hint: при расхождении SHA есть подсказка" "$hint" "self-update"
  # совпадение SHA → подсказки нет
  printf 'SELF_SHA=%s\n' "$(git -C "$sm" rev-parse main)" > "$xdg/pbx/self.rev"
  hint="$(XDG_CONFIG_HOME="$xdg" bash -c 'source "'"$PBX"'"; UI_COLOR_OUT=1; self_update_hint' 2>/dev/null)"
  assert_no "hint: SHA совпал — подсказки нет" "$hint" "self-update"
  # сбой ls-remote (битый URL) → молча rc=0
  printf 'SELF_MIRROR=%s\n' "$CE_BASE/nope.git" > "$xdg/pbx/self.conf"
  local hrc=0
  hint="$(XDG_CONFIG_HOME="$xdg" bash -c 'source "'"$PBX"'"; UI_COLOR_OUT=1; self_update_hint' 2>/dev/null)" || hrc=$?
  assert_eq "hint: сбой сети — rc=0"     "$hrc" "0"
  assert_no "hint: сбой сети — молчит"   "$hint" "self-update"
  rm -rf "$CE_BASE" "$SN_REG" "$ws"
}

test_diag_selfrev_line() {
  _mk_selfupdate_fixture
  local xdg="$SU_BASE/xdg"; mkdir -p "$xdg/pbx"
  printf 'SELF_SHA=%s\nUPDATED_AT=1751500000\n' "abc1234abc1234abc1234abc1234abc1234abc12" > "$xdg/pbx/self.rev"
  local out
  out="$(XDG_CONFIG_HOME="$xdg" bash -c 'source "'"$PBX"'"; collect_diag' 2>/dev/null)"
  assert_has "diag: строка self.rev" "$out" "self.rev"
  # без self.rev строка отсутствует (plain-инвариант прежних машин)
  out="$(XDG_CONFIG_HOME="$SU_BASE/empty" bash -c 'source "'"$PBX"'"; collect_diag' 2>/dev/null)"
  assert_no "diag: без self.rev строки нет" "$out" "self.rev"
  rm -rf "$SU_BASE"
}

test_menu_has_ctx_and_selfupdate() {
  # меню: пункт 5 — ctx (после corp), пункт 11 — self-update; выход — последний
  local out
  out="$(printf '14\n' | bash -c 'source "'"$PBX"'"; UI_TTY=1 TERM=xterm cmd_menu' 2>&1 || true)"
  assert_has "меню: пункт ctx"         "$out" "ctx"
  assert_has "меню: пункт self-update" "$out" "self-update"
}
```

Вызовы: три имени после Task 5-вызовов.

ГРАБЛЯ: существующие тесты меню (`test_menu_snapshot_runs_and_exits`, `test_menu_corp_returns_to_menu`, `test_menu_exit_item` и др.) выбирают пункты по НОМЕРУ — после вставки двух пунктов номера сдвигаются. Найти их: `grep -n "menu" _tests/test_pbx.sh`, обновить подаваемые номера: пункты ПОСЛЕ corp (лог, status, list, scan, add, help, выход) сдвигаются на +1 после вставки ctx и ещё +1 после self-update для help/выход.

- [ ] **Step 2: Запустить — падают.**

- [ ] **Step 3: Реализовать**

`self_update_hint` после `cmd_self_update`:

```bash
# Тихая проверка свежести pbx (конец успешного snapshot — сеть там есть).
# Best-effort: любой сбой молчит; вывод только TTY (ui_dim); rc всегда 0.
self_update_hint() {
  (( UI_COLOR_OUT )) || return 0
  local mirror branch cur ls_out sha
  mirror="$(self_mirror_url)"
  [[ -n "$mirror" ]] || return 0
  [[ -f "$SELF_REV_FILE" ]] || return 0
  cur="$(strip_cr "$(sed -n 's/^SELF_SHA=//p' "$SELF_REV_FILE" | head -1)")"
  [[ -n "$cur" ]] || return 0
  branch="$(self_branch_name)"
  ls_out="$(GIT_TERMINAL_PROMPT=0 timeout 30 git ls-remote "$mirror" "refs/heads/$branch" 2>/dev/null)" || return 0
  sha="${ls_out%%$'\t'*}"
  if [[ -n "$sha" && "$sha" != "$cur" ]]; then
    ui_dim "доступно обновление pbx: pbx self-update"
  fi
  return 0
}
```

В `cmd_snapshot`: (1) в ветке одиночного проекта — перед `return 0` после `c_green "✅ $project: …"` добавить строку `self_update_hint`; (2) в ветке «все проекты» — после строки `c_blue "🔵 Итог: …"` добавить `self_update_hint`.

В `collect_diag` после блока `printf '[pbx]     script=%s commit=%s\n' …` добавить:

```bash
    if [[ -f "$SELF_REV_FILE" ]]; then
      printf '[pbx]     self.rev=%s updated=%s\n' \
        "$(sed -n 's/^SELF_SHA=//p' "$SELF_REV_FILE" | head -1)" \
        "$(date -d "@$(sed -n 's/^UPDATED_AT=//p' "$SELF_REV_FILE" | head -1)" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '—')"
    fi
```

В `cmd_menu` массив `items` — вставить после `'corp    — корп-состояние проектов (дом)'`:

```bash
    'ctx     — вердикт дом↔корп: готовность к доставке (дом)'
```

и после `'add     — добавить проект (подсказка)'`:

```bash
    'self-update — обновить pbx из зеркала (ноут)'
```

`case "$idx"` перенумеровать: `5) cmd_ctx || true; menu_pause ;;`, лог→6, status→7, list→8, scan→9, add→10, `11) cmd_self_update || true; menu_pause ;;`, help→12, выход→13. Обновить сломанные номерами существующие меню-тесты.

- [ ] **Step 4: Запустить ВЕСЬ набор — проходит, включая старые меню-тесты**

Run: `bash _tests/test_pbx.sh 2>&1 | tail -5`
Expected: `FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add pbx _tests/test_pbx.sh
git commit -m "feat(Э4): тихая проверка self-update при snapshot, self.rev в diag, пункты меню ctx/self-update"
```

---

### Task 7: финальная верификация, README, слияние

**Files:**
- Modify: `README.md` — ctx и self-update в список команд + короткая секция
- Test: полный прогон `_tests/test_pbx.sh`

**Interfaces:**
- Consumes: всё выше.
- Produces: ветка готова к merge в `main`.

- [ ] **Step 1: Полный регресс**

Run: `bash /mnt/c/Users/darkl/Claude/Projects/Pybotx/_tests/test_pbx.sh 2>&1 | tail -3`
Expected: `--- Итог: PASS=<N> FAIL=0 ---` (N ≥ 102 старых + ~30 новых).

- [ ] **Step 2: Ручная проверка команд (санити)**

```bash
bash pbx help | grep -E "ctx|self-update"        # обе строки есть
bash pbx ctx --json 2>/dev/null | head -3         # валидный JSON-массив (реальный реестр)
bash pbx self-update --check 2>&1 | head -3       # die про SELF_MIRROR ЛИБО статус — по машине
```

Expected: без креша; вывод осмысленный.

- [ ] **Step 3: README**

В списке команд README.md добавить две строки (стиль существующих):

```markdown
| `pbx ctx [проект] [--json]` | дом: вердикт готовности к доставке — автосравнение дом↔корп по снимку (`ok/warn/danger/unknown`, страховка SUP-2603 на этапе планирования) |
| `pbx self-update [--check]` | ноут: обновить pbx из личного зеркала инструмента (`SELF_MIRROR=` в `~/.config/pbx/self.conf`); `--check` — только проверить |
```

(Если README использует не таблицу, а список — повторить стиль соседних строк.)

- [ ] **Step 4: Commit + merge**

```bash
git add README.md
git commit -m "docs: README — команды ctx и self-update (Э4)"
git checkout main && git merge --no-ff feature/pbx-ctx-selfupdate -m "Merge: Э4 — pbx ctx (вердикт дом↔корп) + pbx self-update"
git push origin main
```

---

## Self-Review (выполнен при написании плана)

- Покрытие спеки: §3 ctx (Tasks 1–4), §3.3 JSON (Task 4), §4 self-update (Task 5), §4 тихая проверка + diag (Task 6), §5 инварианты (тесты plain-инвариантов в Tasks 3/6 + регресс Task 7), §6 деградации (unknown-тесты Task 1, сбои сети Task 5/6), §8 тестирование — все 5 пунктов спеки замаплены.
- Уточнения спеки, принятые в плане: код причины `no_base` (деградация «нет origin/dev в снимке» из Э3); в `--json` для явно спрошенного проекта без MIRROR — unknown-запись вместо die (консистентно с corp_json); пункты меню (прецедент Э3).
- Типы/имена сквозные: `ctx_compare <dir> <rc>` (rc 0/2/3/4), CTX_*-глобали, `_ctx_reason <code> <level> <msg>`, `self_mirror_url`/`self_branch_name` — использованы одинаково в Tasks 1–6.
