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

# Ask where the files for one format live.
#
# Sets PROMPT_PATH to the folder, or to "" when the operator chooses to skip.
#   _prompt_source_folder FORMAT PREVIOUS_PATH required|skippable
PROMPT_PATH=""
_prompt_source_folder() {
    local fmt="$1" previous="$2" mode="$3"
    local suggestions src_path file_count n s count

    PROMPT_PATH=""

    say
    rule
    say_bold "  Where are the ${fmt} files on this server?"
    say

    # Products published in several formats are usually written to one folder,
    # so offer the previous answer instead of making someone type it twice.
    if [ -n "$previous" ]; then
        count="$(list_source_files "$previous" "$fmt" "" | grep -c . || true)"
        if [ "$count" -gt 0 ]; then
            say_dim "  The folder you gave for the previous format also holds"
            say_dim "  $count .${fmt} file(s):"
            say "      $previous"
            say
            if confirm "  Use that folder for ${fmt} as well?"; then
                say_ok "Found $count .${fmt} file(s)"
                PROMPT_PATH="$previous"
                return 0
            fi
            say
        fi
    fi

    suggestions="$(suggest_source_dirs "$fmt")"
    if [ -n "$suggestions" ]; then
        say_dim "  Folders on this server that contain .${fmt} files:"
        n=1
        while IFS= read -r s; do
            say "    $n) $s"
            n=$((n + 1))
        done <<< "$suggestions"
        say_dim "  Type a number, or the full path to a different folder."
        say
    fi

    if [ "$mode" = "skippable" ]; then
        say_dim "  Leave blank if ${fmt} files are not produced on this server."
        say
    fi

    while true; do
        ask src_path "  Folder: "
        src_path="${src_path%/}"

        # Allow picking a suggestion by number.
        if [ -n "$suggestions" ] && [[ "$src_path" =~ ^[0-9]+$ ]]; then
            src_path="$(sed -n "${src_path}p" <<< "$suggestions")"
            src_path="${src_path%/}"
        fi

        if [ -z "$src_path" ]; then
            if [ "$mode" = "skippable" ]; then
                PROMPT_PATH=""
                return 0
            fi
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

        # Count what would actually be sent, not every matching filename: a
        # count that includes half-written or hidden files would promise more
        # than the sync delivers.
        file_count="$(list_source_files "$src_path" "$fmt" "" | grep -c . || true)"
        if [ "$file_count" -eq 0 ]; then
            say_warn "No .${fmt} files found in $src_path"
            if confirm "  Use it anyway?"; then
                PROMPT_PATH="$src_path"
                return 0
            fi
            continue
        fi

        say_ok "Found $file_count .${fmt} file(s)"
        list_source_files "$src_path" "$fmt" "" \
            | head -3 | while IFS= read -r f; do say_dim "      $(basename "$f")"; done
        PROMPT_PATH="$src_path"
        return 0
    done
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

    # -- 2. work through every format the product publishes -------------------
    #
    # A product configured with both pdf and png needs both synced, or half of
    # it silently never appears on the website. So every format gets asked
    # about; the operator can skip any that are not produced on this server.
    local -a fmt_list=()
    local raw_fmt
    IFS=',' read -r -a fmt_list <<< "${FORMATS:-$FORMAT}"
    for i in "${!fmt_list[@]}"; do
        raw_fmt="$(printf '%s' "${fmt_list[$i]}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
        fmt_list[$i]="$raw_fmt"
    done

    local -a chosen_formats=() chosen_paths=()
    local fmt last_path=""

    if [ "${#fmt_list[@]}" -gt 1 ]; then
        say
        say_bold "  This product is published in ${#fmt_list[@]} formats: ${FORMATS//,/, }"
        say_dim "      Each one is set up in turn. You can skip any that are not"
        say_dim "      produced on this server."
    fi

    for fmt in "${fmt_list[@]}"; do
        [ -n "$fmt" ] || continue

        # Only offer skipping when there is more than one format — skipping the
        # only format would leave nothing to do.
        if [ "${#fmt_list[@]}" -gt 1 ]; then
            _prompt_source_folder "$fmt" "$last_path" skippable
        else
            _prompt_source_folder "$fmt" "$last_path" required
        fi

        if [ -n "$PROMPT_PATH" ]; then
            chosen_formats+=("$fmt")
            chosen_paths+=("$PROMPT_PATH")
            last_path="$PROMPT_PATH"
        else
            say_dim "      Skipping ${fmt} — it will not be published from this server."
        fi
    done

    if [ "${#chosen_formats[@]}" -eq 0 ]; then
        setup_die "Nothing was set up, because every format was skipped." \
"Run the command again once you know which folders hold the files."
    fi

    # The operator is deliberately not asked how often to check.
    #
    # A run with nothing to send takes about a tenth of a second — it is one
    # directory walk and one small request — so there is nothing to save by
    # checking less often, and two things to lose: new bulletins wait longer to
    # appear, and a "Sync all files" request from the website waits up to a full
    # interval before anything happens. On a daily schedule that was most of a
    # day, which made the button feel broken.
    local cron_spec="*/10 * * * *"

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
# still valid. To add another product, copy the last block under 'products:'.

climweb:
  transport: https
  base_url: $BASE_URL
  token_file: /etc/climweb-sync/token
  verify_tls: true
  watch_root: ${WATCH_ROOT:-/}

defaults:
  max_age_days: 30

products:
EOF

    local idx
    for idx in "${!chosen_formats[@]}"; do
        cat >> /etc/climweb-sync/config.yaml <<EOF
  - variable_name: $VARIABLE_NAME
    format: ${chosen_formats[$idx]}
    src_path: ${chosen_paths[$idx]}
EOF
    done

    chmod 640 /etc/climweb-sync/config.yaml
    say_ok "Configuration saved (${#chosen_formats[@]} format(s))"

    # -- 6. prove it works ----------------------------------------------------
    # Every format is tested, not just the first: a permissions or naming
    # problem can easily affect one folder and not another.
    local test_failures=0
    for idx in "${!chosen_formats[@]}"; do
        printf '  Sending a test %s file ... ' "${chosen_formats[$idx]}"
        if climweb_sync_selftest "${chosen_paths[$idx]}" "${chosen_formats[$idx]}"; then
            printf '%sOK%s\n' "$C_GREEN" "$C_OFF"
        else
            printf '%sfailed%s\n' "$C_RED" "$C_OFF"
            [ -n "$SELFTEST_DETAIL" ] && say_dim "      $SELFTEST_DETAIL"
            test_failures=$((test_failures + 1))
        fi
    done

    if [ "$test_failures" -gt 0 ]; then
        say
        say_dim "  The settings were saved, so nothing is lost. Once the problem"
        say_dim "  above is resolved, run this to retry:"
        say_dim "      sudo climweb-sync --verbose"
        say
        return 1
    fi

    # -- 7. schedule ----------------------------------------------------------
    install -d -m 0750 /var/log/climweb-sync /var/lib/climweb-sync

    if is_macos; then
        # macOS cron ignores /etc/cron.d entirely, so writing the job here and
        # announcing "Scheduled" would leave someone believing their bulletins
        # publish automatically when nothing ever runs.
        say_warn "Automatic scheduling was skipped."
        say_dim  "      This is macOS, which does not read /etc/cron.d. The sync is"
        say_dim  "      supported for day-to-day use on Linux servers."
        say_dim  "      You can still publish at any time with: sudo climweb-sync"
    else
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
    fi

    # -- done -----------------------------------------------------------------
    say
    rule
    say
    say_bold "  Done. $PRODUCT_NAME will publish automatically from now on."
    say
    say_dim "  New files placed in these folders appear on the website within"
    say_dim "  the hour. Nothing else needs to be done."
    say
    for idx in "${!chosen_formats[@]}"; do
        say_dim "      ${chosen_formats[$idx]}  ${chosen_paths[$idx]}"
    done

    # Naming a skipped format here is worth the extra line: it is the one thing
    # that will otherwise be noticed months later, as a product that only ever
    # publishes half its files.
    local f listed
    for f in "${fmt_list[@]}"; do
        listed=0
        for idx in "${!chosen_formats[@]}"; do
            [ "${chosen_formats[$idx]}" = "$f" ] && listed=1
        done
        if [ "$listed" -eq 0 ] && [ -n "$f" ]; then
            say
            say_warn "${f} was skipped, so those files will not be published"
            say_dim "      from this server. Run setup again with a new code if"
            say_dim "      that was not intended."
        fi
    done
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
#
# On failure, SELFTEST_DETAIL explains why. Reporting only "failed" leaves the
# operator with nothing to act on, which defeats the point of testing at all.
SELFTEST_DETAIL=""
climweb_sync_selftest() {
    local src="$1" fmt="$2" one rel code body err detail

    SELFTEST_DETAIL=""

    # Use the same selection the real sync uses, rather than a bare find. That
    # keeps the test representative — it applies the tmp/part/dotfile filtering
    # — and it is sorted, so the file chosen is the same on every machine.
    rel="$(list_source_files "$src" "$fmt" "" | head -1)"
    [ -n "$rel" ] || return 0   # nothing to send is not a failure

    one="$src/$rel"
    body="$(mktemp)"
    err="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$body' '$err'" RETURN

    code="$(curl --silent --show-error --location --max-time 120 \
        -o "$body" -w '%{http_code}' \
        -X POST \
        -H "Authorization: Bearer $TOKEN" \
        -F "variable_name=$VARIABLE_NAME" \
        -F "format=$fmt" \
        -F "relative_path=$rel" \
        -F "file=@$one" \
        "$BASE_URL/api/product-sync/upload/" 2>"$err")" || true
    code="${code:-000}"

    case "$code" in
        200|201|409) return 0 ;;
    esac

    # The API returns {"error": ..., "detail": "..."}; the detail is written for
    # a human, so prefer it over anything we could invent here.
    detail="$(sed -n 's/.*"detail": *"\([^"]*\)".*/\1/p' "$body" 2>/dev/null | head -1)"

    case "$code" in
        000)
            SELFTEST_DETAIL="Could not reach $BASE_URL to upload the file.
      $(head -2 "$err" 2>/dev/null)
      The setup code worked, so this is usually a proxy or TLS problem
      on the upload request specifically."
            ;;
        401|403)
            SELFTEST_DETAIL="The server rejected the token (HTTP $code).
      Ask for a new setup code and run this again."
            ;;
        404)
            SELFTEST_DETAIL="No upload endpoint at $BASE_URL (HTTP 404).
      This ClimWeb version may be older than the one that issued the code."
            ;;
        413)
            SELFTEST_DETAIL="The file is larger than the website accepts (HTTP 413).
      Ask the website administrator to raise the upload limit."
            ;;
        5*)
            SELFTEST_DETAIL="The website hit an internal error (HTTP $code).
      ${detail:-Ask the administrator to check the ClimWeb logs.}"
            ;;
        *)
            SELFTEST_DETAIL="The website refused the file (HTTP $code).
      ${detail:-No explanation was returned.}
      File sent: $rel"
            ;;
    esac
    return 1
}
