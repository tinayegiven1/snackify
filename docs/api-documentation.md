# Snackify API

Base URL (local development): `http://localhost:3000/api/v1`

All endpoints are versioned under `/api/v1`. Requests and responses use JSON. Dates and times
are ISO 8601 strings in UTC (for example `2026-10-12T10:52:24.950Z`).

## Error format

Every error response has the same shape, so clients can handle errors in one place:

```json
{
  "error": {
    "code": "NOT_FOUND",
    "message": "Route GET /api/v1/unknown was not found.",
    "details": {}
  }
}
```

`details` is optional and only present when there is extra, safe information. For validation
errors it lists each invalid field:

```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "Some fields are missing or invalid.",
    "details": [{ "field": "newPin", "message": "Use at least 4 digits" }]
  }
}
```

Raw database errors, stack traces and submitted values are never returned.

| Status | `code`                     | When                                                       |
| ------ | -------------------------- | ---------------------------------------------------------- |
| 400    | `INVALID_JSON`             | The request body is not valid JSON                         |
| 400    | `VALIDATION_ERROR`         | One or more fields are missing or invalid (see `details`)  |
| 401    | `UNAUTHENTICATED`          | No session token, or the session has ended                 |
| 401    | `INVALID_CREDENTIALS`      | Wrong username or PIN (same answer for both)               |
| 403    | `PIN_CHANGE_REQUIRED`      | The account is on the starting PIN 1234: choose a new PIN first |
| 423    | `ACCOUNT_LOCKED`           | 5 wrong PINs in a row: the account is locked for 15 minutes |
| 403    | `FORBIDDEN`                | Signed in, but the role does not allow this action         |
| 404    | `NOT_FOUND`                | The route does not exist                                   |
| 404    | `USER_NOT_FOUND`           | No staff account has that id                               |
| 409    | `USERNAME_TAKEN`           | The username is already used (letter case is ignored)      |
| 409    | `CANNOT_CHANGE_OWN_ACCESS` | An admin tried to change their own role or deactivate themselves |
| 409    | `USE_CHANGE_PASSWORD`      | An admin tried to reset their own password                 |
| 409    | `PRODUCT_INACTIVE`         | Stock cannot be received for a deactivated product         |
| 409    | `OPENING_BALANCE_NOT_ALLOWED` | The product already has stock records                   |
| 409    | `INSUFFICIENT_STOCK`       | The change would leave less than zero in stock             |
| 409    | `CUSTOMER_CODE_TAKEN`      | Another customer already uses that code                    |
| 404    | `CUSTOMER_NOT_FOUND`       | No customer has that id                                    |
| 404    | `DISPATCH_NOT_FOUND`       | No dispatch has that id                                    |
| 409    | `DISPATCH_NOT_DRAFT`       | Only drafts can be edited, cancelled or confirmed          |
| 409    | `DISPATCH_NOT_CONFIRMED`   | Only confirmed dispatches can be reversed                  |
| 409    | `DISPATCH_DATE_IN_FUTURE`  | A dispatch dated in the future cannot be confirmed yet     |
| 409    | `CUSTOMER_INACTIVE`        | The customer has been deactivated                          |
| 409    | `CREDIT_LIMIT_EXCEEDED`    | Confirming would go over the credit limit (see below)      |
| 413    | `PAYLOAD_TOO_LARGE`        | The request body is larger than 100 KB                     |
| 429    | `TOO_MANY_ATTEMPTS`        | 10 failed PIN attempts from one address in 15 minutes      |
| 500    | `INTERNAL_ERROR`           | Unexpected server error (details are logged)               |

## Signing in and permissions

1. `POST /api/v1/auth/login` with a username and **PIN** returns a session `token`.
2. Send it on every other request: `Authorization: Bearer <token>`.
3. A session lasts 12 hours. It ends earlier on sign-out, when an admin resets the PIN or
   deactivates the account, or when the user changes their PIN on another device.
4. Every account starts on the PIN **1234** (`user.mustChangePin: true`). Until it chooses its
   own PIN (`POST /api/v1/auth/change-pin`), every other request except `GET /auth/me` and
   `POST /auth/logout` answers **403** `PIN_CHANGE_REQUIRED`.

**Permissions** (StockFlow Stage 3, see [STAGE_3_5_PLAN.md](STAGE_3_5_PLAN.md)). Each user
belongs to one organisation (the Head Office or a subsidiary) and holds one or more **roles**;
each role is a set of **permission codes** such as `stock.receive`. Endpoints check permission
codes, on the server, on every request; `403 FORBIDDEN` means none of the user's roles allows
it. Which role has which permission is data (`GET /api/v1/roles`), changeable without code.

| Role (code)                                    | Organisation | Main permissions |
| ---------------------------------------------- | ------------ | ---------------- |
| System Administrator (`system_admin`)          | HQ           | `organisation.manage`, `user.manage`, `role.manage`, `audit.view`, `product.manage`, `stock.adjust`, `stock.opening_balance`, `dispatch.reverse`, `payment.void`, `customer.change_active` |
| HQ Warehouse Officer (`hq_warehouse_officer`)  | HQ           | `stock.receive`, `dispatch.draft`, `dispatch.confirm`, `label.print`, `report.stock`, `forecast.use` |
| HQ Finance Officer (`hq_finance_officer`)      | HQ           | `invoice.manage`, `payment.manage`, `customer.edit_credit_limit`, `report.financial`, `report.stock`, `forecast.use` |
| HQ Sales Officer (`hq_sales_officer`)          | HQ           | `customer.edit_details`, `dispatch.draft` |
| Subsidiary Manager (`subsidiary_manager`)      | Subsidiary   | `stock.view` (own organisation); orders from Stage 5 |
| Subsidiary Storekeeper (`subsidiary_storekeeper`) | Subsidiary | `stock.view` (own organisation) |

All Head Office roles also have `stock.view`, `customer.view`, `dispatch.view` and
`report.dashboard`. A subsidiary's staff can only hold subsidiary roles (the database refuses
anything else).

**Organisation separation.** Head Office staff may see every organisation's records; a
subsidiary's staff only their own, plus the shared product catalogue. The organisation is always
taken from the signed-in user; an `organisationId` sent by the app is only accepted when the user
may see that organisation, and another organisation's record answers **404** (so its existence
is not revealed).

**Sessions** are read only from the `Authorization` header, never from cookies, so another
website cannot act through a signed-in browser (no cross-site request forgery).

## Endpoints

### `GET /api/v1/health`

Reports whether the API is running and can reach PostgreSQL (it runs `SELECT 1`, waiting at most
2 seconds). No authentication required. Responses are never cached.

**200 OK**: the API and database are working.

```json
{
  "status": "ok",
  "service": "snackify-api",
  "environment": "development",
  "timestamp": "2026-10-12T12:21:18.369Z",
  "uptimeSeconds": 12,
  "checks": { "database": "up" }
}
```

**503 Service Unavailable**: the API is running but cannot reach the database, so it cannot
serve requests. The reason is written to the server log, never to the response.

```json
{
  "status": "unavailable",
  "service": "snackify-api",
  "environment": "development",
  "timestamp": "2026-10-12T12:21:19.449Z",
  "uptimeSeconds": 1,
  "checks": { "database": "down" }
}
```

### `POST /api/v1/auth/login`

Public. Rate-limited: after 10 failed attempts from one network address within 15 minutes,
further attempts get `429` (successful sign-ins do not count). After 5 wrong PINs in a row an
account is locked for 15 minutes (**423** `ACCOUNT_LOCKED`, even with the right PIN; a correct
PIN resets the count; an admin's reset unlocks it). Usernames are not case-sensitive.

Request:

```json
{ "username": "tendai", "pin": "4826" }
```

**200 OK**

```json
{
  "token": "x3cU8...43 characters",
  "expiresAt": "2026-10-13T00:47:25.123Z",
  "user": {
    "id": "7f9c2b1e-...",
    "username": "tendai",
    "fullName": "Tendai Moyo",
    "organisation": { "id": "3b1f...", "code": "HQ", "name": "Head Office", "type": "HQ" },
    "roles": [{ "code": "hq_warehouse_officer", "name": "HQ Warehouse Officer" }],
    "permissions": ["customer.view", "dispatch.confirm", "dispatch.draft", "stock.receive", "stock.view"],
    "mustChangePin": false
  }
}
```

(The permission list is shortened here.) **401** `INVALID_CREDENTIALS` for a wrong PIN, an
unknown username, a deactivated account, or an account whose organisation is deactivated. The
answer is identical in every case.

### `POST /api/v1/auth/logout`

Signed in. Ends the current session. **204 No Content**.

### `GET /api/v1/auth/me`

Signed in. **200 OK** with `{ "user": { ... } }`, the same as the sign-in answer. Roles and
permissions are read on every request, so a change an admin makes applies at once.

### `POST /api/v1/auth/change-pin`

Signed in (also on the starting PIN). Changes your own PIN and signs you out on every other
device.

```json
{ "currentPin": "1234", "newPin": "58203" }
```

**200 OK** with `{ "user": { ..., "mustChangePin": false } }`. **400** `VALIDATION_ERROR` if the
current PIN is wrong, or the new one is not 4–8 digits, is 1234 or easy to guess (0000, 1111,
4321, 2468 …), or equals the current one. Rate-limited like sign-in. Audited as
`auth.pin_changed`.

## Staff accounts (`user.manage`)

New accounts start on the PIN 1234 and must choose their own at the first sign-in. Usernames are 3–32 characters (letters, digits, `.`, `-`,
`_`) and are stored in lower case. Accounts are never deleted; deactivate them instead.

### `GET /api/v1/users`

Optional `?organisationId=`. **200 OK**, active accounts first. PIN hashes are never returned.

```json
{
  "users": [
    {
      "id": "7f9c2b1e-...",
      "username": "tendai",
      "fullName": "Tendai Moyo",
      "organisation": { "id": "3b1f...", "code": "HQ", "name": "Head Office", "type": "HQ" },
      "roles": [{ "code": "hq_warehouse_officer", "name": "HQ Warehouse Officer" }],
      "isActive": true,
      "createdAt": "2026-10-12T12:35:43.000Z",
      "lastSignInAt": "2026-10-12T12:47:25.000Z"
    }
  ]
}
```

### `POST /api/v1/users`

```json
{
  "username": "rudo",
  "fullName": "Rudo Chikore",
  "organisationId": "3b1f...",
  "roleCodes": ["hq_finance_officer", "hq_warehouse_officer"]
}
```

**201 Created** with `{ "user": { ... } }`. **409** `USERNAME_TAKEN`. **400** with a `roleCodes`
field error for an unknown role, or one that does not suit the organisation.

### `PATCH /api/v1/users/:id`

Send any of `fullName`, `organisationId`, `roleCodes`, `isActive`. Other fields are rejected.

```json
{ "roleCodes": ["system_admin"] }
```

**200 OK** with `{ "user": { ... } }`. Role changes apply to the user's next request. Moving
someone to another organisation needs roles that suit it, and signs them out. Setting
`isActive: false` signs the user out everywhere at once. Admins cannot change their own roles or
organisation, or deactivate themselves (`409 CANNOT_CHANGE_OWN_ACCESS`), so there is always an
active admin. Role changes are audited as `user.roles_changed` (from and to).

### `POST /api/v1/users/:id/reset-pin`

No body. Puts the account back on the PIN 1234 (to be changed at the next sign-in), unlocks it
and signs it out everywhere. **200 OK** with `{ "pin": "1234", "mustChangePin": true }`. Admins
change their own PIN with `/auth/change-pin` instead (`409 USE_CHANGE_PIN`). Audited as
`user.pin_reset`.

## Roles (`user.manage` or `role.manage`)

### `GET /api/v1/roles`

**200 OK** with every role (`code`, `name`, `description`, `organisationType` `HQ` or
`SUBSIDIARY`, `permissions`) and every permission (`code`, `description`).

### `PUT /api/v1/roles/:code/permissions` (`role.manage`)

```json
{ "permissions": ["stock.view", "customer.view", "report.dashboard", "forecast.use"] }
```

Replaces what the role allows, for everyone holding it, at once. **200 OK** with `{ "role" }`.
The System Administrator role must keep `user.manage` and `role.manage`
(`409 PERMISSION_REQUIRED`). Audited as `role.permissions_changed`.

## Organisations

Everyone signed in sees the organisations they may access (Head Office staff: all; a
subsidiary's staff: their own). Adding and changing them needs `organisation.manage`.
Organisations are deactivated, never deleted.

### `GET /api/v1/organisations`

Optional `?includeInactive=true`. **200 OK**:

```json
{
  "organisations": [
    {
      "id": "8c2e...",
      "code": "SUB-01",
      "name": "Bulawayo Branch",
      "type": "SUBSIDIARY",
      "isActive": true,
      "contactName": "Nomsa Dube",
      "contactPhone": "+263 29 222 3333",
      "contactEmail": "orders@bulawayo.example",
      "address": "5 Fife Street, Bulawayo",
      "billingName": null,
      "billingAddress": null,
      "taxNumber": null,
      "customerId": "41aa...",
      "createdAt": "...",
      "updatedAt": "..."
    }
  ]
}
```

### `GET /api/v1/organisations/:id`

**200 OK** with `{ "organisation" }`, or **404** `ORGANISATION_NOT_FOUND` (also for an
organisation the user may not see).

### `POST /api/v1/organisations` (adds a subsidiary)

```json
{ "code": "bul-01", "name": "Bulawayo Branch", "contactPhone": "+263 29 222 3333" }
```

Codes are 2–20 letters, digits, `-` or `_`, stored in upper case. The subsidiaries are the
buyers (decision D1), so a **customer record** is created with it, in the same transaction, for
today's dispatch and invoice screens (its code is the subsidiary's code when free). To reuse an
existing customer record instead, send `"existingCustomerId"` (only one not linked yet).
**201 Created**; **409** `ORGANISATION_CODE_TAKEN`.

### `PATCH /api/v1/organisations/:id`

Send any of `code`, `name`, the contact and billing fields (`null` clears one), `isActive`. The
linked customer record keeps the subsidiary's name and active state. Deactivating a subsidiary
signs its staff out and stops them signing in; the Head Office cannot be deactivated
(`409 HEAD_OFFICE_ALWAYS_ACTIVE`).

## Audit log (`audit.view`)

### `GET /api/v1/audit-logs`

Newest first. Optional `from`, `to` (dates), `action` (`user.created`, or a group such as
`stock`), `userId`, `organisationId`, `limit` (1–200, default 50), `offset`.

```json
{
  "entries": [
    {
      "id": "...",
      "occurredAt": "2026-10-20T09:15:00.000Z",
      "action": "user.roles_changed",
      "actor": { "id": "...", "fullName": "Tendai Moyo" },
      "organisation": { "id": "...", "code": "HQ" },
      "entityType": "user",
      "entityId": "...",
      "details": { "from": ["hq_sales_officer"], "to": ["system_admin"] },
      "ipAddress": "192.0.2.10"
    }
  ],
  "total": 1
}
```

Every entry records the organisation and network address of the request. Passwords and tokens
are never recorded.

## Products

Everyone signed in can view products; only **admins** can add or change them (spec section 5).
Products are never deleted (there is no DELETE endpoint); deactivate them instead.

Prices are exact decimal **strings** such as `"0.50"`, in the business's base currency (USD),
so money is never rounded by floating-point maths. When sending a price, a string (`"0.5"`) or a
JSON number (`0.5`) is accepted; it must be 0 or more with at most 2 decimal places.

| Field          | Rules                                                                 |
| -------------- | --------------------------------------------------------------------- |
| `sku`          | Required, unique. Stored in capitals: letters, digits, `.` `_` `-`, up to 40 |
| `name`         | Required, up to 100 characters                                        |
| `flavour`      | Required, up to 60 characters                                         |
| `size`         | Required, up to 40 characters                                         |
| `barcode`      | Optional; `null` or `""` for none. Unique when set; 4–48 letters, digits or `-` |
| `defaultPrice` | Required, see above                                                   |
| `reorderLevel` | Optional whole number (packs); stock at or below it counts as low. `null` for no alert |
| `safetyStock`  | Optional whole number (packs), default 0: kept on top of forecast demand when suggesting how much to receive |
| `isActive`     | Changes only; `false` hides the product from normal lists             |
| `description`  | Optional free text, up to 500 characters (StockFlow Stage 4)          |
| `categoryId`   | Optional; an active category from `/api/v1/categories`, or `null`     |
| `baseUnitId`   | Optional; the unit stock is counted in (default: pack). Cannot change once the product has stock records (**409** `BASE_UNIT_IN_USE`) |

Each product also returns `category` (`{ id, name }` or `null`), `baseUnit` (`{ id, code,
name }`) and `conversions`: the larger units it is bought in, e.g.
`[{ "unit": { "code": "carton", … }, "baseQuantity": 24 }]` (1 carton = 24 packs).

The same name + flavour + size cannot be registered twice (letter case is ignored).

Product errors: **409** `SKU_TAKEN` or `BARCODE_TAKEN` (with `details` naming the field),
**409** `PRODUCT_EXISTS` (same name, flavour and size), **404** `PRODUCT_NOT_FOUND`.

### `GET /api/v1/products`

Query parameters, all optional:

| Parameter         | Meaning                                                                  |
| ----------------- | ------------------------------------------------------------------------ |
| `q`               | Part of the SKU, name, flavour or size (case ignored), or an exact barcode |
| `includeInactive` | `true` to include deactivated products                                   |
| `limit`           | 1–200, default 50                                                        |
| `offset`          | 0 or more, default 0                                                     |

**200 OK**, sorted by name, flavour, size. `total` is the number of matches, which may be more
than one page.

```json
{
  "products": [
    {
      "id": "3b0d6c5e-...",
      "sku": "PC-BBQ-S",
      "name": "Potato Crisps",
      "flavour": "BBQ",
      "size": "Small",
      "barcode": "2000000000015",
      "defaultPrice": "0.50",
      "isActive": true,
      "createdAt": "2026-10-12T12:18:44.000Z",
      "updatedAt": "2026-10-12T12:18:44.000Z"
    }
  ],
  "total": 1
}
```

### `GET /api/v1/products/:id`

**200 OK** with `{ "product": { ... } }`.

### `POST /api/v1/products` (admins)

```json
{
  "sku": "PC-SV-L",
  "name": "Potato Crisps",
  "flavour": "Salt & Vinegar",
  "size": "Large",
  "barcode": null,
  "defaultPrice": "1.00"
}
```

**201 Created** with `{ "product": { ... } }`. Recorded in the audit log as `product.created`.

### `PATCH /api/v1/products/:id` (admins)

Send only the fields to change. Leaving `barcode` out keeps it; `"barcode": null` removes it.

```json
{ "defaultPrice": "0.55", "isActive": false }
```

**200 OK** with `{ "product": { ... } }`. The audit log records exactly what changed, e.g.
`{"changes": {"defaultPrice": {"from": "0.50", "to": "0.55"}}}`. Earlier sales keep the
price they were made at; only new transactions use the new default.

### `PUT /api/v1/products/:id/conversions` (`product.manage`)

`{ "conversions": [{ "unitId": "…", "baseQuantity": 24 }] }` replaces the product's
conversions. `baseQuantity` is a whole number of base units, 2–100,000; the base unit itself
cannot be listed. Quantities entered in a unit are converted exactly (3 cartons = 72 packs);
a unit without a conversion is refused.

### Barcodes (spec 6.7)

A barcode identifies a product variation; it does not prove how many packs are physically
present. Each product has at most one barcode, and no two products share one.

- **Manufacturer barcodes** (EAN-13, UPC-A, or anything of 4–48 letters, digits or `-`) are
  typed or scanned into the product by an admin.
- **Snackify's own barcodes** are for packs without one. They are EAN-13 codes starting with
  **20**: GS1 reserves prefixes 20–29 for numbers used only inside a business, so they never
  clash with a manufacturer's barcode. They are numbered from `internal_barcode_seq`; a number
  already used by another product is skipped.

### `GET /api/v1/products/barcode/:barcode` (everyone signed in)

Finds the product with exactly this barcode, active or not (check `isActive` before using it
in a transaction). Spaces are ignored (`"6 001234 567890"`). **200 OK** with
`{ "product": { … } }`.

- **404** `BARCODE_NOT_FOUND`: `No product has the barcode 6009876543210.`
- **400** `VALIDATION_ERROR` (field `barcode`): anything other than letters, digits and dashes,
  or more than 48 characters. What was sent is never repeated back.

Only an exact match counts, so part of a barcode (a misread scan) finds nothing.

### `POST /api/v1/products/:id/barcode` (admins)

Gives a product without a barcode one of Snackify's own (`2000000000015`, `2000000000022`, …).
**200 OK** with `{ "product": { … } }`. **409** `PRODUCT_HAS_BARCODE` if it already has one.
Recorded in the audit log as `product.barcode_assigned`.

### `GET /api/v1/products/:id/labels` (storekeepers and admins)

Printable barcode labels as a PDF: A4 sheets of 24 labels (3 across, 8 down, 70 × 37 mm, the
common "24 per sheet" size). Each label shows the product (name, flavour, size), its SKU and
the EAN-13 barcode at its standard size (0.33 mm bars, about 37 mm wide with margins), with the
digits underneath.

| Query   | Meaning                                                                       |
| ------- | ----------------------------------------------------------------------------- |
| `count` | Number of labels, 1–240 (default 24, one sheet)                               |
| `skip`  | Labels already used on the first sheet, 0–23 (default 0): printing starts after them |

`Content-Type: application/pdf`, file name `labels-PC-BBQ-S.pdf`. **409**
`PRODUCT_HAS_NO_BARCODE` when the product has no barcode, and **409** `BARCODE_NOT_PRINTABLE`
when its barcode is not an EAN-13 (UPC-A barcodes are printed as EAN-13 with a leading 0).

## Stock

Stock is kept as a **ledger**: every change is a movement with a signed `quantityDelta`
(positive adds stock, negative removes it). Movements are never edited or deleted, and stock on
hand is always the sum of the ledger. Business dates (`receivedDate`, `businessDate`) are
`YYYY-MM-DD` in the business time zone (`BUSINESS_TIMEZONE`, default `Africa/Harare`) and may not
be in the future.

**Stock belongs to an organisation** (StockFlow Stage 3). Where stock is kept is not who owns
it: every batch and movement records its owner. The `GET` endpoints below take an optional
`organisationId` (default: the user's own organisation); Head Office staff may ask for any
organisation, a subsidiary's staff only their own (another organisation answers **404**).
Stock arrives through **goods-received notes** (below), which say whose stock it is; a
subsidiary-owned receipt adds only to that subsidiary's balance. Dispatches are the Head
Office's stock.

Balances are kept per product, owner, warehouse and delivery batch (`stock_balances`), updated
in the same transaction as each movement; they can never go below zero. Stock leaves the
earliest-expiring batch first (FEFO; batches without an expiry date last).

| Action                                      | Permission                                |
| ------------------------------------------- | ----------------------------------------- |
| View balances, receipts and movements       | `stock.view` (own organisation, or any for the Head Office) |
| Receive stock (goods-received notes)        | `stock.receive`                           |
| Record an opening balance                   | `stock.opening_balance`                   |
| Damage and corrections (adjustments)        | `stock.adjust`, with a reason             |

Movement types: `opening_balance`, `receipt`, `damage`, `adjustment`, `dispatch`,
`customer_return`, `reversal`, and (reserved for later stages) `custody_release`,
`internal_transfer`, `return_to_supplier`. Every movement has a unique reference such as
`M0000042`.

### `POST /api/v1/stock/receipts` (opening balances only)

Since StockFlow Stage 4 deliveries are recorded as goods-received notes; this endpoint only
records **opening balances** and refuses anything else with **409** `USE_GOODS_RECEIVED_NOTE`.

```json
{
  "productId": "3b0d6c5e-...",
  "quantity": 48,
  "receivedDate": "2026-10-12",
  "batchNumber": "L2026-10A",
  "expiryDate": "2027-02-01",
  "supplierReference": "Delivery note 1042",
  "isOpeningBalance": true
}
```

`productId`, `quantity` (a whole number, 1–1,000,000) and `isOpeningBalance: true` are required. `receivedDate`
defaults to today; `expiryDate` may not be before it. Empty optional text counts as "not given".

An **opening balance** (`isOpeningBalance: true`, admins only) records stock that was already on
the shelf. It is only allowed while the product has no stock records at all; after that, use an
adjustment.

**201 Created**

```json
{
  "receipt": {
    "id": "…",
    "product": { "id": "…", "sku": "MP-CH-S", "name": "Maize Puffs", "flavour": "Cheese", "size": "Small" },
    "quantity": 48,
    "receivedDate": "2026-10-12",
    "batchNumber": "L2026-10A",
    "expiryDate": "2027-02-01",
    "supplierReference": "Delivery note 1042",
    "isOpeningBalance": false,
    "receivedBy": { "id": "…", "fullName": "Tendai Moyo" },
    "createdAt": "2026-10-12T13:05:00.000Z"
  },
  "quantityOnHand": 68
}
```

### `GET /api/v1/stock/receipts`

Query: `from`, `to` (default: today), optional `productId`. At most 366 days.
**200 OK** with `{ "from", "to", "receipts": [ … ], "totalQuantity": 60 }`, newest first.

### `POST /api/v1/stock/adjustments` (admins)

```json
{ "productId": "…", "type": "damage", "quantityDelta": -2, "reason": "Packs torn in transit" }
```

`type` is `damage` (must be negative) or `adjustment` (either direction, e.g. after a stock
count). `reason` is required (3–500 characters). `businessDate` is optional (default today).
Optional `organisationId`, `warehouseId` and `batchId` say whose stock, where, and which
delivery (defaults: the user's own organisation, the default warehouse; removals take the
earliest-expiring batches first, additions go to unbatched stock unless a batch is named).
Refused with **409** `INSUFFICIENT_STOCK` if it would leave less than zero. Recorded in the audit
log as `stock.adjusted` with the balance before and after.

**201 Created** with `{ "movement": { … }, "quantityOnHand": 98 }`.

### `GET /api/v1/stock/balance`

Query: optional `q` (as for products), `lowStockOnly=true`, `includeInactive=true`.

```json
{
  "balances": [
    {
      "product": { "id": "…", "sku": "MP-CH-S", "name": "Maize Puffs", "flavour": "Cheese", "size": "Small", "isActive": true },
      "quantityOnHand": 20,
      "reorderLevel": 50,
      "isLowStock": true,
      "quantityReserved": 0,
      "quantityAvailable": 20
    }
  ]
}
```

### `GET /api/v1/stock/movements`

Query: optional `productId`, `from`, `to`, `limit` (1–500, default 100), `offset`.
Newest first. `balanceAfter` is the product's stock straight after each movement was recorded.

```json
{
  "movements": [
    {
      "id": "…",
      "product": { "id": "…", "sku": "PC-BBQ-S", "name": "Potato Crisps", "flavour": "BBQ", "size": "Small" },
      "type": "damage",
      "quantityDelta": -3,
      "businessDate": "2026-10-12",
      "occurredAt": "2026-10-12T13:20:00.000Z",
      "reference": null,
      "reason": "Torn",
      "batchNumber": null,
      "createdBy": { "id": "…", "fullName": "Demo Admin" },
      "balanceAfter": 97,
      "movementNumber": "M0000042",
      "warehouse": { "id": "…", "code": "HQ-MAIN" },
      "entered": null,
      "relatedDocument": null
    }
  ],
  "total": 3
}
```

`entered` is what was typed when it was not the base unit, e.g. `{ "unit": "carton",
"quantity": 3 }` for a 72-pack movement. `relatedDocument` points at the source, e.g.
`{ "type": "stock_receipt", "id": "…" }`.

## Catalogue: categories, units, suppliers, warehouses

`/api/v1/categories`, `/api/v1/units`, `/api/v1/suppliers` and `/api/v1/warehouses` all work
the same way. Everyone signed in can read them (`GET`, with `includeInactive=true` to include
deactivated entries) and receives `{ "items": [ … ] }`. `POST` adds one and `PATCH /:id` changes
one (including `isActive`); both answer `{ "item": { … } }`. Nothing is deleted. Changes are
recorded in the audit log (`catalogue.created`, `catalogue.updated`).

| List        | Fields                                                              | Changed with       |
| ----------- | ------------------------------------------------------------------- | ------------------ |
| categories  | `name` (unique, ignoring letter case)                               | `catalogue.manage` |
| units       | `code` (lower case, e.g. `carton`), `name`                          | `catalogue.manage` |
| suppliers   | `code` (2–20 capitals, digits, `-`, `_`), `name`, `contactName`, `phone`, `email`, `address` | `supplier.manage` |
| warehouses  | `code`, `name`, `address`; also returns `isDefault`, `organisationId` | `catalogue.manage` |

The default warehouse (`HQ-MAIN`) stays active (**409** `DEFAULT_WAREHOUSE_ACTIVE`). A code or
name already used answers **409** `ALREADY_EXISTS` with the field in `details`.

## Goods-received notes (`/api/v1/receipts`)

A goods-received note (GRN, numbered `GRN000001` …) records one delivery: whose stock it is
(`organisationId`: the Head Office or, for Head Office staff, a subsidiary), the supplier, the
supplier's invoice number, dates, and one line per product with the quantity **bought** and the
quantity **received** (in any unit the product has), the unit cost, batch and expiry. Supplier
documents (PDF, JPEG, PNG) are attached to it.

Statuses: `DRAFT` → `PENDING_VERIFICATION` → `VERIFIED` or `REJECTED` → `POSTED` → `REVERSED`.
The server and a database trigger allow only these steps, and a submitted receipt's details and
lines never change.

**When stock is added** (`RECEIPT_STOCK_AVAILABLE_BEFORE_VERIFICATION`, default `true`, the
owner's decision D3): on submission, so it can be used at once. Verifying then makes it
`POSTED`; rejecting takes the stock back out. With `false`, verification makes it `VERIFIED`
and `POST /:id/post` adds the stock. Each line becomes one delivery batch and one `receipt`
movement for the owner, all in one transaction (a failure part-way changes nothing).

| Action                                                  | Permission            |
| ------------------------------------------------------- | --------------------- |
| List, view, PDF, download documents                     | `stock.view` (own organisation; the Head Office sees all) |
| Create, change drafts, attach documents, submit, post   | `stock.receive`       |
| Submit without a document (with a reason)               | `receipt.no_document` |
| Review documents, verify or reject the receipt          | `receipt.verify`      |
| Reverse a posted receipt                                | `receipt.reverse`     |

A receipt outside the user's access answers **404** `RECEIPT_NOT_FOUND`.

### `POST /api/v1/receipts` and `PUT /api/v1/receipts/:id` (drafts)

```json
{
  "organisationId": "…",
  "warehouseId": null,
  "supplierId": "…",
  "supplierInvoiceNumber": "INV-1042",
  "purchaseDate": "2026-10-19",
  "receivedDate": "2026-10-20",
  "notes": null,
  "lines": [
    {
      "productId": "…",
      "unitId": "…",
      "quantityPurchased": 3,
      "quantityReceived": 3,
      "unitCost": "10.20",
      "batchNumber": "L2026-10A",
      "expiryDate": "2027-02-01",
      "discrepancyReason": null,
      "notes": null
    }
  ]
}
```

`organisationId` defaults to the user's own; `warehouseId` to the default warehouse;
`receivedDate` to today (never in the future; `purchaseDate` not after it, expiry dates not
before it). A supplier may be left out of a draft but is required to submit. Quantities are
whole numbers 0–1,000,000 (not both 0); `unitCost` has up to 4 decimal places.
`discrepancyReason` (`shortage`, `overage`, `damaged`, `rejected`) is required exactly when
the quantities differ. Line totals (quantity bought × unit cost, rounded to cents) and the total
are worked out by the database, exactly. **201** / **200** with `{ "receipt": { … } }`.

A receipt returns its summary (`id`, `grnNumber`, `status`, `owner`, `warehouse`, `supplier`,
`receivedDate`, `currency`, `total`, `lineCount`, `attachmentCount`, `stockAdded`) plus
`flags`: `discrepancies` (lines that differ), `documentTotalMismatch` (a document's total, as
the reviewer read it, differs from the GRN total) and `documentsPending`; and in full: `lines`
(with `baseQuantityReceived`, `lineTotal`, `batchId`), `attachments`, who received, verified,
rejected or reversed it and why.

### `GET /api/v1/receipts` and `GET /api/v1/receipts/:id`

List query: optional `status`, `organisationId`, `from`, `to`, `limit` (1–200, default 50),
`offset`. **200** with `{ "receipts": [ … ], "total": 12 }`, newest first.

### `POST /api/v1/receipts/:id/attachments?filename=invoice.pdf`

The request **body is the file itself** (any `Content-Type`). The server decides its type from
its first bytes: only PDF, JPEG and PNG are accepted, and the name's extension must match
(a program renamed `invoice.pdf` answers **415** `UNSUPPORTED_DOCUMENT`). Larger than
`ATTACHMENT_MAX_BYTES` answers **413**. Allowed while the receipt is a draft or waiting for
verification (e.g. a replacement for a rejected document). Files are stored outside the web app
under random names, with a SHA-256 checksum, and are never deleted.

### `GET /api/v1/receipts/:id/attachments/:attachmentId`

Downloads the document (as an attachment, never shown as a web page) for someone who may see
the receipt.

### `POST /api/v1/receipts/:id/attachments/:attachmentId/review` (`receipt.verify`)

`{ "status": "VERIFIED", "notes": null, "documentTotal": "125.50" }` or
`{ "status": "REJECTED", "notes": "Photo too blurry" }` (a reason is required). Each document is
reviewed once (**409** `DOCUMENT_ALREADY_REVIEWED`).

### `POST /api/v1/receipts/:id/submit` (`stock.receive`)

`{ "noDocumentReason": null }`. Needs a supplier, at least one line and, when
`RECEIPT_DOCUMENT_REQUIRED` is on, at least one document that is not rejected (**409**
`DOCUMENT_REQUIRED`). A user with `receipt.no_document` may submit without one by giving a
reason (3–500 characters; audit action `receipt.no_document`).

### `POST /api/v1/receipts/:id/verify` (`receipt.verify`)

`{ "notes": "Matches the invoice" }`. Every document must have been reviewed (**409**
`DOCUMENTS_NOT_REVIEWED`) and at least one verified, unless the receipt was submitted without one
(**409** `NO_VERIFIED_DOCUMENT`).

### `POST /api/v1/receipts/:id/reject` (`receipt.verify`)

`{ "reason": "Not our order" }`. If its stock was already added, it is taken back out.

### `POST /api/v1/receipts/:id/post` (`stock.receive`)

Adds a `VERIFIED` receipt's stock (only when stock waits for verification).

### `POST /api/v1/receipts/:id/reverse` (`receipt.reverse`)

`{ "reason": "Delivered to the wrong company" }`. Takes a `POSTED` receipt's stock back out with
`reversal` movements that point at the movements they cancel; the receipt and its history are
kept. If some of the delivery has already been dispatched or written off, it is refused with
**409** `RECEIPT_STOCK_USED`: correct the stock with an adjustment instead.

### `GET /api/v1/receipts/:id/pdf`

The GRN as an A4 PDF (`GRN000001.pdf`): supplier, owner, warehouse, lines, total, who received
and verified it, and the number of documents. Anything not final is marked in the heading.

All receipt actions are recorded in the audit log (`receipt.created`, `receipt.updated`,
`receipt.document_added`, `receipt.document_reviewed`, `receipt.submitted`,
`receipt.no_document`, `receipt.verified`, `receipt.posted`, `receipt.rejected`,
`receipt.reversed`).

## Orders (`/api/v1/orders`)

A subsidiary orders goods from the Head Office (StockFlow Stage 5). For each line it says the
quantity (in any unit the product has), the price it **expects** and the **maximum** it accepts;
during review the Head Office sets the **actual** price. Order numbers are `ORD000001` ….

Statuses: `DRAFT` → `SUBMITTED` → `UNDER_REVIEW` → `APPROVED` or `REJECTED`; `DRAFT` or
`SUBMITTED` → `CANCELLED` (`PARTIALLY_DISPATCHED`, `FULLY_DISPATCHED`, `COMPLETED` are reserved
for dispatching). The server and a database trigger allow only these steps (**409**
`ORDER_WRONG_STATUS` otherwise), and every change is kept in the order's `history`.

**Money** is exact: line totals (quantity × price) and the price-exception flag are generated by
the database; totals sent by the app are ignored. Prices have up to 2 decimal places.

| Action                                              | Permission                | Who has it (default) |
| --------------------------------------------------- | ------------------------- | -------------------- |
| See orders (own organisation; the Head Office: all) | `order.view`              | Subsidiary Manager, HQ Finance, HQ Sales, System Administrator |
| Create, change drafts, submit, cancel               | `order.create`            | Subsidiary Manager |
| Start review, set actual prices                     | `order.price`             | HQ Finance Officer |
| Approve or reject                                   | `order.approve`           | HQ Finance Officer |
| Approve a price above the maximum                   | `price.exception.approve` | HQ Finance Officer |

The ordering organisation is the signed-in user's own (a subsidiary's staff cannot order for
another: **404**). Reviewing, pricing and deciding are for Head Office staff only. Another
organisation's order answers **404** `ORDER_NOT_FOUND`.

### `POST /api/v1/orders` (`order.create`)

```json
{
  "idempotencyKey": "6f1c2a8e-3b4d-4e5f-9a7b-1c2d3e4f5a6b",
  "requiredDate": "2026-10-30",
  "notes": null,
  "lines": [
    {
      "productId": "…",
      "unitId": "…",
      "requestedQuantity": 3,
      "expectedUnitPrice": "0.10",
      "maximumUnitPrice": "0.15",
      "notes": null
    }
  ]
}
```

`idempotencyKey` is a new random UUID per order, kept by the app for retries: sending the same
key again answers **200** with the order it created the first time and `"replayed": true`
(so a double click or a retry never creates two orders); the first time answers **201** with
`"replayed": false`. `maximumUnitPrice` must be at least `expectedUnitPrice`; a product and
unit may appear once; `requiredDate` may not be in the past. Head Office staff (if a role ever
lets them create orders) must give `organisationId` (a subsidiary).

An order returns: `id`, `orderNumber`, `status`, `organisation`, `orderDate`, `requiredDate`,
`currency`, `requestedBy`, `lineCount`, `expectedTotal`, `maximumTotal`, `actualTotal` (once
every line is priced, else `null`), `priceException`; in full also `lines` (with
`expectedLineTotal`, `maximumLineTotal`, `actualUnitPrice`, `actualLineTotal`,
`priceException`, `baseQuantity`, and for Head Office staff only `hqAvailable`: the Head
Office's available stock in base units), `history` (from, to, who, when, comment), `changes`
(each actual-price change: line, old, new, who, when, comment), `submittedBy`, `decidedBy`,
`decisionComment`, `priceExceptionApproved`, `cancelReason`, `taxAmount` and
`discountAmount` (hooks, 0 for now).

### `GET /api/v1/orders` and `GET /api/v1/orders/:id`

List query: optional `status`, `organisationId`, `priceException=true`, `q` (part of the order
number), `from`, `to` (order date), `sort` (`newest` default, `oldest`, `required`), `limit`
(1–200, default 50), `offset`. **200** with `{ "orders": [ … ], "total": 3 }`.

### `PUT /api/v1/orders/:id` (drafts, `order.create`)

The same body as creating, without `idempotencyKey`. Only while `DRAFT`.

### `POST /api/v1/orders/:id/submit` (`order.create`)

Needs at least one line. Submitting an order that is already submitted changes nothing and
answers with `"alreadySubmitted": true`.

### `POST /api/v1/orders/:id/cancel` (`order.create`)

`{ "reason": "Ordered twice" }` (required). Only while `DRAFT` or `SUBMITTED`: once the Head
Office has started the review, the subsidiary can no longer cancel.

### `POST /api/v1/orders/:id/review` (`order.price`)

Takes a `SUBMITTED` order into review.

### `PUT /api/v1/orders/:id/prices` (`order.price`)

`{ "prices": [{ "itemId": "…", "actualUnitPrice": "0.12", "comment": null }] }`. Allowed while
`SUBMITTED` (it then goes into review) or `UNDER_REVIEW`. The subsidiary's quantities and
prices never change; each actual-price change is logged with the old and new value.

### `POST /api/v1/orders/:id/approve` (`order.approve`)

`{ "comment": "…" }` (optional, unless there is a price exception). Every line needs an actual
price (**409** `PRICES_MISSING`). If an actual price is above the maximum, approval needs
`price.exception.approve` (**403** `PRICE_EXCEPTION_NOT_ALLOWED`) **and** a comment (**400**);
the order then shows `priceExceptionApproved: true`. With `ORDERS_ALLOW_BACKORDERS=false`, the
Head Office must have enough available stock for every line (**409** `INSUFFICIENT_STOCK`,
naming the products); with the default `true`, the rest waits as a backorder. Approving does
not move stock: dispatching comes in a later stage.

### `POST /api/v1/orders/:id/reject` (`order.approve`)

`{ "comment": "Out of season" }` (required, 3–1000 characters). From `SUBMITTED` or
`UNDER_REVIEW`.

### `GET /api/v1/orders/:id/pdf`

The order sheet (`ORD000001.pdf`): the subsidiary and the Head Office, order number and dates,
each line's quantity, unit, expected, maximum and actual prices and totals, the overall values,
the status and who submitted and decided.

Audit actions: `order.created`, `order.updated`, `order.submitted`, `order.review_started`,
`order.prices_set`, `order.approved`, `order.rejected`, `order.cancelled`.

## Customers

Customers are never deleted (there is no DELETE endpoint); admins deactivate them instead. Only
the details billing and deliveries need are stored (spec 6.5).

| Field         | Rules                                                                       |
| ------------- | --------------------------------------------------------------------------- |
| `code`        | Unique, stored in capitals, up to 20 letters/digits/`.`/`_`/`-`. Leave out (or send `""`) when adding to get the next code: `C0001`, `C0002`, … |
| `name`        | Required, up to 120 characters                                              |
| `phone`       | Optional. Digits, spaces, brackets, dashes, optional leading `+`            |
| `address`     | Optional delivery address, up to 300 characters                             |
| `creditLimit` | Optional money string (`"500.00"`) in the base currency; `null` for no limit |
| `isActive`    | Changes only; `false` hides the customer from normal lists                  |

**Who may do what** (spec section 5: salespeople manage *permitted* customer information).
A request that tries to change a field the role may not change is refused with **403** and a
`details` entry naming the field; nothing is changed.

| Action                                       | Who                         |
| -------------------------------------------- | --------------------------- |
| View and search                              | Everyone signed in          |
| Add a customer; change code, name, phone, address | Salespeople and admins |
| Set or change `creditLimit`                  | Accounts staff and admins   |
| Change `isActive`                            | Admins                      |

Credit limits are stored now; checking them against unpaid balances starts when dispatches and
invoices are added. Changes are recorded in the audit log (`customer.created`,
`customer.updated` with exactly what changed).

### `GET /api/v1/customers`

Query: optional `q` (part of the code, name or phone, case ignored), `includeInactive=true`,
`limit` (1–200, default 50), `offset`. Sorted by name.

```json
{
  "customers": [
    {
      "id": "…",
      "code": "C0001",
      "name": "Avondale Tuckshop",
      "phone": "+263 77 123 4567",
      "address": "12 King George Road, Avondale",
      "creditLimit": "500.00",
      "isActive": true,
      "createdAt": "2026-10-12T14:00:00.000Z",
      "updatedAt": "2026-10-12T14:05:00.000Z"
    }
  ],
  "total": 1
}
```

### `GET /api/v1/customers/:id`

**200 OK** with `{ "customer": { … } }`.

### `POST /api/v1/customers` (no longer used)

Since StockFlow Stage 3 the buyers are the subsidiaries (decision D1): a customer record is
created with each subsidiary (`POST /api/v1/organisations`). This endpoint answers
**409** `ADD_AS_SUBSIDIARY` for everyone. Customer records carry `organisationId` (the subsidiary
they stand for, or `null` for customers added before Stage 3).

### `PATCH /api/v1/customers/:id`

Send only the fields to change; `null` clears `phone`, `address` or `creditLimit`.

```json
{ "creditLimit": "750.00" }
```

**200 OK** with `{ "customer": { … } }`.

### Later: `GET /api/v1/customers/:id/history`

Planned with dispatches and invoices: the customer's dispatches, invoices, payments and
outstanding balance.

## Dispatches

A dispatch sends goods to a customer (spec 6.6): **draft → confirmed**, or **draft →
cancelled**; a confirmed dispatch can be **reversed**. Dispatch numbers (`D000001`, …) are given
when the draft is created and kept even if it is cancelled, so the numbering has no gaps.

| Action                                   | Who                                    |
| ---------------------------------------- | -------------------------------------- |
| View and search                          | Everyone signed in                     |
| Create, edit and cancel drafts           | Salespeople, storekeepers and admins   |
| Confirm (stock is deducted)              | Storekeepers and admins                |
| Reverse a confirmed dispatch             | Admins, with a reason                  |

Rules:

- **Drafts do not change stock.** Confirming checks every line against stock on hand and
  deducts it in one transaction; if any line is short, nothing is deducted (**409**
  `INSUFFICIENT_STOCK`, with `details: [{ productId, requested, available }]`).
- **Simultaneous confirmations cannot oversell**: products are locked while stock is checked
  and deducted.
- **Confirming is safe to repeat.** Confirming an already-confirmed dispatch changes nothing
  and returns `alreadyConfirmed: true`.
- **Prices are snapshots.** Each line keeps the price agreed for this dispatch; it defaults to
  the product's current price. Later price changes never alter past dispatches.
- **Confirmed dispatches are never edited or deleted** (the database itself refuses). Mistakes
  are corrected with a reversal, which puts the stock back with `reversal` movements that
  point at the original ones; both stay in the history.
- **Credit-limit warnings.** If confirming would take the customer's unpaid balance over their
  credit limit, the request is refused with **409** `CREDIT_LIMIT_EXCEEDED` and
  `details: { creditLimit, balanceBefore, dispatchTotal, balanceAfter, exceedsLimit }`. Send
  the confirmation again with `"acknowledgeCreditLimit": true` to go ahead; the dispatch is then
  marked `confirmedOverCreditLimit` and the audit log records the override. The **unpaid
  balance** is the value of the customer's confirmed dispatches (invoiced or not) less the
  payments received from them (voided payments do not count).

Changes are recorded in the audit log: `dispatch.confirmed`, `dispatch.cancelled`,
`dispatch.reversed`.

### `POST /api/v1/dispatches` (create a draft)

```json
{
  "customerId": "…",
  "dispatchDate": "2026-10-12",
  "notes": "Deliver before noon",
  "items": [
    { "productId": "…", "quantity": 12 },
    { "productId": "…", "quantity": 5, "unitPrice": "0.25" }
  ]
}
```

`dispatchDate` defaults to today. Each product may appear once; 1–100 lines. `unitPrice` left
out = the product's default price. **201 Created** with `{ "dispatch": { … } }`:

```json
{
  "dispatch": {
    "id": "…",
    "dispatchNumber": "D000001",
    "status": "draft",
    "dispatchDate": "2026-10-12",
    "notes": "Deliver before noon",
    "customer": { "id": "…", "code": "C0001", "name": "Avondale Tuckshop", "creditLimit": "300.00" },
    "items": [
      {
        "id": "…",
        "product": { "id": "…", "sku": "PC-BBQ-S", "name": "Potato Crisps", "flavour": "BBQ", "size": "Small" },
        "quantity": 12,
        "unitPrice": "0.50",
        "lineTotal": "6.00",
        "quantityOnHand": 100
      }
    ],
    "totalQuantity": 12,
    "totalValue": "6.00",
    "createdBy": { "id": "…", "fullName": "Tendai Moyo" },
    "createdAt": "…",
    "confirmedBy": null,
    "confirmedAt": null,
    "confirmedOverCreditLimit": false,
    "cancelledBy": null,
    "cancelledAt": null,
    "cancelReason": null,
    "reversedBy": null,
    "reversedAt": null,
    "reversalReason": null,
    "creditCheck": {
      "creditLimit": "300.00",
      "balanceBefore": "0.00",
      "dispatchTotal": "6.00",
      "balanceAfter": "6.00",
      "exceedsLimit": false
    }
  }
}
```

`creditCheck` (what confirming would do) and `quantityOnHand` (to spot shortages) are there so
a draft can be reviewed before it is confirmed. `creditCheck` is `null` once it is no longer a
draft.

### `PUT /api/v1/dispatches/:id` (edit a draft)

Same body as creating; replaces the customer, date, notes and all lines. **409**
`DISPATCH_NOT_DRAFT` once confirmed, cancelled or reversed.

### `POST /api/v1/dispatches/:id/confirm` (storekeepers and admins)

Body (optional): `{ "acknowledgeCreditLimit": true }`.
**200 OK** with `{ "dispatch": { … }, "alreadyConfirmed": false }`. A dispatch dated in the future
cannot be confirmed (**409** `DISPATCH_DATE_IN_FUTURE`).

### `POST /api/v1/dispatches/:id/cancel` (drafts only)

```json
{ "reason": "Customer changed their order" }
```

### `POST /api/v1/dispatches/:id/reverse` (admins, confirmed dispatches only)

```json
{ "reason": "Delivered to the wrong shop" }
```

A dispatch that is on an invoice cannot be reversed (**409** `DISPATCH_INVOICED`): void the draft
invoice first; an issued invoice will be corrected with a credit note (a later stage).

### `GET /api/v1/dispatches`

Query: optional `status` (`draft`, `confirmed`, `cancelled`, `reversed`), `customerId`, `from`,
`to` (dispatch dates), `q` (part of the dispatch number or customer name), `limit` (1–200,
default 50), `offset`. Newest first.

```json
{
  "dispatches": [
    {
      "id": "…",
      "dispatchNumber": "D000001",
      "status": "confirmed",
      "dispatchDate": "2026-10-12",
      "customer": { "id": "…", "code": "C0001", "name": "Avondale Tuckshop" },
      "lineCount": 1,
      "totalQuantity": 12,
      "totalValue": "6.00",
      "createdBy": "Tendai Moyo"
    }
  ],
  "total": 1
}
```

### `GET /api/v1/dispatches/:id`

**200 OK** with `{ "dispatch": { … } }` as above.

## Invoices

Invoices bill customers for confirmed dispatches (spec 6.8): **draft → issued**, or
**draft → voided**. Accounts staff and admins only; everyone else gets **403**.

**Billing period.** Every endpoint below that takes `from` and `to` (dates, both included)
defaults to the **last complete billing week** in the business time zone (`BUSINESS_TIMEZONE`,
default `Africa/Harare`). Weeks start on `BILLING_WEEK_STARTS_ON` (default `monday`), so on any
day the default period is the previous Monday to Sunday. Give only `from` for a single day.
A period may be at most 92 days, `to` must not be before `from`, and it cannot end in the future
(**400** `VALIDATION_ERROR` with the field).

Rules:

- **What is billed.** A draft contains every line of the customer's **confirmed** dispatches
  dated in the period that is not on another invoice yet. Draft, cancelled and reversed
  dispatches are never billed.
- **Nothing is billed twice.** A dispatch line can be on only one invoice (enforced by a unique
  constraint), and creating a draft locks the customer and the dispatches, so two people
  invoicing at the same moment get one draft between them. The other gets **409**
  `NOTHING_TO_INVOICE` (or, rarely, `ALREADY_INVOICED`); refresh and try again.
- **A dispatch on an invoice cannot be reversed** (**409** `DISPATCH_INVOICED`).
- **Issuing** gives the invoice the next number (`INV-000001`, …; voided drafts never use a
  number, so there are no gaps), today's date as the issue date, a **due date**
  `PAYMENT_TERMS_DAYS` later (default 7), and freezes the customer's name, code, phone and
  address as printed. Issuing again changes nothing.
- **Issued invoices never change** and cannot be voided (**409** `INVOICE_ISSUED`); the database
  itself refuses changes. Mistakes will be corrected with credit notes (a later stage).
- **Voiding a draft** (with a reason) releases its dispatch lines so they can be invoiced again.
- **Totals.** `total` equals `subtotal`, the sum of the lines (no discounts yet; the database
  checks this when issuing). `amountPaid` is what payments that have not been voided allocated
  to it, and `balanceDue` is `total - amountPaid` (`0.00` for a voided draft). For issued
  invoices, `paymentStatus` is `unpaid`, `part_paid` or `paid`, and `overdue` is `true` when
  something is still owed after the due date (in the business time zone). All amounts are in
  `currency` (`BASE_CURRENCY`, default `USD`).

Changes are recorded in the audit log: `invoice.issued`, `invoice.voided`.

### `GET /api/v1/invoices/unbilled`

Who still has dispatches to invoice. Query: optional `from`, `to`.

```json
{
  "from": "2026-10-05",
  "to": "2026-10-11",
  "customers": [
    {
      "customer": { "id": "…", "code": "C0001", "name": "Avondale Tuckshop" },
      "dispatchCount": 2,
      "lineCount": 3,
      "subtotal": "7.50"
    }
  ]
}
```

### `GET /api/v1/invoices/preview`

What a draft for one customer would contain. Changes nothing. Query: `customerId`, optional
`from`, `to`.

```json
{
  "preview": {
    "customer": { "id": "…", "code": "C0001", "name": "Avondale Tuckshop", "phone": null, "address": "1 Example Road" },
    "periodFrom": "2026-10-05",
    "periodTo": "2026-10-11",
    "currency": "USD",
    "lines": [
      {
        "dispatchItemId": "…",
        "dispatchNumber": "D000001",
        "dispatchDate": "2026-10-06",
        "product": { "id": "…", "sku": "PC-BBQ-S", "description": "Potato Crisps — BBQ — Small" },
        "quantity": 12,
        "unitPrice": "0.50",
        "lineTotal": "6.00"
      }
    ],
    "subtotal": "6.00"
  }
}
```

### `POST /api/v1/invoices` (create a draft for one customer)

```json
{ "customerId": "…", "from": "2026-10-05", "to": "2026-10-11" }
```

`from` and `to` are optional. **201 Created** with `{ "invoice": { … } }`:

```json
{
  "invoice": {
    "id": "…",
    "invoiceNumber": null,
    "status": "draft",
    "customer": { "id": "…", "code": "C0001", "name": "Avondale Tuckshop", "phone": null, "address": "1 Example Road" },
    "periodFrom": "2026-10-05",
    "periodTo": "2026-10-11",
    "issueDate": null,
    "currency": "USD",
    "lines": [ { "…": "as in the preview" } ],
    "subtotal": "6.00",
    "total": "6.00",
    "dueDate": null,
    "amountPaid": "0.00",
    "balanceDue": "6.00",
    "paymentStatus": null,
    "overdue": false,
    "payments": [],
    "createdBy": "Rudo Accounts",
    "createdAt": "2026-10-12T08:30:00.000Z",
    "issuedBy": null,
    "issuedAt": null,
    "voidReason": null
  }
}
```

For a draft, `customer` shows the customer's current details; for an issued invoice, the details
printed on it. **409** `NOTHING_TO_INVOICE` when there is nothing left to bill.

### `POST /api/v1/invoices/generate` (the weekly run)

Body (optional): `{ "from": "…", "to": "…" }`. Creates a draft for every customer with unbilled
dispatches in the period, each in its own transaction. **201 Created** with
`{ "from", "to", "invoices": [ … ] }`; running it again creates nothing new.

### `POST /api/v1/invoices/:id/issue`

**200 OK** with `{ "invoice": { … } }`, now `issued` with its number, issue date and due date.
**409** `INVOICE_VOIDED` for a voided draft.

### `POST /api/v1/invoices/:id/void` (drafts only)

```json
{ "reason": "Wrong period chosen" }
```

### `GET /api/v1/invoices`

Query: optional `status` (`draft`, `issued`, `voided`), `payment` (`unpaid`: issued and not
fully paid; `overdue`: also past the due date), `customerId`, `q` (part of the invoice number
or customer name), `limit` (1–200, default 50), `offset`. Newest first.

```json
{
  "invoices": [
    {
      "id": "…",
      "invoiceNumber": "INV-000001",
      "status": "issued",
      "customer": { "id": "…", "code": "C0001", "name": "Avondale Tuckshop" },
      "periodFrom": "2026-10-05",
      "periodTo": "2026-10-11",
      "issueDate": "2026-10-12",
      "dueDate": "2026-10-19",
      "total": "7.50",
      "amountPaid": "2.00",
      "balanceDue": "5.50",
      "paymentStatus": "part_paid",
      "overdue": false,
      "currency": "USD",
      "lineCount": 2
    }
  ],
  "total": 1
}
```

### `GET /api/v1/invoices/:id`

**200 OK** with `{ "invoice": { … } }` as above. `payments` lists what paid it, oldest first:
`[{ "paymentId", "paymentNumber": "P000001", "paymentDate", "method": "cash", "amount": "2.00" }]`.

### `GET /api/v1/invoices/:id/pdf`

The invoice as an A4 PDF (`Content-Type: application/pdf`, file name `INV-000001.pdf`, or
`draft-C0001-2026-10-05.pdf` for a draft). It shows the business name and contact line
(`BUSINESS_NAME`, `BUSINESS_CONTACT`), invoice number, issue and due dates, period, the customer, every
line (dispatch date and number, product with flavour and size, quantity, unit price, amount),
subtotal, total, amount paid and balance due. Drafts are headed **DRAFT INVOICE** and say they
are not a valid invoice; voided drafts are headed **VOIDED DRAFT**.

## Payments

Money received from customers (spec 6.9). Accounts staff and admins record payments; only
admins void one. Everyone else gets **403**.

Rules:

- **A payment is in the base currency** (`BASE_CURRENCY`, default `USD`). Payments in another
  currency need an exchange-rate rule first, so they are not accepted yet.
- **Allocation.** A payment can pay one or more of the same customer's **issued** invoices, in
  parts or in full. Allocations never add up to more than the payment, and an invoice is never
  paid beyond its total (**409** `ALLOCATION_EXCEEDS_PAYMENT` / `ALLOCATION_EXCEEDS_BALANCE`,
  the latter with `details: { invoiceId, balanceDue }`). Drafts and voided drafts cannot be paid
  (**409** `INVOICE_NOT_ISSUED`), nor can another customer's invoice (**409**
  `INVOICE_OTHER_CUSTOMER`).
- **Credit.** Whatever is not allocated stays as credit on the customer's account. It can be
  allocated later, for example to next week's invoice.
- **Simultaneous allocations** are checked one after the other (the payment and invoices are
  locked), so two people cannot overpay the same invoice. The database checks the same rules.
- **No duplicates.** Send a fresh `idempotencyKey` (a UUID) with each new payment. If the same
  request arrives again (a double tap, or a retry after a dropped connection), the payment
  already recorded is returned with **200 OK** and `"duplicate": true` instead of recording it
  twice. Reusing a key for a different payment is refused (**409** `IDEMPOTENCY_KEY_REUSED`).
- **Payments are never edited or deleted**, enforced by the database. A payment recorded by
  mistake is **voided** by an admin with a reason: its allocations stay as history but no
  longer count, so the invoices it paid are owed again. Record it again with the right details.
- A payment is money received; an invoice or dispatch is never treated as proof of payment.

Changes are recorded in the audit log: `payment.recorded`, `payment.allocated`,
`payment.voided`.

### `POST /api/v1/payments`

```json
{
  "customerId": "…",
  "paymentDate": "2026-10-12",
  "amount": "20.00",
  "method": "mobile_money",
  "reference": "MP261012.1234",
  "notes": null,
  "idempotencyKey": "8f14e45f-ceea-4e7a-9b8a-1f3c5d2e7a90",
  "allocations": [
    { "invoiceId": "…", "amount": "10.00" },
    { "invoiceId": "…", "amount": "5.00" }
  ]
}
```

`method` is one of `cash`, `bank_transfer`, `mobile_money`, `card`, `cheque`, `other`.
`paymentDate` cannot be in the future. `reference` (up to 100 characters), `notes` (up to 500),
`idempotencyKey` and `allocations` are optional. **201 Created**:

```json
{
  "duplicate": false,
  "payment": {
    "id": "…",
    "paymentNumber": "P000001",
    "status": "recorded",
    "customer": { "id": "…", "code": "C0001", "name": "Avondale Tuckshop" },
    "paymentDate": "2026-10-12",
    "amount": "20.00",
    "currency": "USD",
    "method": "mobile_money",
    "reference": "MP261012.1234",
    "notes": null,
    "allocations": [
      {
        "invoiceId": "…",
        "invoiceNumber": "INV-000001",
        "amount": "10.00",
        "allocatedBy": "Rudo Accounts",
        "allocatedAt": "2026-10-12T09:15:00.000Z"
      }
    ],
    "allocatedAmount": "15.00",
    "unallocatedAmount": "5.00",
    "recordedBy": "Rudo Accounts",
    "recordedAt": "2026-10-12T09:15:00.000Z",
    "voidedBy": null,
    "voidedAt": null,
    "voidReason": null
  }
}
```

### `POST /api/v1/payments/:id/allocations` (allocate credit)

```json
{ "allocations": [{ "invoiceId": "…", "amount": "3.00" }] }
```

**200 OK** with `{ "payment": { … } }`. **409** `PAYMENT_VOIDED` for a voided payment.

### `POST /api/v1/payments/:id/void` (admins only)

```json
{ "reason": "Cheque bounced" }
```

**200 OK** with `{ "payment": { … } }`, now `voided` with `unallocatedAmount` `"0.00"`. Voiding
again changes nothing.

### `GET /api/v1/payments`

Query: optional `customerId`, `status` (`recorded`, `voided`), `from`, `to` (payment dates),
`q` (part of the receipt number, reference or customer name), `limit` (1–200, default 50),
`offset`. Newest first: `{ "payments": [ … ], "total": 1 }`, each with `id`, `paymentNumber`,
`status`, `customer`, `paymentDate`, `amount`, `currency`, `method`, `reference`,
`allocatedAmount` and `unallocatedAmount`.

### `GET /api/v1/payments/:id`

**200 OK** with `{ "payment": { … } }` as above.

## Balances and statements

What customers owe, as separate measures (spec 6.10: dispatch value, invoiced sales and cash
received are never mixed). Accounts staff and admins only.

| Measure             | Meaning                                                              |
| ------------------- | -------------------------------------------------------------------- |
| `notYetInvoiced`    | Confirmed dispatches not on an issued invoice yet (including drafts) |
| `invoicedUnpaid`    | Still owed on issued invoices                                        |
| `overdue`           | The part of `invoicedUnpaid` past its due date                       |
| `unallocatedCredit` | Payments received but not yet allocated to an invoice                |
| `balance`           | `notYetInvoiced + invoicedUnpaid - unallocatedCredit`: confirmed dispatches less payments received; negative when the customer has paid in advance |

The same `balance` is what dispatch credit-limit warnings use.

### `GET /api/v1/balances`

Every customer with confirmed dispatches or payments, most overdue first, then largest balance.

```json
{
  "currency": "USD",
  "customers": [
    {
      "customer": { "id": "…", "code": "C0001", "name": "Avondale Tuckshop", "creditLimit": null },
      "notYetInvoiced": "2.00",
      "invoicedUnpaid": "12.00",
      "overdue": "7.00",
      "unallocatedCredit": "1.00",
      "balance": "13.00",
      "oldestOverdueDueDate": "2026-09-29"
    }
  ],
  "totals": {
    "notYetInvoiced": "2.00",
    "invoicedUnpaid": "12.00",
    "overdue": "7.00",
    "unallocatedCredit": "1.00",
    "balance": "13.00"
  }
}
```

### `GET /api/v1/balances/:customerId` (account and statement)

Query: optional `from`, `to` for the statement (default: the last 90 days up to today; at most
366 days).

```json
{
  "account": {
    "customer": { "id": "…", "code": "C0001", "name": "Avondale Tuckshop", "phone": null, "address": null, "creditLimit": null },
    "currency": "USD",
    "summary": { "notYetInvoiced": "0.00", "invoicedUnpaid": "11.00", "overdue": "6.00", "unallocatedCredit": "1.50", "balance": "9.50", "oldestOverdueDueDate": "2026-09-09" },
    "openInvoices": [
      { "id": "…", "invoiceNumber": "INV-000001", "issueDate": "2026-09-02", "dueDate": "2026-09-09", "total": "10.00", "amountPaid": "4.00", "balanceDue": "6.00", "overdue": true, "daysOverdue": 33 }
    ],
    "creditPayments": [
      { "id": "…", "paymentNumber": "P000002", "paymentDate": "2026-10-10", "amount": "1.50", "unallocatedAmount": "1.50" }
    ],
    "statement": {
      "from": "2026-09-06",
      "to": "2026-10-12",
      "openingBalance": "10.00",
      "entries": [
        { "date": "2026-09-07", "type": "payment", "id": "…", "reference": "P000001", "periodFrom": null, "periodTo": null, "method": "cash", "paymentReference": null, "debit": null, "credit": "4.00", "balance": "6.00" },
        { "date": "2026-10-12", "type": "invoice", "id": "…", "reference": "INV-000002", "periodFrom": "2026-10-05", "periodTo": "2026-10-11", "method": null, "paymentReference": null, "debit": "5.00", "credit": null, "balance": "11.00" }
      ],
      "closingBalance": "11.00"
    }
  }
}
```

`openInvoices` are issued invoices not fully paid, oldest due date first. The **statement**
lists issued invoices (debits, on their issue date) and payments (credits, on the date received)
with a running balance; the opening balance carries in everything before `from`. Voided payments
and draft invoices are not on a statement, and dispatches not yet invoiced appear only in the
summary (`notYetInvoiced`).

## Reports

Read-only reports (spec 6.10), calculated from the stored records each time, so they always
reconcile with them. Each measure is defined once and labelled separately; they are never added
together:

| Measure             | What it counts                                                              |
| ------------------- | --------------------------------------------------------------------------- |
| Sales value         | Confirmed dispatches (quantity × agreed price) by **dispatch date**. Drafts, cancelled and reversed dispatches do not count |
| Packs dispatched    | The quantities on those confirmed dispatches                                 |
| Invoiced            | Issued invoices by **issue date**                                            |
| Payments received   | Payments that have not been voided, by the **date received**                |
| Owed by customers   | Today's balance: confirmed dispatches less payments (as on the Payments screen) |

A dispatch reversed later disappears from the sales of the day it was dispatched, because the
goods came back.

| Report           | Who                                  |
| ---------------- | ------------------------------------ |
| `dashboard`      | Everyone signed in (money only for admins and accounts staff) |
| `sales`, `products`, `customers` | Admins and accounts staff |
| `stock-received`, `expiring` | Admins, accounts staff and storekeepers |

**Dates.** Reports that take `from` and `to` (both included) default to the last 30 days up to
today in the business time zone. `to` cannot be in the future or before `from`, and a report
covers at most two years (**400** `VALIDATION_ERROR` with the field).

### `GET /api/v1/reports/dashboard`

```json
{
  "dashboard": {
    "today": "2026-10-13",
    "dispatchesToday": { "dispatches": 3, "packs": 25, "salesValue": "9.80" },
    "dispatchesThisWeek": { "dispatches": 11, "packs": 140, "salesValue": "64.10" },
    "receivedToday": { "receipts": 1, "packs": 48 },
    "lowStock": {
      "count": 1,
      "products": [{ "product": { "id": "…", "sku": "PC-BBQ-S", "description": "Potato Crisps — BBQ — Small" }, "quantityOnHand": 12, "reorderLevel": 50 }]
    },
    "expiring": { "withinDays": 30, "count": 1, "batches": [ { "…": "as in /expiring" } ] },
    "money": {
      "currency": "USD",
      "salesThisMonth": "219.80",
      "invoicedThisMonth": "163.50",
      "paymentsThisMonth": "97.50",
      "owedByCustomers": "122.30",
      "overdue": "16.00"
    },
    "trend": [{ "date": "2026-09-30", "packs": 25, "salesValue": "12.50" }]
  }
}
```

"This week" is the billing week (`BILLING_WEEK_STARTS_ON`) up to today; "this month" is the
calendar month up to today; `trend` is the last 14 days, oldest first. For storekeepers and
salespeople `money` is `null` and every `salesValue` is `null`. At most 8 low-stock products and
5 expiring batches are listed (`count` gives the full number).

### `GET /api/v1/reports/sales` (admins, accounts staff)

Query: `from`, `to`, `groupBy` (`day`, `week` or `month`; default `day`). Weeks start on the
billing day; months are calendar months. The first and last periods are cut to the requested
dates. Every period in the range is listed, including quiet ones.

```json
{
  "from": "2026-10-01",
  "to": "2026-10-13",
  "groupBy": "week",
  "currency": "USD",
  "totals": { "dispatches": 4, "packs": 45, "salesValue": "19.80", "invoiced": "13.50", "paymentsReceived": "7.50" },
  "periods": [
    { "start": "2026-10-01", "end": "2026-10-04", "dispatches": 1, "packs": 20, "salesValue": "10.00", "invoiced": "0.00", "paymentsReceived": "4.00" }
  ]
}
```

The periods always add up to the totals.

### `GET /api/v1/reports/products` (admins, accounts staff)

Best-selling products. Query: `from`, `to`, `sortBy` (`value` or `packs`; default `value`).

```json
{
  "from": "…", "to": "…", "currency": "USD",
  "products": [
    { "product": { "id": "…", "sku": "PC-BBQ-S", "description": "Potato Crisps — BBQ — Small" }, "dispatches": 3, "packs": 30, "salesValue": "15.30" }
  ],
  "totals": { "packs": 45, "salesValue": "19.80" }
}
```

### `GET /api/v1/reports/customers` (admins, accounts staff)

Each customer with dispatches, invoices or payments in the period, highest sales value first:
`dispatches`, `packs`, `salesValue`, `invoiced` and `paymentsReceived` in the period, and
`balanceNow`: what they owe today, whatever the period (negative when in credit).

### `GET /api/v1/reports/stock-received` (admins, accounts staff, storekeepers)

Deliveries in the period per product (`receipts`, `packs`) with `totals`. Opening balances are
not deliveries and are left out.

### `GET /api/v1/reports/expiring` (admins, accounts staff, storekeepers)

Query: `days` (1–365, default 30). Deliveries of active products that expire within that many
days, or have already expired, and probably still have packs on the shelf, soonest first:

```json
{
  "today": "2026-10-13",
  "withinDays": 30,
  "batches": [
    {
      "product": { "id": "…", "sku": "MP-CH-S", "description": "Maize Puffs — Cheese — Small" },
      "batchNumber": "B-114",
      "receivedDate": "2026-10-03",
      "expiryDate": "2026-10-16",
      "daysToExpiry": 3,
      "estimatedPacksLeft": 5
    }
  ]
}
```

**`estimatedPacksLeft` is an estimate.** Dispatches do not record which delivery they took stock
from, so stock is assumed to leave oldest first: each product's stock on hand is assigned to its
most recent deliveries. `daysToExpiry` is negative once a batch has expired.

## Forecasts

Estimates of demand for each active product over the **next 7 days** and the **next 30 days**
(spec 6.11), for admins, accounts staff and storekeepers. They are estimates, not guaranteed
sales, and every screen says so.

**Demand** is the packs on **confirmed dispatches**, by dispatch date. Draft, cancelled and
reversed dispatches, returns, damage and stock corrections are not demand.

**Method (`weekday-average`).** The demand expected on a day is the average of the packs
dispatched on the same weekday over the last 8 weeks (fewer if there is less history, but at
least 4). A period's forecast is the sum of its days. Only days **before** the forecast start
are used. The range (`lower`–`upper`) is a rough 80% range from how much the weekly totals have
varied, widened for the 30-day horizon.

**Too little history is reported, not guessed:** a product first dispatched less than 28 days
before the forecast start gets `status: "insufficient_history"` (with `historyDays`), and one
never dispatched gets `"no_history"`; neither has a prediction.

**Restocking:** `suggestedReorder` = forecast (rounded up) + the product's `safetyStock` − stock
on hand, never below 0.

**Accuracy:** once a 7-day forecast's week is over, it is compared with the packs actually
dispatched that week (the latest forecast made for each start date counts once). The mean
absolute error (`mae`, in packs) of the last 8 such weeks is given once at least 3 weeks are
available.

Forecasts are stored as they were made (`forecast_runs`, `forecasts`) and never changed.
Making one is recorded in the audit log as `forecast.run`.

### `POST /api/v1/forecasts/run`

Forecasts every active product from today (business time zone). **201 Created** with
`{ "forecast": { … } }` as below.

### `GET /api/v1/forecasts`

The latest run. Before the first run: `{ "forecast": { "run": null, "products": [] } }`.

```json
{
  "forecast": {
    "run": {
      "id": "…",
      "forecastStart": "2026-10-13",
      "method": "weekday-average",
      "createdAt": "2026-10-13T06:15:00.000Z",
      "createdBy": "Tendai Moyo"
    },
    "products": [
      {
        "product": { "id": "…", "sku": "PC-BBQ-S", "description": "Potato Crisps — BBQ — Small" },
        "onHand": 15,
        "safetyStock": 15,
        "week": {
          "horizonDays": 7, "status": "ok", "predicted": 10, "lower": 8, "upper": 12,
          "historyDays": 56, "weeksUsed": 8, "suggestedReorder": 10
        },
        "month": {
          "horizonDays": 30, "status": "ok", "predicted": 50, "lower": 40, "upper": 60,
          "historyDays": 56, "weeksUsed": 8, "suggestedReorder": 50
        },
        "accuracy": {
          "mae": 1.3,
          "weeksCompared": 3,
          "needed": 3,
          "recent": [{ "forecastStart": "2026-09-29", "predicted": 10, "actual": 10 }]
        }
      }
    ]
  }
}
```

Products that need restocking come first, then those with the most demand.
