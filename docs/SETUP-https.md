# Setting up the https transport

> **Check first.** This transport needs an upload API on the ClimWeb server that
> not every version provides — see [SERVER-API.md](SERVER-API.md). Confirm with
> your ClimWeb administrator before going further. If it is not available, use
> [SETUP-rsync.md](SETUP-rsync.md) instead.

## When to use it

Only when the source server cannot open an outbound SSH connection to the
ClimWeb server — typically a ministry network that permits HTTPS and nothing
else, or hosting where port 22 is closed and will not be opened.

It is slower than rsync: each file is uploaded whole, there is no resume, and a
large backfill over a poor link can take a long time. For routine daily
bulletins that is usually fine.

## Setup

### 1. Get a token

Ask your ClimWeb administrator for a product-sync API token scoped to the
products you are syncing. Store it on the source server, readable only by root:

```bash
sudo install -d -m 0750 /etc/climweb-sync
sudo tee /etc/climweb-sync/token >/dev/null   # paste the token, then Ctrl-D
sudo chmod 600 /etc/climweb-sync/token
```

### 2. Configure

```yaml
climweb:
  transport: https
  base_url: https://cms.meteo.example.org
  token_file: /etc/climweb-sync/token
  verify_tls: true
  watch_root: /home/cms/climweb/climweb/media/products

defaults:
  max_age_days: 30

products:
  - variable_name: weekly_rainfall
    format: pdf
    src_path: /home/username/data/wkrainfall
```

`watch_root` is not used to build the upload URL — the server resolves the
destination itself — but keep it filled in so `--check` can show you the path
the files are headed for.

Leave `verify_tls: true`. Turning it off means the token can be intercepted by
anyone able to sit between the two servers.

### 3. Check and run

```bash
sudo climweb-sync --check
sudo climweb-sync --dry-run --verbose
sudo climweb-sync --verbose
```

A `404` from `--check` means this ClimWeb version has no product-sync API. A
`401` or `403` means the token is wrong or has been revoked.

## Behind a proxy

```bash
sudo systemctl edit climweb-sync.service
```

```ini
[Service]
Environment="https_proxy=http://proxy.example.org:3128"
```

For cron, add the same variable at the top of `/etc/cron.d/climweb-sync`.

## Upload state

The client records which files the server has confirmed, in
`/var/lib/climweb-sync/<variable_name>.<format>.state`, so a run does not
re-upload everything. If the ClimWeb server is ever rebuilt and its files lost,
delete those state files to force a full re-upload:

```bash
sudo rm -f /var/lib/climweb-sync/*.state
```

## Rotating the token

Write the new token to `/etc/climweb-sync/token`, run `climweb-sync --check` to
confirm it is accepted, then have the old one revoked.
