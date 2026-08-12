# climweb-product-sync

Publish forecast bulletins and other products on a [ClimWeb](https://github.com/wmo-raf/climweb)
website automatically, by copying them from the server that generates them.

You install this on **your own server** — the one where your products are
written. It sends new files to the website on a schedule, and they appear
without anyone uploading anything by hand.

```
  Met service server                              ClimWeb website
  ┌──────────────────────┐                        ┌──────────────────────────┐
  │ /data/wkrainfall/    │                        │                          │
  │   bulletin_w32.pdf   │  ── climweb-sync ──▶   │   Weekly Rainfall        │
  │   bulletin_w33.pdf   │      (every hour)      │   published automatically│
  └──────────────────────┘                        └──────────────────────────┘
```

## Setting it up

Ask whoever manages your ClimWeb website to open the product in the admin,
click **Automated Publishing**, and send you the command shown there. It looks
like this:

```bash
curl -fsSL https://your-website/api/product-sync/setup.sh | sudo bash -s K7FA-2C9D-TX43
```

Run it once, on the server where the files are generated. It asks you a single
question — which folder the files are in — and sets up everything else itself:

```
  ClimWeb — automated publishing setup
  ────────────────────────────────────────────────────────

  Contacting https://your-website ... connected

  ✓ Found: Weekly Rainfall
        File format: pdf
        Destination: set automatically — you do not need to know it

  ────────────────────────────────────────────────────────
  Where are the pdf files on this server?

  Folders on this server that contain .pdf files:
    1) /home/met/data/wkrainfall
    2) /home/met/data/seasrainfall
  Type a number, or the full path to a different folder.

  Folder: 1
  ✓ Found 14 .pdf file(s)
        bulletin_2026-08-03.pdf
        bulletin_2026-07-27.pdf

  ────────────────────────────────────────────────────────
  How often are new files produced?
    1) Several times a day    (check every hour)
    2) Once a day             (check every morning)

  Choose [1]: 2

  ✓ Configuration saved
    Sending a test file ... OK
  ✓ Scheduled

  Done. Weekly Rainfall will publish automatically from now on.
```

Nothing is transcribed, so nothing can be mistyped. The variable name, file
format and destination all come from the website itself.

### If the setup code does not work

Codes expire after 48 hours and can only be used once. Ask for a new one — it
takes a few seconds to generate.

## Checking on it later

```bash
sudo climweb-sync             # run now, without waiting for the schedule
sudo climweb-sync --check     # confirm everything still works
sudo climweb-sync --dry-run   # show what would be sent, send nothing
```

Logs are in `/var/log/climweb-sync/sync.log`.

## Setting it up by hand

The guided setup needs a ClimWeb version that supports it. If your website is
older, or your server cannot reach the internet directly, you can configure the
tool yourself — see **[docs/SETUP-rsync.md](docs/SETUP-rsync.md)**.

Doing it by hand also gives you the `rsync` transport, which is worth choosing
if you have years of archive to send or a slow link: it transfers only what
changed and resumes after an interruption.

```bash
git clone https://github.com/wmo-raf/climweb-product-sync.git
cd climweb-product-sync
sudo ./install.sh
sudo nano /etc/climweb-sync/config.yaml
sudo climweb-sync --check
```

## Configuration

Whether it was written by the wizard or by you, the settings live in
`/etc/climweb-sync/config.yaml`:

```yaml
climweb:
  transport: https
  base_url: https://your-website
  token_file: /etc/climweb-sync/token

defaults:
  max_age_days: 30

products:
  - variable_name: weekly_rainfall
    format: pdf
    src_path: /home/met/data/wkrainfall
```

To add a second product, copy the last block and change the three values. Run
`climweb-sync --check` afterwards to confirm it is still valid.

Every option is documented in [`config.example.yaml`](config.example.yaml).

### Why YAML rather than JSON

The file is edited by hand by people who do not necessarily write code. YAML
takes comments, so each setting explains itself; it has no trailing-comma trap,
which is the most common way a hand-edited JSON file stops parsing; and
`variable_name: weekly_rainfall` reads like a form.

The parser accepts a deliberately small subset and rejects anything outside it,
including unknown keys, so a typo produces a line number instead of a product
that silently stops updating.

## The one rule behind all of this

ClimWeb's ingester scans:

```
<watch_root>/<variable_name>/<format>/<filename convention>.<format>
```

`climweb-sync` never asks anyone to type that path. It derives it from
`variable_name` and `format`, which the guided setup takes directly from the
CMS. That is the whole reason the setup code exists: a path transcribed by hand
is a product that silently stops publishing six months later.

## How it behaves

- **Safe to run often.** Nothing is re-sent unless it changed, and a lock file
  stops overlapping runs colliding.
- **Only recent files.** `max_age_days` (default 30) keeps each run fast once
  the source folder holds years of history. Set `0` to send everything.
- **Subdirectories are preserved**, so `2026/bulletin_09-03-2026.pdf` works with
  a `{yyyy}/...` filename convention in ClimWeb.
- **Half-written files are skipped** — `*.tmp`, `*.part` and dotfiles are left
  alone, so a bulletin still being generated is never published truncated.
- **Nothing is ever deleted** on the website unless you set `delete_remote: true`.

## Transports

| | `https` | `rsync` |
|---|---|---|
| Set up by | The guided wizard | By hand, with an administrator |
| Needs | A setup code | SSH access to the ClimWeb server |
| Sends | Whole files, no resume | Only changed blocks, resumable |
| Best for | Almost everyone | Large archives, slow or unreliable links |

## Documentation

- [SETUP-https.md](docs/SETUP-https.md) — the guided flow, and configuring it by hand
- [SETUP-rsync.md](docs/SETUP-rsync.md) — SSH keys and the restricted account, step by step
- [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — "it copied but nothing appears on the site", and friends
- [SERVER-API.md](docs/SERVER-API.md) — the endpoints this tool talks to

## Tests

```bash
./tests/run-tests.sh     # config parsing, path derivation, rsync transport
./tests/test-setup.sh    # the guided setup wizard
```

Both run offline. The rsync transport is exercised against a local shim, and the
wizard against a stubbed API, so neither needs a ClimWeb server.

## License

MIT. See [LICENSE](LICENSE).
