# Runs one of the scripts in this folder on the VPS as root, over SSH. SSH asks for the root
# password in this terminal; it is typed by you and never stored or shown.
#   & .\deploy\vps\run-on-vps.ps1 inspect.sh
param(
  [Parameter(Mandatory)] [string] $Script,
  [string] $HostName = '187.77.98.21'
)
$path = Join-Path $PSScriptRoot $Script
if (-not (Test-Path $path)) { throw "No script $path" }
# Windows line endings are removed on the server before bash reads the script.
Get-Content -Raw $path | ssh -o StrictHostKeyChecking=accept-new "root@$HostName" "tr -d '\r' | bash -s"
