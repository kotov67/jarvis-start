#!/usr/bin/env bash
# Джарви Старт, фаза 2: собираем самого помощника.
# Запускать от имени пользователя jarvis:
#   sudo -iu jarvis /home/jarvis/jarvis-start/bin/setup.sh
#
# Для мозга Claude перед запуском должен быть выполнен вход в подписку:
#   sudo -iu jarvis claude auth login
# Для мозга Kimi скрипт сам спросит ключ Kimi Code.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="${HOME}/.openclaw/workspace"
DOMAIN="$(cat "${HERE}/.domain" 2>/dev/null || true)"
BRAIN="$(tr -d ' \n\r' < "${HERE}/.brain" 2>/dev/null || true)"
[ "$BRAIN" = "kimi" ] || BRAIN="claude"
# Модель Kimi: K3 с окном 256 тыс. токенов. Отвечает так же, как K3 на миллион,
# но тратит лимит подписки вдвое медленнее и доступна с тарифа Plus.
KIMI_MODEL="kimi/k3-256k"

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_HEAD=$'\033[1;36m'; C_OFF=$'\033[0m'
step() { printf '\n%s>>> %s%s\n' "$C_HEAD" "$1" "$C_OFF"; }
ok()   { printf '%s  [готово]%s %s\n' "$C_OK" "$C_OFF" "$1"; }
warn() { printf '%s  [внимание]%s %s\n' "$C_WARN" "$C_OFF" "$1"; }
die()  { printf '\n%s  [ошибка]%s %s\n\n' "$C_ERR" "$C_OFF" "$1" >&2; exit 1; }
# Оборвался ввод (закрыли окно, отвалился ssh): останавливаемся, а не крутим вопрос по кругу.
ask()  { local p="$1" d="${2:-}" a; if [ -n "$d" ]; then read -r -p "$p [$d]: " a || die "Ввод прервался. Запустите скрипт заново."; echo "${a:-$d}"; else read -r -p "$p: " a || die "Ввод прервался. Запустите скрипт заново."; echo "$a"; fi; }

export PATH="${HOME}/.npm-global/bin:${PATH}"

[ "$(id -un)" != "root" ] || die "Этот скрипт запускают от имени jarvis, а не от root. Выполните: sudo -iu jarvis /home/jarvis/jarvis-start/bin/setup.sh"

if [ "$BRAIN" = "kimi" ]; then
# ------------------------------------------------------------ ключ Kimi ---
step "Подключаю подписку Kimi"
cat <<'KIMI'
  Нужен ключ Kimi Code. Если его ещё нет:

    1. Оформите подписку Kimi на kimi.com, тариф Plus или выше
       (на тарифе Go помощник работать не будет).
    2. Откройте консоль Kimi Code: kimi.com/code/console
    3. Создайте API-ключ и скопируйте его. Он показывается один раз.

KIMI
KIMI_KEY=""
while [ -z "$KIMI_KEY" ]; do
  read -r -s -p "  Вставьте ключ (символы не отображаются, так задумано): " KIMI_KEY || die "Ввод прервался. Запустите скрипт заново."
  echo
  KIMI_KEY="$(printf '%s' "$KIMI_KEY" | tr -d '[:space:]')"
  [ -n "$KIMI_KEY" ] || continue
  # Ключ уходит в curl через stdin, а не аргументом: так его не видно в списке процессов.
  CODE="$(printf 'header = "Authorization: Bearer %s"\n' "$KIMI_KEY" \
    | curl -s -o /dev/null --max-time 20 -w '%{http_code}' -K - https://api.kimi.com/coding/v1/models 2>/dev/null || true)"
  case "$CODE" in
    200) ok "Ключ принят, подписка Kimi активна" ;;
    401|403) warn "Kimi не принял ключ (код ${CODE}). Проверьте, что скопирован ключ целиком и подписка Plus или выше активна."; KIMI_KEY="" ;;
    *) die "Не достучался до сервера Kimi (код ${CODE:-нет ответа}). Проверьте интернет на сервере и повторите." ;;
  esac
done
else
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
fi

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

if [ "$BRAIN" = "kimi" ]; then AUTH_CHOICE="skip"; else AUTH_CHOICE="anthropic-cli"; fi
openclaw onboard --non-interactive --accept-risk \
  --mode local \
  --auth-choice "$AUTH_CHOICE" \
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
  || {
    # Первый запуск помощника на небольшом сервере идёт до минуты, а сборка ждёт меньше
    # и сообщает «не отвечает». Если служба поставлена, просто дожидаемся её.
    for _ in $(seq 1 40); do openclaw health >/dev/null 2>&1 && break; sleep 3; done
    openclaw health >/dev/null 2>&1 || die "Сборка не прошла. Покажите специалисту файл /tmp/jarvis-onboard.log"
    warn "Помощник запускался дольше обычного, но запустился"
  }
ok "Основа собрана"

if [ "$BRAIN" = "kimi" ]; then
  step "Подключаю мозг Kimi"
  openclaw plugins install @openclaw/kimi-provider >>/tmp/jarvis-onboard.log 2>&1 \
    || die "Не установился модуль Kimi. Покажите специалисту файл /tmp/jarvis-onboard.log"
  # Ключ передаём через stdin: он не попадает ни в аргументы, ни в историю, ни в лог.
  printf '%s' "$KIMI_KEY" | openclaw models auth paste-token --provider kimi --profile-id kimi:default >>/tmp/jarvis-onboard.log 2>&1 \
    || die "Не удалось сохранить ключ Kimi. Покажите специалисту файл /tmp/jarvis-onboard.log"
  unset KIMI_KEY
  openclaw models set "$KIMI_MODEL" >>/tmp/jarvis-onboard.log 2>&1 \
    || die "Не удалось выбрать модель Kimi. Покажите специалисту файл /tmp/jarvis-onboard.log"
  openclaw config set agents.defaults.model.fallbacks '[]' --strict-json >/dev/null 2>&1 || true
  ok "Мозг: Kimi K3 по вашей подписке"
else
  openclaw models auth login --provider anthropic --method cli --set-default >/dev/null 2>&1 || true
fi

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
if [ "$BRAIN" = "kimi" ]; then
  BRAIN_LINE="Kimi K3 по подписке Kimi Code (модель ${KIMI_MODEL}), ключ хранится в OpenClaw."
else
  BRAIN_LINE="Claude Code по подписке, ключи API не используются."
fi
for f in SOUL.md AGENTS.md USER.md IDENTITY.md MEMORY.md TOOLS.md; do
  [ -f "${HERE}/templates/${f}" ] || continue
  sed -e "s/{{AGENT_NAME}}/${AGENT_NAME}/g" \
      -e "s/{{OWNER_NAME}}/${OWNER_NAME}/g" \
      -e "s#{{TZ}}#${TZ_NAME}#g" \
      -e "s/{{TODAY}}/${TODAY}/g" \
      -e "s/{{DOMAIN}}/${DOMAIN:-адрес панели}/g" \
      -e "s#{{BRAIN_LINE}}#${BRAIN_LINE}#g" \
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

# ------------------------------------------------ проверка обновлений ---
step "Включаю ежедневную проверку обновлений"
if "${HERE}/bin/update-check-cron.sh" install >/dev/null 2>&1; then
  ok "Раз в день в 11:00 помощник проверит, не вышло ли обновление, и предложит обновиться"
else
  warn "Проверку обновлений включить не удалось. Позже: ~/jarvis-start/bin/update-check-cron.sh install"
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
