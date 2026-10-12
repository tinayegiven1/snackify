# Snackify — Project Specification for Claude Code

> **Purpose:** Build a stock receiving, dispatching, customer billing, barcode scanning, and sales forecasting system for a small snacks business.
>
> **Primary platforms:** Responsive web application and Android application sharing one backend and database.
>
> **Users:** Approximately 2–5 staff members.
>
> **Development approach:** Build in small, testable stages. Do not attempt to implement every feature in one step.

---

## 1. Instructions for Claude Code

Act as a senior full-stack engineer helping build Snackify. Work incrementally and explain important decisions in clear, simple English.

Before changing files:
1. Inspect the existing repository and identify the current framework, files, and working features.
2. If the repository is empty, initialise the structure described below.
3. Do not overwrite working code without inspecting it first.
4. Identify assumptions and ask a concise question only when a decision blocks progress. Otherwise choose a sensible, documented default.

For each task:
- Implement only the requested stage and its necessary dependencies.
- Prefer readable, maintainable code over unnecessary abstraction.
- Use TypeScript strict mode for the backend.
- Validate all incoming data on the server.
- Add database migrations rather than relying on manually edited production schemas.
- Add tests for important business rules.
- Run the relevant formatter, linter, type checker, and tests when available.
- Report files created/changed, commands run, test results, known limitations, and the exact next step.
- Never claim a test passed unless it was actually run successfully.
- Do not expose secrets, passwords, tokens, or connection strings.
- Do not put real credentials in source control.

Use this document as the product specification. If implementation details conflict with these requirements, explain the conflict before making a significant change.

---

## 2. Product vision

Snackify should help the business track snacks from the time stock is received until products are dispatched, invoiced, paid for, and analysed.

The web and Android apps must use the same backend API and central database. A transaction entered on one platform should appear on the other after it is saved or synchronised.

### Core workflows

1. Staff register product variations such as flavour and pack size.
2. Staff record received stock, including quantity, date, batch, and optional expiry date.
3. Staff register customers.
4. Staff create dispatches containing one or more product lines.
5. The server validates available stock and confirms dispatches safely.
6. At the end of a billing period, staff generate an itemised invoice for each customer from eligible unbilled dispatches.
7. Staff record full or partial payments and view balances.
8. Staff scan barcodes to find products and speed up receiving or dispatching.
9. Managers review reports and forecast demand for upcoming weeks and months.

---

## 3. Recommended technology

Use the following stack unless the repository already has a well-established alternative that is worth retaining.

### Frontend
- **Flutter** for Android and web from a shared codebase.
- Organise Flutter code by feature.
- Keep API calls in a dedicated data/service layer, not directly inside UI widgets.
- Use responsive layouts: desktop navigation and tables for the web; touch-friendly screens for Android.
- Use a Flutter-compatible barcode scanner package, such as `mobile_scanner`, after checking current platform support.
- Generate invoice PDFs with a maintained Flutter PDF package, or have the backend generate them if that fits the architecture better.

### Backend
- Node.js using a supported LTS release.
- Express and TypeScript.
- PostgreSQL driver: `pg`.
- Request validation: `zod`.
- Security middleware such as `helmet`.
- Authentication using secure password hashing and short-lived access tokens or secure sessions, selected deliberately for the deployment model.
- Document the API using OpenAPI when practical.

### Database and hosting
- PostgreSQL is the authoritative data store.
- Use managed cloud PostgreSQL for production so both platforms can access the same data.
- A local PostgreSQL database may be used for development.
- Evaluate provider availability, connectivity from Zimbabwe, cost, backups, restore process, and connection limits before selecting production hosting.
- Use HTTPS in production.
- Never connect the Flutter client directly to PostgreSQL. All business operations must go through the backend API.

### Developer tools
- Git and GitHub.
- Visual Studio Code.
- Android Studio and an Android emulator or physical Android phone.
- Postman or an equivalent API client.
- Automated tests and database migrations.

### Forecasting
Begin with explainable baseline methods in the backend, such as moving averages and weekday averages. Add more advanced modelling only when enough reliable historical data exists. A separate Python forecasting service is optional and should not be introduced until it provides a clear benefit.

---

## 4. Proposed repository structure

```text
snackify/
├── mobile_web/                   # Flutter web and Android app
│   ├── android/
│   ├── web/
│   ├── assets/
│   │   ├── images/
│   │   ├── icons/
│   │   └── fonts/
│   ├── lib/
│   │   ├── main.dart
│   │   ├── app.dart
│   │   ├── core/
│   │   │   ├── config/
│   │   │   ├── routing/
│   │   │   ├── theme/
│   │   │   └── network/
│   │   ├── shared/
│   │   │   ├── widgets/
│   │   │   └── models/
│   │   └── features/
│   │       ├── auth/
│   │       ├── dashboard/
│   │       ├── products/
│   │       ├── stock/
│   │       ├── customers/
│   │       ├── dispatches/
│   │       ├── barcodes/
│   │       ├── invoices/
│   │       ├── payments/
│   │       ├── reports/
│   │       └── forecasting/
│   └── pubspec.yaml
├── backend/
│   ├── src/
│   │   ├── app.ts
│   │   ├── server.ts
│   │   ├── config/
│   │   ├── middleware/
│   │   ├── modules/
│   │   │   ├── auth/
│   │   │   ├── products/
│   │   │   ├── stock/
│   │   │   ├── customers/
│   │   │   ├── dispatches/
│   │   │   ├── barcodes/
│   │   │   ├── invoices/
│   │   │   ├── payments/
│   │   │   ├── reports/
│   │   │   └── forecasting/
│   │   ├── database/
│   │   ├── utils/
│   │   └── tests/
│   ├── package.json
│   ├── tsconfig.json
│   └── .env.example
├── database/
│   ├── migrations/
│   └── seeds/
├── docs/
│   ├── requirements.md
│   ├── database-design.md
│   └── api-documentation.md
├── .gitignore
└── README.md
```

Adjust folder placement if the existing repository already follows a sound structure. Do not create empty folders for every feature immediately; create feature folders as implementation begins.

---

## 5. Roles and permissions

Implement role-based access control on the backend. Hiding a button in the frontend is not sufficient permission enforcement.

- **Admin:** manage users, products, stock, customers, dispatches, invoices, payments, reports, settings, and audit records.
- **Storekeeper:** receive stock, view stock, scan barcodes, and prepare/confirm dispatches if authorised.
- **Salesperson:** manage permitted customer information and create dispatches.
- **Accounts:** generate invoices, record payments, view balances, and run financial reports.

The business may initially have one administrator and a few staff accounts. Create an initial admin through a safe setup command or one-time process. Never hard-code a production password.

---

## 6. Functional requirements

### 6.1 Authentication and staff
- Sign in and sign out.
- Secure password hashing.
- Role-based permissions enforced by the backend.
- Ability for an admin to deactivate staff accounts.
- Audit important actions with user and timestamp.
- Do not log passwords, authentication tokens, or sensitive credentials.

### 6.2 Product catalogue
Each sellable variation must have:
- Unique internal ID.
- Unique SKU/product code.
- Product name.
- Flavour.
- Size.
- Unique barcode when assigned.
- Default selling price.
- Active/inactive status.
- Created and updated timestamps.

Example: “Potato Crisps — BBQ — Small” and “Potato Crisps — BBQ — Large” are separate product variations.

Do not delete products that are referenced by historical transactions. Deactivate them instead.

### 6.3 Stock receiving
- Record quantity received, received date, batch/lot number where used, optional expiry date, supplier/reference if later required, and staff member.
- Show receipts for a selected date or date range.
- Allow scanning a barcode to select the product.
- Validate quantities and dates.
- Record stock movements as immutable ledger entries.
- Support low-stock alerts and expiry warnings.
- Record opening stock through a documented opening-balance transaction, not by silently setting a balance.

### 6.4 Stock balance and movements
- Current balance must be derived from stock movements or maintained through a transactionally consistent balance table with the movement ledger as the audit source.
- Movement types should cover receipt, dispatch, customer return, damage, adjustment, and reversal.
- Every movement must include product, quantity delta, timestamp, creator, and reference; batch reference is optional where appropriate.
- Use positive deltas for stock added and negative deltas for stock removed.
- Restrict manual adjustments to authorised users and require a reason.
- Never let normal operations silently rewrite old movements.

### 6.5 Customers
- Customer code, name, phone, address, active status, and optional credit limit.
- Customer history showing dispatches, invoices, payments, and outstanding balance.
- Validate credit rules on the server if credit limits are enforced.
- Avoid storing unnecessary personal information.

### 6.6 Dispatches
- A dispatch has a unique dispatch number, customer, date/time, user, status, and one or more line items.
- Each line item contains product, quantity, and the unit price agreed for that transaction.
- Default price may come from the product, but preserve the price snapshot on the dispatch item.
- Support draft, confirmed, and cancelled states.
- Confirming a dispatch must use a database transaction.
- Validate available stock and deduct stock atomically.
- Handle concurrent dispatch attempts safely; use appropriate row locks or equivalent transaction-safe controls.
- Reject dispatches that would make stock negative, unless a deliberate, authorised back-order feature is later designed.
- A confirmed dispatch must not be silently deleted or edited. Corrections should use a controlled reversal/return process.
- Provide a printable dispatch note if practical.

### 6.7 Barcode scanning
- Assign a unique barcode to each product variation.
- Support scanning using an Android camera.
- Allow manually entering/searching a barcode if camera scanning is unavailable.
- Show a clear “barcode not found” message.
- Avoid adding the same scan twice accidentally.
- Confirm quantities before committing a dispatch.
- Support generating printable barcode labels for products without manufacturer barcodes.
- Web scanning can be considered if browser camera permissions and device support are reliable.
- Test on a real Android device, not only an emulator.

A barcode identifies a product variation; it does not by itself prove how many packs are physically present.

### 6.8 Weekly invoices
- Allow staff to choose a customer and billing period.
- Provide a preview before issuing the invoice.
- Include every eligible confirmed, unbilled dispatch item in the period.
- Show invoice number, customer details, issue date, period covered, dispatch references/dates, product, flavour, size, quantity, unit price, line total, subtotal, adjustments/discounts if supported, amount paid, and balance due.
- Produce a printable/downloadable PDF.
- Support draft and issued states.
- Once issued, preserve the invoice snapshot. Correct errors through credit notes or another controlled correction process.
- Prevent the same dispatch item from being billed twice.
- Invoice generation must be transaction-safe when multiple staff members operate concurrently.
- Use a configurable billing-week definition. Document the default timezone and week boundary.
- Do not include cancelled dispatches in invoices.
- Keep invoice totals and payment allocations auditable.

### 6.9 Payments and balances
- Record payment date, customer, amount, currency, method, reference, and staff member.
- Support partial and full payments.
- Allocate a payment to one or more invoices, with the allocation total no greater than the payment amount.
- Calculate invoice balance from invoice total minus valid allocations/credits.
- Show customer account statements and overdue balances.
- Do not treat a dispatch or an invoice as proof that payment was received.

### 6.10 Dashboard and reports
Show, with date filters where relevant:
- Current stock by product variation.
- Stock received for a selected day/date range.
- Dispatches today and during a selected period.
- Sales value based on confirmed dispatches.
- Invoiced amount, payments received, and outstanding debt as separate measures.
- Low-stock products.
- Expiring stock.
- Best-selling products by quantity and value.
- Customer sales summaries.
- Daily, weekly, and monthly trends.

Label each metric clearly. Do not mix cash received, invoiced sales, and dispatch value as if they were the same thing.

### 6.11 Sales forecasting
- Forecast product-level demand for the next week and month.
- Base demand forecasting primarily on confirmed dispatch quantities and dates. Invoice and payment data can support financial analysis but may be delayed by weekly billing.
- Start with a moving average or weekday-average baseline.
- Record forecast creation time, model/method, horizon, predicted quantity, and optional lower/upper estimates.
- Clearly label predictions as estimates, not guaranteed sales.
- If historical data is insufficient, display that limitation instead of presenting false precision.
- Compare forecasts with actual dispatches and calculate an error metric such as MAE when enough data exists.
- Use forecasts to estimate replenishment needs, considering available stock and a configurable safety-stock quantity.
- Do not forecast returns or stock adjustments as sales demand.
- Keep forecasting calculations in a testable service separate from UI code.

### 6.12 Offline behaviour
Offline support is a later-stage feature, not a prerequisite for the first release.
- If introduced, store unsynchronised operations in a local queue with unique client-generated IDs.
- Show clearly which transactions are pending synchronisation.
- The backend must validate stock when a pending dispatch synchronises.
- Handle conflicts and rejected transactions visibly.
- Use idempotency keys to avoid duplicate submissions.
- Do not claim that a transaction is confirmed until the server has accepted it.

---

## 7. Database design

Use PostgreSQL with migrations. Use foreign keys, indexes, check constraints, and transactions.

Recommended core tables:

| Table | Purpose |
|---|---|
| `users` | Staff accounts and roles |
| `customers` | Customer details and credit settings |
| `products` | Product variations, SKU, flavour, size, barcode, default price |
| `stock_batches` | Receipt batch, date, expiry date |
| `stock_movements` | Stock ledger, positive/negative quantity delta and reference |
| `dispatches` | Dispatch header, customer, date, status, staff member |
| `dispatch_items` | Product, quantity and transaction price for each dispatch |
| `invoices` | Invoice header, customer, billing period, totals and status |
| `invoice_items` | Itemised charges linked to dispatch items |
| `payments` | Payment receipt, amount, method, date, currency |
| `payment_allocations` | Amount of a payment applied to an invoice |
| `audit_logs` | Important actions and changes |
| `forecasts` | Product, forecast date/horizon, predicted demand, method and optional bounds |

Potential later tables include suppliers, stocktakes, credit notes, price lists, notification settings, and offline sync records.

### Suggested core fields and constraints

- Use generated primary keys or UUIDs consistently.
- Use `NUMERIC`, not floating-point types, for money.
- Store timestamps as `TIMESTAMPTZ`; store business-local dates deliberately.
- Set a business timezone explicitly, initially configurable for `Africa/Harare`.
- Store currency codes on invoices and payments. Never add amounts in different currencies without a documented conversion rule.
- Use `UNIQUE` constraints for SKU, barcode when present, dispatch number, and invoice number.
- Add indexes for product/date stock movements, customer/date dispatches, invoice status, and invoice item links.
- Keep dispatch line unit prices as snapshots so later price changes do not rewrite historical sales.
- Preserve invoice totals and line descriptions as an issued snapshot.
- Prefer soft deactivation for referenced products, customers, and users.
- Use database transactions for dispatch confirmation, receipt posting, invoice issuance, payment allocation, and reversals.

### Stock ledger rule

Use `quantity_delta`:
- Receipt of 100 packs: `+100`.
- Dispatch of 12 packs: `-12`.
- Accepted return of 2 packs: `+2`.
- Damage of 1 pack: `-1`.

The example ledger gives a balance of `100 - 12 + 2 - 1 = 89` packs. Apply batch-aware stock allocation if batches and expiry dates are used operationally.

---

## 8. API design

Use a versioned API prefix, for example `/api/v1`. Validate inputs and return consistent error responses.

Initial endpoint plan:

| Method | Endpoint | Purpose |
|---|---|---|
| `GET` | `/api/v1/health` | Service health |
| `POST` | `/api/v1/auth/login` | Sign in |
| `GET` | `/api/v1/products` | List/search products |
| `POST` | `/api/v1/products` | Create product variation |
| `GET` | `/api/v1/stock/balance` | Current stock |
| `GET` | `/api/v1/stock/movements` | Movement history with date filters |
| `POST` | `/api/v1/stock/receipts` | Record receipt |
| `GET` | `/api/v1/customers` | List/search customers |
| `POST` | `/api/v1/customers` | Create customer |
| `GET` | `/api/v1/customers/:id/history` | Customer activity |
| `POST` | `/api/v1/dispatches` | Create draft dispatch |
| `POST` | `/api/v1/dispatches/:id/confirm` | Validate and confirm dispatch |
| `POST` | `/api/v1/dispatches/:id/reverse` | Controlled correction, permission protected |
| `GET` | `/api/v1/invoices/preview` | Preview eligible unbilled items |
| `POST` | `/api/v1/invoices/generate` | Generate invoice(s) for a period |
| `GET` | `/api/v1/invoices/:id/pdf` | Retrieve PDF |
| `POST` | `/api/v1/payments` | Record payment and allocations |
| `GET` | `/api/v1/reports/sales` | Sales report |
| `GET` | `/api/v1/forecasts` | Read forecasts |
| `POST` | `/api/v1/forecasts/run` | Generate forecasts |

Document request/response shapes, status codes, pagination, date formats, validation errors, and role requirements. Do not return raw database errors to clients.

---

## 9. Security, reliability, and deployment

- Use HTTPS in production.
- Hash passwords with a modern password-hashing algorithm such as Argon2id or bcrypt with appropriate parameters.
- Keep secrets in environment variables or the host's secret manager.
- Validate and authorise every sensitive API operation on the server.
- Use least-privilege database credentials.
- Apply rate limiting to authentication endpoints.
- Configure CORS for the actual frontend origins; do not use permissive wildcard settings with credentials.
- Use secure token/session handling appropriate to web and Android clients.
- Keep an audit log for stock changes, dispatch confirmation/reversal, invoice issuance, payment changes, and user administration.
- Back up the database automatically and test restoration.
- Set up structured logs without credentials or unnecessary personal data.
- Use database migrations and a separate development/test database.
- Before production, verify provider availability and performance from Zimbabwe.
- Do not include real customer data in development seeds or automated tests.

---

## 10. Four-week implementation roadmap

The following is a target for a first usable release, not a guarantee. Adjust it to available development time and test results.

### Week 1 — Foundation
1. Inspect installed tools and the existing repository.
2. Set up Flutter web/Android and the Node.js TypeScript backend.
3. Configure local PostgreSQL and environment variables.
4. Add migrations and safe seed data.
5. Implement `/api/v1/health` and a database connectivity check.
6. Create the responsive Snackify theme, app navigation, and login skeleton.
7. Verify web and Android can reach the backend.

**Acceptance:** both clients run, backend health checks pass, and database connectivity is verified.

### Week 2 — Products, stock, customers, dispatches
1. Implement products and unique barcode/SKU validation.
2. Implement stock receipts and movement history.
3. Implement current stock balance.
4. Implement customer management.
5. Implement draft dispatches and line items.
6. Implement atomic dispatch confirmation and concurrency tests.
7. Add date filters and basic stock dashboard.

**Acceptance:** receiving, dispatching, returns, and adjustments produce correct balances; insufficient stock is rejected.

### Week 3 — Invoices, payments, barcodes
1. Preview eligible unbilled dispatches by customer and period.
2. Generate invoices transactionally and prevent duplicate billing.
3. Render and test invoice PDFs.
4. Implement payments, allocations, and outstanding balances.
5. Add Android camera scanning and manual barcode search.
6. Test unknown barcodes, repeated scans, and physical-device camera permissions.

**Acceptance:** invoices reconcile to dispatch items; partial payments work; barcodes identify the correct product variation.

### Week 4 — Reports, forecasts, hardening
1. Build daily/weekly/monthly reports.
2. Implement baseline weekly and monthly demand forecasts.
3. Display forecast limitations and compare predictions with actuals.
4. Add role permissions and audit logging.
5. Add backups and verify restoration.
6. Test edge cases and user workflows.
7. Deploy a staging version, then prepare production deployment.

**Acceptance:** core stock-to-invoice workflow works end-to-end, reports reconcile with stored records, and forecasts are labelled as estimates.

---

## 11. Essential automated tests

At minimum, add tests for:
- Invalid quantities and prices are rejected.
- A receipt increases stock correctly.
- A confirmed dispatch decreases stock correctly.
- A dispatch larger than available stock is rejected.
- Concurrent dispatches cannot oversell stock.
- Repeated API requests do not duplicate a transaction when idempotency is required.
- Cancelled dispatches are excluded from invoice generation.
- A dispatch item cannot be billed twice.
- Invoice totals equal the sum of item lines and supported adjustments.
- Partial payment allocations calculate balances correctly.
- A user without permission cannot perform restricted actions.
- Unknown barcodes return a safe, clear response.
- Forecasts use only appropriate historical dispatch data.
- Insufficient history is reported honestly.
- Database backup restoration works in a test environment.

---

## 12. Definition of done

A feature is complete only when:
1. Its database migration exists if schema changes are needed.
2. The backend validates and authorises the operation.
3. The frontend has loading, success, empty, and error states.
4. Business rules are covered by tests.
5. Relevant formatting, linting, type checking, and tests pass.
6. The feature has been manually tested in the relevant browser or Android device.
7. The README or API documentation is updated.
8. Any limitations are documented.

Do not start with machine-learning complexity. First ensure that stock and dispatch data are accurate, then use that history for increasingly useful forecasts.

---

## 13. First task for Claude Code

Start with **Stage 1 only**.

1. Inspect the repository and installed project structure.
2. Check availability of Flutter, Dart, Node.js, npm, Git, and PostgreSQL tooling.
3. Report what is installed and what is missing.
4. Create or adapt the initial project structure without deleting existing work.
5. Set up a minimal Node.js/Express/TypeScript backend with:
   - `GET /api/v1/health`
   - environment configuration
   - clear error handling
   - a test for the health endpoint
6. Create the Flutter web/Android project if it does not already exist.
7. Add a basic responsive Snackify landing/dashboard shell using placeholder data only.
8. Add `.gitignore`, `.env.example`, and a concise README with exact local run commands.
9. Run the available checks and report actual results.

Do **not** implement all stock, billing, barcode, or forecasting features during Stage 1. Complete the foundation first, then wait for the next instruction.

### Stage 1 completion report format

When finished, report:
- Current repository structure.
- Tools detected and missing.
- Files created or changed.
- Commands to run the backend and Flutter app.
- URL or route used to verify backend health.
- Tests and checks actually run, with results.
- Any blockers.
- The recommended next task: PostgreSQL setup and the first database migrations.
