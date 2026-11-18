#!/usr/bin/env bash
# Self-Host Vaultwarden on a VPS: Free Bitwarden-Compatible Password Manager
# Video: https://youtu.be/eMYS1ldxhh4
# Tested on a fresh Ubuntu 24.04 server. Run as root: bash install.sh
set -euo pipefail

echo '==> Step 1: Update the system'
apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

echo '==> Step 2: Install Docker'
curl -fsSL https://get.docker.com | sh

echo '==> Step 3: Write the compose file'
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

echo '==> Step 4: Start Vaultwarden'
cd /opt/vaultwarden && docker compose up -d

echo '==> Step 5: Open the SSH tunnel'
echo 'On YOUR laptop run: ssh -N -L 8080:127.0.0.1:8080 root@YOUR_SERVER_IP  (leave it running)'

echo '==> Step 6: Create your account'
echo 'In your laptop browser open http://localhost:8080 , click Create account, use a strong master password.'

echo '==> Step 7: Add the browser extension'
echo 'Install the Bitwarden extension, set Server URL to http://localhost:8080 , log in, add a test password.'

echo '==> Step 8: Schedule daily backups'
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

echo '==> Step 9: Disable public sign-ups'
cd /opt/vaultwarden && sed -i 's/SIGNUPS_ALLOWED=true/SIGNUPS_ALLOWED=false/' compose.yaml && docker compose up -d
