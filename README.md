# pbx — CLI доставки проектов

Единый bash-инструмент: упаковать проект, доставить архив в git-репозиторий и
создать MR/PR. Один и тот же `pbx` работает на обеих машинах: разработка и `pack`
на рабочей машине, `deliver` — там, где лежит git-репозиторий и есть доступ к
git-хосту. Копирование архива между машинами — вручную (scp/общая папка).

## Команды

    pbx add     <имя> [путь]                       завести проект в реестр (SRC=путь|$PWD)
    pbx scan    (--repo|--src) [каталог] [--dry-run]  заполнить реестр из найденных репо
    pbx list                                        показать проекты (реестр ∪ WORKSPACE)
    pbx pack    <имя>                               упаковать SRC в _dist/<имя>.tar.gz
    pbx deliver <имя> <ветка> <сообщение> [архив] [--yes]  распаковать в REPO, ветка, коммит, MR/PR
    pbx help

## Реестр проектов

Проекты описываются в `$PBX_REGISTRY_DIR` (дефолт `~/.config/pbx/projects/`),
один файл `<имя>.conf` на проект — свой на каждой машине:

    SRC=/home/me/sup          # что паковать на ЭТОЙ машине (корень репо)
    REPO=/root/sup            # куда доставлять (иначе $PROJECTS_ROOT/<имя>)
    TARGET_BRANCH=dev         # + BASE_BRANCH / FORGE / EXTRA_*

Если проекта нет в реестре — fallback: `SRC=$WORKSPACE/<имя>`, `REPO=$PROJECTS_ROOT/<имя>`.

## Слои настроек (побеждает верхний)

    встроенные дефолты → $WORKSPACE/.pbx.conf → реестр <имя>.conf → <SRC>/.pbx.conf → env PBX_*

## Переменные окружения

    PBX_WORKSPACE  PBX_PROJECTS_ROOT  PBX_DIST_DIR  PBX_REGISTRY_DIR
    PBX_BASE_BRANCH  PBX_TARGET_BRANCH  PBX_FORGE  PBX_IGNORE_DIRS

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
