#!/usr/bin/env bash
# Джарви Старт: ежедневная проверка обновлений (задача jarvis-update-check).
#
# Запускается планировщиком OpenClaw как «команда», без модели, то есть не тратит подписку.
# Что напечатает, то OpenClaw отправит владельцу в Телеграм. Нечего сказать - печатает NO_REPLY,
# и задача проходит молча. Сама ничего не обновляет, только сообщает и предлагает.
#
# Правила, чтобы не надоедать:
#   - о новом выпуске Джарви Старт сообщает один раз на версию;
#   - если вышла только новая платформа OpenClaw, сообщает не чаще раза в 7 дней;
#   - при любой ошибке сети молчит (NO_REPLY): завтра проверит снова.
#
# Для проверки на стенде: JARVIS_CHECK_LATEST=1.3.0 и JARVIS_CHECK_CHANGELOG=<файл> подменяют GitHub,
# JARVIS_CHECK_OC_LATEST=<версия> подменяет npm.

set -uo pipefail
REPO="${JARVIS_REPO:-kotov67/jarvis-start}"
HOME_DIR="${HOME}/jarvis-start"
STATE="${HOME_DIR}/.update-notified"
PLATFORM_EVERY_DAYS=7

export PATH="${HOME}/.npm-global/bin:/usr/local/bin:${PATH}"
if OC_REAL="$(readlink -f "$(command -v openclaw 2>/dev/null)" 2>/dev/null)" && [ -n "$OC_REAL" ]; then
  case "$OC_REAL" in
    */lib/node_modules/openclaw/*) export PATH="${OC_REAL%%/lib/node_modules/openclaw/*}/bin:${PATH}" ;;
  esac
fi

quiet() { echo "NO_REPLY"; exit 0; }
ver_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

INSTALLED="$(cat "${HOME_DIR}/.version" 2>/dev/null | tr -d ' \n\r')"
INSTALLED="${INSTALLED:-1.0.0}"

LATEST="${JARVIS_CHECK_LATEST:-}"
if [ -z "$LATEST" ]; then
  LATEST="$(curl -fsSL --max-time 20 "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
    | grep -oE '"tag_name": *"[^"]+"' | head -1 | sed -E 's/.*"v?([^"]+)"$/\1/')"
  if [ -z "$LATEST" ]; then
    LATEST="$(curl -fsSI --max-time 20 "https://github.com/${REPO}/releases/latest" 2>/dev/null \
      | grep -i '^location:' | sed -E 's#.*/tag/v?([^[:space:]]+).*#\1#' | tr -d '\r')"
  fi
fi

OC_NOW="$(openclaw --version 2>/dev/null | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+(-[a-z0-9.]+)?' | head -1)"
OC_LATEST="${JARVIS_CHECK_OC_LATEST:-$(npm view openclaw version 2>/dev/null | tr -d ' \n\r')}"

LAYER_NEW=0; PLATFORM_NEW=0
[ -n "$LATEST" ] && ver_gt "$LATEST" "$INSTALLED" && LAYER_NEW=1
[ -n "$OC_LATEST" ] && [ -n "$OC_NOW" ] && ver_gt "$OC_LATEST" "$OC_NOW" && PLATFORM_NEW=1
[ "$LAYER_NEW" -eq 1 ] || [ "$PLATFORM_NEW" -eq 1 ] || quiet

# Что уже сообщали: строка «слой платформа время».
LAST_LAYER=""; LAST_PLATFORM=""; LAST_TS=0
if [ -f "$STATE" ]; then
  read -r LAST_LAYER LAST_PLATFORM LAST_TS < "$STATE" || true
fi
NOW_TS="$(date +%s)"
SINCE_LAST=$(( NOW_TS - ${LAST_TS:-0} ))
WEEK=$(( PLATFORM_EVERY_DAYS * 86400 ))
if [ "$LAYER_NEW" -eq 1 ] && [ "$LAST_LAYER" != "$LATEST" ]; then
  :   # новый выпуск Джарви Старт, о нём ещё не сообщали
elif [ "$PLATFORM_NEW" -eq 1 ] && [ "$LAST_PLATFORM" != "$OC_LATEST" ] && [ "$SINCE_LAST" -ge "$WEEK" ]; then
  :   # новая платформа, о ней не сообщали, и с прошлого сообщения прошла неделя
else
  quiet
fi

# Выдержка из журнала изменений: разделы новее установленной версии.
NOTES=""
if [ "$LAYER_NEW" -eq 1 ]; then
  if [ -n "${JARVIS_CHECK_CHANGELOG:-}" ]; then
    CHANGELOG="$(cat "$JARVIS_CHECK_CHANGELOG" 2>/dev/null)"
  else
    CHANGELOG="$(curl -fsSL --max-time 20 "https://raw.githubusercontent.com/${REPO}/v${LATEST}/CHANGELOG.md" 2>/dev/null)"
  fi
  NOTES="$(printf '%s\n' "$CHANGELOG" | awk -v from="$INSTALLED" '
    /^## / { v = $2; if (v == from) exit; show = 1; next }
    show && /^- / { sub(/^- /, "• "); print; next }
    show && /^  [^ ]/ { sub(/^  /, "  "); print }
  ' | head -25)"
fi

# Сначала запоминаем, о чём сообщили, потом печатаем: если вывод оборвётся, повтора не будет.
printf '%s %s %s\n' "${LATEST:-$INSTALLED}" "${OC_LATEST:-$OC_NOW}" "$NOW_TS" > "$STATE"

{
  echo "Вышло обновление для меня."
  echo
  [ "$LAYER_NEW" -eq 1 ] && echo "Джарви Старт: ${INSTALLED} → ${LATEST}"
  [ "$PLATFORM_NEW" -eq 1 ] && echo "Платформа OpenClaw: ${OC_NOW} → ${OC_LATEST}"
  if [ -n "$NOTES" ]; then
    echo
    echo "Что нового:"
    printf '%s\n' "$NOTES"
  fi
  echo
  echo "Чтобы обновиться, напишите мне «обнови себя». Я сделаю копию, обновлюсь и пришлю итог,"
  echo "на это время замолчу на 5-15 минут. Если что-то пойдёт не так, верну всё как было."
}

exit 0
