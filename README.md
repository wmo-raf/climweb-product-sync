# climweb-product-sync

Copy forecast bulletins and other products from the server that generates them
to the folder [ClimWeb](https://github.com/wmo-raf/climweb) watches, so they are
published on the website automatically.

You install this on **your own server** — the one where your products are
written. It pushes files to the ClimWeb server on a schedule. Nothing needs to
be installed on the ClimWeb side.

```
  Met service server                              ClimWeb server
  ┌──────────────────────┐                        ┌──────────────────────────┐
  │ /data/wkrainfall/    │                        │ <watch_root>/            │
  │   bulletin_w32.pdf   │  ── climweb-sync ──▶   │   weekly_rainfall/pdf/   │
  │   bulletin_w33.pdf   │      (hourly cron)     │     bulletin_w32.pdf     │
  └──────────────────────┘                        └──────────────────────────┘
                                                              │
                                                   ClimWeb scans this folder
                                                   and publishes each new file
```

## Why a config file, and why YAML

The whole point is that a country's IT team fills in one file and never touches
the script. That file is YAML rather than JSON for three reasons:

- **Comments.** Every setting can carry an explanation right next to it. JSON
  has no comment syntax, so the explanation has to live in a separate document
  that gets out of sync with the file people actually edit.
- **Fewer ways to break it.** No braces to balance, no quotes required around
  paths, and no trailing-comma trap — which is the single most common way a
  hand-edited JSON file stops parsing.
- **It reads like a form.** `variable_name: weekly_rainfall` is legible to
  someone who does not write code.

The parser here accepts a deliberately small YAML subset and rejects anything
outside it, including unknown keys, so a typo produces a line number rather
than a product that silently stops updating.

## The one rule that matters

ClimWeb's ingester scans:

```
<watch_root>/<variable_name>/<format>/<filename convention>.<format>
```

So `variable_name` and `format` in your config **must match the Product snippet
in the ClimWeb admin exactly**. You never write the destination path yourself —
`climweb-sync` builds it from those two fields. If they match the CMS, the files
land where the ingester is looking; if they don't, nothing is published and
`--check` will show you the path being used.

## Install

On the server that generates your products:

```bash
git clone https://github.com/wmo-raf/climweb-product-sync.git
cd climweb-product-sync
sudo ./install.sh
```

That installs `climweb-sync`, creates `/etc/climweb-sync/config.yaml`, and adds
an hourly cron job. For a systemd timer instead: `sudo ./install.sh --schedule systemd`.

Requirements: `bash`, `rsync`, `ssh`, `awk`, `find`. All are present on a
standard Debian/Ubuntu or RHEL install.

## Configure

Edit `/etc/climweb-sync/config.yaml`:

```yaml
climweb:
  transport: rsync
  host: cms.meteo.example.org
  user: climweb-sync
  ssh_key: /etc/climweb-sync/id_ed25519
  watch_root: /home/cms/climweb/climweb/media/products

defaults:
  max_age_days: 30

products:
  - variable_name: weekly_rainfall
    format: pdf
    src_path: /home/username/data/wkrainfall

  - variable_name: seasonal_rainfall
    format: pdf
    src_path: /home/username/data/seasrainfall
```

Every option is documented in [`config.example.yaml`](config.example.yaml).

Then set up SSH access — see **[docs/SETUP-rsync.md](docs/SETUP-rsync.md)** for
the exact commands, including what to send your ClimWeb administrator.

## Check before you trust it

```bash
sudo climweb-sync --check              # validate config, test the connection,
                                       # print the destination paths it will use
sudo climweb-sync --dry-run --verbose  # list what would be sent, send nothing
sudo climweb-sync --verbose            # do it for real
```

`--check` prints the resolved destination for each product. Compare it against
the Watch Root Path on the Product snippet in the CMS before the first real run.

## Usage

```
climweb-sync [options]

  -c, --config FILE   Config file (default /etc/climweb-sync/config.yaml)
  -n, --dry-run       Show what would be transferred, send nothing
      --check         Validate config and connection, then exit
      --only NAME     Sync only the product with this variable_name
  -v, --verbose       List every file transferred
  -h, --help          Show help
```

Exit codes: `0` success · `1` one or more products failed · `2` config error ·
`3` cannot reach the ClimWeb server · `4` another run is already in progress.

## How it behaves

- **Safe to run often.** rsync only sends what changed, and a lock file means
  overlapping cron ticks cannot collide. An hourly schedule on a product
  generated daily is fine.
- **Only recent files.** `max_age_days` (default 30) keeps each run fast once
  the source directory holds years of history. Set it to `0` to send everything.
- **Subdirectories are preserved**, so a source layout of `2026/bulletin_09-03-2026.pdf`
  works with a `{yyyy}/...` filename convention in ClimWeb.
- **Half-written files are skipped** — anything matching `*.tmp`, `*.part` or a
  dotfile is left alone, so a bulletin still being generated is never ingested
  truncated.
- **Nothing is ever deleted** on the ClimWeb server unless you explicitly set
  `delete_remote: true`.

## Transports

| | `rsync` (recommended) | `https` |
|---|---|---|
| Needs | SSH access to the ClimWeb server | An API token |
| Sends | Only changed blocks, resumable | Whole files, no resume |
| Use when | Normally | Outbound SSH is blocked on your network |

The `https` transport needs an upload endpoint on the ClimWeb server that not
every version ships. Check [docs/SERVER-API.md](docs/SERVER-API.md) and confirm
with your ClimWeb administrator before choosing it.

## Documentation

- [SETUP-rsync.md](docs/SETUP-rsync.md) — SSH keys and the restricted account, step by step
- [SETUP-https.md](docs/SETUP-https.md) — token-based uploads for locked-down networks
- [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — "the files copied but nothing appears on the site", and friends
- [SERVER-API.md](docs/SERVER-API.md) — the endpoint the https transport expects

## Tests

```bash
./tests/run-tests.sh
```

No network and no ClimWeb server required — the rsync path is exercised against
a local shim.

## License

MIT. See [LICENSE](LICENSE).
