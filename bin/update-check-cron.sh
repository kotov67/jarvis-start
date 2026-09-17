#!/usr/bin/env bash
# Джарви Старт: задача ежедневной проверки обновлений в планировщике OpenClaw.
#
#   update-check-cron.sh install   завести задачу, если её ещё нет (повторный запуск ничего не ломает)
#   update-check-cron.sh status    есть ли задача
#   update-check-cron.sh remove    удалить задачу
#
# Задача jarvis-update-check: каждый день в 11:00 по часовому поясу сервера запускает
# ~/jarvis-start/bin/check-updates.sh без модели и отправляет его ответ владельцу в Телеграм.

set -uo pipefail
NAME="jarvis-update-check"
HOME_DIR="${HOME}/jarvis-start"
export PATH="${HOME}/.npm-global/bin:/usr/local/bin:${PATH}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if OC_REAL="$(readlink -f "$(command -v openclaw 2>/dev/null)" 2>/dev/null)" && [ -n "$OC_REAL" ]; then
  case "$OC_REAL" in
    */lib/node_modules/openclaw/*) export PATH="${OC_REAL%%/lib/node_modules/openclaw/*}/bin:${PATH}" ;;
  esac
fi

json_get() {
  node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{let d;try{d=JSON.parse(s)}catch(e){process.exit(2)}let v;try{v=('"$1"')}catch(e){process.exit(1)}if(v===undefined||v===null||v===false||v==="")process.exit(1);if(v!==true)console.log(typeof v==="object"?JSON.stringify(v):String(v))})'
}

wait_gateway() {
  for _ in $(seq 1 45); do openclaw health >/dev/null 2>&1 && return 0; sleep 2; done
  return 1
}

job_id() {
  openclaw cron list --json 2>/dev/null | json_get "(d.jobs || []).filter(j => j.name === '${NAME}').map(j => j.id)[0]"
}

# Владелец из хранилища подтверждённых собеседников (pairing): в новых версиях OpenClaw это таблица
# channel_pairing_allow_entries в ~/.openclaw/state/openclaw.sqlite, в старых - файлы в credentials.
pairing_owner() {
  local id=""
  if [ -f "$HOME/.openclaw/state/openclaw.sqlite" ]; then
    id="$(node -e 'try{const {DatabaseSync}=require("node:sqlite");const db=new DatabaseSync(process.argv[1],{readOnly:true});const r=db.prepare("select entry from channel_pairing_allow_entries where channel_key=? order by sort_order, updated_at limit 1").get("telegram");if(r)console.log(String(r.entry).replace(/^telegram:/,""))}catch(e){}' "$HOME/.openclaw/state/openclaw.sqlite" 2>/dev/null)"
  fi
  if [ -z "$id" ]; then
    for f in "$HOME"/.openclaw/credentials/telegram*allow*.json; do
      [ -f "$f" ] || continue
      id="$(json_get 'd.map(String).map(x => x.replace(/^telegram:/, "")).find(x => /^[0-9]+$/.test(x))' < "$f" 2>/dev/null)"
      [ -n "$id" ] && break
    done
  fi
  printf '%s' "$id"
}

owner_id() {
  local id
  id="$(openclaw config get commands.ownerAllowFrom 2>/dev/null \
    | json_get 'd.map(String).find(x => x.startsWith("telegram:"))' 2>/dev/null | sed 's/^telegram://')"
  [ -n "$id" ] || id="$(openclaw config get channels.telegram.allowFrom 2>/dev/null \
    | json_get 'd.map(String).map(x => x.replace(/^telegram:/, "")).find(x => /^[0-9]+$/.test(x))' 2>/dev/null)"
  [ -n "$id" ] || id="$(pairing_owner)"
  printf '%s' "$id"
}

# Часовой пояс владельца: настройка OpenClaw, затем профиль USER.md, затем пояс сервера.
# Серверы часто стоят в UTC, а «11:00» должно быть по времени человека.
owner_tz() {
  local tz
  tz="$(openclaw config get agents.defaults.userTimezone 2>/dev/null | tr -d '"' | grep -oE '^[A-Za-z]+/[A-Za-z_+-]+$')"
  [ -n "$tz" ] || tz="$(grep -iE 'timezone|часов[ойы]+ пояс|пояс' "$HOME/.openclaw/workspace/USER.md" 2>/dev/null \
    | grep -oE '(Africa|America|Antarctica|Asia|Atlantic|Australia|Europe|Indian|Pacific|Etc)/[A-Za-z_+-]+' | head -1)"
  [ -n "$tz" ] || tz="$(timedatectl show -p Timezone --value 2>/dev/null)"
  [ -n "$tz" ] || tz="$(cat /etc/timezone 2>/dev/null)"
  printf '%s' "${tz:-Europe/Moscow}"
}

case "${1:-install}" in
  status)
    wait_gateway || { echo "помощник не отвечает"; exit 1; }
    ID="$(job_id)"
    [ -n "$ID" ] && echo "задача ${NAME} есть: ${ID}" || { echo "задачи ${NAME} нет"; exit 1; }
    ;;
  remove)
    wait_gateway || { echo "помощник не отвечает"; exit 1; }
    ID="$(job_id)"
    [ -n "$ID" ] || { echo "задачи ${NAME} и так нет"; exit 0; }
    openclaw cron rm "$ID" >/dev/null && echo "задача ${NAME} удалена"
    ;;
  install)
    wait_gateway || { echo "помощник не отвечает, задачу проверки обновлений завести не удалось" >&2; exit 1; }
    ID="$(job_id)"
    if [ -n "$ID" ]; then echo "задача ${NAME} уже есть"; exit 0; fi
    TZ_NAME="$(owner_tz)"
    OWNER="$(owner_id)"
    DELIVERY=(--announce --channel telegram --best-effort-deliver)
    if [ -n "$OWNER" ]; then DELIVERY+=(--to "$OWNER"); else DELIVERY=(--announce --channel last --best-effort-deliver); fi
    openclaw cron add --name "$NAME" \
      --description "Джарви Старт: раз в сутки проверяет, вышло ли обновление, и предлагает владельцу обновиться. Без модели, подписку не тратит." \
      --cron "0 11 * * *" --tz "$TZ_NAME" \
      --command "${HOME_DIR}/bin/check-updates.sh" \
      --timeout-seconds 120 \
      "${DELIVERY[@]}" >/dev/null \
      || { echo "не удалось завести задачу ${NAME}" >&2; exit 1; }
    echo "задача ${NAME} заведена: каждый день в 11:00 (${TZ_NAME})${OWNER:+, получатель ${OWNER}}"
    ;;
  *)
    echo "использование: update-check-cron.sh install|status|remove" >&2; exit 2 ;;
esac
