<#
.SYNOPSIS
  Turns on WhatsApp sending of approved goods-received notes on the live server.

.DESCRIPTION
  Asks for the WhatsApp access token (hidden as you type) and the phone number ID from Meta,
  writes them to /etc/snackify/snackify.env on the server (root only), restarts Snackify and
  checks it came back. The token goes to the server over SSH and is never printed or saved on
  this computer. Run it again to replace them (e.g. a new token).

  Run from the project folder:
    powershell -ExecutionPolicy Bypass -File deploy\vps\set-whatsapp.ps1
#>
param(
  [string]$Server = 'root@187.77.98.21',
  [string]$Key = "$HOME\.ssh\snackify_vps"
)
$ErrorActionPreference = 'Stop'

$phoneId = (Read-Host 'WhatsApp phone number ID (digits, from WhatsApp > API Setup)').Trim()
if ($phoneId -notmatch '^[0-9]{5,25}$') {
  Write-Host 'That is not a phone number ID: it is the long number of digits under the phone number in API Setup, not the phone number itself.' -ForegroundColor Red
  exit 1
}
$secure = Read-Host 'WhatsApp access token (hidden)' -AsSecureString
$token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
  [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)).Trim()
if ($token.Length -lt 20 -or $token -match '\s') {
  Write-Host 'That does not look like an access token. Copy the whole token from Meta and try again.' -ForegroundColor Red
  exit 1
}

# The values travel on the SSH connection's input, never on a command line.
$remote = @'
set -eu
IFS= read -r token; token=${token%$'\r'}
IFS= read -r phone; phone=${phone%$'\r'}
env=/etc/snackify/snackify.env
sed -i '/^WHATSAPP_ACCESS_TOKEN=/d;/^WHATSAPP_PHONE_NUMBER_ID=/d' "$env"
printf 'WHATSAPP_ACCESS_TOKEN=%s\nWHATSAPP_PHONE_NUMBER_ID=%s\n' "$token" "$phone" >> "$env"
chmod 600 "$env"
cd /opt/snackify
docker compose -f deploy/vps/docker-compose.yml --env-file "$env" up -d app >/dev/null 2>&1
for i in $(seq 1 30); do curl -fs http://127.0.0.1:3020/api/v1/health >/dev/null && break; sleep 2; done
if curl -fs http://127.0.0.1:3020/api/v1/health >/dev/null; then
  echo "Snackify restarted with WhatsApp turned on."
else
  echo "Snackify did not come back. Recent log:"; docker logs --tail 20 snackify-app-1 2>&1 | grep -v WHATSAPP_ACCESS_TOKEN
  exit 1
fi
'@ -replace "`r", ''

# The script itself goes base64-encoded on the command line (no secrets in it, no quoting
# trouble); the token and ID follow on the connection's input, where the script reads them.
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remote))
$run = "echo $encoded | base64 -d > /root/.snackify-whatsapp.sh && bash /root/.snackify-whatsapp.sh; status=`$?; rm -f /root/.snackify-whatsapp.sh; exit `$status"
"$token`n$phoneId`n" | ssh -i $Key -o ConnectTimeout=15 $Server $run
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host 'Done. Approve a subsidiary note (or press Send on WhatsApp again on one) to test.' -ForegroundColor Green
