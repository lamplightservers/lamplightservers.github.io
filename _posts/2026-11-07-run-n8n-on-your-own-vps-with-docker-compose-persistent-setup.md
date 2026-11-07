---
layout: post
title: 'Run n8n on Your Own VPS with Docker Compose: Persistent Setup'
description: Set up a self-hosted n8n server on a VPS with Docker and Compose. Includes
  persistent storage, auto-restart, a firewall, and a localhost health check.
tags:
- selfhosted
- docker
- n8n
- automation
date: 2026-11-07 12:27:49 +0000
---

Cloud automation tools are convenient, but the bills grow with every workflow, and your data and credentials live on someone else's servers. Setting up your own instance by hand can also be fiddly, especially when you want it to survive reboots and updates without losing anything.

In this guide we build a self-hosted n8n workflow automation server in Docker on a VPS. It has persistent storage, automatic restarts, an encrypted credential store, and a working health check on localhost. Self-hosting gives you full control over your data, no per-execution pricing, and a setup you can back up, move, or upgrade whenever you like.

<iframe width="100%" style="aspect-ratio:16/9" src="https://www.youtube-nocookie.com/embed/k5du4Mumgqo" title="Video tutorial" frameborder="0" allowfullscreen></iframe>

## What you need

- A VPS with Ubuntu 24.04 (2 vCPU / 4 GB RAM is plenty). I use [VDSina](https://www.vdsina.com/?partner=xuevxsn1ece5) *(affiliate link — it supports the channel at no extra cost to you)*.
- An SSH connection to it (any terminal works).

> Short on time? Every command below is also in [one ready-to-run script](https://github.com/lamplightservers/lamplightservers.github.io/blob/main/scripts/run-n8n-on-your-own-vps-with-docker-compose-persistent-setup/install.sh).

## Step 1: Install Docker

Docker's official install script sets up Docker Engine and the Compose plugin in one pass. Running it non-interactively means it won't pause for prompts, which makes the setup repeatable and easy to paste into a fresh server.

```bash
curl -fsSL https://get.docker.com | DEBIAN_FRONTEND=noninteractive sh
```

## Step 2: Enable the firewall

The firewall is configured so that SSH on port 22 is allowed before anything else. This order matters, because enabling the firewall without that rule could cut off your own connection. The force flag skips the confirmation question so the command runs straight through.

```bash
ufw allow 22/tcp && ufw --force enable
```

## Step 3: Generate encryption key

n8n encrypts the credentials you store in it, using a secret encryption key. We create a project folder, generate a random 64-character key with OpenSSL, and save it in a .env file. Restricting that file to root with chmod keeps the key private. Back it up somewhere safe, since without it saved credentials can't be decrypted.

```bash
mkdir -p /opt/n8n
echo "N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)" > /opt/n8n/.env
chmod 600 /opt/n8n/.env
```

## Step 4: Create compose file

The compose file pulls the official n8n image and uses a restart policy that brings it back after crashes or reboots unless you stop it yourself. The port is bound to 127.0.0.1, so n8n stays private to the server rather than exposed to the internet. A named volume stores workflows and data outside the container so they survive replacement. Quoting the EOF marker prevents the shell from expanding the key, so Compose reads it from the .env file instead.

```bash
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
```

## Step 5: Start n8n

Docker Compose downloads the image and starts n8n in the background. The first run takes longer because the image has to be pulled, and later starts are much faster.

```bash
docker compose -f /opt/n8n/compose.yaml up -d
```

## Step 6: Wait for n8n

Viewing the last few lines of the container logs shows how startup is going. You're waiting for a line saying the editor is accessible, which means n8n has finished initializing and is ready to serve requests.

```bash
docker compose -f /opt/n8n/compose.yaml logs --tail 5 n8n
```

## Step 7: Test the web interface

A curl request to the local web interface, printing only the HTTP status code, makes a quick health check. A 200 response confirms that n8n is running and answering on localhost.

```bash
curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:5678/
```

## Common mistakes

- Losing or changing the encryption key. If the .env file is deleted or the key is regenerated, existing credentials become unreadable. Store a copy in a password manager and generate the key only once.
- Enabling the firewall before allowing SSH. This can lock you out of the VPS entirely. Always add the port 22 rule first, and if you use a custom SSH port, allow that one instead.
- Expecting to reach n8n from the internet after binding to 127.0.0.1. The binding is deliberate for safety, so the editor is only reachable from the server itself. To use it remotely, put a reverse proxy with HTTPS in front or use an SSH tunnel, rather than opening the port directly.

## Wrap-up

Next, put a reverse proxy such as Caddy or Nginx in front of n8n with a domain and HTTPS so you can reach the editor securely from anywhere. After that, set up regular backups of the data volume and your .env file, then start building your first workflows.

Every command here was tested on a fresh Ubuntu 24.04 server before publishing. Watch the full walkthrough on [YouTube](https://youtu.be/k5du4Mumgqo) — new tutorials every week on **Lamplight Servers**.
