#!/usr/bin/env bash
# Часть make-nvm-client.sh, которая выполняется от smith.
OC="$1"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash >/dev/null 2>&1
. "$HOME/.nvm/nvm.sh"
nvm install 24 >/dev/null 2>&1
npm install -g "openclaw@${OC}" >/dev/null 2>&1
for b in node npm openclaw; do sudo ln -sf "$(command -v "$b")" "/usr/local/bin/$b"; done
openclaw onboard --non-interactive --accept-risk --mode local --auth-choice skip --gateway-bind loopback \
  --gateway-auth password --gateway-password testpass12345 --install-daemon --daemon-runtime node \
  --skip-channels --skip-search --skip-hooks --skip-ui --skip-skills >/tmp/onboard-smith.log 2>&1
echo "onboard=$?"
openclaw config set commands.ownerAllowFrom '["telegram:1111111"]' --strict-json >/dev/null
printf '\n## Моё правило\n\nЛИЧНОЕ-ПРАВИЛО-123\n' >> "$HOME/.openclaw/workspace/AGENTS.md"
for i in $(seq 1 40); do openclaw health >/dev/null 2>&1 && break; sleep 2; done
openclaw cron add --name test-reminder --cron '0 9 * * *' --message 'Тест' --session isolated >/dev/null; echo "cron=$?"
openclaw --version; readlink -f /usr/local/bin/openclaw; command -v jq || echo "jq нет"
