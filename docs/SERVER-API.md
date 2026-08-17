# Server API reference (for the `https` transport)

> **Requires a ClimWeb version with the product-sync API.** Against an older
> site, `climweb-sync --check` fails with a message telling the operator to use
> `transport: rsync` instead, which needs no server-side support at all.

## Endpoints

### `GET /api/product-sync/setup.sh`

The bootstrap script behind the one-line command shown in the CMS. Downloads
this tool and hands over to `climweb-sync setup`. Unauthenticated — it contains
no secrets, and refuses to run without a setup code.

### `POST /api/product-sync/setup/exchange/`

Trades a one-time setup code for a credential and the product's settings.

Unauthenticated by design: possession of the code *is* the credential. That is
acceptable because a code is single-use, expires in 48 hours, is scoped to one
product, and grants only the ability to upload files of one format into one
folder.

| Field | Description |
|---|---|
| `code` | The setup code. Case and dashes are normalised, so `k7fa2c9dtx43` works. |
| `hostname` | Reported by the client; shown in the CMS so an administrator can tell servers apart. |
| `format` | `env` to get shell assignments instead of JSON. |

Returns `product_name`, `variable_name`, `formats`, `format`, `watch_root`,
`base_url`, `ingestion_enabled` and `token`.

| Response | Meaning |
|---|---|
| `200` | Accepted; the code is now spent |
| `403` | Unknown, expired, or already-used code |
| `409` | The product is missing a variable name or a format in the CMS |

The `format=env` variant exists because the client is a bash script on a met
service server that may not have `jq` installed. Values are single-quoted with
embedded quotes escaped, so the response can be sourced directly.

### `GET /api/product-sync/ping/`

A liveness and credential check. Called by `climweb-sync --check`.

```
Authorization: Bearer <token>
```

| Response | Meaning |
|---|---|
| `200` | Token valid, API available |
| `401` / `403` | Token missing, invalid, or revoked |
| `404` | This ClimWeb version has no product-sync API |

Returns `full_sync_requested` (`"true"`/`"false"`), which is how the **Sync all
files** button in the admin reaches the source server: the request cannot be
pushed, so it is carried on the check the client already makes at the start of
every run. Supports `?format=env`.

Reading the flag must **not** clear it — see the completion endpoint below.

### `POST /api/product-sync/full-sync-complete/`

Acknowledges a finished full sync, clearing the pending state in the admin.

```
Authorization: Bearer <token>
```

The client calls this only after a run with no failures. Clearing on
acknowledgement rather than on read means a run that dies partway leaves the
request outstanding, so the next run retries it instead of dropping it.

| Response | Meaning |
|---|---|
| `200` | Cleared, or there was nothing pending |
| `401` | Authentication failure |

A credential can only clear its own request.

### `POST /api/product-sync/upload/`

`multipart/form-data`, one file per request.

```
Authorization: Bearer <token>
```

| Field | Type | Description |
|---|---|---|
| `variable_name` | text | Must match `Product.variable_name` |
| `format` | text | Must match the category's `category_format` (lowercase, no dot) |
| `relative_path` | text | Path relative to the format directory, e.g. `2026/bulletin_09-03-2026.pdf`. May contain subdirectories. |
| `file` | file | The file itself |

| Response | Meaning |
|---|---|
| `201` | Stored |
| `200` | Stored, replacing an existing file |
| `409` | Identical file already present; client records it as done |
| `400` | Bad request — unknown `variable_name`, bad `format`, or unsafe `relative_path` |
| `401` / `403` | Authentication failure |
| `413` | File exceeds the server's upload limit |

## Server-side invariants

These are the properties the ClimWeb implementation upholds. They are recorded
here because they are the parts that must not regress.

**Resolve the destination the same way the ingester does.** The file is
written to:

```
<product.watch_root>/<product.variable_name>/<format>/<relative_path>
```

using the same `_resolve_watch_root()` logic as
`climweb/pages/products/tasks.py`, so a relative `watch_root` resolves under
`MEDIA_ROOT` consistently for both paths.

**Reject path traversal.** `relative_path` is attacker-controlled. Normalise it
and confirm the result is still inside the destination directory; reject any
component equal to `..`, any absolute path, and any symlink. A single mistake
here is an arbitrary file write on the ClimWeb server.

**Validate the format.** Only accept a `format` that matches a
`ProductCategory.category_format` belonging to that product, and require the
uploaded file's extension to match it. Do not accept arbitrary extensions.

**Write atomically.** Write to a temporary file in the same directory, then
rename into place. Otherwise the ingestion scan, which runs on its own timer,
can pick up a half-uploaded bulletin.

**Set readable permissions** on the finished file, so the ingester can open it.

**Scope tokens per product.** A token should authorise a specific set of
products, not the whole watch root. Store hashed, support revocation, and
record last-used time so stale credentials are visible in the admin.

**Rate limit,** and enforce a maximum file size, returning `413` rather than
timing out.

## Client behaviour worth knowing

- One request per file; there is no batching and no resume.
- The client keeps a local state file (`/var/lib/climweb-sync/*.state`) recording
  size and mtime for files the server confirmed. A file is only recorded after a
  `2xx` or `409`, so an interrupted run retries rather than skipping.
- If the server is rebuilt and its files lost, delete the client state files to
  force a full re-upload.
- Failures are logged per file; the run continues and exits `1` at the end.

## Implementation notes

The ClimWeb implementation lives in `climweb/pages/products/sync_api.py` and
`sync_models.py`, reusing `Product` and `ProductCategory` for validation.

Uploading does *not* trigger ingestion inline — the existing periodic
`ingest_product_files` task picks the files up, so both transports converge on
exactly the same code path and there is only one ingestion behaviour to reason
about.
