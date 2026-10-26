#!/usr/bin/env bash
# Read-only look at the VPS before setting Snackify up on it. Changes nothing.
echo "== system"; uname -a; grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release
echo "== resources"; nproc; free -h | head -2; df -h / | tail -1
echo "== software"
for tool in git node npm psql nginx caddy pm2 docker ufw certbot; do
  printf '%-8s ' "$tool"; command -v "$tool" >/dev/null && echo "$($tool --version 2>&1 | head -1)" || echo "-"
done
echo "== services"; for s in postgresql nginx caddy docker snackify; do printf '%-11s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)"; done
echo "== listening ports"; ss -tlnp 2>/dev/null | awk 'NR>1 {print $4, $6}' | sort -u | head -20
echo "== firewall"; (ufw status 2>/dev/null || echo "ufw not installed") | head -8
echo "== snackify folders"; ls -d /opt/* /srv/* /var/www/* /root/* 2>/dev/null | head -30
echo "== github access"; ls -la /root/.ssh 2>/dev/null | tail -n +2
