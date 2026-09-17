#!/usr/bin/env bash
# Джарви Старт: обновление помощника одной командой.
#
#   sudo -iu jarvis ~/jarvis-start/bin/update.sh            обновить
#   sudo -iu jarvis ~/jarvis-start/bin/update.sh --check    только показать, что есть нового
#
# Что делает:
#   1. проверяет, что есть новая версия Джарви Старт и платформы OpenClaw
#   2. делает копию помощника (настройки, память, расписания)
#   3. обновляет OpenClaw штатной командой и Claude Code
#   4. обновляет наши скрипты и дописывает новые правила в файлы помощника,
#      не трогая его память, личность и пароли
#   5. выполняет разовые миграции настроек нового выпуска
#   6. проверяет, что помощник поднялся; если нет - возвращает всё из копии
#
# Другие ключи:
#   --version 1.2.0     поставить конкретный выпуск Джарви Старт
#   --skip-platform     не обновлять OpenClaw и Claude Code, только наш слой
#   --force             запустить, даже если похоже, что скрипт вызван из самого помощника
#
# Для разработчиков: JARVIS_UPDATE_SOURCE=<папка или .tar.gz выпуска> вместо скачивания с GitHub.

set -uo pipefail

REPO="${JARVIS_REPO:-kotov67/jarvis-start}"
HOME_DIR="${HOME}/jarvis-start"
WORKSPACE="${HOME}/.openclaw/workspace"
STATE_DIR="${HOME}/.openclaw"
BACKUP_DIR="${HOME}/jarvis-backups"
LOG="${HOME_DIR}/update.log"
KEEP_BACKUPS=3

export PATH="${HOME}/.npm-global/bin:${PATH}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_HEAD=$'\033[1;36m'; C_OFF=$'\033[0m'
log()   { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null || true; }
step()  { printf '\n%s>>> %s%s\n' "$C_HEAD" "$1" "$C_OFF"; log "== $1"; }
ok()    { printf '%s  [готово]%s %s\n' "$C_OK" "$C_OFF" "$1"; log "ok: $1"; }
warn()  { printf '%s  [внимание]%s %s\n' "$C_WARN" "$C_OFF" "$1"; log "warn: $1"; }
die()   { printf '\n%s  [ошибка]%s %s\n\n' "$C_ERR" "$C_OFF" "$1" >&2; log "error: $1"; exit 1; }

CHECK_ONLY=0; WANT_VERSION=""; SKIP_PLATFORM=0; FORCE=0
ARGS=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --version) shift; WANT_VERSION="${1#v}" ;;
    --skip-platform) SKIP_PLATFORM=1 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Неизвестный ключ: $1. Справка: update.sh --help" ;;
  esac
  shift
done

# ------------------------------------------------------------ кто запускает ---
if [ "$(id -u)" -eq 0 ]; then
  id jarvis >/dev/null 2>&1 || die "Пользователь jarvis не найден. Это точно сервер с помощником Джарви Старт?"
  exec sudo -iu jarvis "/home/jarvis/jarvis-start/bin/update.sh" "${ARGS[@]}"
fi
[ -d "$HOME_DIR" ] || die "Не нашёл папку ${HOME_DIR}. Запускайте от имени jarvis: sudo -iu jarvis ~/jarvis-start/bin/update.sh"
command -v openclaw >/dev/null 2>&1 || die "Команда openclaw не найдена. Помощник установлен по методичке Джарви Старт?"

# Обновление перезапускает помощника. Если скрипт позвал сам помощник из переписки,
# он убьёт процесс, который выполняет обновление, и всё оборвётся на середине.
if [ "$FORCE" -eq 0 ] && [ "$CHECK_ONLY" -eq 0 ]; then
  pid=$$
  for _ in $(seq 1 12); do
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
    # Родитель именно процесс шлюза: node, затем путь к openclaw/dist/index.js, затем слово gateway.
    # Совпадение текста в чужой команде (например, в скрипте, который упоминает шлюз) не считается.
    if tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null \
       | awk 'NR == 1 { isnode = ($0 ~ /(^|\/)node[0-9]*$/) }
              prev ~ /openclaw\/dist\/index\.js$/ && $0 == "gateway" { found = 1 }
              { prev = $0 }
              END { exit !(isnode && found) }'; then
      die "Похоже, обновление запустил сам помощник. Так нельзя: он перезапустится и оборвёт обновление.
  Запустите команду в терминале сервера: sudo -iu jarvis ~/jarvis-start/bin/update.sh"
    fi
  done
fi

exec 9>"${HOME_DIR}/.update.lock"
flock -n 9 || die "Обновление уже идёт в другом окне. Дождитесь его окончания."

touch "$LOG" 2>/dev/null || true
log "---- запуск update.sh ${ARGS[*]:-}"

ver_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }
ver_le() { ! ver_gt "$1" "$2"; }

INSTALLED="$(cat "${HOME_DIR}/.version" 2>/dev/null | tr -d ' \n\r' || true)"
INSTALLED="${INSTALLED:-1.0.0}"

oc_version() { openclaw --version 2>/dev/null | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+(-[a-z0-9.]+)?' | head -1; }

# ------------------------------------------------------------ новый выпуск ---
step "Проверяю, что нового"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RELEASE_DIR=""
TARGET=""

fetch_release() {
  local tag="$1" tarball="$TMP/release.tar.gz"
  curl -fsSL --max-time 120 "https://codeload.github.com/${REPO}/tar.gz/refs/tags/${tag}" -o "$tarball" || return 1
  mkdir -p "$TMP/release" && tar -xzf "$tarball" -C "$TMP/release" --strip-components=1 || return 1
  RELEASE_DIR="$TMP/release"
}

if [ -n "${JARVIS_UPDATE_SOURCE:-}" ]; then
  if [ -d "$JARVIS_UPDATE_SOURCE" ]; then
    RELEASE_DIR="$JARVIS_UPDATE_SOURCE"
  else
    mkdir -p "$TMP/release" && tar -xzf "$JARVIS_UPDATE_SOURCE" -C "$TMP/release" --strip-components=1 \
      || die "Не распаковался выпуск ${JARVIS_UPDATE_SOURCE}"
    RELEASE_DIR="$TMP/release"
  fi
  TARGET="$(tr -d ' \n\r' < "$RELEASE_DIR/VERSION" 2>/dev/null || true)"
else
  if [ -n "$WANT_VERSION" ]; then
    TAG="v${WANT_VERSION}"
  else
    TAG="$(curl -fsSL --max-time 20 "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
      | grep -oE '"tag_name": *"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
    if [ -z "$TAG" ]; then
      # Запасной путь, если GitHub API ограничил запросы: страница последнего выпуска отдаёт редирект на тег.
      TAG="$(curl -fsSI --max-time 20 "https://github.com/${REPO}/releases/latest" 2>/dev/null \
        | grep -i '^location:' | sed -E 's#.*/tag/([^[:space:]]+).*#\1#' | tr -d '\r')"
    fi
  fi
  if [ -n "$TAG" ]; then
    TARGET="${TAG#v}"
  else
    warn "Не удалось узнать последний выпуск Джарви Старт на GitHub. Обновлю только платформу."
  fi
fi

LAYER_UPDATE=0
if [ -n "$TARGET" ] && ver_gt "$TARGET" "$INSTALLED"; then
  LAYER_UPDATE=1
fi
if [ -n "$WANT_VERSION" ] && [ "$TARGET" = "$WANT_VERSION" ] && [ "$TARGET" != "$INSTALLED" ]; then
  LAYER_UPDATE=1
fi

OC_BEFORE="$(oc_version)"
OC_LATEST=""
if [ "$SKIP_PLATFORM" -eq 0 ]; then
  OC_LATEST="$(npm view openclaw version 2>/dev/null | tr -d ' \n\r' || true)"
fi
PLATFORM_UPDATE=0
if [ "$SKIP_PLATFORM" -eq 0 ] && [ -n "$OC_LATEST" ] && [ -n "$OC_BEFORE" ] && ver_gt "$OC_LATEST" "$OC_BEFORE"; then
  PLATFORM_UPDATE=1
fi

printf '  Джарви Старт: установлено %s, последний выпуск %s\n' "$INSTALLED" "${TARGET:-неизвестно}"
printf '  OpenClaw:     установлено %s, последняя версия %s\n' "${OC_BEFORE:-неизвестно}" "${OC_LATEST:-не проверялась}"

if [ "$LAYER_UPDATE" -eq 1 ] && [ -z "$RELEASE_DIR" ]; then
  fetch_release "v${TARGET}" || die "Не скачался выпуск v${TARGET} с GitHub. Проверьте интернет на сервере и повторите."
fi
if [ "$LAYER_UPDATE" -eq 1 ]; then
  [ -f "$RELEASE_DIR/bin/update.sh" ] && [ -f "$RELEASE_DIR/VERSION" ] || die "Выпуск v${TARGET} неполный, обновление отменено."
fi

if [ "$LAYER_UPDATE" -eq 1 ] && [ -f "$RELEASE_DIR/CHANGELOG.md" ]; then
  echo
  echo "  Что нового:"
  awk -v from="$INSTALLED" '
    /^## / { v=$2; show = (v != from) }
    /^## / && v == from { exit }
    show { print "    " $0 }
  ' "$RELEASE_DIR/CHANGELOG.md" | head -40
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo
  if [ "$LAYER_UPDATE" -eq 0 ] && [ "$PLATFORM_UPDATE" -eq 0 ]; then
    ok "Обновлять нечего, всё свежее"
  else
    ok "Есть что обновить. Запустите без --check: sudo -iu jarvis ~/jarvis-start/bin/update.sh"
  fi
  exit 0
fi

if [ "$LAYER_UPDATE" -eq 0 ] && [ "$PLATFORM_UPDATE" -eq 0 ]; then
  ok "Обновлять нечего, всё свежее"
  exit 0
fi

# Новая версия самого update.sh: переключаемся на неё, чтобы обновление шло по свежим правилам.
if [ "$LAYER_UPDATE" -eq 1 ] && [ -z "${JARVIS_UPDATE_REEXEC:-}" ] \
   && ! cmp -s "$RELEASE_DIR/bin/update.sh" "$0"; then
  cp "$RELEASE_DIR/bin/update.sh" "$HOME_DIR/bin/update.sh" && chmod +x "$HOME_DIR/bin/update.sh"
  cp -r "$RELEASE_DIR" "$HOME_DIR/.update-release" 2>/dev/null || true
  ok "Скрипт обновления сам обновился, продолжаю по новой версии"
  exec 9>&-
  JARVIS_UPDATE_REEXEC=1 JARVIS_UPDATE_SOURCE="$HOME_DIR/.update-release" exec "$HOME_DIR/bin/update.sh" "${ARGS[@]}"
fi

# ------------------------------------------------------ управление службой ---
UNIT="openclaw-gateway.service"
GW_PATTERN='openclaw/dist/index\.js gateway'

# Остановка только через systemd и с ожиданием: `openclaw gateway stop` может вернуть успех,
# а процесс продолжит работать. Проверено: иначе откат меняет файлы под живым процессом.
gw_stop() {
  openclaw gateway stop >/dev/null 2>&1 || true
  systemctl --user stop "$UNIT" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    pgrep -u "$(id -u)" -f "$GW_PATTERN" >/dev/null 2>&1 || return 0
    sleep 1
  done
  pkill -TERM -u "$(id -u)" -f "$GW_PATTERN" >/dev/null 2>&1 || true
  sleep 5
  pkill -KILL -u "$(id -u)" -f "$GW_PATTERN" >/dev/null 2>&1 || true
  sleep 1
  ! pgrep -u "$(id -u)" -f "$GW_PATTERN" >/dev/null 2>&1
}
gw_restart() {
  systemctl --user restart "$UNIT" >/dev/null 2>&1 || openclaw gateway restart >/dev/null 2>&1 || true
}

# ------------------------------------------------------------ здоровье до ---
# Мало того, что шлюз отвечает: после подмены файлов он может отвечать на пинг, но не
# загружать части установки. Поэтому дополнительно просим список расписаний.
health_ok() {
  systemctl --user is-active "$UNIT" >/dev/null 2>&1 || return 1
  openclaw health >/dev/null 2>&1 || return 1
  openclaw cron list --json 2>/dev/null \
    | jq -e 'if type == "object" and has("ok") then .ok != false else true end' >/dev/null 2>&1
}
telegram_ok() {
  openclaw channels status --probe --json 2>/dev/null \
    | jq -e '.channels.telegram.configured == true and .channels.telegram.probe.ok == true' >/dev/null 2>&1
}
wait_healthy() {
  for _ in $(seq 1 45); do health_ok && return 0; sleep 2; done
  return 1
}

HEALTH_BEFORE=0; TG_BEFORE=0
health_ok && HEALTH_BEFORE=1
[ "$HEALTH_BEFORE" -eq 1 ] && telegram_ok && TG_BEFORE=1
if [ "$HEALTH_BEFORE" -eq 0 ]; then
  warn "Помощник сейчас не отвечает. Обновлю, но проверить результат по «было хорошо» не получится."
fi

AVAIL_MB=$(df -Pm "$HOME" | tail -1 | awk '{print $4}')
[ "${AVAIL_MB:-0}" -ge 1500 ] || die "На диске свободно ${AVAIL_MB} МБ, для копии и обновления нужно хотя бы 1,5 ГБ.
  Очистите логи: sudo journalctl --vacuum-time=3d"

# ------------------------------------------------------------------ копия ---
step "Делаю копию помощника"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
BACKUP="${BACKUP_DIR}/jarvis-backup-$(date +%F-%H%M%S).tar.gz"
# Останавливаем помощника на время копии: базы данных, скопированные на ходу, могут не открыться.
gw_stop || die "Не удалось остановить помощника для копии. Обновление отменено, помощник не тронут."
tar -czf "$BACKUP" --exclude='jarvis-start/.update-release' --exclude='jarvis-start/.update.lock' -C "$HOME" .openclaw jarvis-start 2>>"$LOG"
TAR_RC=$?
gw_restart
[ "$TAR_RC" -eq 0 ] && [ -s "$BACKUP" ] && tar -tzf "$BACKUP" >/dev/null 2>&1 \
  || die "Копия не получилась, обновление отменено, помощник не тронут. Подробности: ${LOG}"
chmod 600 "$BACKUP"
ok "Копия: ${BACKUP} ($(du -h "$BACKUP" | cut -f1))"
ls -1t "$BACKUP_DIR"/jarvis-backup-*.tar.gz 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -f
wait_healthy >/dev/null 2>&1 || true

# ---------------------------------------------------------------- откат ---
rollback() {
  local reason="$1" failed
  printf '\n%s  [ошибка]%s %s\n' "$C_ERR" "$C_OFF" "$reason" >&2
  log "rollback: $reason"
  step "Возвращаю помощника из копии"
  gw_stop || warn "Помощник не остановился штатно, продолжаю откат"
  local oc_now; oc_now="$(oc_version)"
  if [ -n "$OC_BEFORE" ] && [ "$oc_now" != "$OC_BEFORE" ]; then
    npm install -g "openclaw@${OC_BEFORE}" >>"$LOG" 2>&1 \
      && ok "OpenClaw возвращён на ${OC_BEFORE}" \
      || warn "Не удалось вернуть OpenClaw ${OC_BEFORE}, продолжаю откат данных"
  fi
  failed="${HOME}/jarvis-failed-update-$(date +%F-%H%M%S)"
  mkdir -p "$failed"
  # Обе папки возвращаем целиком, а не распаковкой поверх: иначе в них останутся файлы
  # неудачного выпуска (например, сломанная миграция, которая сработает при следующем обновлении).
  mv "$STATE_DIR" "$failed/.openclaw" 2>/dev/null || true
  mv "$HOME_DIR" "$failed/jarvis-start" 2>/dev/null || true
  LOG="$failed/jarvis-start/update.log"
  if tar -xzf "$BACKUP" -C "$HOME" 2>>"$LOG"; then
    cat "$LOG" > "$HOME_DIR/update.log" 2>/dev/null || true
    LOG="$HOME_DIR/update.log"
    ok "Настройки и память восстановлены"
  else
    mv "$failed/.openclaw" "$STATE_DIR" 2>/dev/null || true
    mv "$failed/jarvis-start" "$HOME_DIR" 2>/dev/null || true
    LOG="$HOME_DIR/update.log"
    die "Копию распаковать не удалось. Помощник оставлен как был после обновления. Копия: ${BACKUP}"
  fi
  chmod -R go-w "$(npm root -g)/openclaw" 2>/dev/null || true
  gw_restart
  if wait_healthy; then
    ok "Помощник снова работает на прежней версии"
    printf '\n  Обновление не применено. Неудачное состояние сохранено в %s,\n  его можно показать специалисту. Журнал: %s\n\n' "$failed" "$LOG"
  else
    warn "После отката помощник пока не отвечает. Подождите минуту и проверьте: ~/jarvis-start/bin/doctor.sh"
  fi
  exit 1
}

simulate_fail() { [ "${JARVIS_UPDATE_SIMULATE_FAIL:-}" = "$1" ] && rollback "Проверочный сбой на шаге «$1»"; }

# -------------------------------------------------------------- платформа ---
PLATFORM_CHANGED=0
if [ "$PLATFORM_UPDATE" -eq 1 ]; then
  step "Обновляю платформу OpenClaw (${OC_BEFORE} → ${OC_LATEST})"
  echo "  Это займёт несколько минут. Помощник перезапустится."
  if openclaw update --yes --timeout 1200 >>"$LOG" 2>&1; then
    OC_AFTER="$(oc_version)"
    [ "$OC_AFTER" != "$OC_BEFORE" ] && PLATFORM_CHANGED=1
    ok "OpenClaw ${OC_AFTER:-обновлён}"
  else
    rollback "Штатное обновление OpenClaw завершилось ошибкой"
  fi
  # На некоторых серверах права по умолчанию оставляют папку пакета доступной на запись,
  # и панель отказывается запускать из неё код.
  chmod -R go-w "$(npm root -g)/openclaw" 2>/dev/null || true
fi
simulate_fail platform

if [ "$SKIP_PLATFORM" -eq 0 ]; then
  CC_BEFORE="$(claude --version 2>/dev/null | awk '{print $1}')"
  if npm install -g @anthropic-ai/claude-code@latest >>"$LOG" 2>&1; then
    CC_AFTER="$(claude --version 2>/dev/null | awk '{print $1}')"
    [ "$CC_BEFORE" != "$CC_AFTER" ] && ok "Claude Code ${CC_BEFORE:-?} → ${CC_AFTER}"
  else
    warn "Claude Code не обновился, это не мешает работе. Подробности в ${LOG}"
  fi
fi

# ------------------------------------------------------------ наш слой ---
RESTART_FLAG="$TMP/restart-needed"
if [ "$LAYER_UPDATE" -eq 1 ]; then
  step "Обновляю Джарви Старт (${INSTALLED} → ${TARGET})"
  # Папки заменяем целиком: файлы, которых нет в новом выпуске (старые миграции, убранные
  # правила), не должны оставаться и срабатывать. Работающий update.sh это не ломает:
  # bash дочитывает уже открытый файл.
  for d in bin templates managed migrations; do
    [ -d "$RELEASE_DIR/$d" ] || continue
    rm -rf "$HOME_DIR/$d.new" && cp -r "$RELEASE_DIR/$d" "$HOME_DIR/$d.new" \
      && rm -rf "$HOME_DIR/$d" && mv "$HOME_DIR/$d.new" "$HOME_DIR/$d" \
      || rollback "Не скопировались файлы выпуска ($d)"
  done
  for f in VERSION CHANGELOG.md; do
    [ -f "$RELEASE_DIR/$f" ] && cp "$RELEASE_DIR/$f" "$HOME_DIR/$f"
  done
  chmod +x "$HOME_DIR"/bin/*.sh 2>/dev/null || true
  ok "Скрипты обновлены"

  # shellcheck disable=SC1091
  . "$HOME_DIR/bin/managed.sh" || rollback "Не загрузился модуль правил"
  jarvis_apply_managed "$HOME_DIR/managed" "$WORKSPACE" 2>>"$LOG" || rollback "Не удалось обновить правила в файлах помощника"
  ok "Новые правила дописаны, память и личность не тронуты"
  simulate_fail layer

  if [ -d "$HOME_DIR/migrations" ]; then
    MIGRATIONS="$(ls -1 "$HOME_DIR/migrations"/*.sh 2>/dev/null \
      | awk -F/ '{f=$NF; v=f; sub(/-.*/, "", v); print v "\t" $0}' | sort -V -k1,1 || true)"
    while IFS=$'\t' read -r mver mfile; do
      [ -n "$mfile" ] || continue
      if ver_gt "$mver" "$INSTALLED" && ver_le "$mver" "$TARGET"; then
        echo "  миграция $(basename "$mfile")"
        JARVIS_HOME_DIR="$HOME_DIR" JARVIS_WORKSPACE="$WORKSPACE" \
        JARVIS_FROM_VERSION="$INSTALLED" JARVIS_TO_VERSION="$TARGET" \
        JARVIS_UPDATE_RESTART_FLAG="$RESTART_FLAG" \
          bash "$mfile" >>"$LOG" 2>&1 || rollback "Миграция $(basename "$mfile") завершилась ошибкой"
        log "migration ok: $(basename "$mfile")"
      fi
    done <<< "$MIGRATIONS"
    ok "Настройки приведены к версии ${TARGET}"
  fi
  simulate_fail migrations
fi

# ---------------------------------------------------------------- проверка ---
step "Проверяю, что помощник поднялся"
if [ -f "$RESTART_FLAG" ] || [ "$PLATFORM_CHANGED" -eq 0 ]; then
  gw_restart
fi
if wait_healthy; then
  ok "Помощник отвечает"
elif [ "$HEALTH_BEFORE" -eq 1 ]; then
  rollback "После обновления помощник не отвечает"
else
  warn "Помощник не отвечал и до обновления. Запустите проверку: ~/jarvis-start/bin/doctor.sh"
fi
simulate_fail health

if [ "$TG_BEFORE" -eq 1 ]; then
  tg_up=0
  for _ in $(seq 1 10); do telegram_ok && { tg_up=1; break; }; sleep 3; done
  if [ "$tg_up" -eq 1 ]; then
    ok "Телеграм-бот на связи"
  else
    rollback "После обновления Телеграм-бот перестал отвечать"
  fi
fi

[ "$LAYER_UPDATE" -eq 1 ] && printf '%s\n' "$TARGET" > "$HOME_DIR/.version"
rm -rf "$HOME_DIR/.update-release"
log "success: layer ${INSTALLED}->${TARGET:-$INSTALLED}, openclaw ${OC_BEFORE}->$(oc_version)"

cat <<FINAL

${C_HEAD}================================================================${C_OFF}
${C_OK} Обновление завершено.${C_OFF}
${C_HEAD}================================================================${C_OFF}

  Джарви Старт:  $( [ "$LAYER_UPDATE" -eq 1 ] && echo "${INSTALLED} → ${TARGET}" || echo "${INSTALLED}, без изменений" )
  OpenClaw:      $( [ "$PLATFORM_CHANGED" -eq 1 ] && echo "${OC_BEFORE} → $(oc_version)" || echo "$(oc_version), без изменений" )
  Копия:         ${BACKUP}

  Если что-то ведёт себя странно, проверка здоровья:
      sudo -iu jarvis ~/jarvis-start/bin/doctor.sh

FINAL
