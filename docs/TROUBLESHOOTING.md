# Troubleshooting

Start here:

```bash
sudo climweb-sync --check
sudo tail -50 /var/log/climweb-sync/sync.log
```

---

## The setup command did not work

**"That setup code was not accepted."**
Codes last 48 hours and work once only. Generating a new code also cancels the
previous one, so if two were sent, only the newer works. Ask the website
administrator for a fresh code — it takes seconds.

**"The product is not fully configured on the website yet."**
Something is missing on the Product snippet. The **Automated Publishing** screen
in the admin lists exactly which item, with a tick or a cross against each.

**"This ClimWeb website does not support automated setup."**
The site is running a version older than this feature. Set the sync up by hand
instead — see [SETUP-rsync.md](SETUP-rsync.md).

**"Could not reach ..."**
This server has no route to the website. Check internet access and the address,
and set `https_proxy` if your organisation uses a proxy.

**"Could not download the tool from ..."**
The server cannot reach GitHub. Ask your ClimWeb administrator for an offline
copy of this repository, run `sudo ./install.sh --no-schedule` from it, then
`sudo climweb-sync setup --server https://your-website YOUR-CODE`.

---

## The files copied, but nothing appears on the website

This is the most common problem, and it is almost always a mismatch between the
config and the CMS. Work down this list in order.

If setup was done with a setup code, skip straight to step 2 — the paths came
from the website itself and cannot be wrong.

**1. Is the destination path the one ClimWeb scans?**

```bash
sudo climweb-sync --check
```

Compare the printed path against the product in **Snippets → Products**:

```
<watch_root>/<variable_name>/<format>/
```

Every part must match. `weekly-rainfall` and `weekly_rainfall` are different
folders. So are `PDF` and `pdf`.

**2. Is auto-ingestion actually enabled?**

On the product snippet, **Enable Auto-Ingestion** must be ticked. Without it the
scanner skips the product entirely, however many files arrive.

**3. Do the filenames match the convention?**

ClimWeb only ingests files whose names match the **File Name Convention** on the
Product Item Type, with `{yyyy}`, `{mm}`, `{dd}` and `{hh}` standing in for the
date parts. A file called `rainfall_final_v2.pdf` will be ignored no matter
where it sits.

Ask your administrator for the exact convention and compare it to a real
filename, character by character. Accents and spaces count.

**4. Has the scan run yet?**

Ingestion runs on a timer, not instantly. Your administrator can force it with
the **Trigger ingestion** action on the product page in the CMS admin.

**5. Can the ClimWeb process read the files?**

On the ClimWeb server:

```bash
ls -l <watch_root>/<variable_name>/<format>/
```

The files need to be readable by the user ClimWeb runs as. If they are not, set
`chmod: F644` in the `defaults:` block of your config and check the setgid step
in [SETUP-rsync.md](SETUP-rsync.md) Part 2.

---

## "cannot reach the ClimWeb server over SSH" (exit code 3)

Test the connection by hand to see the real error:

```bash
ssh -i /etc/climweb-sync/id_ed25519 -p 22 climweb-sync@YOUR-CLIMWEB-HOST
```

| What you see | What it means |
|---|---|
| `Permission denied (publickey)` | The public key was never added on the ClimWeb server, or was added to the wrong account. Re-send `/etc/climweb-sync/id_ed25519.pub`. |
| `Connection timed out` | A firewall is blocking the SSH port. Check outbound rules on your side and inbound on theirs. |
| `Connection refused` | Nothing is listening on that port. Confirm the port number with your administrator. |
| `Host key verification failed` | The server's key changed. Confirm with your administrator that this was expected, then `ssh-keygen -R YOUR-CLIMWEB-HOST`. |
| `This service allows sftp connections only` | The key was installed with the wrong restrictions. See Part 2 of the setup guide. |

Note that with `rrsync` restrictions in place, a bare `ssh` login is *supposed*
to fail — that is the restriction working. `climweb-sync --check` accounts for
this; a plain `ssh` test does not.

---

## "some files could not be transferred (code 23)"

Permission denied writing into the watch folder. On the ClimWeb server:

```bash
sudo chgrp -R climweb-sync <watch_root>
sudo chmod -R 2775 <watch_root>
```

---

## "another climweb-sync run is already in progress" (exit code 4)

A previous run is still going — normal on the first sync of a large archive.
Check with `ps aux | grep climweb-sync`.

If nothing is running, a killed run left a stale lock:

```bash
sudo rm -f /tmp/climweb-sync.lock*
```

To make first runs shorter, lower `max_age_days` so only recent files are sent.

---

## "config error, line N"

The parser accepts a small, strict YAML subset and reports the offending line.
Common causes:

- **Tabs.** Indent with spaces only.
- **A misspelled key.** Unknown keys are rejected rather than ignored, on
  purpose — a silently ignored `watchroot:` would be much harder to find.
- **A `#` inside a path.** `#` starts a comment. Rename the directory.
- **A missing `- `.** Each product must begin with `- variable_name: ...`.
- **A nested block.** Only `key: value` lines are supported; there is no level
  below `climweb:`, `defaults:` or `products:`.

---

## Old files are not being sent

By default only files modified in the last 30 days are considered. To backfill
an archive, temporarily raise or disable the limit:

```bash
sudo climweb-sync --only weekly_rainfall -v   # after setting max_age_days: 0
```

Expect the first such run to take a while. Put the limit back afterwards so
routine runs stay fast.

---

## A file was sent while it was still being written

Files matching `*.tmp`, `*.part` or starting with `.` are skipped. If your
generation process writes directly to the final filename, have it write to
`name.pdf.tmp` and rename to `name.pdf` when finished — a rename is atomic, so
the sync only ever sees the complete file.

---

## Nothing in the log at all

Confirm the schedule is active:

```bash
systemctl list-timers climweb-sync.timer    # if using systemd
cat /etc/cron.d/climweb-sync                # if using cron
grep CRON /var/log/syslog | grep climweb    # did cron try?
```

---

## Still stuck

Open an issue at <https://github.com/wmo-raf/climweb-product-sync/issues> with:

```bash
climweb-sync --version
sudo climweb-sync --check 2>&1
```

Redact hostnames if you need to — but keep the destination paths, since those
are usually where the problem is.
