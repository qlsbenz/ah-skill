# ah-skills

Проектный harness для Codex: навыки, правила, инструкции ролей и тестовый хук. Репозиторий разделён на домены; CLI устанавливает выбранные ресурсы в другой проект.

## Оглавление

- [Домены](#домены)
- [Структура репозитория](#структура-репозитория)
- [Установка (CLI `ah-skills`)](#установка-cli-ah-skills)
- [Разработка самого harness](#разработка-самого-harness)
- [Контрибьютинг и безопасность](#контрибьютинг-и-безопасность)
- [Лицензия](#лицензия)

## Домены

| Домен | Описание | Что внутри |
|---|---|---|
| **[`code`](domains/code/)** | Цикл планирования, реализации, ревью и отладки; проектный `AGENTS.md` и работа с Godot. | 6 навыков, 7 инструкций ролей, тестовый хук |
| **[`core`](domains/core/)** | Краткие ответы, memory bank и его дефрагментация. | 3 навыка |
| **[`devops`](domains/devops/)** | Kubernetes, Helm, GitLab CI, ArgoCD; консультанты и исполнители с заданными областями файлов. | 7 навыков, 7 инструкций ролей |
| **[`git`](domains/git/)** | Conventional Commits, описание PR и Git workflow. | 3 навыка, 1 правило, 1 инструкция роли |

Все текущие домены устанавливаются без переменных окружения. `content` и `obsidian` в этой версии репозитория отсутствуют. Навыки вызываются в Codex как `$code-plan`, `$git-flow` и так далее; файлы `.agents/agents/` и `.agents/rules/` навыки читают явно.

## Структура репозитория

```
ah-skills/
├── domains/                 # Исходники доменов
│   ├── code/                # manifest, skills, agents, hooks
│   ├── core/                # manifest, skills
│   ├── devops/              # manifest, skills, agents
│   └── git/                 # manifest, skills, agents, rules
├── tools/                   # Go CLI, проверки и тесты
├── install.sh               # Сборка CLI и настройка PATH
├── AGENTS.md                # Рабочие инструкции Codex для этого репозитория
├── CONTRIBUTING.md          # Как менять домены и навыки
├── SECURITY.md              # Модель безопасности
├── LICENCE
└── README.md
```

`domains/` — источник навыков. Установленные в проект `.agents/` содержат снимки, а не живые ссылки на навыки источника. Хук `test_gate.py` — исключение: он остаётся симлинком на исходный файл.

## Установка (CLI `ah-skills`)

Нужен Go. Из корня репозитория:

```bash
source install.sh
```

Скрипт собирает `ah-skills`, добавляет текущий каталог в `PATH` оболочки и сохраняет PATH для новых терминалов через `~/.config/ah-skills/env` и файл настройки оболочки. Если запустить `./install.sh`, сборка и сохранение PATH для новых терминалов выполнятся, но уже открытая родительская оболочка PATH не получит. Для ручной сборки:

```bash
go build -o ah-skills ./tools
```

### Быстрый старт

```bash
ah-skills list domains
ah-skills install domains code core --project <путь-к-проекту>
ah-skills doctor --project <путь-к-проекту>
```

Без `--project` цель — текущий каталог. `--target codex` можно указать явно; Codex уже выбран по умолчанию. `--copy` принимается для совместимости и не меняет режим навыков: они всегда копируются. Чтобы обновить установленный снимок после правок в `domains/`, повтори `install`.

Навыки, правила и инструкции ролей попадают в `<project>/.agents/{skills,rules,agents}/`; lockfile — в `<project>/.agents/skills-lock.json`. Домен `code` дополнительно ставит `.codex/hooks.json` и `.codex/hooks/test_gate.py`. Для работы хука нужны `python3`, доверие к проекту и подтверждение определения хука в Codex. Хук проверяет успешный полный запуск тестов после изменения тестовых файлов; подробности — в [`tools/README.md`](tools/README.md).

Установщик не создаёт `AGENTS.md` целевого проекта. После установки домена `code` вызови `$code-init` в целевом проекте, чтобы создать или дополнить инструкции Codex.

### Команды и платформы

`ah-skills` поддерживает `list`, `install`, `uninstall`, `status`, `doctor`, `check`; флаги включают `--project`, `--harness-root`, `--dry-run`, `--force`, `--copy`, `--target codex`. Полный синтаксис — в [`tools/README.md`](tools/README.md).

Go CLI собирается для macOS, Linux и Windows. `install.sh` требует POSIX shell; в Windows для него нужны Git Bash или WSL, либо собери бинарь напрямую: `go build -o ah-skills.exe ./tools`. Для fish добавь каталог checkout в PATH вручную через `fish_add_path`.

## Разработка самого harness

Корневой `.agents/` — локальная установка, исключённая из Git. Меняй файлы в `domains/` и переустанавливай нужные домены для проверки. Не удаляй `.agents/` и `.codex/` целиком: в них могут быть чужие файлы.

```bash
go build -o ah-skills ./tools
./ah-skills check
go test ./...
./ah-skills install domains code core git --project .
./ah-skills doctor --project .
```

## Контрибьютинг и безопасность

- Как добавлять и менять навыки — [`CONTRIBUTING.md`](CONTRIBUTING.md).
- Что устанавливается и как работает хук — [`SECURITY.md`](SECURITY.md).

## Лицензия

MIT — см. [`LICENCE`](LICENCE).
