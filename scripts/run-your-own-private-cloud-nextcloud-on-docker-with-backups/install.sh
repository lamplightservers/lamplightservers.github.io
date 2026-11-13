#!/usr/bin/env bash
# Self-Host Nextcloud on a VPS: Replace Google Drive & Dropbox (Docker Compose)
# Video: https://youtu.be/KgVJjIxZd6U
# Tested on a fresh Ubuntu 24.04 server. Run as root: bash install.sh
set -euo pipefail

echo '==> Step 1: Update the system'
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y -o Dpkg::Options::=--force-confold
apt-get install -y cron
systemctl enable --now cron

echo '==> Step 2: Install Docker'
curl -fsSL https://get.docker.com | sh

echo '==> Step 3: Generate secrets file'
mkdir -p /opt/nextcloud && cd /opt/nextcloud
cat > .env <<EOF
DB_PASSWORD=$(openssl rand -hex 16)
NC_ADMIN_USER=admin
NC_ADMIN_PASSWORD=$(openssl rand -hex 12)
EOF
chmod 600 .env

echo '==> Step 4: Write the compose file'
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

echo '==> Step 5: Start Nextcloud and create admin'
cd /opt/nextcloud && docker compose up -d

echo '==> Step 6: Show login and phone info'
. /opt/nextcloud/.env
IP=$(hostname -I | awk '{print $1}')
echo "Tunnel from your PC: ssh -N -L 8080:localhost:8080 root@$IP"
echo "Then open: http://localhost:8080"
echo "User: $NC_ADMIN_USER  Password: $NC_ADMIN_PASSWORD"
echo "Phone: install the official Nextcloud app (Google Play, F-Droid or App Store) and log in to this server."
echo "Note: a phone can only reach it through a tunnel or VPN, since port 8080 is bound to localhost only."

echo '==> Step 7: Upload and verify a test file'
. /opt/nextcloud/.env
echo "Lamplight sync works" > /tmp/test.txt
curl -s -u "$NC_ADMIN_USER:$NC_ADMIN_PASSWORD" -T /tmp/test.txt http://localhost:8080/remote.php/dav/files/$NC_ADMIN_USER/test.txt

echo '==> Step 8: Write the backup script'
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

echo '==> Step 9: Schedule nightly backup'
cat > /etc/cron.d/nextcloud-backup <<'EOF'
0 3 * * * root /usr/local/bin/nc-backup.sh >> /var/log/nc-backup.log 2>&1
EOF
chmod 644 /etc/cron.d/nextcloud-backup

echo '==> Step 10: Run backup and verify'
/usr/local/bin/nc-backup.sh && ls -lh /var/backups/nextcloud
