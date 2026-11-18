---
layout: post
title: Run Your Own Vaultwarden Password Manager on a VPS with Docker
description: Set up a private Vaultwarden server in Docker on a VPS, accessed over
  an SSH tunnel, with nightly backups and public sign-ups turned off.
tags:
- selfhosted
- docker
- vaultwarden
- linux
date: 2026-11-18 10:09:51 +0000
---

Password managers hold the keys to everything you own online, yet the hosted ones put that vault on someone else's servers and often lock useful features behind a subscription. If you'd rather keep control of your own data, self-hosting is a realistic option, even on a small VPS.

In this guide we build a private Vaultwarden server, a lightweight, Bitwarden-compatible backend, running in Docker. It is never exposed to the public internet and is reachable only through an SSH tunnel. We also add automatic daily backups and disable public sign-ups, so the only account on the server is yours. You get the polished Bitwarden apps and extensions, with a vault that lives on a machine you control.

<iframe width="100%" style="aspect-ratio:16/9" src="https://www.youtube-nocookie.com/embed/eMYS1ldxhh4" title="Video tutorial" frameborder="0" allowfullscreen></iframe>

## What you need

- A VPS with Ubuntu 24.04 (2 vCPU / 4 GB RAM is plenty). I use [VDSina](https://www.vdsina.com/?partner=xuevxsn1ece5) *(affiliate link — it supports the channel at no extra cost to you)*.
- An SSH connection to it (any terminal works).

> Short on time? Every command below is also in [one ready-to-run script](https://github.com/lamplightservers/lamplightservers.github.io/blob/main/scripts/run-your-own-vaultwarden-password-manager-on-a-vps-with-dock/install.sh).

## Step 1: Update the system

Refresh the package list and install pending updates so the server has the latest security patches. A machine that stores your passwords should be fully patched before anything else goes on it, and the update may take a minute or two.

```bash
apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
```

## Step 2: Install Docker

Install Docker using the official convenience script, which sets up the Docker engine and the compose plugin together. Running Vaultwarden in a container keeps it isolated from the rest of the system, so upgrades and removal stay clean.

```bash
curl -fsSL https://get.docker.com | sh
```

## Step 3: Write the compose file

Create a dedicated folder and write a compose file describing the Vaultwarden service. The key detail is binding the published port to 127.0.0.1, which keeps the service off the public internet. Your vault data is stored in a data folder beside the compose file, and sign-ups stay enabled for now so you can create your own account.

```bash
mkdir -p /opt/vaultwarden/data
cat > /opt/vaultwarden/compose.yaml <<'EOF'
services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    environment:
      - DOMAIN=http://localhost:8080
      - SIGNUPS_ALLOWED=true
    volumes:
      - ./data:/data
    ports:
      - "127.0.0.1:8080:80"
EOF
```

## Step 4: Start Vaultwarden

Start the container with docker compose, which pulls the image and runs it in the background. The restart policy in the compose file brings Vaultwarden back automatically after a server reboot.

```bash
cd /opt/vaultwarden && docker compose up -d
```

## Step 5: Open the SSH tunnel

Because the port is closed to the outside, you reach it through an SSH tunnel opened from your laptop, not from the server. The tunnel forwards a local port on your laptop (8080) to the server's private port, and it only works while that terminal stays open.

```bash
echo 'On YOUR laptop run: ssh -N -L 8080:127.0.0.1:8080 root@YOUR_SERVER_IP  (leave it running)'
```

## Step 6: Create your account

With the tunnel active, open localhost on port 8080 in your laptop's browser and create your account. Choose a strong master password and store it somewhere safe, because nobody, including the server admin, can recover it for you.

```bash
echo 'In your laptop browser open http://localhost:8080 , click Create account, use a strong master password.'
```

## Step 7: Add the browser extension

Install the Bitwarden browser extension and, before logging in, change its server URL to http://localhost:8080 so it connects to your server instead of the official cloud. Log in and save a test password to confirm everything works end to end.

```bash
echo 'Install the Bitwarden extension, set Server URL to http://localhost:8080 , log in, add a test password.'
```

## Step 8: Schedule daily backups

Install cron and add a small script that archives the data folder and keeps only the last fourteen days of backups. A cron entry runs it every night at 3 AM, and running it once by hand gives you a first backup immediately. Copy the archives off the server now and then, since a backup stored on the same machine won't help if you lose that machine.

```bash
DEBIAN_FRONTEND=noninteractive apt-get install -y cron
mkdir -p /root/backups
cat > /usr/local/bin/vw-backup.sh <<'EOF'
#!/bin/sh
tar czf /root/backups/vaultwarden-$(date +%F).tar.gz -C /opt/vaultwarden data
find /root/backups -name 'vaultwarden-*.tar.gz' -mtime +14 -delete
EOF
chmod +x /usr/local/bin/vw-backup.sh
echo '0 3 * * * root /usr/local/bin/vw-backup.sh' > /etc/cron.d/vaultwarden-backup
chmod 644 /etc/cron.d/vaultwarden-backup
systemctl enable --now cron
/usr/local/bin/vw-backup.sh
```

## Step 9: Disable public sign-ups

Once your account exists, turn off public sign-ups by flipping the setting to false with a quick sed edit, then recreate the container with compose up. Your account and data stay intact, and nobody else can register on your server.

```bash
cd /opt/vaultwarden && sed -i 's/SIGNUPS_ALLOWED=true/SIGNUPS_ALLOWED=false/' compose.yaml && docker compose up -d
```

## Common mistakes

- Closing the SSH tunnel terminal and then wondering why the extension or browser can't connect. The tunnel must stay running whenever you sync, so reopen it (or set up a persistent tunnel) before logging in.
- Keeping backups only on the same VPS. If the server is lost or the disk fails, the backups go with it, so regularly copy the archives to another machine or storage location.
- Forgetting to disable sign-ups, or losing the master password. Leaving registration open invites strangers onto your server, and a lost master password cannot be reset, so store it safely offline.

## Wrap-up

You now have a private, self-hosted password manager that's patched, backed up and closed to the public. Next, import your existing passwords, test restoring a backup so you know it works, and consider adding the mobile app through the same tunnel or a private network such as a VPN.

Every command here was tested on a fresh Ubuntu 24.04 server before publishing. Watch the full walkthrough on [YouTube](https://youtu.be/eMYS1ldxhh4) — new tutorials every week on **Lamplight Servers**.
