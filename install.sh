#!/usr/bin/env bash
#
# install.sh — install climweb-sync system-wide and set up a schedule.
#
#   sudo ./install.sh                    # install, then check every 10 min
#   sudo ./install.sh --schedule systemd # use a systemd timer instead of cron
#   sudo ./install.sh --no-schedule      # install only
#   sudo ./install.sh --uninstall

set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
CONFIG_DIR="/etc/climweb-sync"
STATE_DIR="/var/lib/climweb-sync"
LOG_DIR="/var/log/climweb-sync"
SCHEDULE="cron"
CRON_SPEC="${CRON_SPEC:-*/10 * * * *}"   # a no-op run costs ~0.1s, so check often
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "run this with sudo"

UNINSTALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --schedule)    SCHEDULE="${2:-cron}"; shift 2 ;;
        --no-schedule) SCHEDULE="none"; shift ;;
        --uninstall)   UNINSTALL=1; shift ;;
        --prefix)      PREFIX="${2:-}"; shift 2 ;;
        -h|--help)     sed -n '2,10p' "$0"; exit 0 ;;
        *) fail "unknown option '$1'" ;;
    esac
done

# -----------------------------------------------------------------------------
if [ "$UNINSTALL" -eq 1 ]; then
    echo "Removing climweb-sync..."
    rm -f "$PREFIX/bin/climweb-sync"
    rm -rf "$PREFIX/lib/climweb-sync"
    rm -f /etc/cron.d/climweb-sync
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now climweb-sync.timer 2>/dev/null || true
        rm -f /etc/systemd/system/climweb-sync.{service,timer}
        systemctl daemon-reload 2>/dev/null || true
    fi
    ok "removed (config in $CONFIG_DIR was left in place)"
    exit 0
fi

echo "Installing climweb-sync..."

# --- dependencies ------------------------------------------------------------
missing=()
for dep in rsync ssh awk find; do
    command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
done
if [ ${#missing[@]} -gt 0 ]; then
    fail "missing required commands: ${missing[*]}
  On Debian/Ubuntu:  sudo apt install rsync openssh-client
  On RHEL/Rocky:     sudo dnf install rsync openssh-clients"
fi
ok "dependencies present"

# --- files -------------------------------------------------------------------
install -d "$PREFIX/lib/climweb-sync"
install -m 0755 "$SRC_DIR/climweb-sync" "$PREFIX/bin/climweb-sync"
install -m 0644 "$SRC_DIR"/lib/*.sh  "$PREFIX/lib/climweb-sync/"
install -m 0644 "$SRC_DIR"/lib/*.awk "$PREFIX/lib/climweb-sync/"
ok "installed to $PREFIX/bin/climweb-sync"

install -d -m 0750 "$CONFIG_DIR"
install -d -m 0750 "$STATE_DIR"
install -d -m 0750 "$LOG_DIR"

if [ -f "$CONFIG_DIR/config.yaml" ]; then
    install -m 0640 "$SRC_DIR/config.example.yaml" "$CONFIG_DIR/config.example.yaml"
    say "existing $CONFIG_DIR/config.yaml left untouched"
else
    install -m 0640 "$SRC_DIR/config.example.yaml" "$CONFIG_DIR/config.yaml"
    install -m 0640 "$SRC_DIR/config.example.yaml" "$CONFIG_DIR/config.example.yaml"
    ok "created $CONFIG_DIR/config.yaml — edit this before the first run"
fi

# --- schedule ----------------------------------------------------------------
# macOS cron does not read /etc/cron.d, so a job written there never fires.
# The Mac is a development platform for this tool, not a deployment target.
if [ "$(uname -s 2>/dev/null)" = "Darwin" ] && [ "$SCHEDULE" != "none" ]; then
    say "macOS detected — skipping the schedule."
    say "  macOS does not read /etc/cron.d, so a cron job here would never run."
    say "  The tool is installed and 'sudo climweb-sync' works; scheduling is"
    say "  supported on Linux servers."
    SCHEDULE="none"
fi

case "$SCHEDULE" in
    cron)
        cat > /etc/cron.d/climweb-sync <<EOF
# climweb-sync — push met service products into ClimWeb's watch folder.
# Runs every 10 minutes. A run with nothing to send costs ~0.1s, so there is
# nothing to gain by making this less frequent.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=root

$CRON_SPEC root $PREFIX/bin/climweb-sync >> $LOG_DIR/sync.log 2>&1
EOF
        chmod 0644 /etc/cron.d/climweb-sync
        ok "cron job installed (/etc/cron.d/climweb-sync, runs '$CRON_SPEC')"
        ;;
    systemd)
        command -v systemctl >/dev/null 2>&1 || fail "systemd not available; use --schedule cron"
        sed "s|@PREFIX@|$PREFIX|g" "$SRC_DIR/systemd/climweb-sync.service" \
            > /etc/systemd/system/climweb-sync.service
        install -m 0644 "$SRC_DIR/systemd/climweb-sync.timer" /etc/systemd/system/
        systemctl daemon-reload
        systemctl enable --now climweb-sync.timer
        ok "systemd timer enabled (systemctl list-timers climweb-sync.timer)"
        ;;
    none)
        say "no schedule configured"
        ;;
    *) fail "unknown --schedule '$SCHEDULE' (expected cron, systemd or none)" ;;
esac

# --- log rotation ------------------------------------------------------------
if [ -d /etc/logrotate.d ]; then
    cat > /etc/logrotate.d/climweb-sync <<EOF
$LOG_DIR/*.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    copytruncate
}
EOF
    ok "log rotation configured"
fi

cat <<EOF

Installed. Next steps:

  1. Edit the config:
       sudo nano $CONFIG_DIR/config.yaml

  2. Create an SSH key and send the public half to whoever administers your
     ClimWeb server (full instructions in docs/SETUP-rsync.md):
       sudo ssh-keygen -t ed25519 -N "" -f $CONFIG_DIR/id_ed25519
       sudo cat $CONFIG_DIR/id_ed25519.pub

  3. Once they confirm the key is installed, check everything:
       sudo climweb-sync --check

  4. Do a rehearsal that transfers nothing:
       sudo climweb-sync --dry-run --verbose

  5. Then let the schedule take over. Logs: $LOG_DIR/sync.log

EOF
