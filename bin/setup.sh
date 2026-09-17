#!/usr/bin/env bash
# Джарви Старт, фаза 2: собираем самого помощника.
# Запускать от имени пользователя jarvis:
#   sudo -iu jarvis /home/jarvis/jarvis-start/bin/setup.sh
#
# Перед запуском должен быть выполнен вход в подписку:
#   sudo -iu jarvis claude auth login

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="${HOME}/.openclaw/workspace"
DOMAIN="$(cat "${HERE}/.domain" 2>/dev/null || true)"

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_HEAD=$'\033[1;36m'; C_OFF=$'\033[0m'
step() { printf '\n%s>>> %s%s\n' "$C_HEAD" "$1" "$C_OFF"; }
ok()   { printf '%s  [готово]%s %s\n' "$C_OK" "$C_OFF" "$1"; }
warn() { printf '%s  [внимание]%s %s\n' "$C_WARN" "$C_OFF" "$1"; }
die()  { printf '\n%s  [ошибка]%s %s\n\n' "$C_ERR" "$C_OFF" "$1" >&2; exit 1; }
ask()  { local p="$1" d="${2:-}" a; if [ -n "$d" ]; then read -r -p "$p [$d]: " a; echo "${a:-$d}"; else read -r -p "$p: " a; echo "$a"; fi; }

export PATH="${HOME}/.npm-global/bin:${PATH}"

[ "$(id -un)" != "root" ] || die "Этот скрипт запускают от имени jarvis, а не от root. Выполните: sudo -iu jarvis /home/jarvis/jarvis-start/bin/setup.sh"

# --------------------------------------------------- проверка входа в Клод ---
step "Проверяю вход в подписку Claude"
AUTH_JSON="$(claude auth status --json 2>/dev/null || true)"
if [ "$(printf '%s' "$AUTH_JSON" | jq -r '.loggedIn // false' 2>/dev/null)" != "true" ]; then
  die "Вход в Claude не выполнен. Сначала выйдите отсюда (наберите exit) и запустите:
      sudo -iu $(id -un) claude auth login
  затем повторите этот скрипт."
fi
PLAN="$(printf '%s' "$AUTH_JSON" | jq -r '.subscriptionType // "подписка"' 2>/dev/null)"
ok "Подписка Claude подключена (${PLAN})"

# ------------------------------------------------------------- знакомство ---
step "Знакомимся"
echo "  Ответьте на несколько вопросов, помощник запомнит их навсегда."
echo
AGENT_NAME="$(ask '  Как назовём помощника' 'Джарвис')"
OWNER_NAME="$(ask '  Как помощнику обращаться к вам' 'шеф')"
echo
echo "  Часовой пояс (от него зависят напоминания и расписания):"
echo "    1) Москва        2) Екатеринбург   3) Новосибирск"
echo "    4) Владивосток   5) Калининград    6) ввести вручную"
TZ_CHOICE="$(ask '  Ваш выбор' '1')"
case "$TZ_CHOICE" in
  1) TZ_NAME="Europe/Moscow" ;;
  2) TZ_NAME="Asia/Yekaterinburg" ;;
  3) TZ_NAME="Asia/Novosibirsk" ;;
  4) TZ_NAME="Asia/Vladivostok" ;;
  5) TZ_NAME="Europe/Kaliningrad" ;;
  *) TZ_NAME="$(ask '  Название пояса, например Europe/Samara' 'Europe/Moscow')" ;;
esac
sudo timedatectl set-timezone "$TZ_NAME" >/dev/null 2>&1 || warn "Не удалось сменить пояс сервера, помощник всё равно будет знать про ${TZ_NAME}"
ok "Помощник: ${AGENT_NAME}. Владелец: ${OWNER_NAME}. Пояс: ${TZ_NAME}"

# ----------------------------------------------------------- Телеграм-бот ---
step "Телеграм-бот"
cat <<'TG'
  Помощнику нужен собственный бот. Это две минуты:

    1. Откройте Телеграм и найдите пользователя @BotFather
       (проверьте имя буква в букву, поддельных ботов много).
    2. Отправьте ему команду:  /newbot
    3. Придумайте имя бота (любое) и имя пользователя,
       которое заканчивается на bot, например my_jarvis_bot.
    4. BotFather пришлёт строку вида 8123456789:AAG...
       Это токен. Скопируйте его целиком.

TG
BOT_TOKEN=""
while [ -z "$BOT_TOKEN" ]; do
  BOT_TOKEN="$(ask '  Вставьте токен бота')"
  if ! printf '%s' "$BOT_TOKEN" | grep -qE '^[0-9]{6,}:[A-Za-z0-9_-]{30,}$'; then
    warn "Это не похоже на токен. Он выглядит так: 8123456789:AAG_длинный_набор_букв"
    BOT_TOKEN=""
  fi
done
BOT_NAME="$(curl -fsS --max-time 15 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null | jq -r '.result.username // empty' || true)"
[ -n "$BOT_NAME" ] || die "Телеграм не принял этот токен. Проверьте, что скопировали его целиком."
ok "Бот @${BOT_NAME} на связи"

# ----------------------------------------------------------------- сборка ---
step "Собираю помощника (это займёт пару минут)"
PANEL_PASS="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"

openclaw onboard --non-interactive --accept-risk \
  --mode local \
  --auth-choice anthropic-cli \
  --gateway-bind loopback \
  --gateway-auth password \
  --gateway-password "$PANEL_PASS" \
  --install-daemon \
  --daemon-runtime node \
  --skip-channels \
  --skip-search \
  --skip-hooks \
  --skip-ui \
  --skip-skills >/tmp/jarvis-onboard.log 2>&1 \
  || die "Сборка не прошла. Покажите специалисту файл /tmp/jarvis-onboard.log"
ok "Основа собрана"

openclaw models auth login --provider anthropic --method cli --set-default >/dev/null 2>&1 || true

# ------------------------------------------------------------- настройки ---
step "Прописываю настройки"
openclaw config set channels.telegram.enabled true --strict-json >/dev/null
openclaw config set channels.telegram.botToken "$BOT_TOKEN" >/dev/null
openclaw config set channels.telegram.dmPolicy '"pairing"' --strict-json >/dev/null
ok "Телеграм подключён"

# ---------------------------------------------------------- личность и память ---
step "Записываю личность и правила памяти"
mkdir -p "${WORKSPACE}/memory" "${WORKSPACE}/knowledge"
TODAY="$(date +%F)"
for f in SOUL.md AGENTS.md USER.md IDENTITY.md MEMORY.md TOOLS.md; do
  [ -f "${HERE}/templates/${f}" ] || continue
  sed -e "s/{{AGENT_NAME}}/${AGENT_NAME}/g" \
      -e "s/{{OWNER_NAME}}/${OWNER_NAME}/g" \
      -e "s#{{TZ}}#${TZ_NAME}#g" \
      -e "s/{{TODAY}}/${TODAY}/g" \
      -e "s/{{DOMAIN}}/${DOMAIN:-адрес панели}/g" \
      "${HERE}/templates/${f}" > "${WORKSPACE}/${f}"
done
# Правила, которые потом обновляет update.sh, живут в отдельном блоке с метками.
if [ -f "${HERE}/bin/managed.sh" ]; then
  # shellcheck disable=SC1091
  . "${HERE}/bin/managed.sh"
  jarvis_apply_managed "${HERE}/managed" "${WORKSPACE}" || warn "Не удалось дописать правила обновления в AGENTS.md"
fi
cat > "${WORKSPACE}/memory/${TODAY}.md" <<MEM
# ${TODAY}

- Помощник ${AGENT_NAME} запущен на сервере. Владелец: ${OWNER_NAME}, часовой пояс ${TZ_NAME}.
- Каналы: Телеграм (@${BOT_NAME}) и панель в браузере.
MEM
ok "Личность записана"

# ----------------------------------------------------------------- запуск ---
step "Запускаю помощника"
openclaw gateway restart >/dev/null 2>&1 || openclaw gateway start >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
  openclaw health >/dev/null 2>&1 && break
  sleep 2
done
openclaw health >/dev/null 2>&1 || warn "Помощник ещё поднимается. Через минуту проверьте: openclaw status"
ok "Помощник работает"

# ------------------------------------------------------- первое сообщение ---
step "Первое сообщение"
echo "  Откройте Телеграм, найдите своего бота @${BOT_NAME} и отправьте ему: привет"
echo "  Жду вашего сообщения..."
CODE=""
for _ in $(seq 1 60); do
  RAW="$(openclaw pairing list telegram --json 2>/dev/null || true)"
  CODE="$(printf '%s' "$RAW" | jq -r '[.. | objects | .code? // empty] | first // empty' 2>/dev/null || true)"
  [ -n "$CODE" ] && break
  sleep 5
done

if [ -n "$CODE" ]; then
  openclaw pairing approve telegram "$CODE" >/dev/null 2>&1 && ok "Вы опознаны, бот теперь отвечает только вам"
else
  warn "Сообщение не дождался. Напишите боту, а потом выполните две команды:
      openclaw pairing list telegram
      openclaw pairing approve telegram КОД_ИЗ_СПИСКА"
fi

# ------------------------------------------------------------------ финал ---
printf '%s\n' "$PANEL_PASS" > "${HOME}/.jarvis-panel-password"
chmod 600 "${HOME}/.jarvis-panel-password"

cat <<FINAL

${C_HEAD}================================================================${C_OFF}
${C_OK} Готово. ${AGENT_NAME} на связи.${C_OFF}
${C_HEAD}================================================================${C_OFF}

  Телеграм:  @${BOT_NAME}
  Панель:    https://${DOMAIN:-адрес-из-первой-фазы}
  Пароль:    ${PANEL_PASS}

  Пароль сохранён в файле ~/.jarvis-panel-password
  Посмотреть позже:  sudo -iu $(id -un) cat ${HOME}/.jarvis-panel-password

  Проверка здоровья в любой момент:
      sudo -iu $(id -un) ${HOME}/jarvis-start/bin/doctor.sh

FINAL
