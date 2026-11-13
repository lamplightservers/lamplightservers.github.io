---
layout: post
title: 'Run Your Own Private Cloud: Nextcloud on Docker with Backups'
description: Set up a private Nextcloud with PostgreSQL in Docker on your VPS. Includes
  SSH tunnel access, WebDAV sync testing and a nightly cron backup.
tags:
- selfhosted
- docker
- nextcloud
- linux
date: 2026-11-13 08:58:39 +0000
---

Cloud storage is convenient, but your files live on someone else's servers, under someone else's rules and pricing. Free tiers fill up quickly, and handing personal documents, photos and backups to a third party is a trade-off many developers would rather avoid.

In this guide we build a private Nextcloud backed by PostgreSQL, running in Docker on your own VPS. It restarts automatically after a reboot, stays off the public internet and is reached through an SSH tunnel. We also test file sync over WebDAV and set up a nightly backup job. Self-hosting gives you full control over your data, predictable costs and a setup you can fully understand and reproduce.

<iframe width="100%" style="aspect-ratio:16/9" src="https://www.youtube-nocookie.com/embed/KgVJjIxZd6U" title="Video tutorial" frameborder="0" allowfullscreen></iframe>

## What you need

- A VPS with Ubuntu 24.04 (2 vCPU / 4 GB RAM is plenty). I use [VDSina](https://www.vdsina.com/?partner=xuevxsn1ece5) *(affiliate link — it supports the channel at no extra cost to you)*.
- An SSH connection to it (any terminal works).

> Short on time? Every command below is also in [one ready-to-run script](https://github.com/lamplightservers/lamplightservers.github.io/blob/main/scripts/run-your-own-private-cloud-nextcloud-on-docker-with-backups/install.sh).

## Step 1: Update the system

We start by updating the system packages so we're building on a clean, current base. We also install cron, which the nightly backup needs later, and enable it so it starts on every boot.

```bash
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y -o Dpkg::Options::=--force-confold
apt-get install -y cron
systemctl enable --now cron
```

## Step 2: Install Docker

Next we install Docker with the official convenience script. It sets up the Docker engine and the Compose plugin, which lets us run Nextcloud and its database as containers instead of installing them by hand.

```bash
curl -fsSL https://get.docker.com | sh
```

## Step 3: Generate secrets file

We create a project folder and a secrets file holding the database and admin passwords. The passwords are generated randomly with OpenSSL so they can't be guessed, and the file permissions are tightened so only root can read it.

```bash
mkdir -p /opt/nextcloud && cd /opt/nextcloud
cat > .env <<EOF
DB_PASSWORD=$(openssl rand -hex 16)
NC_ADMIN_USER=admin
NC_ADMIN_PASSWORD=$(openssl rand -hex 12)
EOF
chmod 600 .env
```

## Step 4: Write the compose file

The compose file defines two services, PostgreSQL and Nextcloud, both set to restart unless stopped so they return after a reboot. Nextcloud waits for the database health check before starting and listens only on localhost, so it isn't exposed to the internet. A config check at the end confirms the file is valid.

```bash
cat > /opt/nextcloud/docker-compose.yml <<'EOF'
name: nextcloud
services:
  db:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: nextcloud
      POSTGRES_USER: nextcloud
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - db:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U nextcloud -d nextcloud"]
      interval: 5s
      timeout: 5s
      retries: 20
  app:
    image: nextcloud:apache
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "127.0.0.1:8080:80"
    environment:
      POSTGRES_HOST: db
      POSTGRES_DB: nextcloud
      POSTGRES_USER: nextcloud
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      NEXTCLOUD_ADMIN_USER: ${NC_ADMIN_USER}
      NEXTCLOUD_ADMIN_PASSWORD: ${NC_ADMIN_PASSWORD}
      NEXTCLOUD_TRUSTED_DOMAINS: localhost 127.0.0.1
    volumes:
      - app:/var/www/html
volumes:
  db:
  app:
EOF
cd /opt/nextcloud && docker compose config -q && echo compose-ok
```

## Step 5: Start Nextcloud and create admin

We bring everything up with docker compose. Docker pulls the images, starts the database, then starts Nextcloud, which creates the admin account on its first run. That first start can take a minute or two, so be patient.

```bash
cd /opt/nextcloud && docker compose up -d
```

## Step 6: Show login and phone info

This step prints the login details. Since the port is bound to localhost, you open an SSH tunnel from your own computer and browse to localhost on port 8080 to sign in with the generated credentials. The phone app works the same way, but only through a tunnel or a VPN.

```bash
. /opt/nextcloud/.env
IP=$(hostname -I | awk '{print $1}')
echo "Tunnel from your PC: ssh -N -L 8080:localhost:8080 root@$IP"
echo "Then open: http://localhost:8080"
echo "User: $NC_ADMIN_USER  Password: $NC_ADMIN_PASSWORD"
echo "Phone: install the official Nextcloud app (Google Play, F-Droid or App Store) and log in to this server."
echo "Note: a phone can only reach it through a tunnel or VPN, since port 8080 is bound to localhost only."
```

## Step 7: Upload and verify a test file

To test sync for real, we create a small text file and upload it over WebDAV, the same protocol sync clients use. If the command finishes without an error the upload worked, and the file shows up in the web interface.

```bash
. /opt/nextcloud/.env
echo "Lamplight sync works" > /tmp/test.txt
curl -s -u "$NC_ADMIN_USER:$NC_ADMIN_PASSWORD" -T /tmp/test.txt http://localhost:8080/remote.php/dav/files/$NC_ADMIN_USER/test.txt
```

## Step 8: Write the backup script

The backup script puts Nextcloud into maintenance mode, dumps the database and archives the files volume. It turns maintenance mode off again on exit, even if something fails, so the instance isn't left locked. Backups older than seven days are deleted so the disk doesn't fill up.

```bash
cat > /usr/local/bin/nc-backup.sh <<'EOF'
#!/bin/bash
set -e
B=/var/backups/nextcloud
D=$(date +%F-%H%M)
mkdir -p "$B"
cd /opt/nextcloud
occ() { docker compose exec -T -u www-data app php occ "$@"; }
occ maintenance:mode --on
trap 'occ maintenance:mode --off' EXIT
docker compose exec -T db sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' | gzip > "$B/db-$D.sql.gz"
docker run --rm -v nextcloud_app:/data:ro -v "$B":/backup alpine tar czf "/backup/files-$D.tar.gz" -C /data .
find "$B" -type f -mtime +7 -delete
echo "backup $D done"
EOF
chmod +x /usr/local/bin/nc-backup.sh
```

## Step 9: Schedule nightly backup

We schedule the script with a cron file so it runs every night at three o'clock. Its output goes to a log file, which lets you check later that it actually ran.

```bash
cat > /etc/cron.d/nextcloud-backup <<'EOF'
0 3 * * * root /usr/local/bin/nc-backup.sh >> /var/log/nc-backup.log 2>&1
EOF
chmod 644 /etc/cron.d/nextcloud-backup
```

## Step 10: Run backup and verify

Finally we run the backup by hand to prove it works. The listing should show a compressed database dump and a files archive. A backup you haven't tested is just a hope, so never skip this check.

```bash
/usr/local/bin/nc-backup.sh && ls -lh /var/backups/nextcloud
```

## Common mistakes

- Exposing the Nextcloud port publicly without HTTPS sends logins and files in plain text. Keep it bound to localhost and use an SSH tunnel or VPN, or put a properly configured TLS reverse proxy in front of it.
- Leaving the backups on the same server means a disk failure or a compromised VPS takes both the data and its copies. Regularly copy the archives to another machine or off-site storage.
- Losing or exposing the secrets file causes trouble either way. Keep it readable only by root, store a copy somewhere safe, and don't commit it to Git, since the database password can't easily be recovered.

## Wrap-up

Now that your Nextcloud is running and backed up, try restoring a backup on a test machine to be sure it works. Then add a domain with HTTPS, install the desktop and mobile sync clients, and consider off-site copies of your backups.

Every command here was tested on a fresh Ubuntu 24.04 server before publishing. Watch the full walkthrough on [YouTube](https://youtu.be/KgVJjIxZd6U) — new tutorials every week on **Lamplight Servers**.
