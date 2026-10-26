# StockFlow Stages 3–5 in Snackify: plan

Plan for `SNACKIFY_CLAUDE.md` ("Stages 3 to 5": organisations and access, products and
inventory, orders and price approvals). Written before any code was changed, as that file asks.

> **Numbering.** Snackify was already built in its own Stages 1–12 (see the README). To avoid
> confusion, the new work is called **StockFlow Stage 3, 4 and 5** here.

## 1. The existing system

| Part        | What it is                                                                                     |
| ----------- | ---------------------------------------------------------------------------------------------- |
| Backend     | Node.js 24, Express 5, TypeScript (strict), zod validation, pdfkit for PDFs, helmet, express-rate-limit |
| Database    | PostgreSQL 18. Plain-SQL migrations in `database/migrations` (node-pg-migrate), run as `snackify_owner`; the API connects as `snackify_app` (least privilege: no DDL, no deletes on business tables) |
| Clients     | One Flutter app for the web and Android (`mobile_web/`), talking only to the REST API `/api/v1` |
| Sign-in     | Username + password (Argon2id; the database rejects anything else). Opaque 256-bit session tokens sent as `Authorization: Bearer`, stored only as SHA-256 hashes, 12-hour expiry, revoked on sign-out, deactivation and password change. 10 failed attempts per 15 minutes per client address |
| Roles       | One role per user: `admin`, `storekeeper`, `salesperson`, `accounts`, checked on the server by `requireRole(...)` |
| Audit       | Append-only `audit_logs` (actor, action, entity, details as JSON; never secrets) |
| Tests       | Backend: 74 unit tests and 182 database tests (vitest, against a real `snackify_test` database). App: 116 widget tests |
| Operations  | Daily backups with an automatic restore check; staging deployment to Google Cloud prepared |

Business data today: products (name, flavour, size, barcode, price, reorder level, safety
stock), a stock ledger (`stock_movements`, append-only) with batches and expiry dates,
customers (shops), dispatches, weekly invoices, payments and allocations, reports and forecasts,
staff accounts. **There is one owner of all stock and no idea of organisations.**

## 2. What already exists, against the new file

✅ exists · 🟡 partly · ❌ missing

### StockFlow Stage 3: authentication and organisation access

| Requirement                         | Status | Notes |
| ----------------------------------- | ------ | ----- |
| Organisations (HQ + 5 subsidiaries) | ❌ | New table, seeded from a data file |
| Login, logout, current user         | ✅ | `/api/v1/auth/login`, `/logout`, `/me` |
| Argon2id passwords, never logged    | ✅ | Enforced by a database constraint |
| Session security                    | 🟡 | New token on every sign-in, timeout, revocation ✅. The spec's cookie rules (HttpOnly, Secure, SameSite) and CSRF apply to **cookie** sessions; Snackify sends a bearer token in a header, which browsers never attach on their own, so cross-site request forgery cannot work against it. See decision **D4** |
| Rate-limited sign-in                | ✅ | |
| User belongs to one organisation    | ❌ | Add `users.organisation_id`; existing users become HQ users |
| Several roles per user; permissions | ❌ | Today: one fixed role. Needs `roles`, `permissions`, `role_permissions`, `user_roles`, and every route checking a permission code instead of a role |
| Organisation scoping in data layer  | ❌ | Nothing is per organisation yet |
| Audit log with organisation and IP  | 🟡 | Add `organisation_id`, `ip_address`; log role changes and logout (sign-in, failed sign-in already logged) |

### StockFlow Stage 4: products and inventory

| Requirement                           | Status | Notes |
| ------------------------------------- | ------ | ----- |
| Products                              | 🟡 | Exist. Add `description`, `category_id`, `base_unit`; `reorder_level` serves as `min_stock_level` |
| Categories, units, unit conversions   | ❌ | New tables. Quantities stay whole numbers of the base unit (pack); the entered unit and quantity are recorded on each line |
| Batch/lot and expiry                  | ✅ | `stock_batches` |
| Suppliers, warehouses/locations       | ❌ | Today a receipt has a free-text supplier reference only |
| Balances keyed by product + owner + location (+ batch), with reserved quantity | ❌ | Today `stock_balances` is a view summing the ledger per product. Becomes a real table with the four-part key, non-negative checks and a `quantity_reserved` |
| Immutable ledger, same-transaction posting with row locks | ✅ | Already append-only (`snackify_app` cannot update or delete), and every stock change already locks the product row. Gains owner and location columns |
| Movement types                        | 🟡 | Existing: `opening_balance`, `receipt`, `dispatch`, `customer_return`, `damage`, `adjustment`, `reversal`. Add the missing ones; see the mapping in §4 |
| Corrections only by reversal/adjustment with a reason | ✅ | |
| Adjustments need authorised approval  | 🟡 | Today only admins can adjust, immediately. Becomes request → approval by someone else with `stock.adjustment.approve` |
| Receipt workflow (GRN, statuses, verification, posting) | ❌ | Today a receipt adds stock at once. Becomes a goods-received note with lines and statuses; stock is added when it is posted |
| Private, content-checked attachments  | ❌ | New. Stored outside the web root under generated names, served only through an authorised route, file type checked by content |
| GRN PDF                               | ❌ | pdfkit, as for invoices |

### StockFlow Stage 5: orders and price approvals

| Requirement                               | Status | Notes |
| ----------------------------------------- | ------ | ----- |
| Orders from subsidiaries with expected, maximum and actual prices | ❌ | New. (Existing *dispatches* are HQ's sales to shops; they stay as they are) |
| Decimal-safe totals on the server         | ✅ pattern | Money is `numeric` in the database and whole cents in code (`utils/money.ts`) |
| Price exceptions and authorised approval  | ❌ | |
| Status transitions and history            | ❌ | (Dispatches and invoices already enforce transitions in the database; the same approach is used) |
| Change log of submitted values            | ❌ | |
| Duplicate-submit protection               | ✅ pattern | Payments already use an idempotency key |
| Order sheet PDF                           | ❌ | |
| Subsidiary and HQ screens                 | ❌ | |

## 3. Stack: keep it

Nothing in the file needs a different stack. It mentions PHP functions as examples
(`password_hash`, `bcmath`); their equivalents are already in place (Argon2id through Node's
built-in crypto; whole cents and `numeric`). **No stack change is proposed.**

New dependencies (small, widely used):

- Backend: `busboy` (or `multer`) to receive file uploads; file types checked by their first
  bytes with a small built-in check (PDF `%PDF-`, JPEG `FF D8 FF`, PNG `89 50 4E 47`), no
  extension trusted.
- App: `file_picker` (web and Android) to choose documents and photos.

## 4. Design

### Organisations and access (Stage 3)

- `organisations` (`code` unique, `name`, `organisation_type` HQ/SUBSIDIARY, `is_active`,
  contact and billing fields, timestamps). Exactly one HQ (partial unique index).
- Seed: `database/seeds/organisations.json` with placeholder names for development; the real
  names go into that file (or the admin screen), never into code.
- `users.organisation_id NOT NULL`. Migration: every existing user joins HQ.
- `roles`, `permissions` (codes such as `stock.receive`, `receipt.verify`, `order.approve`,
  `price.exception.approve`), `role_permissions`, `user_roles`. Roles and their permissions are
  rows, so they can be reconfigured without code changes. The old `users.role` column is kept
  until the switch is complete, then dropped by a later migration.
- Every route asks for a **permission**, not a role: `requirePermission('stock.receive')`.
  Existing features (customers, dispatches, invoices, payments, reports, forecasts, staff) get
  permission codes too, so their behaviour does not change.
- **Scoping in the service layer:** each request carries an `AccessScope` built on the server
  from the signed-in user: either "all organisations" (HQ users with the right permission) or
  "only organisation X". Every stock, receipt, movement and order query takes the scope and adds
  the organisation filter itself; an organisation id sent by the app is only accepted if the
  scope allows it. Another organisation's record answers **404** (so its existence is not
  revealed). Tests check this by list and by direct id.
- Customers, dispatches, invoices and payments are HQ's own business and only HQ users can see
  them, as now.
- `audit_logs` gains `organisation_id` and `ip_address`; role changes and sign-out are logged.

### Stock ownership and receipts (Stage 4)

- `warehouses` (seed: one HQ main warehouse), `suppliers`, `product_categories`,
  `units` (seed: pack, carton, case), `unit_conversions` (per product, e.g. 1 carton = 24 packs).
- `stock_movements` gains `owner_organisation_id`, `warehouse_id`, `unit_id`,
  `entered_quantity`, `related_document_type`/`id` and a unique `reference`. Existing rows: owner
  HQ, HQ main warehouse.
- `stock_balances` becomes a **table** keyed by product + owner + warehouse + batch, with
  `quantity_on_hand >= 0`, `quantity_reserved >= 0`, `reserved <= on_hand`; available = on hand −
  reserved, calculated when read. It is filled from the existing ledger in the migration, then
  updated in the same transaction as each movement, under `SELECT … FOR UPDATE`. A database test
  checks that the table always equals the sum of the ledger.
- Movement types: the existing codes keep their meaning and new ones are added.

  | Spec type            | Snackify code                         |
  | -------------------- | ------------------------------------- |
  | PURCHASE_RECEIPT     | `receipt` (and `opening_balance`)     |
  | HQ_SALE_DISPATCH     | `dispatch` (existing HQ sales)        |
  | CUSTODY_RELEASE      | `custody_release` (new, reserved)     |
  | INTERNAL_TRANSFER    | `internal_transfer` (new, reserved)   |
  | RETURN_TO_SUPPLIER   | `return_to_supplier` (new, reserved)  |
  | WRITE_OFF            | `damage`                              |
  | ADJUSTMENT           | `adjustment`                          |
  | REVERSAL             | `reversal`                            |

- Goods-received notes: `stock_receipts` (GRN number, owner organisation, supplier, supplier
  invoice number, purchase date, status, received by, verified by, posted at…) and
  `stock_receipt_lines` (product, unit, quantity purchased, quantity received, unit cost,
  currency, batch, expiry, discrepancy reason). Status flow DRAFT → PENDING_VERIFICATION →
  VERIFIED / REJECTED → POSTED (→ REVERSED), enforced by the server and a database trigger.
- Posting creates the movements and updates the **owner's** balance in one transaction; a
  subsidiary-owned receipt never touches HQ's balance.
- Existing receipts are kept as they are and treated as already posted.
- Attachments: `stock_receipt_attachments` as specified; files under `ATTACHMENT_STORAGE_DIR`
  (outside the web app folder) with random names; downloads only through
  `GET /api/v1/receipts/:id/attachments/:attachmentId` after an access check. On Google Cloud
  the folder becomes a private Cloud Storage bucket (staging already planned there; a disk folder
  would be lost on restart).

### Orders (Stage 5)

- `orders` (order number, ordering organisation, dates, requested by, currency, status,
  idempotency key, totals) and `order_items` (product, unit, requested quantity, expected,
  maximum and actual unit price, totals, price-exception flag). All money `numeric(12,2)`,
  calculated on the server in whole cents; the app's totals are never trusted.
- `order_status_history` and `order_item_changes` (who, when, field, old, new); submitted values
  are never overwritten.
- Transitions DRAFT → SUBMITTED → UNDER_REVIEW → APPROVED / REJECTED, CANCELLED; rejection needs
  a comment; an order with an actual price above the maximum can only be approved by someone with
  `price.exception.approve`, with a comment.
- Order sheet PDF with pdfkit.

### Settings (configurable, not hard-coded)

New settings in `backend/.env.example`, all optional with conservative defaults:
`RECEIPT_STOCK_AVAILABLE_BEFORE_VERIFICATION=true` (owner's decision D3), `RECEIPT_DOCUMENT_REQUIRED=true`,
`ATTACHMENT_MAX_BYTES=10485760`, `ATTACHMENT_STORAGE_DIR`, `ORDERS_ALLOW_BACKORDERS=true`,
tax and discount (default none). Currency already exists (`BASE_CURRENCY`).

### App screens

New sections: Organisations (HQ), Suppliers, Warehouses, Receive Stock (GRNs), Receipt
Verification, Stock Movements, Orders, Audit Log; Staff becomes Users & Roles. On phones the
menu is grouped so it stays short. Buttons a person may not use are hidden, and the server
refuses them anyway.

## 5. Planned migrations (all additive; nothing dropped while data depends on it)

1. Organisations; `users.organisation_id` (existing users → HQ); roles, permissions,
   role_permissions, user_roles (existing roles mapped, see D2); audit log columns.
2. Categories, units, conversions, suppliers, warehouses; product columns.
3. Stock ownership: movement columns (existing rows → HQ, main warehouse), the balances table
   filled from the ledger, new movement types, adjustment requests.
4. Goods-received notes, lines and attachments.
5. Orders, items, status history, change log.
6. (Later, once nothing reads it) drop `users.role`.

A backup is taken and restore-checked (`npm run db:backup`) before applying them.

## 6. Decisions and assumptions

Decided by the owner on 2026-10-20:

| #  | Question | Decision |
| -- | -------- | -------- |
| D1 | How do the five subsidiaries relate to today's customers (shops)? | **Subsidiaries replace customers.** The subsidiaries are the buyers. Dispatch and invoicing are out of scope for this pass (Stages 6–7), so in Stages 3–5: each subsidiary organisation is linked to a customer record (`customers.organisation_id`), created automatically, so today's dispatch, invoice and payment screens keep working for subsidiaries until Stage 6 moves them onto organisations; no new stand-alone customers are added; existing customers stay (their history is kept) and can be linked to a subsidiary or deactivated by an admin |
| D2 | What roles do existing accounts get? | **Keep current powers.** `admin` → System Administrator **plus** HQ Finance Officer (the file allows "separately granted" powers); `storekeeper` → HQ Warehouse Officer; `accounts` → HQ Finance Officer; `salesperson` → a new **HQ Sales Officer** role with today's customer and dispatch permissions |
| D3 | Receipts: stock available only after verification? | **No: available immediately**, as today. `RECEIPT_STOCK_AVAILABLE_BEFORE_VERIFICATION` defaults to `true` (the file's default is the opposite; it stays a setting). Documents and costs are still verified afterwards, and a rejected receipt is corrected by a reversal |

Assumptions (the file allows conservative, documented ones):

| #  | Question | Assumption |
| -- | -------- | ---------- |
| D4 | Cookies and CSRF | Keep bearer tokens (not cookies), so CSRF does not apply; documented, and a test proves the API ignores cookies |
| D5 | Real organisation names | Placeholders for development; real names before production |
| D6 | Who sees all organisations? | Users of the HQ organisation, within their permissions. Users of a subsidiary see only their own organisation, plus the shared product catalogue |

## 7. Order of work and effort

Each stage is finished, tested and reported before the next starts, as the file asks.

1. **Stage 3** (largest refactor: every route moves from roles to permissions, with tests for
   each role and for cross-organisation access).
2. **Stage 4** (stock ownership, receipts, attachments, GRN PDF).
3. **Stage 5** (orders, price exceptions, order sheet PDF).

Each is about the size of two or three of Snackify's earlier stages.

## 8. Progress

### Stage 3: done (2026-10-20)

- [x] Repo inspected, `docs/STAGE_3_5_PLAN.md` written
- [x] Organisations table + seed (HQ + 5 subsidiaries, `database/seeds/003_sample-organisations.sql`)
- [x] Secure login/logout/current user, hashed passwords, rate limit; CSRF does not apply to
      header tokens (decision D4; a test proves cookies are ignored)
- [x] Roles, permissions, user_roles; server-side checks on every route
- [x] Organisation scoping in the data layer (stock, users, organisations, audit log)
- [x] Audit log with organisation and network address; role changes recorded
- [x] Stage 3 tests passing

Change from the plan: "keep current powers" (D2) needed old admins to hold **all four** Head
Office roles, not only System Administrator and HQ Finance Officer: otherwise they would have
lost receiving stock, confirming dispatches and printing labels.

Migration: `20261020090000000_organisations-and-permissions.sql`. Commands, from `backend`:

```powershell
npm run db:backup     # first: a restore-checked backup
npm run db:migrate
npm run db:seed       # development only: sample organisations
npm run check         # all backend checks and tests
```

### Stage 4: done (2026-10-21)

- [x] Products, categories, units, conversions, suppliers, warehouses (Catalogue screen; units
      and categories on the product form)
- [x] Stock balances keyed by product + owner + warehouse + batch (`stock_balances` table,
      kept in step by a trigger, never below zero; earliest expiry leaves first)
- [x] Immutable stock movement ledger, transactional posting (numbered `M0000001`…)
- [x] Receive Stock workflow with statuses (goods-received notes, Goods Received screen)
- [x] Multi-file private attachments with content validation
- [x] Verification (verify/reject + notes, per document and per receipt)
- [x] GRN PDF
- [x] Adjustments/reversals with reason (adjustments may name owner, warehouse and batch;
      receipts are reversed or rejected with a reason)
- [x] Stage 4 tests passing

Changes from the plan:

- The old quick receipt (`POST /api/v1/stock/receipts`) now records **opening balances only**;
  deliveries need a goods-received note, so the document rule cannot be bypassed.
- Rejecting a receipt whose stock was already added (D3) takes that stock back out; if some of
  it was already used, rejection and reversal are refused (`RECEIPT_STOCK_USED`) and the stock
  is corrected with an adjustment.
- Migrated balances: per product, owner and warehouse they equal the ledger exactly. Per batch,
  existing stock was given to the newest batches, because older dispatches recorded no batch.

Migrations: `20261021090000000_catalogue.sql`, `20261021100000000_stock-balances.sql`,
`20261021110000000_goods-received-notes.sql`. The development database was backed up
(`snackify_dev-20261021T101311.076Z.dump`) and migrated. Receipt documents are kept in
`ATTACHMENT_STORAGE_DIR` (default `storage/attachments`, ignored by Git): back it up with the
database.

### Stage 5: done (2026-10-21)

- [x] Orders + order items with expected/max/actual prices (Orders screen: subsidiaries order;
      the Head Office reviews)
- [x] Decimal-safe totals computed server-side (generated numeric columns; app totals ignored)
- [x] Price exception flag + authorised approval (`price.exception.approve` and a comment)
- [x] Status transitions + history (server and database trigger; `order_status_history`)
- [x] Change log for submitted values (submitted values locked; `order_item_changes`)
- [x] Order sheet PDF
- [x] Stage 5 tests passing (all six from the file, plus backorders, units, PDF, separation)

Decisions (conservative, documented):

- Permissions: `order.view` (Subsidiary Manager, HQ Finance, HQ Sales, System Administrator),
  `order.create` (Subsidiary Manager), `order.price`, `order.approve` and
  `price.exception.approve` (HQ Finance Officer: the file's "confirm selling prices, approve
  price exceptions"). The System Administrator role alone cannot approve prices.
- Reviewing, pricing and deciding are for Head Office staff only, whatever the permissions.
- A subsidiary may cancel its order while it is a draft or submitted, with a reason; once the
  review starts, only the Head Office can reject it.
- Price exception: any actual price above the maximum (no tolerance setting yet).
- Backorders allowed by default (`ORDERS_ALLOW_BACKORDERS=true`); approval does not reserve or
  move stock (dispatching approved orders is the next stage). Head Office stock is shown to Head
  Office staff only.
- Tax and discount: hooks only (`tax_amount`, `discount_amount`, 0).
- Idempotency: a key per new order, unique per person; the same key returns the first order.

Migration: `20261021120000000_orders.sql`. The development database was backed up
(`snackify_dev-20261021T112726.895Z.dump`) and migrated.

### Owner changes after Stage 5 (2026-10-21 to 2026-10-26)

- **Sign-in by PIN instead of password.** Every account starts on the PIN 1234 and must choose
  its own (4–8 digits, not easy to guess) at the first sign-in before doing anything else; an
  admin's Reset PIN puts it back on 1234. Five wrong PINs in a row lock the account for 15
  minutes. Migration `20261021130000000_pin-sign-in.sql` reset every existing account to 1234.
- **No supplier on goods-received notes.** The Supplier field was removed from Receive Stock and
  is no longer required to submit (migration `20261021140000000_receipt-supplier-optional.sql`);
  the supplier invoice number and documents are still recorded.
