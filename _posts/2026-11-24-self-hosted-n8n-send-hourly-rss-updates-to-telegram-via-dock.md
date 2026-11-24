---
layout: post
title: 'Self-Hosted n8n: Send Hourly RSS Updates to Telegram via Docker'
description: Run n8n in Docker on a VPS and push the newest RSS item to your Telegram
  bot every hour. The workflow stays active after restarts and reboots.
tags:
- n8n
- docker
- telegram
- selfhosted
date: 2026-11-24 18:00:29 +0000
---

Keeping up with a news source usually means opening a tab and hoping you remember to check it. RSS fixes part of that, but feed readers are one more app to open. A message in Telegram, on the other hand, shows up where you already spend your time.

In this article we build a small automation with n8n running in Docker on your own VPS. Every hour it reads an RSS feed and sends the newest item to your Telegram bot. Self-hosting keeps your bot token and workflow data on a server you control, avoids per-execution pricing, and the whole setup comes back on its own after a restart.

<iframe width="100%" style="aspect-ratio:16/9" src="https://www.youtube-nocookie.com/embed/TcWDB3SamQQ" title="Video tutorial" frameborder="0" allowfullscreen></iframe>

## What you need

- A VPS with Ubuntu 24.04 (2 vCPU / 4 GB RAM is plenty). I use [VDSina](https://www.vdsina.com/?partner=xuevxsn1ece5) *(affiliate link — it supports the channel at no extra cost to you)*.
- An SSH connection to it (any terminal works).

> Short on time? Every command below is also in [one ready-to-run script](https://github.com/lamplightservers/lamplightservers.github.io/blob/main/scripts/self-hosted-n8n-send-hourly-rss-updates-to-telegram-via-dock/install.sh).

## Step 1: Update the system

Refresh the package list and install the latest patches in non-interactive mode, so no prompts block the process. A fresh server should always start from an up-to-date state, which avoids odd problems later.

```bash
apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
```

## Step 2: Install Docker

Install Docker using the official convenience script. It sets up the Docker engine and a service that starts on boot, which our restart test relies on at the end.

```bash
curl -fsSL https://get.docker.com | sh
```

## Step 3: Save Telegram bot settings

Store your Telegram bot token (from BotFather) and your chat ID in a separate env file, replacing the placeholders with real values. This keeps secrets out of the workflow itself, and restricting the file to root with chmod 600 means no other user on the server can read it.

```bash
mkdir -p /opt/n8n
cat > /opt/n8n/.env <<'EOF'
TELEGRAM_BOT_TOKEN=123456:REPLACE_WITH_BOTFATHER_TOKEN
TELEGRAM_CHAT_ID=123456789
EOF
chmod 600 /opt/n8n/.env
```

## Step 4: Run n8n in Docker

Start n8n as a container with a restart policy that brings it back unless you stop it manually. It is bound to localhost only, so it is not exposed to the internet, and its data lives in a Docker volume that survives container recreation. The env file is passed in and workflows are allowed to read those variables.

```bash
docker run -d --name n8n --restart unless-stopped \
  -p 127.0.0.1:5678:5678 \
  -v n8n_data:/home/node/.n8n \
  --env-file /opt/n8n/.env \
  -e N8N_BLOCK_ENV_ACCESS_IN_NODE=false \
  -e N8N_SECURE_COOKIE=false \
  -e GENERIC_TIMEZONE=UTC \
  docker.n8n.io/n8nio/n8n
```

## Step 5: Create the workflow file

Write the workflow as a JSON file with four nodes: an hourly schedule, an RSS reader, a limit that keeps only the newest item, and an HTTP request that calls the Telegram API. The example uses Hacker News posts with over a hundred points, but any feed URL works.

```bash
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
```

## Step 6: Import the workflow

Copy the JSON file into the container and import it with n8n's command line tool, so you never need to click through the web interface. The import creates the workflow, but it stays switched off.

```bash
docker cp /opt/n8n/workflow.json n8n:/tmp/workflow.json
docker exec n8n n8n import:workflow --input=/tmp/workflow.json
```

## Step 7: Activate the workflow

Activate the workflow by its ID using the CLI, then restart n8n. The running instance only picks up the activation after a restart. After that, the schedule runs by itself.

```bash
docker exec n8n n8n update:workflow --id=tgrss1 --active=true
docker restart n8n
```

## Step 8: Test the workflow once

Run the workflow once on demand instead of waiting an hour, and look at the last lines of the output. If everything is right, the newest feed item arrives as a message from your bot in Telegram.

```bash
docker exec n8n n8n execute --id=tgrss1 2>&1 | tail -n 15 || true
```

## Step 9: Restart Docker and verify

Restart Docker itself to simulate a reboot or crash. Thanks to the restart policy, the n8n container should come back automatically with the workflow still active, which proves the setup is durable.

```bash
systemctl restart docker
```

## Common mistakes

- Forgetting to restart n8n after activating the workflow via the CLI. The change is not picked up by the running instance, so the schedule silently never fires. Always restart the container after activation.
- Leaving placeholder values or typos in the Telegram env file, such as a wrong chat ID or a token with stray spaces. The workflow then runs but no message arrives. Double-check the values and message your bot first, since it cannot write to you until you have started a chat with it.
- Exposing n8n directly on a public port to reach the editor. Binding to localhost is deliberate; if you need remote access, use an SSH tunnel or a reverse proxy with HTTPS and authentication.

## Wrap-up

Now that the basic pipeline works, try swapping in other feeds, filtering items by keyword, or sending to several chats. You can also add a reverse proxy with HTTPS if you want to edit workflows from a browser, and set up regular backups of the Docker volume so your workflows are safe.

Every command here was tested on a fresh Ubuntu 24.04 server before publishing. Watch the full walkthrough on [YouTube](https://youtu.be/TcWDB3SamQQ) — new tutorials every week on **Lamplight Servers**.
