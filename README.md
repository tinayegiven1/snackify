# Snackify

Stock receiving, dispatching, customer billing, barcode scanning and sales forecasting for a small
snacks business. One backend API and database serve a Flutter web app and a Flutter Android app.

The full product specification is in [Snackify_Claude_Code_Spec.md](Snackify_Claude_Code_Spec.md).

## Current status: Stage 1 (foundation)

| Part                                   | Status                                                         |
| -------------------------------------- | -------------------------------------------------------------- |
| Backend (Node.js, Express, TypeScript) | Health endpoint, config validation, error handling, tests      |
| Flutter app (web + Android)            | Responsive dashboard shell with **sample data only**           |
| PostgreSQL, migrations, login          | Not started (next stage)                                       |
| Products, stock, dispatches, billing   | Not started (navigation shows "coming soon" pages)             |

## Project structure

```text
Snackify/
├── backend/                 Express + TypeScript API
│   ├── src/
│   │   ├── app.ts           Builds the Express app (used by server and tests)
│   │   ├── server.ts        Starts the HTTP server
│   │   ├── config/          Environment variable validation
│   │   ├── middleware/      404 and error handlers
│   │   ├── modules/health/  GET /api/v1/health
│   │   ├── utils/           AppError, JSON logger
│   │   └── tests/           Vitest + Supertest tests
│   └── .env.example
├── mobile_web/              Flutter app for web and Android
│   ├── lib/
│   │   ├── core/            config, network (API client), routing, theme
│   │   ├── shared/widgets/  app shell, API status chip, logo
│   │   └── features/dashboard/
│   ├── test/
│   └── assets/images/
└── docs/api-documentation.md
```

## Prerequisites

| Tool                                | Needed for              | Version used |
| ----------------------------------- | ----------------------- | ------------ |
| Node.js (LTS)                       | Backend                 | 24.x         |
| npm                                 | Backend                 | 11.x         |
| Flutter SDK (includes Dart)         | Web and Android app     | 3.47 stable  |
| Android Studio + Android SDK        | Android builds          | SDK 36       |
| Google Chrome or Microsoft Edge     | Running the web app     | any current  |
| PostgreSQL                          | Next stage              | 17 or newer  |

---

## Backend

All commands run from the `backend` folder (PowerShell shown).

### First-time setup

```powershell
cd backend
npm install
Copy-Item .env.example .env
```

`.env` holds local settings and is ignored by Git. The defaults work as-is.

### Run in development (auto-restarts on file changes)

```powershell
npm run dev
```

### Verify it is running

Open <http://localhost:3000/api/v1/health> in a browser, or run:

```powershell
curl.exe http://localhost:3000/api/v1/health
```

Expected: HTTP 200 with `"status":"ok"`. `"database":"not_configured"` is expected until the
next stage.

### Checks

```powershell
npm test               # Vitest + Supertest
npm run typecheck      # TypeScript strict mode
npm run lint           # ESLint
npm run format:check   # Prettier (use `npm run format` to fix)
npm run check          # all of the above
```

### Production-style run

```powershell
npm run build
npm start
```

### Configuration (`backend/.env`)

| Variable       | Default                 | Meaning                                                     |
| -------------- | ----------------------- | ----------------------------------------------------------- |
| `NODE_ENV`     | `development`           | `development`, `test` or `production`                       |
| `PORT`         | `3000`                  | Port the API listens on                                     |
| `CORS_ORIGINS` | `http://localhost:8080` | Comma-separated browser origins allowed to call the API     |

Invalid values stop the server at startup with a message naming the variable.

---

## Flutter app (web + Android)

All commands run from the `mobile_web` folder.

### One-time setup

1. Install Flutter (stable), following <https://docs.flutter.dev/install/manual>.
   Extract it to a path **without spaces**, such as `C:\src\flutter`, and add
   `C:\src\flutter\bin` to your user `PATH`. Then open a new terminal.
2. In Android Studio, open **SDK Manager → SDK Tools** and install
   **Android SDK Command-line Tools (latest)**.
3. Accept the Android licences and check the setup:

   ```powershell
   flutter doctor --android-licenses
   flutter doctor
   ```

4. Install packages:

   ```powershell
   cd mobile_web
   flutter pub get
   ```

The `android/` and `web/` platform folders already exist (generated with
`flutter create . --platforms=web,android --project-name snackify --org com.snackify`).
The Android application ID is `com.snackify.snackify` (in `android/app/build.gradle.kts`).
Change it before the first Play Store release, because it cannot be changed after that.

### Run on the web

Start the backend first, then:

```powershell
flutter run -d chrome --web-port 8080
```

Use `-d edge` for Microsoft Edge. Port `8080` matches `CORS_ORIGINS` in `backend/.env`. If you
use a different port, add that origin to `CORS_ORIGINS` and restart the backend. The first debug
start takes about a minute while Flutter compiles; later starts are faster.

### Run on Android

- **Emulator:** create a device in Android Studio (**Device Manager → Create Virtual Device**),
  start it, then run `flutter run`. The app automatically uses `http://10.0.2.2:3000`, which is
  how the emulator reaches the backend on your computer.
- **Physical phone:** enable USB debugging, connect the phone, and make sure the phone and the
  computer are on the same Wi-Fi network. Find your computer's IP address with `ipconfig`, then:

  ```powershell
  flutter run --dart-define=API_BASE_URL=http://192.168.1.50:3000
  ```

  Replace `192.168.1.50` with your computer's IPv4 address. If Windows Firewall asks, allow
  Node.js on **private** networks.

### Verify it is working

The chip in the top-right corner shows **API online** when the app can reach the backend and
**API offline** when it cannot. Tap it to check again. Resize the browser window: below 840 px
wide, navigation moves into a menu drawer; wider screens show a permanent sidebar.

### Checks

```powershell
flutter analyze
flutter test
dart format .
```

---

## Known limitations (Stage 1)

- The dashboard shows **sample data only**; nothing is saved or loaded from a database yet.
- No database, login or role permissions yet. Do not deploy this stage to the internet.
- The backend allows browser requests only from the origins in `CORS_ORIGINS`.
- Plain HTTP is only for local development. Production must use HTTPS.
- **Keep the project out of OneDrive and other sync folders.** Sync tools lock files in
  `mobile_web/build/`, and Flutter then fails with "failed to delete a directory". The project
  lives at `C:\dev\snackify`; use Git/GitHub for backup instead.

## API documentation

See [docs/api-documentation.md](docs/api-documentation.md).
