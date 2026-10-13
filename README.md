# Snackify

Stock receiving, dispatching, customer billing, barcode scanning and sales forecasting for a small
snacks business. One backend API and database serve a Flutter web app and a Flutter Android app.

The full product specification is in [Snackify_Claude_Code_Spec.md](Snackify_Claude_Code_Spec.md).

## Current status: Stage 9 (payments and balances)

| Part                                   | Status                                                                     |
| -------------------------------------- | -------------------------------------------------------------------------- |
| Backend (Node.js, Express, TypeScript) | Health, sign-in, roles, staff, products, stock ledger, customers, dispatches, invoices with PDFs, payments, balances and statements, audit log, tests |
| PostgreSQL                             | Dev + test databases, least-privilege roles, migrations, seed              |
| Database tables                        | `products`, `users`, `sessions`, `audit_logs`, `stock_batches`, `stock_movements`, `customers`, `dispatches`, `dispatch_items`, `invoices`, `invoice_items`, `payments`, `payment_allocations` |
| Flutter app (web + Android)            | Login, **Products**, **Stock** (on hand, low stock, receipts, history, damage/corrections), **Customers**, **Dispatches** (drafts, confirm, cancel, reverse, credit warnings), **Invoices** (weekly run, preview, drafts, issue, void, PDF, paid/overdue), **Payments** (record and allocate payments, balances, account statements); dashboard with **sample data** |
| Staff management screens               | Not yet: use the API or `npm run user:create`                              |
| Reports, forecasts, barcode scanning   | Not started (navigation shows "coming soon" pages)                         |

## Project structure

```text
snackify/
├── backend/                 Express + TypeScript API
│   ├── src/
│   │   ├── app.ts           Builds the Express app (used by server and tests)
│   │   ├── server.ts        Starts the HTTP server and database pool
│   │   ├── config/          Environment variable validation
│   │   ├── database/        Connection pool, transactions, migration runner
│   │   ├── middleware/      Sign-in and role checks, 404 and error handlers
│   │   ├── modules/         auth, users, products, stock, customers, dispatches, invoices (+ PDF), payments, audit, health
│   │   ├── scripts/         db:migrate, db:seed and user:create commands
│   │   ├── utils/           AppError, validation, JSON logger
│   │   └── tests/           Unit tests; tests/db/ = tests against PostgreSQL
│   └── .env.example
├── database/
│   ├── setup/               One-time script that creates roles and databases
│   ├── migrations/          SQL schema changes, applied in order
│   └── seeds/               Sample data for local development (no real data)
├── mobile_web/              Flutter app for web and Android
│   ├── lib/
│   │   ├── core/            config, network (API client), files (PDF sharing), routing, theme
│   │   ├── shared/widgets/  app shell, API status chip, logo
│   │   └── features/        auth, dashboard, products, stock, customers, dispatches, invoices, payments
│   ├── test/
│   └── assets/images/
└── docs/                    api-documentation.md, database-design.md
```

## Prerequisites

| Tool                                | Needed for              | Version used |
| ----------------------------------- | ----------------------- | ------------ |
| Node.js (LTS)                       | Backend                 | 24.x         |
| npm                                 | Backend                 | 11.x         |
| Flutter SDK (includes Dart)         | Web and Android app     | 3.47 stable  |
| Android Studio + Android SDK        | Android builds          | SDK 36       |
| Google Chrome or Microsoft Edge     | Running the web app     | any current  |
| PostgreSQL (with pgAdmin)           | Database                | 18.x         |

---

## Database (PostgreSQL)

The design, conventions and roles are described in
[docs/database-design.md](docs/database-design.md).

### One-time setup

1. Install PostgreSQL 18 from <https://www.postgresql.org/download/windows/> (the EDB
   installer). It runs as the Windows service `postgresql-x64-18` and starts with Windows.
   Remember the password you choose for the `postgres` superuser.
2. Create the Snackify roles and databases. Choose two long passwords, then from the project
   root:

   ```powershell
   $env:SNACKIFY_OWNER_PASSWORD = '<long random password 1>'
   $env:SNACKIFY_APP_PASSWORD   = '<long random password 2>'
   & 'C:\Program Files\PostgreSQL\18\bin\psql.exe' -h localhost -U postgres -d postgres -f database/setup/local-setup.sql
   ```

   This creates `snackify_owner` (runs migrations), `snackify_app` (used by the API), and the
   databases `snackify_dev` and `snackify_test`. It is safe to run again, for example to change
   the passwords.
3. Copy `backend/.env.example` to `backend/.env` and replace the `CHANGE_ME_...` placeholders
   with the two passwords.

On this PC the setup is already done. The `postgres` password was generated during install and
is stored in `%APPDATA%\postgresql\pgpass.conf` (the text after the last `:` on each line), so
`psql` connects without asking. pgAdmin asks for it the first time; paste it from that file and
tick **Save password**. The Snackify role passwords are in `backend/.env`.

### Browse the data

Open **pgAdmin 4** from the Start menu, then **Servers → PostgreSQL 18 → Databases →
snackify_dev → Schemas → public → Tables**. Or use the command line:

```powershell
& 'C:\Program Files\PostgreSQL\18\bin\psql.exe' -h localhost -U postgres -d snackify_dev -c "select sku, name, flavour, size, default_price from products"
```

### Migrations and sample data

From the `backend` folder:

```powershell
npm run db:migrate                     # apply all pending migrations
npm run db:seed                        # load sample products and customers (safe to repeat)
npm run db:rollback                    # undo the most recent migration (not in production)
npm run db:new-migration -- add-customers   # create a new, empty SQL migration file
```

---

## Backend

All commands run from the `backend` folder (PowerShell shown).

### First-time setup

Set up the database first (see above), then:

```powershell
cd backend
npm install
npm run db:migrate
npm run db:seed
```

### Create the first admin account

Run this once in a terminal, with your own username and name. It asks for the password twice
and does not show it while you type (the password is never accepted on the command line, so
it cannot end up in your shell history):

```powershell
npm run user:create -- --username your.name --name "Your Full Name" --role admin
```

The same command creates other staff accounts, with `--role storekeeper`, `salesperson` or
`accounts`. Once signed in, an admin can also manage staff through the API (see
[docs/api-documentation.md](docs/api-documentation.md#staff-accounts-admins-only)); screens for
this come in a later stage.

### Roles and sign-in rules

| Role          | Intended for (spec section 5)                                   |
| ------------- | --------------------------------------------------------------- |
| `admin`       | Everything, including staff accounts. Allowed on every endpoint |
| `storekeeper` | Receiving stock, viewing stock, barcodes, preparing dispatches  |
| `salesperson` | Customers and creating dispatches                               |
| `accounts`    | Invoices, payments, balances and financial reports              |

- Passwords: at least 10 characters (a short sentence is ideal), stored as Argon2id hashes.
- A sign-in lasts 12 hours. After 10 wrong passwords from one network address in 15 minutes,
  sign-in is paused for 15 minutes.
- Deactivating an account or resetting its password signs that person out everywhere at once.
- Sign-ins, failed attempts, sign-outs and every staff-account change are recorded in the
  `audit_logs` table.

### Run in development (auto-restarts on file changes)

```powershell
npm run dev
```

### Verify it is running

Open <http://localhost:3000/api/v1/health> in a browser, or run:

```powershell
curl.exe http://localhost:3000/api/v1/health
```

Expected: HTTP 200 with `"status":"ok"` and `"database":"up"`. If PostgreSQL cannot be reached,
the API still runs but answers HTTP 503 with `"database":"down"`, and the server log says why.

### Checks

```powershell
npm test               # unit tests (no database needed)
npm run test:db        # tests against the snackify_test database (rebuilds its schema first)
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

| Variable                      | Default                 | Meaning                                                 |
| ----------------------------- | ----------------------- | ------------------------------------------------------- |
| `NODE_ENV`                    | `development`           | `development`, `test` or `production`                   |
| `PORT`                        | `3000`                  | Port the API listens on                                 |
| `CORS_ORIGINS`                | `http://localhost:8080` | Comma-separated browser origins allowed to call the API |
| `DATABASE_URL`                | (required)              | API connection, as `snackify_app`, to `snackify_dev`    |
| `MIGRATION_DATABASE_URL`      | (required for migrations) | `snackify_owner` connection used by `db:migrate`      |
| `TEST_DATABASE_URL`           | (required for `test:db`) | `snackify_app` connection to `snackify_test`           |
| `TEST_MIGRATION_DATABASE_URL` | (required for `test:db`) | `snackify_owner` connection to `snackify_test`         |
| `BUSINESS_TIMEZONE`           | `Africa/Harare`         | Time zone that decides "today" for business dates       |
| `BILLING_WEEK_STARTS_ON`      | `monday`                | First day of the billing week (`monday` … `sunday`)     |
| `BASE_CURRENCY`               | `USD`                   | Currency of prices and invoices (three letters)         |
| `PAYMENT_TERMS_DAYS`          | `7`                     | Days after the issue date that an invoice is due        |
| `BUSINESS_NAME`               | `Snackify`              | Printed at the top of invoice PDFs                      |
| `BUSINESS_CONTACT`            | (none)                  | Optional contact line on invoice PDFs (address, phone)  |

**Billing week:** by default an invoice covers the last complete Monday-to-Sunday week, with
"today" decided in the `BUSINESS_TIMEZONE` (Africa/Harare). Staff can choose other dates.

Invalid values stop the server at startup with a message naming the variable. Database URLs
contain passwords, so they are never printed.

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

1. The app opens on the **Sign in to Snackify** screen. Sign in with the admin account you
   created. A wrong password shows "Incorrect username or password."
2. The dashboard opens. Your name and role are at the bottom of the menu, with **Sign out**.
3. Reload the page (or restart the app): you stay signed in until you sign out or 12 hours pass.
4. The chip in the top-right corner shows **API online** when the app can reach the backend.
5. Open **Products**. With the sample data loaded (`npm run db:seed`) you see six products.
   Search for "bbq", tick **Show inactive**, and (as an admin) use **Add product** or tap a
   product to change its price or deactivate it. Staff who are not admins can search the list
   but cannot change it.
6. Open **Stock**. Every product starts at 0. As an admin, set a product's **Reorder level**
   in Products, then use **Receive stock**:
   - choose the product (type part of its name, or scan/type its barcode),
   - enter a quantity, and optionally a batch number, expiry date and delivery note,
   - tick **Opening balance** for stock that was already on the shelf (admins, first time only).
   The **On hand** tab updates; products at or below their reorder level show **Low stock**.
7. Tap a product on **On hand** to see its history with the running balance. Admins can use
   **Adjust stock** to record damage or correct a count (a reason is required, and stock can
   never go below zero). The **Receipts** tab lists deliveries for today, the last 7 days, or
   chosen dates.
8. Open **Customers**. The sample data adds three made-up customers. Salespeople and admins
   use **Add customer** (leave the code empty to get C0001, C0002, …). Accounts staff can
   tap a customer to set a **credit limit** but cannot change the other details; admins can
   also deactivate a customer. Storekeepers can view and search only.
9. Open **Dispatches** and use **New dispatch**: choose a customer, add products (the price
   fills in from the product; change it if a different price was agreed), and **Save draft**.
   Drafts do not change stock. Open the draft: it shows stock on hand per line and warns about
   shortages or the customer's credit limit. A storekeeper or admin uses **Confirm dispatch**:
   stock is deducted and the dispatch can no longer be edited. Over the credit limit, the app
   asks first and offers **Confirm anyway**. Admins can **Reverse** a confirmed dispatch (the
   stock comes back); drafts can be cancelled with a reason.
10. Sign in as an admin or accounts user and open **Invoices**. Use **Weekly invoicing**: it
   shows last week (Monday to Sunday) and every customer with confirmed dispatches not yet
   invoiced, with their totals; the arrows and calendar choose another period. Tap a
   customer to **preview** their invoice (nothing is saved), then **Create draft invoice**,
   or create drafts for everyone at once. Open a draft to check it, then **Issue invoice**:
   it gets the next number (INV-000001, …) and today's date and can no longer be changed.
   A draft can be voided with a reason, which frees its dispatches. **Share PDF** (on a
   phone) or **Download PDF** (on the web) produces the printable invoice. A dispatch on an
   invoice can no longer be reversed. Storekeepers and salespeople cannot open invoices.
11. Open **Payments** (admins and accounts staff). **Record payment**: choose the customer,
   enter the amount, date and method (cash, bank transfer, mobile money, card, cheque) and an
   optional reference. Their unpaid invoices are listed oldest first and the amount is applied
   to them in that order; change any amount by hand. Whatever is left is kept as **credit** and
   can be applied later with **Allocate credit** on the payment. The **Balances** tab shows what
   each customer owes, split into overdue, unpaid invoices, not yet invoiced and credit; tap a
   customer for their unpaid invoices and a **statement** (issued invoices and payments with a
   running balance; choose the dates with the calendar). Invoices now show **Paid**,
   **Part paid** or **Overdue**, their due date and the payments that paid them. Admins can
   **Void** a payment recorded by mistake (with a reason); its invoices are owed again.
12. Resize the browser window: below 840 px wide, navigation moves into a menu drawer and
   products are shown as a list; wider screens show a permanent sidebar and a table.

### Checks

```powershell
flutter analyze
flutter test
dart format .
```

---

## Known limitations (Stage 9)

- **Payments are in USD only.** Every payment is recorded in the base currency; there is no way
  to record a ZiG payment yet, because mixing currencies needs a documented exchange-rate rule
  first (spec 7). Decide which currencies you accept and how rates are set, and it can be added.
- **Payment terms are the same for every customer** (`PAYMENT_TERMS_DAYS`, default 7 days after
  the invoice is issued). Invoices issued before this stage were given 7 days.
- **A payment recorded by mistake cannot be edited**: an admin voids it and it is recorded again.
  Allocations cannot be undone one by one either; void and re-record the payment instead.
- **Issued invoices cannot be corrected yet.** They are final by design; credit notes, the
  controlled way to correct them (spec 6.8), come in a later stage. Check drafts before
  issuing, and void a wrong draft instead. There are no discounts or adjustments yet.
- Statements are shown in the app only; there is no statement PDF or receipt PDF yet.
- Voided payments are left off statements, so a statement printed before a payment was voided
  will differ from one produced afterwards.
- Invoice PDFs use the plain built-in Helvetica font and no logo yet; set `BUSINESS_NAME`
  and `BUSINESS_CONTACT` in `backend/.env` for the heading.
- The PDF package used by the app (`printing`) downloads a PDF library from GitHub when
  building the **Windows desktop** app. Web and Android builds do not need it.
- No printable dispatch note yet. A customer's account (Payments → Balances) shows their
  invoices, payments and balance; their dispatches are in Dispatches.
- The Flutter dashboard still shows **sample data only**; it does not read the database yet.
- **Expiry warnings** are not shown yet. Expiry dates are recorded with each receipt, but
  dispatches do not yet record which batch they took stock from, so it is not known which
  batches are still on the shelf.
- A wrong receipt is corrected with an adjustment (with a reason), not by editing or deleting
  it, so the history stays complete.
- Camera barcode scanning comes later; a USB or Bluetooth barcode scanner (which types like a
  keyboard) already works in the product search when receiving stock.
- Product prices are shown in USD (the assumed base currency, set in
  `mobile_web/lib/core/config/app_config.dart`).
- The products screen loads up to 200 products at a time; use search to find others.
- There are no staff-management screens yet; use `npm run user:create` or the API.
- Users are not forced to change a password an admin has reset.
- The sign-in attempt counter is kept in memory: it resets when the backend restarts and
  assumes a single backend server (fine for now; revisit before scaling out).
- On the web, the session token is kept in the browser's storage, which cannot be fully
  protected from malicious scripts. Sessions expire after 12 hours and can be ended from the
  server at any time.
- If the database is down, the app's status chip shows **API offline**, because the health
  endpoint then answers 503.
- Not ready to deploy to the internet yet (needs HTTPS and production hosting).
- The backend allows browser requests only from the origins in `CORS_ORIGINS`.
- Plain HTTP is only for local development. Production must use HTTPS.
- **Keep the project out of OneDrive and other sync folders.** Sync tools lock files in
  `mobile_web/build/`, and Flutter then fails with "failed to delete a directory". The project
  lives at `C:\dev\snackify`; use Git/GitHub for backup instead.

## API documentation

See [docs/api-documentation.md](docs/api-documentation.md).
