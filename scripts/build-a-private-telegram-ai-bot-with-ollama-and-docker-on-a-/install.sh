#!/usr/bin/env bash
# Your Private AI Assistant on Telegram (Self-Hosted, Free)
# Video: https://youtu.be/HSN-1vuK4Dc
# Tested on a fresh Ubuntu 24.04 server. Run as root: bash install.sh
set -euo pipefail

echo '==> Step 1: Update the system'
apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

echo '==> Step 2: Install Docker'
curl -fsSL https://get.docker.com | sh

echo '==> Step 3: Install Ollama'
DEBIAN_FRONTEND=noninteractive apt-get install -y zstd && curl -fsSL https://ollama.com/install.sh | sh

echo '==> Step 4: Pull a tiny model'
ollama pull qwen2.5:0.5b

echo '==> Step 5: Create the bot in BotFather'
mkdir -p /opt/tgbot
echo "On your phone: open Telegram, message @BotFather, send /newbot, pick a name and a username ending in 'bot'."
echo "Copy the token it gives you. Then message @userinfobot to get your numeric Telegram ID."

echo '==> Step 6: Save token and owner ID'
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

echo '==> Step 7: Write the bot code'
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

echo '==> Step 8: Start the bot container'
touch /var/log/dpkg.log
docker rm -f tgbot 2>/dev/null || true
docker run -d --name tgbot --restart unless-stopped --network host \
  --env-file /opt/tgbot/.env \
  -v /opt/tgbot/bot.py:/app/bot.py:ro \
  -v /var/log/dpkg.log:/host/dpkg.log:ro \
  python:3.12-slim python -u /app/bot.py

echo '==> Step 9: Test chat and log summary'
echo "On your phone, open your bot, send: /start, then: What is Docker in one sentence?, then: /logs"
curl -s http://127.0.0.1:11434/api/generate -d '{"model":"qwen2.5:0.5b","prompt":"Say hello in five words.","stream":false,"options":{"num_predict":30}}'

echo '==> Step 10: View bot logs'
docker logs --tail 20 tgbot
