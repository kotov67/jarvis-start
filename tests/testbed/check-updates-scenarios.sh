#!/usr/bin/env bash
# Сценарии для bin/check-updates.sh (от владельца помощника на стенде). Файл журнала для теста: $1.
C=~/jarvis-start/bin/check-updates.sh; S=~/jarvis-start/.update-notified; CL="${1:-/tmp/cl-test.md}"
INST="$(cat ~/jarvis-start/.version)"; rm -f "$S"
echo "1) настоящий GitHub, установлено ${INST}: $($C | grep -c "Платформа OpenClaw")"
echo "2) вышел 1.9.0:"; JARVIS_CHECK_LATEST=1.9.0 JARVIS_CHECK_CHANGELOG="$CL" JARVIS_CHECK_OC_LATEST=2026.9.4 $C
echo "3) снова 1.9.0: $(JARVIS_CHECK_LATEST=1.9.0 JARVIS_CHECK_CHANGELOG="$CL" JARVIS_CHECK_OC_LATEST=2026.9.4 $C)"
rm -f "$S"
echo "4) только платформа, первый раз:"; JARVIS_CHECK_LATEST="$INST" JARVIS_CHECK_OC_LATEST=2026.9.9 $C | grep -c "Платформа OpenClaw"
echo "5) новая платформа на следующий день: $(JARVIS_CHECK_LATEST="$INST" JARVIS_CHECK_OC_LATEST=2026.9.10 $C)"
read -r L P T < "$S"; echo "$L $P $(( T - 8*86400 ))" > "$S"
echo "6) та же платформа через 8 дней: $(JARVIS_CHECK_LATEST="$INST" JARVIS_CHECK_OC_LATEST=2026.9.9 $C)"
echo "7) новая платформа через 8 дней: $(JARVIS_CHECK_LATEST="$INST" JARVIS_CHECK_OC_LATEST=2026.9.10 $C | grep -c "Платформа OpenClaw")"
echo "8) GitHub недоступен и платформа свежая: $(JARVIS_REPO=kotov67/nonexistent-repo-xyz JARVIS_CHECK_OC_LATEST=2026.9.4 $C)"
rm -f "$S"
