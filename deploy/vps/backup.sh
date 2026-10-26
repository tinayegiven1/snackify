#!/usr/bin/env bash
# Backs up Snackify on the VPS: the database (pg_dump, custom format) and the receipt documents,
# into /var/backups/snackify. Keeps the last 14 of each. Run as root (cron runs it nightly).
set -euo pipefail
DIR=/var/backups/snackify
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
install -d -m 700 "$DIR"
COMPOSE=(docker compose -f /opt/snackify/deploy/vps/docker-compose.yml --env-file /etc/snackify/snackify.env)

if [ -z "$("${COMPOSE[@]}" ps -q db 2>/dev/null)" ]; then
  echo "$STAMP no database container yet; nothing to back up"
  exit 0
fi
"${COMPOSE[@]}" exec -T db pg_dump -U postgres -Fc snackify > "$DIR/snackify-$STAMP.dump"
docker run --rm -v snackify_attachments:/data:ro -v "$DIR":/backup debian:bookworm-slim \
  tar -czf "/backup/attachments-$STAMP.tar.gz" -C /data .
chmod 600 "$DIR"/*-"$STAMP".*
ls -1t "$DIR"/snackify-*.dump | tail -n +15 | xargs -r rm -f
ls -1t "$DIR"/attachments-*.tar.gz | tail -n +15 | xargs -r rm -f
echo "$STAMP backup written: $(du -h "$DIR/snackify-$STAMP.dump" | cut -f1)"
