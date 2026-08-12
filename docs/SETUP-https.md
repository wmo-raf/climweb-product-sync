# Setting up with a setup code

This is the guided path, and the one to use unless you have a reason not to.
It needs no SSH access and no coordination between two organisations.

---

## For the website administrator

You do this once, in the ClimWeb admin. It takes about a minute.

### 1. Check the product is ready

Open **Pages → your product page**, and make sure the Product snippet
(**Snippets → Products**) has:

- **Enable Auto-Ingestion** ticked
- a **Variable Name**, e.g. `weekly_rainfall`
- a **Watch Root Path**
- at least one category with a **File Format**, e.g. `pdf`
- a **File Name Convention** on the Product Item Type, e.g.
  `bulletin_{dd}-{mm}-{yyyy}`

The setup screen checks all of these and will not let you generate a code until
they are done, so you do not have to remember the list.

### 2. Generate the code

In the page listing, click **Automated Publishing** on the product, then
**Generate setup code**.

You get a command to send to the met service:

```
curl -fsSL https://your-website/api/product-sync/setup.sh | sudo bash -s K7FA-2C9D-TX43
```

Use **Copy command**, or **Send by email** to open a pre-written message.

### 3. Send it

The code:

- expires after **48 hours**
- can be used **once**
- covers **one product**, and only allows uploading files of that product's
  format into that product's folder

That is why it is safe to send by email or read over the phone. It cannot be
used to log in, read anything, or touch any other part of the website.

Generating a new code immediately invalidates the previous one, so if you are
unsure whether a code went astray, just generate another.

### 4. Watch for the connection

The **Connected servers** section on the same screen fills in as soon as the met
service runs the command, and shows how many files have arrived and when the
server was last seen. **Disconnect** revokes a server's access immediately.

---

## For the met service

Run the command you were sent, on the server where your products are generated.
You need `sudo` on that server.

It asks you one question: which folder the files are in. Everything else —
which product this is, what format, where the files go — comes from the website.

If it cannot reach GitHub to download the tool, ask your ClimWeb administrator
for an offline copy and run `./install.sh` from it, then:

```bash
sudo climweb-sync setup --server https://your-website YOUR-CODE
```

---

## Configuring it by hand instead

If you would rather not use a setup code, ask your administrator for an API
token and write the config yourself.

```bash
sudo install -d -m 0750 /etc/climweb-sync
sudo tee /etc/climweb-sync/token >/dev/null   # paste the token, then Ctrl-D
sudo chmod 600 /etc/climweb-sync/token
```

```yaml
climweb:
  transport: https
  base_url: https://your-website
  token_file: /etc/climweb-sync/token
  verify_tls: true
  watch_root: /home/cms/climweb/climweb/media/products

defaults:
  max_age_days: 30

products:
  - variable_name: weekly_rainfall
    format: pdf
    src_path: /home/met/data/wkrainfall
```

`watch_root` is not used to build the upload URL — the server works the
destination out itself — but keep it filled in so `--check` can show you where
files are headed.

Leave `verify_tls: true`. Turning it off means the token can be read by anyone
positioned between the two servers.

```bash
sudo climweb-sync --check
sudo climweb-sync --dry-run --verbose
sudo climweb-sync --verbose
```

---

## Behind a proxy

```bash
sudo systemctl edit climweb-sync.service
```

```ini
[Service]
Environment="https_proxy=http://proxy.example.org:3128"
```

For cron, add the same line near the top of `/etc/cron.d/climweb-sync`.

---

## Upload state

The client records which files the server has confirmed, in
`/var/lib/climweb-sync/<variable_name>.<format>.state`, so a run does not
re-upload everything each time. A file is only recorded once the server confirms
it, so an interrupted run retries rather than skipping.

If the website is ever rebuilt and its files lost, force a full re-upload:

```bash
sudo rm -f /var/lib/climweb-sync/*.state
```

## Rotating a token

Ask for a new setup code and run setup again — it replaces the token and backs
up the previous configuration. Then have the old credential disconnected from
the **Connected servers** list.
