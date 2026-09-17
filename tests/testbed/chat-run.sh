#!/usr/bin/env bash
# Имитация запуска из переписки: команду вызывает «помощник», после чего его перезапускают.
# Ждём окончания отдельной службы обновления и печатаем итог. Запуск от владельца помощника.
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
START=$(date +%s)
~/jarvis-start/bin/update.sh --from-chat "$@"
echo "--- ответ скрипта выше, перезапускаю помощника, как это случилось бы в жизни"
systemctl --user restart openclaw-gateway.service
UNIT="$(systemctl --user list-units --all --no-legend 'jarvis-update-*' | awk '{print $1}' | tail -1)"
echo "служба: ${UNIT:-не найдена}"
for i in $(seq 1 110); do
  systemctl --user is-active "$UNIT" >/dev/null 2>&1 || break
  sleep 5
done
echo "служба завершилась за $(( $(date +%s) - START )) с"
grep -E 'detached|ok:|warn:|error:|rollback|notify|success' ~/jarvis-start/update.log | tail -20
