#!/usr/bin/env bash
# Джарви Старт: подготовка сервера под личного ИИ-помощника.
# Запускать от root на чистой Ubuntu 22.04/24.04:
#   bash <(curl -fsSL https://raw.githubusercontent.com/kotov67/jarvis-start/main/install.sh)
#
# Что делает этот скрипт (фаза 1, системная):
#   1. проверяет систему и добавляет файл подкачки на маленьких серверах
#   2. заводит отдельного пользователя jarvis, под которым будет жить помощник
#   3. ставит Node.js, Claude Code, OpenClaw и веб-сервер Caddy
#   4. поднимает HTTPS-адрес панели и настраивает файрвол
#   5. печатает две команды для фазы 2
#
# Фаза 2 (вход в Клода и настройка помощника) запускается отдельно, от имени jarvis.

set -euo pipefail

REPO_RAW="${JARVIS_REPO_RAW:-https://raw.githubusercontent.com/kotov67/jarvis-start/main}"
JARVIS_USER="${JARVIS_USER:-jarvis}"
JARVIS_HOME="/home/${JARVIS_USER}"
NODE_MAJOR=24

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_HEAD=$'\033[1;36m'; C_OFF=$'\033[0m'
step()  { printf '\n%s>>> %s%s\n' "$C_HEAD" "$1" "$C_OFF"; }
ok()    { printf '%s  [готово]%s %s\n' "$C_OK" "$C_OFF" "$1"; }
warn()  { printf '%s  [внимание]%s %s\n' "$C_WARN" "$C_OFF" "$1"; }
die()   { printf '\n%s  [ошибка]%s %s\n\n' "$C_ERR" "$C_OFF" "$1" >&2; exit 1; }

# ---------------------------------------------------------------- проверки ---
step "Проверяю сервер"

[ "$(id -u)" -eq 0 ] || die "Скрипт нужно запускать от root. Выполните: sudo -i, потом повторите команду."

. /etc/os-release 2>/dev/null || die "Не удалось определить систему. Нужна Ubuntu 22.04 или 24.04."
case "${ID}:${VERSION_ID}" in
  ubuntu:22.04|ubuntu:24.04|ubuntu:25.04|debian:12|debian:13) ok "Система: ${PRETTY_NAME}" ;;
  *) warn "Система ${PRETTY_NAME} не проверялась. Рекомендуется Ubuntu 24.04. Продолжаю." ;;
esac

ARCH="$(uname -m)"
[ "$ARCH" = "x86_64" ] || [ "$ARCH" = "aarch64" ] || die "Процессор ${ARCH} не поддерживается."

MEM_MB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))
if   [ "$MEM_MB" -lt 900 ];  then die "На сервере ${MEM_MB} МБ памяти. Нужно минимум 2 ГБ, комфортно 4 ГБ.
  Сменить тариф или взять подходящий сервер: https://ishosting.io/affiliate/NzU4MiM4"
elif [ "$MEM_MB" -lt 1900 ]; then warn "Памяти ${MEM_MB} МБ. Помощник запустится, но будет тормозить. Лучше тариф на 2-4 ГБ: https://ishosting.io/affiliate/NzU4MiM4"
else ok "Оперативная память: ${MEM_MB} МБ"
fi

DISK_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
[ "${DISK_GB:-0}" -ge 8 ] || die "На диске свободно ${DISK_GB} ГБ. Нужно минимум 10 ГБ.
  Тариф с диском побольше: https://ishosting.io/affiliate/NzU4MiM4"
ok "Свободно на диске: ${DISK_GB} ГБ"

# --------------------------------------------------------------- подкачка ---
if [ "$MEM_MB" -lt 4000 ] && ! swapon --show | grep -q .; then
  step "Добавляю файл подкачки (страховка от нехватки памяти)"
  if fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none 2>/dev/null; then
    chmod 600 /swapfile
    if mkswap -q /swapfile >/dev/null 2>&1 && swapon /swapfile 2>/dev/null; then
      grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
      ok "Файл подкачки на 2 ГБ включён"
    else
      rm -f /swapfile
      warn "Хостинг не разрешает файл подкачки. Не страшно, но при 2 ГБ памяти помощник может подтормаживать."
    fi
  else
    warn "Не удалось создать файл подкачки, продолжаю без него."
  fi
fi

# ------------------------------------------------------------ базовый софт ---
step "Обновляю списки пакетов и ставлю базовые инструменты"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget git ca-certificates gnupg sudo ufw jq unzip debian-keyring debian-archive-keyring apt-transport-https >/dev/null
ok "Базовые инструменты на месте"

# ------------------------------------------------------------ пользователь ---
step "Готовлю отдельного пользователя ${JARVIS_USER}"
if id "$JARVIS_USER" >/dev/null 2>&1; then
  ok "Пользователь ${JARVIS_USER} уже существует"
else
  adduser --disabled-password --gecos "" "$JARVIS_USER" >/dev/null
  ok "Пользователь ${JARVIS_USER} создан"
fi

# Помощнику нужны права администратора: он ставит пакеты, чинит службы, правит расписания.
# Это осознанный компромисс. Держите на этом сервере только то, что не жалко доверить агенту.
echo "${JARVIS_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-jarvis
chmod 440 /etc/sudoers.d/90-jarvis
ok "Права администратора выданы"

# Службы пользователя должны работать без активного входа в систему.
loginctl enable-linger "$JARVIS_USER" >/dev/null 2>&1 || true
ok "Помощник будет работать даже когда вы отключитесь от сервера"

# Вход по вашему ssh-ключу, если он был у root.
if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ]; then
  install -d -m 700 -o "$JARVIS_USER" -g "$JARVIS_USER" "${JARVIS_HOME}/.ssh"
  cp /root/.ssh/authorized_keys "${JARVIS_HOME}/.ssh/authorized_keys"
  chown "$JARVIS_USER:$JARVIS_USER" "${JARVIS_HOME}/.ssh/authorized_keys"
  chmod 600 "${JARVIS_HOME}/.ssh/authorized_keys"
  ok "Ваш ssh-ключ скопирован пользователю ${JARVIS_USER}"
fi

# ------------------------------------------------------------------ Node ---
step "Ставлю Node.js ${NODE_MAJOR}"
NEED_NODE=1
if command -v node >/dev/null 2>&1; then
  CUR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  [ "${CUR:-0}" -ge 22 ] && { NEED_NODE=0; ok "Node.js ${CUR} уже стоит"; }
fi
if [ "$NEED_NODE" -eq 1 ]; then
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >/dev/null 2>&1
  apt-get install -y -qq nodejs >/dev/null
  ok "Node.js $(node -v) установлен"
fi

# Глобальные пакеты npm кладём в домашнюю папку помощника, чтобы обходиться без sudo.
install -d -o "$JARVIS_USER" -g "$JARVIS_USER" "${JARVIS_HOME}/.npm-global"
sudo -u "$JARVIS_USER" npm config set prefix "${JARVIS_HOME}/.npm-global" >/dev/null 2>&1 || true

# Пишем именно в .profile: его читает даже неинтерактивный вход (sudo -iu jarvis),
# в отличие от .bashrc, который на первой же строке выходит для неинтерактивных сессий.
PROFILE="${JARVIS_HOME}/.profile"
touch "$PROFILE"
add_line() { grep -qxF "$1" "$PROFILE" 2>/dev/null || echo "$1" >> "$PROFILE"; }
add_line ''
add_line '# --- Джарви Старт ---'
add_line "export PATH=\"${JARVIS_HOME}/.npm-global/bin:\$PATH\""
add_line 'export NODE_COMPILE_CACHE=/var/tmp/openclaw-compile-cache'
add_line 'export OPENCLAW_NO_RESPAWN=1'
# Без этой переменной не работает управление службой помощника через systemctl --user.
add_line 'export XDG_RUNTIME_DIR="/run/user/$(id -u)"'
mkdir -p /var/tmp/openclaw-compile-cache && chown "$JARVIS_USER:$JARVIS_USER" /var/tmp/openclaw-compile-cache
chown "$JARVIS_USER:$JARVIS_USER" "$PROFILE"

# ---------------------------------------------------------- Claude Code ---
step "Ставлю Claude Code (мозг помощника)"
sudo -u "$JARVIS_USER" -H bash -lc "npm install -g @anthropic-ai/claude-code >/dev/null 2>&1"
CLAUDE_VER="$(sudo -u "$JARVIS_USER" -H bash -lc 'claude --version 2>/dev/null' || true)"
[ -n "$CLAUDE_VER" ] || die "Claude Code не установился. Проверьте интернет на сервере и запустите скрипт ещё раз."
ok "Claude Code ${CLAUDE_VER}"

# -------------------------------------------------------------- OpenClaw ---
step "Ставлю OpenClaw (тело помощника: память, Телеграм, панель)"
sudo -u "$JARVIS_USER" -H bash -lc "npm install -g openclaw >/dev/null 2>&1"
OC_VER="$(sudo -u "$JARVIS_USER" -H bash -lc 'openclaw --version 2>/dev/null' || true)"
[ -n "$OC_VER" ] || die "OpenClaw не установился. Запустите скрипт ещё раз."
ok "OpenClaw ${OC_VER##*OpenClaw }"

# Ссылки в системной папке, чтобы команды находились независимо от настроек оболочки.
for b in claude openclaw; do
  [ -x "${JARVIS_HOME}/.npm-global/bin/${b}" ] && ln -sf "${JARVIS_HOME}/.npm-global/bin/${b}" "/usr/local/bin/${b}"
done

# ------------------------------------------------------------------ адрес ---
step "Определяю адрес панели"
IP="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null || true)"
[ -n "$IP" ] || die "Не удалось определить внешний адрес сервера."

if [ -n "${JARVIS_DOMAIN:-}" ]; then
  DOMAIN="$JARVIS_DOMAIN"
  ok "Использую ваш домен: ${DOMAIN}"
  warn "Убедитесь, что A-запись ${DOMAIN} указывает на ${IP}, иначе сертификат не выпустится."
else
  DOMAIN="$(echo "$IP" | tr '.' '-').sslip.io"
  ok "Бесплатный адрес: ${DOMAIN} (сервис sslip.io превращает IP в имя, покупать домен не нужно)"
fi

# --------------------------------------------------------------- Caddy ---
step "Ставлю веб-сервер Caddy и выпускаю сертификат"
if ! command -v caddy >/dev/null 2>&1; then
  curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y -qq caddy >/dev/null
fi

cat > /etc/caddy/Caddyfile <<CADDY
# Панель помощника. Caddy сам получает и продлевает сертификат Let's Encrypt.
${DOMAIN} {
	encode zstd gzip
	reverse_proxy 127.0.0.1:18789
}
CADDY
systemctl enable caddy >/dev/null 2>&1 || true
if systemctl restart caddy >/dev/null 2>&1; then
  ok "Caddy запущен, панель будет доступна по https://${DOMAIN}"
else
  warn "Caddy не стартовал. Панель пока недоступна снаружи, посмотреть причину: systemctl status caddy"
fi

# --------------------------------------------------------------- файрвол ---
step "Закрываю лишние двери (файрвол)"
ufw allow 22/tcp  >/dev/null 2>&1 || true
ufw allow 80/tcp  >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true

# Если на сервере уже стоит личный VPN (AmneziaVPN и подобные в докере),
# его порты нужно оставить открытыми, иначе связь с сервером оборвётся.
VPN_PORTS=""
if command -v docker >/dev/null 2>&1; then
  VPN_PORTS="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null \
    | grep -iE 'amnezia|wg-easy|wireguard|xray|openvpn' \
    | grep -oE '0\.0\.0\.0:[0-9]+->[0-9]+/(udp|tcp)' \
    | sed -E 's#0\.0\.0\.0:([0-9]+)->[0-9]+/(udp|tcp)#\1/\2#' | sort -u || true)"
fi
# Дополнительные порты можно задать вручную: JARVIS_EXTRA_PORTS="1234/udp 5678/tcp"
for p in ${VPN_PORTS} ${JARVIS_EXTRA_PORTS:-}; do
  ufw allow "$p" >/dev/null 2>&1 && ok "Оставил открытым порт вашего VPN: ${p}"
done

ufw --force enable >/dev/null 2>&1 || true
ok "Открыты только вход на сервер и сайт панели. Сам помощник наружу не смотрит."
[ -z "${VPN_PORTS}" ] && command -v docker >/dev/null 2>&1 && \
  warn "Личный VPN на сервере не найден. Если он у вас есть и связь оборвётся, откройте его порт: ufw allow НОМЕР/udp"

# ------------------------------------------------------ файлы второй фазы ---
step "Кладу файлы второй фазы"
install -d -o "$JARVIS_USER" -g "$JARVIS_USER" "${JARVIS_HOME}/jarvis-start"
for f in bin/setup.sh bin/doctor.sh templates/SOUL.md templates/AGENTS.md templates/USER.md templates/IDENTITY.md templates/MEMORY.md templates/TOOLS.md; do
  install -d -o "$JARVIS_USER" -g "$JARVIS_USER" "${JARVIS_HOME}/jarvis-start/$(dirname "$f")"
  if [ -f "$(dirname "$0")/$f" ]; then
    cp "$(dirname "$0")/$f" "${JARVIS_HOME}/jarvis-start/$f"
  else
    curl -fsSL "${REPO_RAW}/$f" -o "${JARVIS_HOME}/jarvis-start/$f" || die "Не скачался файл $f"
  fi
  chown "$JARVIS_USER:$JARVIS_USER" "${JARVIS_HOME}/jarvis-start/$f"
done
chmod +x "${JARVIS_HOME}/jarvis-start/bin/"*.sh
printf '%s\n' "$DOMAIN" > "${JARVIS_HOME}/jarvis-start/.domain"
chown "$JARVIS_USER:$JARVIS_USER" "${JARVIS_HOME}/jarvis-start/.domain"
ok "Файлы на месте"

# ----------------------------------------------------------------- финал ---
cat <<FINAL

${C_HEAD}================================================================${C_OFF}
${C_OK} Фаза 1 завершена. Сервер готов.${C_OFF}
${C_HEAD}================================================================${C_OFF}

  Адрес будущей панели:  https://${DOMAIN}
  Пользователь помощника: ${JARVIS_USER}

${C_HEAD}Что делать дальше: две команды, по очереди.${C_OFF}

  ${C_HEAD}Команда 1${C_OFF} (вход в подписку Claude):

      sudo -iu ${JARVIS_USER} claude auth login

    Появится длинная ссылка. Скопируйте её, откройте в браузере
    на своём компьютере, войдите в аккаунт Claude, разрешите доступ.
    Вам покажут код: вернитесь в это окно и вставьте его.

  ${C_HEAD}Команда 2${C_OFF} (сборка помощника):

      sudo -iu ${JARVIS_USER} ${JARVIS_HOME}/jarvis-start/bin/setup.sh

    Скрипт спросит имя помощника и токен Телеграм-бота,
    а в конце покажет пароль от панели.

FINAL
