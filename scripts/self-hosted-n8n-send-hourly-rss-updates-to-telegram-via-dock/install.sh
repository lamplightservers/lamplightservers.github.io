#!/usr/bin/env bash
# Hourly RSS Alerts to Telegram with n8n on Your Own VPS
# Video: https://youtu.be/TcWDB3SamQQ
# Tested on a fresh Ubuntu 24.04 server. Run as root: bash install.sh
set -euo pipefail

echo '==> Step 1: Update the system'
apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

echo '==> Step 2: Install Docker'
curl -fsSL https://get.docker.com | sh

echo '==> Step 3: Save Telegram bot settings'
mkdir -p /opt/n8n
cat > /opt/n8n/.env <<'EOF'
TELEGRAM_BOT_TOKEN=123456:REPLACE_WITH_BOTFATHER_TOKEN
TELEGRAM_CHAT_ID=123456789
EOF
chmod 600 /opt/n8n/.env

echo '==> Step 4: Run n8n in Docker'
docker run -d --name n8n --restart unless-stopped \
  -p 127.0.0.1:5678:5678 \
  -v n8n_data:/home/node/.n8n \
  --env-file /opt/n8n/.env \
  -e N8N_BLOCK_ENV_ACCESS_IN_NODE=false \
  -e N8N_SECURE_COOKIE=false \
  -e GENERIC_TIMEZONE=UTC \
  docker.n8n.io/n8nio/n8n

echo '==> Step 5: Create the workflow file'
cat > /opt/n8n/workflow.json <<'EOF'
{
  "id": "tgrss1",
  "name": "Telegram RSS Alert",
  "active": false,
  "nodes": [
    {
      "id": "a1", "name": "Every Hour",
      "type": "n8n-nodes-base.scheduleTrigger", "typeVersion": 1.2,
      "position": [0, 0],
      "parameters": { "rule": { "interval": [ { "field": "hours", "hoursInterval": 1 } ] } }
    },
    {
      "id": "a2", "name": "Read RSS",
      "type": "n8n-nodes-base.rssFeedRead", "typeVersion": 1,
      "position": [220, 0],
      "parameters": { "url": "https://hnrss.org/newest?points=100" }
    },
    {
      "id": "a3", "name": "Newest Only",
      "type": "n8n-nodes-base.limit", "typeVersion": 1,
      "position": [440, 0],
      "parameters": { "maxItems": 1 }
    },
    {
      "id": "a4", "name": "Send to Telegram",
      "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.2,
      "position": [660, 0],
      "parameters": {
        "method": "POST",
        "url": "=https://api.telegram.org/bot{{ $env.TELEGRAM_BOT_TOKEN }}/sendMessage",
        "sendBody": true,
        "bodyParameters": { "parameters": [
          { "name": "chat_id", "value": "={{ $env.TELEGRAM_CHAT_ID }}" },
          { "name": "text", "value": "={{ $json.title }} {{ $json.link }}" }
        ] }
      }
    }
  ],
  "connections": {
    "Every Hour": { "main": [ [ { "node": "Read RSS", "type": "main", "index": 0 } ] ] },
    "Read RSS": { "main": [ [ { "node": "Newest Only", "type": "main", "index": 0 } ] ] },
    "Newest Only": { "main": [ [ { "node": "Send to Telegram", "type": "main", "index": 0 } ] ] }
  },
  "settings": {}
}
EOF

echo '==> Step 6: Import the workflow'
docker cp /opt/n8n/workflow.json n8n:/tmp/workflow.json
docker exec n8n n8n import:workflow --input=/tmp/workflow.json

echo '==> Step 7: Activate the workflow'
docker exec n8n n8n update:workflow --id=tgrss1 --active=true
docker restart n8n

echo '==> Step 8: Test the workflow once'
docker exec n8n n8n execute --id=tgrss1 2>&1 | tail -n 15 || true

echo '==> Step 9: Restart Docker and verify'
systemctl restart docker
