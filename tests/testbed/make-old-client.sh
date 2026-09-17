#!/usr/bin/env bash
export PATH="$HOME/.npm-global/bin:$PATH"
openclaw gateway stop >/dev/null 2>&1
systemctl --user disable openclaw-gateway.service >/dev/null 2>&1
rm -rf "$HOME/.openclaw" "$HOME/jarvis-backups" "$HOME"/jarvis-failed-update-*
openclaw --version
openclaw onboard --non-interactive --accept-risk --mode local --auth-choice skip --gateway-bind loopback --gateway-auth password --gateway-password testpass12345 --install-daemon --daemon-runtime node --skip-channels --skip-search --skip-hooks --skip-ui --skip-skills > /tmp/onboard93.log 2>&1; echo "onboard=$?"
WS="$HOME/.openclaw/workspace"
for f in SOUL.md AGENTS.md USER.md IDENTITY.md MEMORY.md TOOLS.md; do
  sed -e "s/{{AGENT_NAME}}/Тест/g" -e "s/{{OWNER_NAME}}/Андрей/g" -e "s#{{TZ}}#Asia/Yekaterinburg#g" -e "s/{{TODAY}}/2026-09-01/g" -e "s/{{DOMAIN}}/test.example/g" "$HOME/jarvis-start/templates/$f" > "$WS/$f"
done
printf '\n## Моё правило\n\nВсегда здороваться по имени. ЛИЧНОЕ-ПРАВИЛО-123\n' >> "$WS/AGENTS.md"
printf '\n- Андрей любит гитару. ЛИЧНАЯ-ПАМЯТЬ-456\n' >> "$WS/MEMORY.md"
rm -f "$HOME/jarvis-start/.version"
for i in $(seq 1 40); do openclaw health >/dev/null 2>&1 && break; sleep 2; done
openclaw health >/dev/null 2>&1; echo "health=$?"
openclaw cron add --name test-reminder --cron "0 9 * * *" --message "Тестовое напоминание" --session isolated >/dev/null 2>&1; echo "cron_add=$?"
openclaw cron list 2>/dev/null | grep -c test-reminder
md5sum "$WS"/*.md
