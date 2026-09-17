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
#   --from-chat         запуск из переписки: сам помощник вызывает эту команду, когда человек
#                       просит обновиться. Обновление уходит в отдельный процесс, который переживёт
#                       перезапуск помощника, а итог приходит человеку сообщением в Телеграм.
#   --notify-target ID  кому в Телеграме прислать итог (по умолчанию владелец из настроек)
#   --adopt             подключить к обновлениям помощника, поставленного не по методичке
#                       (создаёт ~/jarvis-start и ставит последний выпуск)
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
# Папка npm, в которую поставлен OpenClaw: ~/.npm-global по методичке, nvm или системная.
# Её bin ставим первым в PATH, чтобы npm, node и откат версии работали с той же установкой.
if OC_REAL="$(readlink -f "$(command -v openclaw 2>/dev/null)" 2>/dev/null)" && [ -n "$OC_REAL" ]; then
  case "$OC_REAL" in
    */lib/node_modules/openclaw/*) export PATH="${OC_REAL%%/lib/node_modules/openclaw/*}/bin:${PATH}" ;;
  esac
fi

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_HEAD=$'\033[1;36m'; C_OFF=$'\033[0m'
log()   { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null || true; }
step()  { printf '\n%s>>> %s%s\n' "$C_HEAD" "$1" "$C_OFF"; log "== $1"; }
ok()    { printf '%s  [готово]%s %s\n' "$C_OK" "$C_OFF" "$1"; log "ok: $1"; }
warn()  { printf '%s  [внимание]%s %s\n' "$C_WARN" "$C_OFF" "$1"; log "warn: $1"; }
die()   { printf '\n%s  [ошибка]%s %s\n\n' "$C_ERR" "$C_OFF" "$1" >&2; log "error: $1"; notify "Обновление не выполнено: $1"; exit 1; }

# Разбор JSON через node: он есть везде, где стоит OpenClaw, а jq бывает не установлен.
# json_get '<выражение над d>' < файл: печатает значение; код 1, если пусто/false; 2, если не JSON.
json_get() {
  node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{let d;try{d=JSON.parse(s)}catch(e){process.exit(2)}let v;try{v=('"$1"')}catch(e){process.exit(1)}if(v===undefined||v===null||v===false||v==="")process.exit(1);if(v!==true)console.log(typeof v==="object"?JSON.stringify(v):String(v))})'
}

# Итог обновления человеку в Телеграм. Работает только в режиме --from-chat / --notify-target.
NOTIFY=0; NOTIFY_TARGET=""; NOTIFIED=0
notify() {
  [ "$NOTIFY" -eq 1 ] && [ "$NOTIFIED" -eq 0 ] || return 0
  local target="$NOTIFY_TARGET"
  if [ -z "$target" ]; then
    target="$(openclaw config get commands.ownerAllowFrom 2>/dev/null \
      | json_get 'd.map(String).find(x => x.startsWith("telegram:"))' 2>/dev/null | sed 's/^telegram://')"
  fi
  if [ -z "$target" ]; then
    target="$(openclaw config get channels.telegram.allowFrom 2>/dev/null \
      | json_get 'd.map(String).find(x => /^[0-9-]+$/.test(x.replace(/^telegram:/, "")))' 2>/dev/null | sed 's/^telegram://')"
  fi
  [ -n "$target" ] || { log "notify: получатель не найден"; return 0; }
  for _ in 1 2 3 4 5 6; do
    if openclaw message send --channel telegram --target "$target" --message "$1" >>"$LOG" 2>&1; then
      NOTIFIED=1; log "notify: отправлено ${target}"; return 0
    fi
    sleep 10
  done
  log "notify: не отправилось"
}

CHECK_ONLY=0; WANT_VERSION=""; SKIP_PLATFORM=0; FORCE=0; FROM_CHAT=0; ADOPT=0
ARGS=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --version) shift; WANT_VERSION="${1#v}" ;;
    --skip-platform) SKIP_PLATFORM=1 ;;
    --force) FORCE=1 ;;
    --from-chat) FROM_CHAT=1 ;;
    --notify-target) shift; NOTIFY_TARGET="${1#telegram:}"; NOTIFY=1 ;;
    --adopt) ADOPT=1 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Неизвестный ключ: $1. Справка: update.sh --help" ;;
  esac
  shift
done

# ------------------------------------------------------------ кто запускает ---
[ -n "${JARVIS_UPDATE_DETACHED:-}" ] && NOTIFY=1
if [ "$(id -u)" -eq 0 ]; then
  # От root переходим к владельцу помощника: jarvis по методичке или тот, у кого есть ~/jarvis-start.
  OWNER="${JARVIS_USER:-}"
  [ -n "$OWNER" ] || { id jarvis >/dev/null 2>&1 && OWNER=jarvis; }
  [ -n "$OWNER" ] || OWNER="$(stat -c %U /home/*/jarvis-start 2>/dev/null | head -1)"
  [ -n "$OWNER" ] || die "Не нашёл пользователя, под которым живёт помощник. Запустите от его имени: sudo -iu ИМЯ ~/jarvis-start/bin/update.sh"
  exec sudo -iu "$OWNER" "$(getent passwd "$OWNER" | cut -d: -f6)/jarvis-start/bin/update.sh" "${ARGS[@]}"
fi
if [ ! -d "$HOME_DIR" ]; then
  if [ "$ADOPT" -eq 1 ]; then
    mkdir -p "$HOME_DIR/bin" && cp "$0" "$HOME_DIR/bin/update.sh" 2>/dev/null; chmod +x "$HOME_DIR/bin/update.sh" 2>/dev/null
    printf '1.0.0\n' > "$HOME_DIR/.version"
  else
    die "Не нашёл папку ${HOME_DIR}. Запускайте от имени владельца помощника: sudo -iu jarvis ~/jarvis-start/bin/update.sh
  Если помощник ставился не по методичке, подключите его к обновлениям ключом --adopt."
  fi
fi
command -v openclaw >/dev/null 2>&1 || die "Команда openclaw не найдена. Помощник установлен по методичке Джарви Старт?"

# Обновление перезапускает помощника. Если скрипт позвал сам помощник из переписки,
# он убьёт процесс, который выполняет обновление, и всё оборвётся на середине.
if [ "$FORCE" -eq 0 ] && [ "$CHECK_ONLY" -eq 0 ] && [ "$FROM_CHAT" -eq 0 ] && [ -z "${JARVIS_UPDATE_DETACHED:-}" ]; then
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
      die "Похоже, обновление запустил сам помощник без ключа --from-chat. Так оно оборвётся при перезапуске.
  Из переписки запускайте: ~/jarvis-start/bin/update.sh --from-chat"
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
    ok "Есть что обновить. Запустите без --check: ~/jarvis-start/bin/update.sh (или напишите помощнику «обнови себя»)"
  fi
  exit 0
fi

if [ "$LAYER_UPDATE" -eq 0 ] && [ "$PLATFORM_UPDATE" -eq 0 ]; then
  ok "Обновлять нечего, всё свежее"
  notify "Обновление не понадобилось: всё уже свежее (Джарви Старт ${INSTALLED}, OpenClaw ${OC_BEFORE})."
  exit 0
fi

# Запуск из переписки: сам помощник будет перезапущен, поэтому обновление уходит в отдельную
# службу systemd. Она живёт независимо от помощника, а итог присылает в Телеграм.
if [ "$FROM_CHAT" -eq 1 ] && [ -z "${JARVIS_UPDATE_DETACHED:-}" ]; then
  command -v systemd-run >/dev/null 2>&1 || die "На сервере нет systemd-run, из переписки обновиться нельзя. Запустите команду в терминале."
  UNIT_NAME="jarvis-update-$(date +%Y%m%d-%H%M%S)"
  CHILD_ARGS=()
  for a in "${ARGS[@]}"; do [ "$a" = "--from-chat" ] || CHILD_ARGS+=("$a"); done
  SETENV=(--setenv=JARVIS_UPDATE_DETACHED=1 --setenv=PATH="$PATH" --setenv=HOME="$HOME")
  [ -n "${JARVIS_UPDATE_SOURCE:-}" ] && SETENV+=(--setenv=JARVIS_UPDATE_SOURCE="$JARVIS_UPDATE_SOURCE")
  [ -n "${JARVIS_UPDATE_SIMULATE_FAIL:-}" ] && SETENV+=(--setenv=JARVIS_UPDATE_SIMULATE_FAIL="$JARVIS_UPDATE_SIMULATE_FAIL")
  [ -n "$NOTIFY_TARGET" ] && CHILD_ARGS+=(--notify-target "$NOTIFY_TARGET")
  exec 9>&-
  systemd-run --user --unit "$UNIT_NAME" --collect --quiet "${SETENV[@]}" \
    /bin/bash "$HOME_DIR/bin/update.sh" "${CHILD_ARGS[@]}" \
    || die "Не удалось запустить обновление отдельной службой."
  log "detached: ${UNIT_NAME}"
  cat <<CHAT
Обновление запущено (служба ${UNIT_NAME}).
Скажи человеку: сейчас помощник перезапустится и 5-15 минут не будет отвечать.
Итог придёт отдельным сообщением: получилось или всё возвращено как было.
Больше ничего не делай и не перезапускайся сам.
CHAT
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
  openclaw cron list --json 2>/dev/null | json_get 'd.ok !== false' >/dev/null 2>&1
}
telegram_ok() {
  openclaw channels status --probe --json 2>/dev/null \
    | json_get 'd.channels.telegram.configured === true && d.channels.telegram.probe.ok === true' >/dev/null 2>&1
}
wait_healthy() {
  for _ in $(seq 1 45); do health_ok && return 0; sleep 2; done
  return 1
}

HEALTH_BEFORE=0; TG_BEFORE=0
# Из переписки служба стартует, пока помощник ещё дописывает ответ или перезапускается: даём ему подняться.
[ -n "${JARVIS_UPDATE_DETACHED:-}" ] && { sleep 20; wait_healthy >/dev/null 2>&1 || true; }
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
    notify "Обновление не получилось, поэтому я вернул всё как было: ${reason}. Работаю на прежней версии, память и настройки на месте."
    printf '\n  Обновление не применено. Неудачное состояние сохранено в %s,\n  его можно показать специалисту. Журнал: %s\n\n' "$failed" "$LOG"
  else
    warn "После отката помощник пока не отвечает. Подождите минуту и проверьте: ~/jarvis-start/bin/doctor.sh"
    NOTIFY=0
  fi
  exit 1
}

simulate_fail() { [ "${JARVIS_UPDATE_SIMULATE_FAIL:-}" = "$1" ] && rollback "Проверочный сбой на шаге «$1»"; }

# -------------------------------------------------------------- платформа ---
PLATFORM_CHANGED=0
if [ "$PLATFORM_UPDATE" -eq 1 ]; then
  step "Обновляю платформу OpenClaw (${OC_BEFORE} → ${OC_LATEST})"
  echo "  Это займёт несколько минут. Помощник перезапустится."
  UPD_OUT="$TMP/openclaw-update.out"
  openclaw update --yes --timeout 1200 >"$UPD_OUT" 2>&1
  UPD_RC=$?
  cat "$UPD_OUT" >>"$LOG"
  # Внутри службы systemd (а режим --from-chat работает именно так) OpenClaw не обновляется сам,
  # а передаёт работу своему помощнику-процессу и сразу выходит. Конец такого обновления виден
  # только в журнале передачи: ждём строку «managed update helper completed code=N».
  HANDOFF_LOG="$(grep -oE 'Log: [^[:space:]]+handoff\.log' "$UPD_OUT" | head -1 | sed 's/^Log: //')"
  if [ -n "$HANDOFF_LOG" ]; then
    echo "  OpenClaw обновляется в фоне, жду окончания (до 30 минут)..."
    log "handoff: ${HANDOFF_LOG}"
    UPD_RC=""
    for _ in $(seq 1 360); do
      UPD_RC="$(grep -oE 'managed update helper completed code=[0-9]+' "$HANDOFF_LOG" 2>/dev/null | tail -1 | grep -oE '[0-9]+$')"
      [ -n "$UPD_RC" ] && break
      sleep 5
    done
    tail -20 "$HANDOFF_LOG" >>"$LOG" 2>/dev/null || true
    [ -n "$UPD_RC" ] || rollback "Обновление OpenClaw не закончилось за 30 минут"
  fi
  OC_AFTER="$(oc_version)"
  if [ "$UPD_RC" = "0" ] && [ -n "$OC_AFTER" ]; then
    [ "$OC_AFTER" != "$OC_BEFORE" ] && PLATFORM_CHANGED=1
    ok "OpenClaw ${OC_AFTER}"
  else
    rollback "Штатное обновление OpenClaw завершилось ошибкой (код ${UPD_RC:-?})"
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
notify "Обновление завершено, всё работает.
Джарви Старт: $( [ "$LAYER_UPDATE" -eq 1 ] && echo "${INSTALLED} → ${TARGET}" || echo "${INSTALLED}, без изменений" )
Платформа OpenClaw: $( [ "$PLATFORM_CHANGED" -eq 1 ] && echo "${OC_BEFORE} → $(oc_version)" || echo "$(oc_version), без изменений" )
Копия на всякий случай сохранена на сервере."

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
