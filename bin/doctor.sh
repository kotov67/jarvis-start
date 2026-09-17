#!/usr/bin/env bash
# Джарви Старт: проверка здоровья помощника.
# Запускать от имени jarvis:  sudo -iu jarvis /home/jarvis/jarvis-start/bin/doctor.sh
# Скрипт ничего не ломает, только смотрит и подсказывает, что делать.

set -uo pipefail
export PATH="${HOME}/.npm-global/bin:${PATH}"
if OC_REAL="$(readlink -f "$(command -v openclaw 2>/dev/null)" 2>/dev/null)" && [ -n "$OC_REAL" ]; then
  case "$OC_REAL" in
    */lib/node_modules/openclaw/*) export PATH="${OC_REAL%%/lib/node_modules/openclaw/*}/bin:${PATH}" ;;
  esac
fi
# Разбор JSON через node: jq есть не на всех серверах.
json_get() {
  node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{let d;try{d=JSON.parse(s)}catch(e){process.exit(2)}let v;try{v=('"$1"')}catch(e){process.exit(1)}if(v===undefined||v===null||v===false||v==="")process.exit(1);if(v!==true)console.log(typeof v==="object"?JSON.stringify(v):String(v))})'
}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOMAIN="$(cat "${HERE}/.domain" 2>/dev/null || true)"

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_HEAD=$'\033[1;36m'; C_OFF=$'\033[0m'
PROBLEMS=0
good() { printf '%s  ✓%s %s\n' "$C_OK" "$C_OFF" "$1"; }
bad()  { printf '%s  ✗%s %s\n     %s→ %s%s\n' "$C_ERR" "$C_OFF" "$1" "$C_WARN" "$2" "$C_OFF"; PROBLEMS=$((PROBLEMS+1)); }
head_() { printf '\n%s%s%s\n' "$C_HEAD" "$1" "$C_OFF"; }

head_ "Проверка помощника"

# 1. память и диск
MEM_FREE=$(( $(grep MemAvailable /proc/meminfo | awk '{print $2}') / 1024 ))
if [ "$MEM_FREE" -lt 200 ]; then
  bad "Свободной памяти всего ${MEM_FREE} МБ" "Перезапустите помощника: openclaw gateway restart. Если повторяется, нужен тариф побольше: https://ishosting.io/affiliate/NzU4MiM4"
else
  good "Память в порядке (свободно ${MEM_FREE} МБ)"
fi

DISK_FREE=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
if [ "${DISK_FREE:-0}" -lt 2 ]; then
  bad "На диске осталось ${DISK_FREE} ГБ" "Очистите логи: sudo journalctl --vacuum-time=3d"
else
  good "Место на диске есть (${DISK_FREE} ГБ)"
fi

# 2. подписка Claude
if claude auth status --json 2>/dev/null | json_get 'd.loggedIn === true' >/dev/null 2>&1; then
  good "Подписка Claude подключена"
else
  bad "Вход в Claude слетел" "Выполните: claude auth login, потом openclaw gateway restart"
fi

# 3. сам помощник
if openclaw health >/dev/null 2>&1; then
  good "Помощник отвечает"
else
  bad "Помощник не отвечает" "Выполните: openclaw gateway restart, подождите минуту и запустите проверку снова"
fi

# 4. служба
if systemctl --user is-active openclaw-gateway.service >/dev/null 2>&1; then
  good "Служба запущена и переживёт перезагрузку"
else
  bad "Служба помощника не запущена" "Выполните: openclaw gateway start"
fi

# 5. телеграм
# Токен из настроек не читаем: новые версии OpenClaw отдают вместо него заглушку.
# Штатная проверка канала сама стучится в Телеграм с настоящим токеном.
TG_JSON="$(openclaw channels status --probe --json 2>/dev/null || true)"
if ! printf '%s' "$TG_JSON" | json_get 'd.channels.telegram.configured === true' >/dev/null 2>&1; then
  bad "Телеграм-бот не настроен" "Запустите /home/jarvis/jarvis-start/bin/setup.sh ещё раз"
elif printf '%s' "$TG_JSON" | json_get 'd.channels.telegram.probe.ok === true' >/dev/null 2>&1; then
  BOT="$(printf '%s' "$TG_JSON" | json_get 'd.channels.telegram.probe.botInfo.username' 2>/dev/null)"
  good "Телеграм-бот на связи${BOT:+ (@${BOT})}"
else
  ERR="$(printf '%s' "$TG_JSON" | json_get 'd.channels.telegram.probe.error || d.channels.telegram.lastError' 2>/dev/null)"
  bad "Телеграм не отвечает${ERR:+: ${ERR}}" "Проверьте интернет на сервере: curl https://api.telegram.org. Если сервер в России, Телеграм может быть недоступен без прокси. Если токен бота менялся в BotFather, запустите setup.sh ещё раз."
fi

# 6. панель (по методичке её отдаёт Caddy; если помощник ставился иначе, этот пункт пропускаем)
if ! command -v caddy >/dev/null 2>&1; then
  :
elif systemctl is-active caddy >/dev/null 2>&1; then
  good "Веб-сервер панели работает"
  if [ -n "$DOMAIN" ]; then
    CODE="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 15 "https://${DOMAIN}/" 2>/dev/null || echo 000)"
    case "$CODE" in
      000) bad "Панель снаружи не открывается" "Проверьте файрвол: sudo ufw status. Порты 80 и 443 должны быть открыты." ;;
      5*)  bad "Панель отвечает ошибкой ${CODE}" "Перезапустите помощника: openclaw gateway restart" ;;
      *)   good "Панель открывается: https://${DOMAIN}" ;;
    esac
  fi
else
  bad "Веб-сервер панели остановлен" "Выполните: sudo systemctl restart caddy"
fi

# 7. пароль панели
if ! command -v caddy >/dev/null 2>&1; then
  :
elif [ -f "${HOME}/.jarvis-panel-password" ]; then
  good "Пароль панели лежит в ~/.jarvis-panel-password"
else
  printf '%s  ·%s Пароль панели не найден. Задать новый: openclaw config set gateway.auth.password "новый-пароль"\n' "$C_WARN" "$C_OFF"
fi

# 8. проверка обновлений
if [ -x "${HERE}/bin/update-check-cron.sh" ]; then
  if "${HERE}/bin/update-check-cron.sh" status >/dev/null 2>&1; then
    good "Ежедневная проверка обновлений включена"
  else
    bad "Ежедневная проверка обновлений выключена" "Включить: ~/jarvis-start/bin/update-check-cron.sh install"
  fi
fi

head_ "Итог"
if [ "$PROBLEMS" -eq 0 ]; then
  printf '%s  Всё работает.%s\n\n' "$C_OK" "$C_OFF"
else
  printf '%s  Нашлось проблем: %s. Что делать, написано рядом с каждой.%s\n' "$C_WARN" "$PROBLEMS" "$C_OFF"
  printf '  Если не помогло, полный отчёт: openclaw doctor\n\n'
fi

VER="$(cat "${HERE}/.version" 2>/dev/null || echo 1.0.0)"
printf '  Версия Джарви Старт: %s. Проверить обновления: ~/jarvis-start/bin/update.sh --check\n\n' "$VER"
