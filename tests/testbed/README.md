# Тестовый стенд для выпусков

Ubuntu 24.04 с systemd в Docker: на нём проверяются установка и `update.sh` перед выпуском.

```bash
docker build -t jarvis-testbed:24.04 tests/testbed
docker run -d --name jarvis-test --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock jarvis-testbed:24.04
docker cp . jarvis-test:/root/js-src && docker exec jarvis-test bash -c 'cd /root/js-src && bash install.sh'
```

Если Docker Hub недоступен, в `Dockerfile` поменяйте базовый образ на доступное зеркало `ubuntu:24.04`.

- `make-old-client.sh` (от jarvis): собрать помощника без входа в Claude и без бота
  (`--auth-choice skip`), разложить шаблоны, добавить личные метки и задачу в расписание.
- `verify.sh` (от jarvis): версия платформы, здоровье, расписание, личные метки, блок правил, контрольные суммы файлов.

Сценарии перед выпуском: откат на каждом шаге (`JARVIS_UPDATE_SIMULATE_FAIL`), обычное
обновление старого клиента, повторный запуск, выпуск с миграцией, выпуск со сломанной миграцией.
Подробности в `RELEASING.md`.

Грабли, найденные на стенде:
- `openclaw gateway stop` может вернуть успех, а процесс останется: останавливать через systemd с ожиданием.
- После запуска новой версии база переходит на новую схему, старая версия её не откроет:
  откат это всегда «старая версия + данные из копии», по отдельности не работает.
- `openclaw config get` отдаёт токены заглушкой `__OPENCLAW_REDACTED__`.
- Способ входа `claude-cli` в `onboard` устарел, правильно `anthropic-cli`.
- OpenClaw 9.4 при первом запуске сам переносит `TOOLS.md` внутрь `AGENTS.md`.
- `pkill -f` с шаблоном в той же команде убивает и саму оболочку, которая его вызвала.
