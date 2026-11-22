---
layout: post
title: Build a Private Telegram AI Bot with Ollama and Docker on a VPS
description: Run a private Telegram bot on your VPS with a tiny local Ollama model
  in Docker. It chats, summarizes server logs, and replies only to you.
tags:
- selfhosted
- docker
- telegram
- ai
date: 2026-11-22 06:48:40 +0000
---

Cloud AI chatbots are convenient, but every message you send goes to someone else's servers. A public Telegram bot is also open to anyone who finds its username, which is a problem if it can read your server logs. You want a small assistant that lives on your own machine and answers only you.

In this guide we build exactly that: a Telegram bot running in Docker on your VPS. It talks to a tiny local Ollama model, summarizes a server log on request, and ignores everyone except your Telegram ID. Self-hosting keeps your prompts and logs on your own server, costs nothing per request, and needs no GPU.

<iframe width="100%" style="aspect-ratio:16/9" src="https://www.youtube-nocookie.com/embed/HSN-1vuK4Dc" title="Video tutorial" frameborder="0" allowfullscreen></iframe>

## What you need

- A VPS with Ubuntu 24.04 (2 vCPU / 4 GB RAM is plenty). I use [VDSina](https://www.vdsina.com/?partner=xuevxsn1ece5) *(affiliate link — it supports the channel at no extra cost to you)*.
- An SSH connection to it (any terminal works).

> Short on time? Every command below is also in [one ready-to-run script](https://github.com/lamplightservers/lamplightservers.github.io/blob/main/scripts/build-a-private-telegram-ai-bot-with-ollama-and-docker-on-a-/install.sh).

## Step 1: Update the system

Updating the system refreshes the package list and installs pending upgrades. Starting from a current base avoids odd dependency problems later, and it can take a minute.

```bash
apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
```

## Step 2: Install Docker

Docker is installed with the official script, which handles the whole setup at once. The bot will run in a container, so it stays isolated from the rest of the server and is easy to restart or remove.

```bash
curl -fsSL https://get.docker.com | sh
```

## Step 3: Install Ollama

Ollama is the tool that runs language models locally. We install zstd first because the installer needs it to unpack its files, then run the official script. By default Ollama listens only on the server itself, so it isn't exposed to the internet.

```bash
DEBIAN_FRONTEND=noninteractive apt-get install -y zstd && curl -fsSL https://ollama.com/install.sh | sh
```

## Step 4: Pull a tiny model

We pull Qwen 2.5 at 0.5 billion parameters. It is small enough to run on a modest VPS without a GPU. It won't be brilliant, but it handles short questions and quick summaries well.

```bash
ollama pull qwen2.5:0.5b
```

## Step 5: Create the bot in BotFather

We create a folder for the bot, then do the Telegram setup on your phone. BotFather creates the bot and gives you a token, and userinfobot tells you your numeric Telegram ID. You need both to lock the bot to yourself.

```bash
mkdir -p /opt/tgbot
echo "On your phone: open Telegram, message @BotFather, send /newbot, pick a name and a username ending in 'bot'."
echo "Copy the token it gives you. Then message @userinfobot to get your numeric Telegram ID."
```

## Step 6: Save token and owner ID

The token and your ID go into a small env file, replacing the two placeholders with your real values. We then restrict the file so only root can read it. The token controls your bot, so treat it like a password.

```bash
BOT_TOKEN="123456789:PASTE_TOKEN_FROM_BOTFATHER"
OWNER_ID="123456789"
cat > /opt/tgbot/.env <<EOF
BOT_TOKEN=${BOT_TOKEN}
ALLOWED_ID=${OWNER_ID}
OLLAMA_URL=http://127.0.0.1:11434
MODEL=qwen2.5:0.5b
EOF
sed -i 's/^[[:space:]]*//' /opt/tgbot/.env
chmod 600 /opt/tgbot/.env
```

## Step 7: Write the bot code

The bot is a short Python script with no extra libraries. It polls Telegram for new messages and checks each sender's ID, ignoring anyone who isn't you. Your text is sent to Ollama and the reply is returned, and the /logs command summarizes the last lines of a log file.

```bash
cat > /opt/tgbot/bot.py <<'EOF'
import os, time, json, urllib.request

TOKEN = os.environ["BOT_TOKEN"]
OWNER = int(os.environ["ALLOWED_ID"])
OLLAMA = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
MODEL = os.environ.get("MODEL", "qwen2.5:0.5b")
API = f"https://api.telegram.org/bot{TOKEN}/"

def call(url, data=None, timeout=60):
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)

def ask(prompt):
    r = call(OLLAMA + "/api/generate",
             {"model": MODEL, "prompt": prompt, "stream": False,
              "options": {"num_predict": 150}}, 300)
    return r["response"].strip() or "(empty answer)"

def send(chat, text):
    call(API + "sendMessage", {"chat_id": chat, "text": text[:4000]})

def handle(chat, text):
    if text.strip() == "/logs":
        with open("/host/dpkg.log") as f:
            tail = "".join(f.readlines()[-15:])[-1200:]
        send(chat, ask("Summarize this log in 2 short sentences:\n" + tail))
    elif text.strip() == "/start":
        send(chat, "Hi! Send a short question, or /logs for a log summary.")
    else:
        send(chat, ask(text[:500]))

print(f"Bot started, owner id {OWNER}, model {MODEL}", flush=True)
offset = 0
while True:
    try:
        upd = call(API + f"getUpdates?timeout=25&offset={offset}", None, 40)
        for u in upd.get("result", []):
            offset = u["update_id"] + 1
            m = u.get("message")
            if not m or "text" not in m:
                continue
            uid = m["from"]["id"]
            if uid != OWNER:
                print(f"Ignored message from id {uid}", flush=True)
                continue
            print("Owner message received", flush=True)
            try:
                handle(m["chat"]["id"], m["text"])
            except Exception as e:
                print("Handler error:", e, flush=True)
                send(m["chat"]["id"], "Error, check server logs.")
    except Exception as e:
        print("Polling error:", e, flush=True)
        time.sleep(10)
EOF
```

## Step 8: Start the bot container

The container uses the standard Python image, mounts the script read-only, and receives the env file. Host networking lets it reach Ollama on the server, and the restart policy brings it back after a reboot. We also create the log file beforehand so the mount works.

```bash
touch /var/log/dpkg.log
docker rm -f tgbot 2>/dev/null || true
docker run -d --name tgbot --restart unless-stopped --network host \
  --env-file /opt/tgbot/.env \
  -v /opt/tgbot/bot.py:/app/bot.py:ro \
  -v /var/log/dpkg.log:/host/dpkg.log:ro \
  python:3.12-slim python -u /app/bot.py
```

## Step 9: Test chat and log summary

On your phone, send /start, ask a simple question like what Docker is, then try /logs. The first reply can be slow while the model loads into memory. The curl check queries Ollama directly, helping you tell model problems from bot problems.

```bash
echo "On your phone, open your bot, send: /start, then: What is Docker in one sentence?, then: /logs"
curl -s http://127.0.0.1:11434/api/generate -d '{"model":"qwen2.5:0.5b","prompt":"Say hello in five words.","stream":false,"options":{"num_predict":30}}'
```

## Step 10: View bot logs

The container logs show when the bot started, when your messages arrived, and any errors. If a stranger messages the bot, their ID appears there marked as ignored. This is the first place to look when something misbehaves.

```bash
docker logs --tail 20 tgbot
```

## Common mistakes

- Leaving the placeholder token or ID in the env file, or pasting them with extra spaces or quotes, makes the bot fail or ignore you. Double-check both values and the container logs after starting.
- Exposing Ollama to the public internet by changing its listen address is risky because it has no authentication. Keep the default local-only setting and use host networking only for the bot.
- Expecting great answers from a 0.5B model leads to disappointment. Keep prompts short and log summaries modest, or move to a larger model if your VPS has the RAM.

## Wrap-up

Once your bot works, try a larger model if your server has the memory, or point /logs at other files like nginx or auth logs. You can also add more commands, such as disk usage or service status, while keeping the owner-ID check in place.

Every command here was tested on a fresh Ubuntu 24.04 server before publishing. Watch the full walkthrough on [YouTube](https://youtu.be/HSN-1vuK4Dc) — new tutorials every week on **Lamplight Servers**.
