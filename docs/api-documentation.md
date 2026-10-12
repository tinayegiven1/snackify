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
