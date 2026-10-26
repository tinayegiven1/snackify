#!/usr/bin/env bash
# First-time setup of Snackify on the VPS, and safe to run again. Run as root:
#   SNACKIFY_DOMAIN=snackify-example.duckdns.org bash setup.sh
# - clones the public repository to /opt/snackify (or updates it)
# - creates /etc/snackify/snackify.env with random database passwords (only if missing)
# - builds and starts the containers (app on 127.0.0.1:3020, database not published)
# - adds an nginx site for the domain and an HTTPS certificate (certbot)
# - adds a daily database and documents backup to /var/backups/snackify (14 kept)
set -euo pipefail

: "${SNACKIFY_DOMAIN:?Set SNACKIFY_DOMAIN, e.g. snackify-example.duckdns.org}"
REPO=https://github.com/tinayegiven1/snackify.git
APP_DIR=/opt/snackify
ENV_FILE=/etc/snackify/snackify.env
COMPOSE=(docker compose -f "$APP_DIR/deploy/vps/docker-compose.yml" --env-file "$ENV_FILE")

echo "== code"
if [ -d "$APP_DIR/.git" ]; then git -C "$APP_DIR" pull --ff-only; else git clone "$REPO" "$APP_DIR"; fi

echo "== secrets"
install -d -m 700 /etc/snackify
if [ ! -f "$ENV_FILE" ]; then
  umask 077
  {
    echo "SNACKIFY_DOMAIN=$SNACKIFY_DOMAIN"
    echo "POSTGRES_PASSWORD=$(openssl rand -hex 24)"
    echo "SNACKIFY_OWNER_PASSWORD=$(openssl rand -hex 24)"
    echo "SNACKIFY_APP_PASSWORD=$(openssl rand -hex 24)"
  } > "$ENV_FILE"
  echo "created $ENV_FILE (random passwords, readable by root only)"
else
  sed -i "s/^SNACKIFY_DOMAIN=.*/SNACKIFY_DOMAIN=$SNACKIFY_DOMAIN/" "$ENV_FILE"
  echo "kept existing $ENV_FILE"
fi

echo "== containers (the first build installs Flutter and takes a while)"
"${COMPOSE[@]}" up -d --build
for i in $(seq 1 60); do
  curl -fs http://127.0.0.1:3020/api/v1/health >/dev/null && break
  sleep 5
done
curl -fs http://127.0.0.1:3020/api/v1/health && echo

echo "== nginx"
cat > /etc/nginx/sites-available/snackify <<NGINX
# Snackify (deploy/vps/setup.sh). The app runs in Docker on 127.0.0.1:3020.
server {
    listen 80;
    listen [::]:80;
    server_name $SNACKIFY_DOMAIN;
    # Receipt documents up to 10 MB.
    client_max_body_size 12m;
    location / {
        proxy_pass http://127.0.0.1:3020;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
    }
}
NGINX
ln -sf /etc/nginx/sites-available/snackify /etc/nginx/sites-enabled/snackify
nginx -t
systemctl reload nginx

echo "== https"
if [ ! -d "/etc/letsencrypt/live/$SNACKIFY_DOMAIN" ]; then
  certbot --nginx -d "$SNACKIFY_DOMAIN" --non-interactive --redirect
else
  echo "certificate already present"
fi

echo "== daily backup"
install -d -m 700 /var/backups/snackify
cat > /etc/cron.d/snackify-backup <<'CRON'
# Snackify: database and receipt documents every night at 22:00 server time; 14 days kept.
0 22 * * * root bash /opt/snackify/deploy/vps/backup.sh >> /var/backups/snackify/backup.log 2>&1
CRON

echo "Snackify is set up at https://$SNACKIFY_DOMAIN"
