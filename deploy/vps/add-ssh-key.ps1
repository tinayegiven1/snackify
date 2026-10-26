# Adds this PC's deployment key (~/.ssh/snackify_vps.pub) to the VPS root account, so later
# deployment steps connect without a password. Asks for the root password once.
# To remove the key later, delete its line ("snackify-deploy from ...") from
# /root/.ssh/authorized_keys on the server.
param([string] $HostName = '187.77.98.21')
$key = Join-Path $HOME '.ssh\snackify_vps.pub'
if (-not (Test-Path $key)) { throw "No key at $key" }
Get-Content -Raw $key | ssh -o StrictHostKeyChecking=accept-new "root@$HostName" "umask 077; mkdir -p ~/.ssh; key=`$(tr -d '\r'); grep -qxF `"`$key`" ~/.ssh/authorized_keys 2>/dev/null || echo `"`$key`" >> ~/.ssh/authorized_keys; echo 'Key added for this PC.'"
