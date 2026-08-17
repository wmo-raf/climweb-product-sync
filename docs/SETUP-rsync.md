# Setting up the rsync transport

This is the recommended way to sync. It takes two people:

- **You**, on the server that generates the products ("the source server")
- **Your ClimWeb administrator**, on the server running the website

Work through Part 1, send the output of step 3 to your administrator, and they
work through Part 2. Then come back for Part 3.

---

## Part 1 — On the source server (you)

### 1. Install

```bash
git clone https://github.com/wmo-raf/climweb-product-sync.git
cd climweb-product-sync
sudo ./install.sh
```

### 2. Find out what ClimWeb expects

Open the ClimWeb admin and go to **Snippets → Products**. Open the product you
want to sync and note three things:

| Field in the CMS | Goes in your config as |
|---|---|
| Variable Name | `variable_name` |
| Watch Root Path | `watch_root` |
| File Format (on the Product Category) | `format` |

If **Watch Root Path** is relative (for example just `products`), ClimWeb
resolves it under its media root. Ask your administrator for the absolute path —
usually something like `/home/cms/climweb/climweb/media/products`. Your config
needs the absolute form.

Also confirm **Enable Auto-Ingestion** is ticked on the product. Without it,
files will arrive and sit there unread.

### 3. Create an SSH key and send the public half

```bash
sudo ssh-keygen -t ed25519 -N "" -C "climweb-sync@$(hostname)" \
    -f /etc/climweb-sync/id_ed25519
sudo chmod 600 /etc/climweb-sync/id_ed25519
sudo cat /etc/climweb-sync/id_ed25519.pub
```

Send **only the `.pub` output** to your ClimWeb administrator, along with Part 2
of this document. The private key never leaves this server.

---

## Part 2 — On the ClimWeb server (your administrator)

You have been sent a public key by a national met service that wants to push
product files into ClimWeb's watch folder. Here is what to set up.

### 1. Create a dedicated account

Do not reuse an existing account, and do not use `root`.

```bash
sudo adduser --system --group --shell /bin/bash --home /home/climweb-sync climweb-sync
sudo mkdir -p /home/climweb-sync/.ssh
sudo chmod 700 /home/climweb-sync/.ssh
```

### 2. Give it write access to the watch folder only

Replace `<watch_root>` with the absolute Watch Root Path from the product
snippet, and `<climweb-user>` with the user the ClimWeb application runs as.

```bash
sudo mkdir -p <watch_root>
sudo chgrp -R climweb-sync <watch_root>
sudo chmod -R 2775 <watch_root>          # setgid: new files keep the group
sudo usermod -aG climweb-sync <climweb-user>
```

The setgid bit matters: without it, files arriving from the sync may not be
readable by the ClimWeb process, and ingestion will fail with permission errors
that are easy to misdiagnose.

### 3. Install the key, restricted

Add the public key you were sent to
`/home/climweb-sync/.ssh/authorized_keys`, prefixed with these restrictions so
the key can only run rsync and cannot open an interactive shell or forward
ports:

```
restrict,command="rrsync -wo <watch_root>" ssh-ed25519 AAAAC3Nza... climweb-sync@met-server
```

`rrsync` ships with rsync (on Debian/Ubuntu:
`/usr/share/rsync/scripts/rrsync`, or `/usr/bin/rrsync` on newer releases). It
confines the connection to the given directory. `-wo` makes it write-only,
so the source server can push files but cannot read anything back off the
ClimWeb server.

```bash
sudo chown -R climweb-sync:climweb-sync /home/climweb-sync/.ssh
sudo chmod 600 /home/climweb-sync/.ssh/authorized_keys
```

> If `rrsync` is not available, the plain `restrict` prefix alone still blocks
> shell access, but does not confine writes to the watch folder. Prefer
> `rrsync` where you can.

### 4. Confirm rsync is installed

```bash
rsync --version || sudo apt install rsync
```

Tell the met service the account name (`climweb-sync`), the hostname, the SSH
port, and the absolute watch root.

---

## Part 3 — Back on the source server (you)

### 1. Fill in the config

```bash
sudo nano /etc/climweb-sync/config.yaml
```

```yaml
climweb:
  transport: rsync
  host: cms.meteo.example.org          # from your administrator
  user: climweb-sync
  port: 22
  ssh_key: /etc/climweb-sync/id_ed25519
  watch_root: /home/cms/climweb/climweb/media/products   # absolute path

defaults:
  max_age_days: 30

products:
  - variable_name: weekly_rainfall     # must match the CMS exactly
    format: pdf                        # must match the CMS exactly
    src_path: /home/username/data/wkrainfall
```

### 2. Check it

```bash
sudo climweb-sync --check
```

This validates the file, tests the SSH connection, and prints the destination
path for each product. **Read those paths.** They are what ClimWeb will scan —
if one looks wrong, fix `variable_name`, `format` or `watch_root` now rather
than wondering later why nothing is publishing.

### 3. Rehearse, then run

```bash
sudo climweb-sync --dry-run --verbose   # transfers nothing
sudo climweb-sync --verbose             # for real
```

### 4. Confirm ClimWeb picked it up

Ingestion runs on a timer, so give it a few minutes. To force it immediately,
your administrator can use the **Trigger ingestion** action on the product page
in the CMS admin. New Product Item pages should appear under the product.

### 5. Let the schedule take over

The installer already set up a check every 10 minutes. To change the frequency:

```bash
sudo nano /etc/cron.d/climweb-sync
```

A run with nothing to send takes about a tenth of a second, so checking often
costs almost nothing and means new files appear promptly. There is little reason
to make this less frequent.

Logs go to `/var/log/climweb-sync/sync.log`.

---

## Rotating the key later

Generate a new key, have your administrator add it alongside the old one,
switch `ssh_key` in the config, confirm with `--check`, then have the old key
removed.
