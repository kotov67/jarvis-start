#!/usr/bin/env bash
# Джарви Старт: «управляемые блоки» в файлах помощника.
#
# Файлы помощника (AGENTS.md и другие) принадлежат владельцу: помощник и человек дописывают
# туда своё. Поэтому обновление никогда не перезаписывает их целиком. Всё, что выпускаем мы,
# живёт внутри одного блока между метками:
#
#   <!-- jarvis-start:managed:begin -->
#   ...
#   <!-- jarvis-start:managed:end -->
#
# Меток нет (старая установка) - блок дописывается в конец файла. Метки есть - заменяется
# только текст между ними, всё остальное в файле остаётся как было.
#
# Использование (подключается из setup.sh и update.sh):
#   . managed.sh
#   jarvis_apply_managed <папка managed из выпуска> <папка workspace помощника>

JARVIS_MANAGED_BEGIN='<!-- jarvis-start:managed:begin -->'
JARVIS_MANAGED_END='<!-- jarvis-start:managed:end -->'

# jarvis_apply_managed_file <файл-источник блока> <целевой файл>
# Код возврата: 0 - применено или уже совпадало, 1 - ошибка.
jarvis_apply_managed_file() {
  local src="$1" dst="$2" tmp block
  [ -f "$src" ] || return 0
  [ -f "$dst" ] || { printf 'нет файла %s, пропускаю\n' "$dst" >&2; return 0; }

  block="$(mktemp)"
  {
    printf '%s\n' "$JARVIS_MANAGED_BEGIN"
    cat "$src"
    printf '%s\n' "$JARVIS_MANAGED_END"
  } > "$block"

  tmp="$(mktemp)"
  if grep -qxF "$JARVIS_MANAGED_BEGIN" "$dst" && grep -qxF "$JARVIS_MANAGED_END" "$dst"; then
    # Заменяем содержимое между метками, не трогая остальное.
    awk -v begin="$JARVIS_MANAGED_BEGIN" -v end="$JARVIS_MANAGED_END" -v blockfile="$block" '
      $0 == begin { while ((getline line < blockfile) > 0) print line; close(blockfile); skip = 1; next }
      $0 == end   { skip = 0; next }
      !skip       { print }
    ' "$dst" > "$tmp" || { rm -f "$tmp" "$block"; return 1; }
  else
    { cat "$dst"; printf '\n'; cat "$block"; } > "$tmp"
  fi

  if cmp -s "$tmp" "$dst"; then
    rm -f "$tmp" "$block"
    return 0
  fi
  # Пишем поверх содержимого, а не подменяем файл: сохраняются права и владелец.
  cat "$tmp" > "$dst" || { rm -f "$tmp" "$block"; return 1; }
  rm -f "$tmp" "$block"
  return 0
}

# jarvis_apply_managed <managed-dir> <workspace>
jarvis_apply_managed() {
  local dir="$1" ws="$2" src name rc=0
  [ -d "$dir" ] || return 0
  for src in "$dir"/*.md; do
    [ -f "$src" ] || continue
    name="$(basename "$src")"
    jarvis_apply_managed_file "$src" "$ws/$name" || rc=1
  done
  return "$rc"
}
