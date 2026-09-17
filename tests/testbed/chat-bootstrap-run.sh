#!/usr/bin/env bash
# Имитация: помощник по старой методичке получил сообщение «подключись к обновлениям» и выполнил
# скачанный скрипт с --adopt --from-chat. Ждём отдельную службу и печатаем журнал. От владельца помощника.
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
START=$(date +%s)
bash /tmp/jarvis-update.sh --adopt --from-chat
UNIT="$(systemctl --user list-units --all --no-legend 'jarvis-update-*' | awk '{print $1}' | tail -1)"
echo "служба: ${UNIT:-не найдена}"
for i in $(seq 1 110); do systemctl --user is-active "$UNIT" >/dev/null 2>&1 || break; sleep 5; done
echo "служба завершилась за $(( $(date +%s) - START )) с"
grep -E 'detached|ok:|warn:|error:|rollback|notify|success|migration' ~/jarvis-start/update.log | tail -22
