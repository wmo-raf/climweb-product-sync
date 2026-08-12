# Server API specification (for the `https` transport)

> **Status: not part of ClimWeb yet.**
>
> The `rsync` transport works against any ClimWeb installation today and needs
> no server-side code. The `https` transport described here requires an upload
> endpoint that ClimWeb does not currently ship. This document specifies what
> `climweb-sync` sends, so the endpoint can be implemented in ClimWeb and the
> two sides agree from the start.
>
> Until it exists, `climweb-sync --check` will fail with a clear message telling
> the operator to use `transport: rsync`.

## Why it would be worth having

Some national met services sit behind networks that permit outbound HTTPS and
nothing else. For them, SSH-based sync is not an option, and the alternative is
a manual upload by a person every day.

## Endpoints

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

Body is ignored by the client.

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

## Server-side requirements

**Resolve the destination the same way the ingester does.** The file must be
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

## Suggested implementation notes

A Wagtail/Django implementation would sit naturally alongside
`climweb/pages/products/`, reusing `Product` and `ProductCategory` for
validation. It should *not* trigger ingestion inline — let the existing periodic
`ingest_product_files` task pick the files up, so both transports converge on
exactly the same code path and there is only one ingestion behaviour to reason
about.
