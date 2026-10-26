#!/usr/bin/env bash
# Pulls the latest code from GitHub and rebuilds and restarts Snackify. Database migrations run
# when the app starts. A backup is taken first. Run as root on the VPS:
#   bash /opt/snackify/deploy/vps/update.sh
set -euo pipefail
APP_DIR=/opt/snackify
ENV_FILE=/etc/snackify/snackify.env
COMPOSE=(docker compose -f "$APP_DIR/deploy/vps/docker-compose.yml" --env-file "$ENV_FILE")

bash "$APP_DIR/deploy/vps/backup.sh"
git -C "$APP_DIR" pull --ff-only
echo "now at: $(git -C "$APP_DIR" log --oneline -1)"
"${COMPOSE[@]}" up -d --build
for i in $(seq 1 60); do
  curl -fs http://127.0.0.1:3020/api/v1/health >/dev/null && break
  sleep 5
done
curl -fs http://127.0.0.1:3020/api/v1/health && echo
docker image prune -f >/dev/null
