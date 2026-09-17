#!/usr/bin/env bash
export PATH="$HOME/.npm-global/bin:$PATH"
WS="$HOME/.openclaw/workspace"
echo "openclaw=$(openclaw --version)"
openclaw health >/dev/null 2>&1; echo "health=$?"
echo "service=$(systemctl --user is-active openclaw-gateway.service)"
echo "cron_test_reminder=$(openclaw cron list 2>/dev/null | grep -c test-reminder)"
echo "version_file=$(cat ~/jarvis-start/.version 2>/dev/null || echo нет)"
echo "personal_rule=$(grep -c ЛИЧНОЕ-ПРАВИЛО-123 $WS/AGENTS.md) personal_memory=$(grep -c ЛИЧНАЯ-ПАМЯТЬ-456 $WS/MEMORY.md)"
echo "managed_blocks=$(grep -c 'jarvis-start:managed:begin' $WS/AGENTS.md)"
md5sum "$WS"/*.md
ls ~/jarvis-start ~/jarvis-start/bin ~/jarvis-backups 2>/dev/null | tr '\n' ' '; echo
