# Deployment

Snackify runs on **Google Cloud in Johannesburg** (`africa-south1`), the closest region to
Zimbabwe. Staging (a test copy with no real data) comes first; production is set up the same
way once staging has been tried.

```text
 Phones (Android app)  ─┐
                        ├─ HTTPS ─▶  Cloud Run: snackify-staging  ─▶  Cloud SQL: PostgreSQL
 Browsers (web app)    ─┘            (API + web app, one address)     (managed, daily backups)
```

- **Cloud Run** runs the server image built from the [Dockerfile](../Dockerfile): the API and
  the Flutter web app on one HTTPS address, so the web app needs no CORS and no second host. It
  starts when someone uses it and stops when idle, so a quiet staging copy costs little.
- **Cloud SQL** is the managed PostgreSQL database, with Google's daily backups and
  point-in-time recovery. The API connects as `snackify_app`, which can read and write data but
  not change the schema; migrations run as `snackify_owner` (see
  [database-design.md](database-design.md)).
- Passwords live in **Secret Manager**, never in the code, the image or the logs.
- The **Android app** is a signed APK, installed directly on staff phones (no Play Store).

## Deploying a new version

From the project root, in PowerShell:

```powershell
.\deploy\deploy-staging.ps1            # or add -DryRun to see the steps without running them
```

It builds the web app, builds the server image in Google Cloud Build, deploys it to Cloud Run,
checks the live health endpoint (API and database), then builds the Android APK for that
address into `releases\`. If a version adds database migrations, run them first (see
**Migrations**).

The server runs with these settings (set by the script):

| Setting            | Value                       | Why                                                      |
| ------------------ | --------------------------- | -------------------------------------------------------- |
| `NODE_ENV`         | `production`                |                                                          |
| `DATABASE_URL`     | secret `snackify-staging-database-url` | `snackify_app`, through Cloud Run's Cloud SQL connection |
| `TRUST_PROXY_HOPS` | `1`                         | Cloud Run's front end is one proxy; sign-in limits then apply per client |
| `WEB_APP_DIR`      | `/app/web` (in the image)   | Serves the web app on the same address                   |
| `CORS_ORIGINS`     | the service's own address   |                                                          |
| max instances      | `1`                         | The sign-in attempt counter is kept in memory            |

## Android signing key

Every APK is signed with Snackify's own key. Phones only install an update signed with the same
key as the installed app, so **this key must never be lost**: without it, every phone has to
uninstall the app (losing its sign-in) and install a new one.

Create it once, in PowerShell. `keytool` asks for a password (choose a long one) and for your
name and organisation:

```powershell
New-Item -ItemType Directory -Force "$HOME\snackify-keys" | Out-Null
& 'C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe' -genkeypair -v -keystore "$HOME\snackify-keys\snackify-release.jks" -storetype PKCS12 -keyalg RSA -keysize 4096 -validity 10000 -alias snackify
```

Then create `mobile_web\android\key.properties` (Git ignores it) with your password in both
password lines:

```properties
storeFile=C:/Users/YOUR_WINDOWS_NAME/snackify-keys/snackify-release.jks
storePassword=YOUR_KEY_PASSWORD
keyAlias=snackify
keyPassword=YOUR_KEY_PASSWORD
```

Keep a copy of `snackify-release.jks` and its password somewhere safe away from this PC (for
example in a password manager). Release builds refuse to run without this file, so an APK
signed with a temporary debug key can never reach staff by accident.

## Giving staff the Android app

1. Run the deploy script; the APK is in `releases\`, e.g. `snackify-staging-0.1.0-build1.apk`.
2. Send the file to staff (for example by WhatsApp or email). On the phone, open it and allow
   **Install unknown apps** for the app it was opened from, once.
3. For an update, raise the version in `mobile_web/pubspec.yaml` first (for example
   `0.1.0+1` → `0.1.1+2`; the number after `+` must always go up), deploy, and send the new APK.
   It installs over the old one and keeps the sign-in.

## Limits

- Staging has **no real data**. Do not enter real customers or prices there.
- Cloud Run stops the server when nobody has used it for a while; the next request then takes
  a few extra seconds while it starts.
- One server instance at a time (see the table above). Enough for a small team; the sign-in
  limiter must move to the database before allowing more.
- **Receipt documents** (supplier invoices attached to goods-received notes) are stored in
  `ATTACHMENT_STORAGE_DIR`. Cloud Run's disk is wiped whenever the server restarts, so on
  staging they are lost on restart. Before real use, mount a Cloud Storage bucket at that
  folder (Cloud Run volume mounts) or move the store to a private bucket; until then, test
  uploads only.
