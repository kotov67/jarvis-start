#!/usr/bin/env bash
# Помощник «не по методичке», как ставили вручную до установщика: пользователь smith, Node через nvm,
# без jq, без ~/jarvis-start. Запускать от root внутри стенда: make-nvm-client.sh [версия OpenClaw]
set -e
OC="${1:-2026.9.3}"
HERE="$(cd "$(dirname "$0")" && pwd)"
id smith >/dev/null 2>&1 || adduser --disabled-password --gecos "" smith >/dev/null
echo "smith ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-smith
loginctl enable-linger smith
apt-get remove -y -qq jq >/dev/null 2>&1 || true
install -m 755 "$HERE/make-nvm-client-user.sh" /tmp/make-nvm-client-user.sh
sudo -iu smith /tmp/make-nvm-client-user.sh "$OC"
