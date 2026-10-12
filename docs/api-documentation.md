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
