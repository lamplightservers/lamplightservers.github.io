#!/usr/bin/env bash
# Self-Host n8n with Docker on Your Own VPS (5 Minutes)
# Video: https://youtu.be/k5du4Mumgqo
# Tested on a fresh Ubuntu 24.04 server. Run as root: bash install.sh
set -euo pipefail

echo '==> Step 1: Install Docker'
curl -fsSL https://get.docker.com | DEBIAN_FRONTEND=noninteractive sh

echo '==> Step 2: Enable the firewall'
ufw allow 22/tcp && ufw --force enable

echo '==> Step 3: Generate encryption key'
mkdir -p /opt/n8n
echo "N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)" > /opt/n8n/.env
chmod 600 /opt/n8n/.env

echo '==> Step 4: Create compose file'
cat > /opt/n8n/compose.yaml <<'EOF'
services:
  n8n:
    image: docker.n8n.io/n8nio/n8n:latest
    restart: unless-stopped
    ports:
      - "127.0.0.1:5678:5678"
    environment:
      - N8N_HOST=localhost
      - N8N_PORT=5678
      - N8N_PROTOCOL=http
      - N8N_SECURE_COOKIE=false
      - GENERIC_TIMEZONE=UTC
      - TZ=UTC
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
    volumes:
      - n8n_data:/home/node/.n8n
volumes:
  n8n_data:
EOF

echo '==> Step 5: Start n8n'
docker compose -f /opt/n8n/compose.yaml up -d

echo '==> Step 6: Wait for n8n'
docker compose -f /opt/n8n/compose.yaml logs --tail 5 n8n

echo '==> Step 7: Test the web interface'
curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:5678/
