# shellcheck shell=bash
#
# setup.sh — the interactive setup wizard.
#
# Design goal: the person running this should not need to know what a watch
# root is, what YAML is, or what their variable_name is. Everything the ClimWeb
# server already knows is fetched with the setup code. The only thing they are
# asked is where their files live, because that is the only thing ClimWeb
# genuinely cannot know.

# --- presentation -------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOUR:-}" ]; then
    C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_GREEN=$'\033[32m'
    C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_OFF=$'\033[0m'
else
    C_BOLD=''; C_DIM=''; C_GREEN=''; C_RED=''; C_YELLOW=''; C_OFF=''
fi

say()      { printf '%s\n' "$*"; }
say_bold() { printf '%s%s%s\n' "$C_BOLD" "$*" "$C_OFF"; }
say_dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }
say_ok()   { printf '  %s✓%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
say_bad()  { printf '  %s✗%s %s\n' "$C_RED" "$C_OFF" "$*"; }
say_warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_OFF" "$*"; }
rule()     { printf '%s\n' "────────────────────────────────────────────────────────"; }

setup_die() {
    say
    say_bad "$1"
    [ -n "${2:-}" ] && { say; say_dim "$2"; }
    say
    exit "${3:-1}"
}

ask() {
    # ask VARNAME "prompt"
    #
    # Reads from the terminal rather than stdin, because this usually runs as
    # `curl ... | sudo bash`, where stdin is the script itself and a plain read
    # would silently consume it.
    #
    # Set CLIMWEB_SYNC_READ_STDIN=1 to read stdin instead — used by the tests,
    # and by anyone driving setup from a script.
    local __var="$1" __prompt="$2" __reply=""
    if [ -z "${CLIMWEB_SYNC_READ_STDIN:-}" ] && [ -r /dev/tty ] && [ -c /dev/tty ]; then
        printf '%s' "$__prompt" > /dev/tty
        IFS= read -r __reply < /dev/tty || true
    else
        printf '%s' "$__prompt"
        IFS= read -r __reply || true
    fi
    printf -v "$__var" '%s' "$__reply"
}

confirm() {
    local reply
    ask reply "$1 [y/N] "
    case "$reply" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# --- helpers ------------------------------------------------------------------

# Look for directories that plausibly hold the product files, so the operator
# can usually confirm a suggestion instead of recalling a full path.
suggest_source_dirs() {
    local fmt="$1" dir count
    for dir in /home/*/data/* /home/*/products/* /data/* /srv/data/* /opt/*/data/* /var/data/*; do
        [ -d "$dir" ] || continue
        count=$(find "$dir" -maxdepth 2 -type f -iname "*.${fmt}" 2>/dev/null | head -1 | grep -c . || true)
        [ "$count" -gt 0 ] && printf '%s\n' "$dir"
    done | head -8
}

# --- the wizard ---------------------------------------------------------------
run_setup() {
    local code="$1" server="$2"
    local hostname http_code

    hostname="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown)"

    say
    say_bold "ClimWeb — automated publishing setup"
    rule
    say

    # -- 1. exchange the code -------------------------------------------------
    printf '  Contacting %s ... ' "$server"

    local tmp_body
    tmp_body="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_body'" RETURN

    # Note: curl already writes '000' to stdout when the connection fails, so
    # this must not append another one — '|| echo 000' would yield '000000'.
    http_code="$(curl --silent --show-error --location --max-time 60 \
        -o "$tmp_body" -w '%{http_code}' \
        -X POST \
        --data-urlencode "code=$code" \
        --data-urlencode "hostname=$hostname" \
        --data-urlencode "format=env" \
        "$server/api/product-sync/setup/exchange/" 2>/dev/null)" || true
    http_code="${http_code:-000}"

    case "$http_code" in
        200)
            printf 'connected\n'
            ;;
        403)
            printf 'rejected\n'
            setup_die "That setup code was not accepted." \
"The code may have expired, or already been used. Codes last 48 hours and
work once only.

Ask whoever manages the ClimWeb website to open the product, click
'Automated Publishing', and generate a new code."
            ;;
        409)
            printf 'not ready\n'
            setup_die "The product is not fully configured on the website yet." \
"$(sed -n 's/.*\"detail\": *\"\([^\"]*\)\".*/\1/p' "$tmp_body")

Ask the website administrator to finish setting up the product, then run
this command again with a new code."
            ;;
        404)
            printf 'unavailable\n'
            setup_die "This ClimWeb website does not support automated setup." \
"The version running at $server is older than this feature.

You can still set the sync up by hand — see:
  https://github.com/wmo-raf/climweb-product-sync/blob/main/docs/SETUP-rsync.md"
            ;;
        000)
            printf 'no connection\n'
            setup_die "Could not reach $server." \
"Check that this server has internet access, and that the address is right.
If your organisation uses a proxy, set https_proxy before running this."
            ;;
        *)
            printf 'error %s\n' "$http_code"
            setup_die "The website returned an unexpected response (HTTP $http_code)."
            ;;
    esac

    # The endpoint returns shell assignments precisely so this works without jq.
    # shellcheck disable=SC1090
    . "$tmp_body"

    : "${PRODUCT_NAME:=}" "${VARIABLE_NAME:=}" "${FORMAT:=}" "${FORMATS:=}"
    : "${TOKEN:=}" "${BASE_URL:=$server}" "${INGESTION_ENABLED:=true}"

    [ -n "$TOKEN" ] || setup_die "The website did not return a usable token."

    say
    say_ok "Found: ${C_BOLD}${PRODUCT_NAME}${C_OFF}"
    say_dim "      File format: ${FORMATS:-$FORMAT}"
    say_dim "      Destination: set automatically — you do not need to know it"

    if [ "$INGESTION_ENABLED" != "true" ]; then
        say
        say_warn "Automatic publishing is currently switched off for this product."
        say_dim "      Files will be copied, but will not appear on the website until"
        say_dim "      the administrator ticks 'Enable Auto-Ingestion'."
    fi

    # -- 2. which format, if there are several --------------------------------
    local chosen_format="$FORMAT"
    if [ "${FORMATS}" != "${FORMAT}" ] && [ -n "$FORMATS" ]; then
        local -a fmt_list
        IFS=',' read -r -a fmt_list <<< "$FORMATS"
        if [ "${#fmt_list[@]}" -gt 1 ]; then
            say
            say_bold "  This product is published in several formats."
            local idx=1 f
            for f in "${fmt_list[@]}"; do
                say "    $idx) $f"
                idx=$((idx + 1))
            done
            local pick
            ask pick "  Which are you sending from this server? [1] "
            pick="${pick:-1}"
            chosen_format="${fmt_list[$((pick - 1))]:-${fmt_list[0]}}"
            chosen_format="$(printf '%s' "$chosen_format" | tr -d '[:space:]')"
        fi
    fi

    # -- 3. the one real question ---------------------------------------------
    say
    rule
    say_bold "  Where are the ${chosen_format} files on this server?"
    say

    local suggestions
    suggestions="$(suggest_source_dirs "$chosen_format")"
    if [ -n "$suggestions" ]; then
        say_dim "  Folders on this server that contain .${chosen_format} files:"
        local n=1 s
        while IFS= read -r s; do
            say "    $n) $s"
            n=$((n + 1))
        done <<< "$suggestions"
        say_dim "  Type a number, or the full path to a different folder."
        say
    fi

    local src_path="" file_count=0
    while true; do
        ask src_path "  Folder: "
        src_path="${src_path%/}"

        # Allow picking a suggestion by number.
        if [ -n "$suggestions" ] && [[ "$src_path" =~ ^[0-9]+$ ]]; then
            src_path="$(sed -n "${src_path}p" <<< "$suggestions")"
            src_path="${src_path%/}"
        fi

        if [ -z "$src_path" ]; then
            say_bad "Please enter a folder path."
            continue
        fi
        case "$src_path" in
            /*) ;;
            *) say_bad "Please give the full path, starting with /"; continue ;;
        esac
        if [ ! -d "$src_path" ]; then
            say_bad "There is no folder at $src_path"
            continue
        fi

        file_count="$(find "$src_path" -type f -iname "*.${chosen_format}" 2>/dev/null | grep -c . || true)"
        if [ "$file_count" -eq 0 ]; then
            say_warn "No .${chosen_format} files found in $src_path"
            confirm "  Use it anyway?" && break
            continue
        fi

        say_ok "Found $file_count .${chosen_format} file(s)"
        find "$src_path" -type f -iname "*.${chosen_format}" 2>/dev/null \
            | head -3 | while IFS= read -r f; do say_dim "      $(basename "$f")"; done
        break
    done

    # -- 4. how often ---------------------------------------------------------
    say
    rule
    say_bold "  How often are new files produced?"
    say "    1) Several times a day    (check every hour)"
    say "    2) Once a day             (check every morning)"
    say "    3) Once a week            (check every hour, still safe)"
    say
    local freq cron_spec
    ask freq "  Choose [1]: "
    case "${freq:-1}" in
        2) cron_spec="30 6 * * *" ;;
        *) cron_spec="17 * * * *" ;;
    esac

    # -- 5. write everything --------------------------------------------------
    say
    rule
    say

    install -d -m 0750 /etc/climweb-sync
    printf '%s\n' "$TOKEN" > /etc/climweb-sync/token
    chmod 600 /etc/climweb-sync/token

    if [ -f /etc/climweb-sync/config.yaml ]; then
        cp /etc/climweb-sync/config.yaml \
           "/etc/climweb-sync/config.yaml.backup-$(date +%Y%m%d%H%M%S)"
        say_dim "  Existing configuration backed up."
    fi

    cat > /etc/climweb-sync/config.yaml <<EOF
# Written by 'climweb-sync setup' on $(date '+%Y-%m-%d %H:%M:%S%z').
# Product: $PRODUCT_NAME
#
# You can edit this file, then run 'climweb-sync --check' to confirm it is
# still valid. To add another product, copy the block under 'products:'.

climweb:
  transport: https
  base_url: $BASE_URL
  token_file: /etc/climweb-sync/token
  verify_tls: true
  watch_root: ${WATCH_ROOT:-/}

defaults:
  max_age_days: 30

products:
  - variable_name: $VARIABLE_NAME
    format: $chosen_format
    src_path: $src_path
EOF
    chmod 640 /etc/climweb-sync/config.yaml
    say_ok "Configuration saved"

    # -- 6. prove it works ----------------------------------------------------
    printf '  Sending a test file ... '
    if climweb_sync_selftest "$src_path" "$chosen_format"; then
        printf '%sOK%s\n' "$C_GREEN" "$C_OFF"
    else
        printf '%sfailed%s\n' "$C_RED" "$C_OFF"
        say
        say_dim "  The settings were saved, but the test upload did not succeed."
        say_dim "  Run this to see the details:"
        say_dim "      sudo climweb-sync --verbose"
        say
        return 1
    fi

    # -- 7. schedule ----------------------------------------------------------
    install -d -m 0750 /var/log/climweb-sync /var/lib/climweb-sync
    cat > /etc/cron.d/climweb-sync <<EOF
# climweb-sync — publishes $PRODUCT_NAME to the ClimWeb website.
# Written by 'climweb-sync setup'. Safe to edit.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=root

$cron_spec root /usr/local/bin/climweb-sync >> /var/log/climweb-sync/sync.log 2>&1
EOF
    chmod 0644 /etc/cron.d/climweb-sync
    say_ok "Scheduled"

    # -- done -----------------------------------------------------------------
    say
    rule
    say
    say_bold "  Done. $PRODUCT_NAME will publish automatically from now on."
    say
    say_dim "  New files placed in $src_path will appear on the website"
    say_dim "  within the hour. Nothing else needs to be done."
    say
    say_dim "  If you ever need it:"
    say_dim "    sudo climweb-sync            run now, without waiting"
    say_dim "    sudo climweb-sync --check    confirm everything still works"
    say_dim "    /var/log/climweb-sync/sync.log    what happened and when"
    say
    return 0
}

# Upload a single real file as proof the whole path works, rather than
# declaring success just because a config file was written.
climweb_sync_selftest() {
    local src="$1" fmt="$2" one rel

    one="$(find "$src" -type f -iname "*.${fmt}" 2>/dev/null | head -1)"
    [ -n "$one" ] || return 0   # nothing to send is not a failure

    rel="${one#"$src"/}"

    local code
    code="$(curl --silent --show-error --location --max-time 120 \
        -o /dev/null -w '%{http_code}' \
        -X POST \
        -H "Authorization: Bearer $TOKEN" \
        -F "variable_name=$VARIABLE_NAME" \
        -F "format=$fmt" \
        -F "relative_path=$rel" \
        -F "file=@$one" \
        "$BASE_URL/api/product-sync/upload/" 2>/dev/null)" || true
    code="${code:-000}"

    case "$code" in
        200|201|409) return 0 ;;
        *) return 1 ;;
    esac
}
