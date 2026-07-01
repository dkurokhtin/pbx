#!/usr/bin/env bash
set -euo pipefail
# ===== Настройки =====
BASE_BRANCH="dev"        # от какой ветки ответвляемся
TARGET_BRANCH="master"   # куда нацелен MR
PROJECTS_ROOT="/root"    # где лежат проекты
# =====================
# Использование:
#   ./update.sh <проект> <архив> <ветка> <сообщение-коммита>
# По конвенции (team-conventions):
#   ветка  — feature/PROJ-123-short-description
#   коммит — кратко и по делу, напр. "Добавить server-default для admin_roles"
PROJECT="${1:?Использование: ./update.sh <проект> <архив> <ветка feature/PROJ-123-...> <сообщение>}"
ARCHIVE="${2:?Укажи путь к архиву (2-й аргумент)}"
BRANCH="${3:-}"
COMMIT_MSG="${4:-}"

# Защита от CRLF/копипаста: убрать возвраты каретки из аргументов
PROJECT="${PROJECT//$'\r'/}"
ARCHIVE="${ARCHIVE//$'\r'/}"
BRANCH="${BRANCH//$'\r'/}"
COMMIT_MSG="${COMMIT_MSG//$'\r'/}"

# Ветка — по конвенции feature/PROJ-123-short-description
if [[ -z "$BRANCH" ]]; then
  BRANCH="update/$(date +%Y%m%d-%H%M%S)"
  echo "⚠️  Ветка не задана (3-й аргумент) — использую '$BRANCH'."
  echo "    По конвенции укажи ветку вида feature/PROJ-123-short-description."
elif [[ ! "$BRANCH" =~ ^(feature|fix|hotfix|bugfix|chore)/ ]]; then
  echo "⚠️  Ветка '$BRANCH' не похожа на конвенцию feature/PROJ-123-... — продолжаю как есть."
fi

# Сообщение коммита — кратко и по делу
if [[ -z "$COMMIT_MSG" ]]; then
  COMMIT_MSG="Update $PROJECT from archive $(basename "$ARCHIVE")"
  echo "⚠️  Сообщение коммита не задано (4-й аргумент) — использую '$COMMIT_MSG'."
fi

BRANCH="${BRANCH//$'\r'/}"
REPO_DIR="$PROJECTS_ROOT/$PROJECT"
[[ -d "$REPO_DIR/.git" ]] || { echo "Не git-репозиторий: $REPO_DIR"; exit 1; }
# Windows-путь → WSL
if command -v wslpath >/dev/null 2>&1 && [[ "$ARCHIVE" == *:\\* || "$ARCHIVE" == *:/* ]]; then
  ARCHIVE="$(wslpath -u "$ARCHIVE")"
fi
[[ -f "$ARCHIVE" ]] || { echo "Архив не найден: $ARCHIVE"; exit 1; }
cd "$REPO_DIR"
# Свежий dev
git checkout "$BASE_BRANCH"
git pull origin "$BASE_BRANCH"
# Распаковка во временную папку
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
case "$ARCHIVE" in
  *.zip)          unzip -q "$ARCHIVE" -d "$TMP" ;;
  *.tar.gz|*.tgz) tar -xzf "$ARCHIVE" -C "$TMP" ;;
  *.tar)          tar -xf "$ARCHIVE" -C "$TMP" ;;
  *) echo "Неизвестный формат: $ARCHIVE"; exit 1 ;;
esac
# Если внутри один корневой каталог — заходим в него
INNER="$TMP"
if [[ $(find "$TMP" -mindepth 1 -maxdepth 1 | wc -l) -eq 1 \
   && $(find "$TMP" -mindepth 1 -maxdepth 1 -type d | wc -l) -eq 1 ]]; then
  INNER="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d)"
fi
# Полная синхронизация
rsync -a --delete \
  --exclude='.git/' \
  --exclude='.gitlab-ci.yml' \
  "$INNER"/ "$REPO_DIR"/
# Ветка от dev, коммит, пуш с MR в master
git checkout -b "$BRANCH"
git add -A
if git diff --cached --quiet; then
  echo "Изменений нет — выходим."
  git checkout "$BASE_BRANCH"
  git branch -d "$BRANCH"
  exit 0
fi
git commit -m "$COMMIT_MSG"
git push -o merge_request.create \
        -o merge_request.target="$TARGET_BRANCH" \
        -o merge_request.title="$COMMIT_MSG" \
        origin "$BRANCH"
echo ""
echo "✅ $PROJECT: ветка '$BRANCH' от '$BASE_BRANCH', MR в '$TARGET_BRANCH' (заголовок: $COMMIT_MSG)."
