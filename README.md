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

### Products published in more than one format

If the product is set up in the CMS with several formats — say PDF and PNG —
the wizard asks about each one in turn, so no part of the product is left
unpublished:

```
  This product is published in 2 formats: pdf, png
      Each one is set up in turn. You can skip any that are not
      produced on this server.

  Where are the pdf files on this server?
  Folder: /home/met/data/wkrainfall
  ✓ Found 14 .pdf file(s)

  Where are the png files on this server?
  The folder you gave for the previous format also holds
  14 .png file(s):
      /home/met/data/wkrainfall

  Use that folder for png as well? [y/N] y
  ✓ Found 14 .png file(s)
```

If a format is produced somewhere else, give a different folder. If it is not
produced on this server at all, leave the answer blank to skip it — the wizard
says plainly which formats were skipped, so a half-configured product is
obvious at the time rather than six months later.

Each format becomes its own entry under `products:`, and each is tested with a
real upload before setup reports success.

### If the setup code does not work

Codes expire after 48 hours and can only be used once. Ask for a new one — it
takes a few seconds to generate.

## Supported systems

| | Status |
|---|---|
| Linux (Ubuntu, Debian, RHEL, Rocky) | Supported. This is what to run in production. |
| Windows, via WSL2 | Supported — WSL2 *is* Linux. See below. |
| macOS | Runs, but does not schedule. Fine for testing, not for production. |
| Windows, without WSL2 | Not supported. |

The tool needs `bash` 3.2 or newer, plus `curl`, `awk` and `find`. Every Linux
distribution ships all of them. The test suite runs on both Ubuntu and macOS in
CI, with macOS pinned to bash 3.2 so the oldest supported shell is genuinely
exercised.

### Windows

Products are usually generated on a Linux server, but if yours are produced on
Windows, install **WSL2** and run the sync inside it. WSL2 is a real Linux
system, so everything above works unchanged.

```powershell
wsl --install -d Ubuntu
```

Then open Ubuntu from the Start menu and run the setup command there. Your
Windows drives appear under `/mnt/`, so a folder at `D:\weather\rainfall` is
`/mnt/d/weather/rainfall` — give that path when the wizard asks where the files
are.

Two things to set, or the sync will stop when you are not looking:

```bash
# Keep WSL running in the background so cron fires without a user logged in.
# In /etc/wsl.conf:
[boot]
systemd=true
```

and confirm cron is running inside WSL with `sudo service cron status`. WSL2
does not start background services by default on older builds.

### macOS

The tool installs and `sudo climweb-sync` works, but macOS ignores
`/etc/cron.d`, so nothing is scheduled. `install.sh` detects this and says so
rather than reporting a schedule that would never fire. Use a Linux server for
anything that has to keep publishing on its own.

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
