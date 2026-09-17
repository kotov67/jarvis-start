#!/usr/bin/env bash
# От jarvis на стенде после install.sh старой методички: помощник на OpenClaw $1 без входа в Claude,
# шаблоны личности и подтверждённый собеседник 2222222 в хранилище pairing (как после setup.sh).
OC="${1:-2026.9.3}"
export PATH="$HOME/.npm-global/bin:$PATH" XDG_RUNTIME_DIR="/run/user/$(id -u)"
npm install -g "openclaw@${OC}" >/dev/null 2>&1
openclaw onboard --non-interactive --accept-risk --mode local --auth-choice skip --gateway-bind loopback \
  --gateway-auth password --gateway-password testpass12345 --install-daemon --daemon-runtime node \
  --skip-channels --skip-search --skip-hooks --skip-ui --skip-skills >/tmp/onboard-old.log 2>&1; echo "onboard=$?"
WS="$HOME/.openclaw/workspace"
for f in SOUL.md AGENTS.md USER.md IDENTITY.md MEMORY.md TOOLS.md; do
  sed -e "s/{{AGENT_NAME}}/Дима-тест/g" -e "s/{{OWNER_NAME}}/Дима/g" -e "s#{{TZ}}#Europe/Moscow#g" -e "s/{{TODAY}}/2026-08-21/g" -e "s/{{DOMAIN}}/test.example/g" "$HOME/jarvis-start/templates/$f" > "$WS/$f"
done
printf '\n## Моё правило\n\nЛИЧНОЕ-ПРАВИЛО-123\n' >> "$WS/AGENTS.md"
for i in $(seq 1 40); do openclaw health >/dev/null 2>&1 && break; sleep 2; done
openclaw gateway stop >/dev/null 2>&1; systemctl --user stop openclaw-gateway.service
node -e 'const {DatabaseSync}=require("node:sqlite");const db=new DatabaseSync(process.argv[1]);db.prepare("insert or ignore into channel_pairing_allow_entries(channel_key,account_id,entry,sort_order,updated_at) values(?,?,?,?,?)").run("telegram","default","2222222",0,Date.now());console.log("pairing entries:",db.prepare("select count(*) c from channel_pairing_allow_entries").get().c)' "$HOME/.openclaw/state/openclaw.sqlite"
systemctl --user start openclaw-gateway.service
for i in $(seq 1 40); do openclaw health >/dev/null 2>&1 && break; sleep 2; done
openclaw health >/dev/null 2>&1; echo "health=$?"; openclaw --version
ls -a ~/jarvis-start
