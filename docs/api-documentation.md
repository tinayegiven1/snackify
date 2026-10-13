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
    "details": [{ "field": "password", "message": "Use at least 10 characters" }]
  }
}
```

Raw database errors, stack traces and submitted values are never returned.

| Status | `code`                     | When                                                       |
| ------ | -------------------------- | ---------------------------------------------------------- |
| 400    | `INVALID_JSON`             | The request body is not valid JSON                         |
| 400    | `VALIDATION_ERROR`         | One or more fields are missing or invalid (see `details`)  |
| 401    | `UNAUTHENTICATED`          | No session token, or the session has ended                 |
| 401    | `INVALID_CREDENTIALS`      | Wrong username or password (same answer for both)          |
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
| 429    | `TOO_MANY_ATTEMPTS`        | 10 failed password attempts from one address in 15 minutes |
| 500    | `INTERNAL_ERROR`           | Unexpected server error (details are logged)               |

## Signing in and permissions

1. `POST /api/v1/auth/login` with a username and password returns a session `token`.
2. Send it on every other request: `Authorization: Bearer <token>`.
3. A session lasts 12 hours. It ends earlier on sign-out, when an admin resets the password or
   deactivates the account, or when the user changes their password on another device.

Roles: `admin`, `storekeeper`, `salesperson`, `accounts`. Each endpoint lists the roles allowed;
**admins are always allowed**. Permissions are checked on the server for every request.

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
further attempts get `429` (successful sign-ins do not count). Usernames are not case-sensitive.

Request:

```json
{ "username": "tendai", "password": "correct horse battery" }
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
    "role": "storekeeper"
  }
}
```

**401** `INVALID_CREDENTIALS` for a wrong password, an unknown username or a deactivated
account. The answer is identical in all three cases.

### `POST /api/v1/auth/logout`

Signed in. Ends the current session. **204 No Content**.

### `GET /api/v1/auth/me`

Signed in. **200 OK** with `{ "user": { "id", "username", "fullName", "role" } }`.

### `POST /api/v1/auth/change-password`

Signed in. Changes your own password and signs you out on every other device.

```json
{ "currentPassword": "correct horse battery", "newPassword": "a brand new passphrase" }
```

**204 No Content**. **400** `VALIDATION_ERROR` if the current password is wrong or the new one
is invalid. Rate-limited like sign-in.

## Staff accounts (admins only)

Passwords must be 10–128 characters. Usernames are 3–32 characters (letters, digits, `.`, `-`,
`_`) and are stored in lower case. Accounts are never deleted; deactivate them instead.

### `GET /api/v1/users`

**200 OK**, active accounts first, then by name. Password hashes are never returned.

```json
{
  "users": [
    {
      "id": "7f9c2b1e-...",
      "username": "tendai",
      "fullName": "Tendai Moyo",
      "role": "storekeeper",
      "isActive": true,
      "createdAt": "2026-10-12T12:35:43.000Z",
      "lastSignInAt": "2026-10-12T12:47:25.000Z"
    }
  ]
}
```

### `POST /api/v1/users`

```json
{ "username": "rudo", "fullName": "Rudo Chikore", "role": "accounts", "password": "first-passphrase" }
```

**201 Created** with `{ "user": { ... } }`. **409** `USERNAME_TAKEN`.

### `PATCH /api/v1/users/:id`

Send any of `fullName`, `role`, `isActive`. Other fields are rejected.

```json
{ "role": "admin" }
```

**200 OK** with `{ "user": { ... } }`. Role changes apply to the user's next request.
Setting `isActive: false` signs the user out everywhere at once. Admins cannot change their own
role or deactivate themselves (`409 CANNOT_CHANGE_OWN_ACCESS`), so there is always an active admin.

### `POST /api/v1/users/:id/reset-password`

```json
{ "newPassword": "temporary passphrase" }
```

**204 No Content**. The user is signed out everywhere and must use the new password. Admins
change their own password with `/auth/change-password` instead (`409 USE_CHANGE_PASSWORD`).

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

| Action                                      | Who                      |
| ------------------------------------------- | ------------------------ |
| View balances, receipts and movements       | Everyone signed in       |
| Receive stock                               | Storekeepers and admins  |
| Record an opening balance                   | Admins                   |
| Damage and corrections (adjustments)        | Admins, with a reason    |

Movement types: `opening_balance`, `receipt`, `damage`, `adjustment` (and later `dispatch`,
`customer_return`, `reversal`).

### `POST /api/v1/stock/receipts`

```json
{
  "productId": "3b0d6c5e-...",
  "quantity": 48,
  "receivedDate": "2026-10-12",
  "batchNumber": "L2026-10A",
  "expiryDate": "2027-02-01",
  "supplierReference": "Delivery note 1042",
  "isOpeningBalance": false
}
```

Only `productId` and `quantity` (a whole number, 1–1,000,000) are required. `receivedDate`
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
      "isLowStock": true
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
      "balanceAfter": 97
    }
  ],
  "total": 3
}
```

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

### `POST /api/v1/customers` (salespeople and admins)

```json
{ "name": "Avondale Tuckshop", "phone": "+263 77 123 4567", "address": "12 King George Road" }
```

**201 Created** with `{ "customer": { … } }`. Only admins may include `creditLimit` here.

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
