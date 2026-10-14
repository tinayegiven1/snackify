<#
.SYNOPSIS
  Deploys Snackify staging to Google Cloud Run (Johannesburg) and builds the matching Android APK.

.DESCRIPTION
  1. Builds the Flutter web app (release).
  2. Builds the server image in Google Cloud Build and deploys it to Cloud Run. The web app and
     the API share one HTTPS address.
  3. Checks the live health endpoint (API and database).
  4. Builds a signed release APK that talks to that address, if the signing key is set up
     (mobile_web/android/key.properties), and copies it to releases/.

  One-time setup (project, database, secrets, service account) is described in
  docs/deployment.md. Database migrations are run separately, before deploying a version that
  needs them: see "Migrations" in docs/deployment.md.

.EXAMPLE
  .\deploy\deploy-staging.ps1
.EXAMPLE
  .\deploy\deploy-staging.ps1 -DryRun     # show what would run, change nothing
#>
param(
  [string]$ProjectId,
  [string]$Region = 'africa-south1',
  [string]$Service = 'snackify-staging',
  [string]$SqlInstance = 'snackify-staging-db',
  [switch]$SkipApk,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Invoke-Step([string]$Description, [string]$Exe, [string[]]$Arguments, [string]$WorkingDirectory = $root) {
  Write-Host "`n== $Description" -ForegroundColor Cyan
  Write-Host "   $Exe $($Arguments -join ' ')"
  if ($DryRun) { return }
  Push-Location $WorkingDirectory
  try {
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Description failed (exit code $LASTEXITCODE)." }
  } finally {
    Pop-Location
  }
}

if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
  throw 'The Google Cloud CLI (gcloud) is not installed. See docs/deployment.md.'
}
if (-not $ProjectId) {
  $ProjectId = (gcloud config get-value project 2>$null)
  if (-not $ProjectId) { throw 'No project: run  gcloud config set project YOUR_PROJECT_ID  first.' }
}
$projectNumber = (gcloud projects describe $ProjectId --format='value(projectNumber)')
if (-not $projectNumber) { throw "Cannot read project $ProjectId. Are you signed in (gcloud auth login)?" }

# Cloud Run's address for a service is fixed: https://SERVICE-PROJECTNUMBER.REGION.run.app
$url = "https://$Service-$projectNumber.$Region.run.app"
$connection = "${ProjectId}:${Region}:$SqlInstance"
$serviceAccount = "$Service-run@$ProjectId.iam.gserviceaccount.com"

Write-Host "Project:  $ProjectId ($projectNumber)"
Write-Host "Address:  $url"
Write-Host "Database: $connection"
if ($DryRun) { Write-Host 'DRY RUN: nothing will be changed.' -ForegroundColor Yellow }

Invoke-Step 'Build the web app' 'flutter' @('build', 'web', '--release') (Join-Path $root 'mobile_web')

$envVars = @(
  'NODE_ENV=production',
  # Cloud Run's front end is the one proxy in front of the server.
  'TRUST_PROXY_HOPS=1',
  "CORS_ORIGINS=$url",
  'BUSINESS_NAME=Snackify (staging)'
) -join ','

Invoke-Step 'Build the server image and deploy it to Cloud Run' 'gcloud' @(
  'run', 'deploy', $Service,
  '--source', '.',
  '--project', $ProjectId,
  '--region', $Region,
  '--service-account', $serviceAccount,
  '--add-cloudsql-instances', $connection,
  '--set-secrets', "DATABASE_URL=$Service-database-url:latest",
  '--set-env-vars', $envVars,
  # One instance: the sign-in attempt limit is kept in memory (see README, Known limitations).
  '--max-instances', '1',
  '--min-instances', '0',
  '--memory', '512Mi',
  '--cpu', '1',
  '--allow-unauthenticated',
  '--quiet'
)

Write-Host "`n== Check the live server" -ForegroundColor Cyan
if (-not $DryRun) {
  $health = Invoke-RestMethod -Uri "$url/api/v1/health" -TimeoutSec 60
  if ($health.status -ne 'ok' -or $health.checks.database -ne 'up') {
    throw "The server answered, but is not healthy: $($health | ConvertTo-Json -Compress)"
  }
  Write-Host "   Healthy: API $($health.status), database $($health.checks.database), environment $($health.environment)" -ForegroundColor Green
}

if ($SkipApk) {
  Write-Host "`nAndroid APK skipped (-SkipApk)."
} elseif (-not (Test-Path (Join-Path $root 'mobile_web/android/key.properties'))) {
  Write-Host "`nAndroid APK not built: no signing key yet (see docs/deployment.md, 'Android signing key')." -ForegroundColor Yellow
} else {
  Invoke-Step 'Build the Android APK' 'flutter' @('build', 'apk', '--release', "--dart-define=API_BASE_URL=$url") (Join-Path $root 'mobile_web')
  if (-not $DryRun) {
    $version = (Select-String -Path (Join-Path $root 'mobile_web/pubspec.yaml') -Pattern '^version:\s*(\S+)').Matches[0].Groups[1].Value
    $releases = Join-Path $root 'releases'
    New-Item -ItemType Directory -Force -Path $releases | Out-Null
    $apk = Join-Path $releases ("snackify-staging-{0}.apk" -f ($version -replace '\+', '-build'))
    Copy-Item (Join-Path $root 'mobile_web/build/app/outputs/flutter-apk/app-release.apk') $apk -Force
    Write-Host "   APK: $apk" -ForegroundColor Green
  }
}

Write-Host "`nDone. Staging: $url" -ForegroundColor Green
