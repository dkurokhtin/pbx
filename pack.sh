#!/usr/bin/env bash
# Упаковать рабочую папку проекта в архив для доставки через update.sh.
# Использование: ./pack.sh <проект>
# Пример:       ./pack.sh bot-support-cleaning
set -euo pipefail
PROJECT="${1:?Использование: ./pack.sh <проект>   (bot-support-cleaning | smartapp-parking)}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
[[ -d "$ROOT/$PROJECT" ]] || { echo "Нет папки проекта: $ROOT/$PROJECT"; exit 1; }
mkdir -p "$ROOT/_dist"
OUT="$ROOT/_dist/$PROJECT.tar.gz"
tar -C "$ROOT" \
    --exclude="$PROJECT/.git" \
    --exclude="$PROJECT/.venv" \
    --exclude="$PROJECT/node_modules" \
    --exclude="$PROJECT/front/node_modules" \
    --exclude="$PROJECT/.claude" \
    --exclude='*/__pycache__' \
    --exclude='*.pyc' \
    -czf "$OUT" "$PROJECT"
echo "✅ Архив готов: $OUT"
echo "   Доставка: ./update.sh $PROJECT $OUT"
