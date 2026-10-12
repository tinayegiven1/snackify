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

`details` is optional and only present when there is extra, safe information (such as which
field failed validation). Raw database errors and stack traces are never returned.

| Status | `code`              | When                                         |
| ------ | ------------------- | -------------------------------------------- |
| 400    | `INVALID_JSON`      | The request body is not valid JSON           |
| 404    | `NOT_FOUND`         | The route does not exist                     |
| 413    | `PAYLOAD_TOO_LARGE` | The request body is larger than 100 KB       |
| 500    | `INTERNAL_ERROR`    | Unexpected server error (details are logged) |

## Endpoints

### `GET /api/v1/health`

Reports whether the API is running. No authentication required.

**200 OK**

```json
{
  "status": "ok",
  "service": "snackify-api",
  "environment": "development",
  "timestamp": "2026-10-12T10:52:24.950Z",
  "uptimeSeconds": 12,
  "checks": { "database": "not_configured" }
}
```

`checks.database` is `not_configured` until PostgreSQL is connected in the next stage. The plan
is for it to then report the database status, with a `503` response when the database is
unreachable.
