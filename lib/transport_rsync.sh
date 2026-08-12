# shellcheck shell=bash
#
# transport_rsync.sh — push files to the ClimWeb server over SSH.
#
# This is the recommended transport: rsync only sends what changed, resumes
# cleanly after a dropped link, and needs nothing installed on the ClimWeb side
# beyond rsync itself.

_ssh_cmd() {
    printf 'ssh -i %s -p %s -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ServerAliveInterval=30' \
        "$CFG_CLIMWEB_SSH_KEY" "$CFG_CLIMWEB_PORT"
}

rsync_check() {
    command -v rsync >/dev/null 2>&1 || die 2 "rsync is not installed on this server (try: sudo apt install rsync)"
    command -v ssh   >/dev/null 2>&1 || die 2 "ssh is not installed on this server"

    local mode
    mode="$(stat -c '%a' "$CFG_CLIMWEB_SSH_KEY" 2>/dev/null || echo '')"
    case "$mode" in
        600|400) ;;
        '') ;;
        *) die 2 "SSH key $CFG_CLIMWEB_SSH_KEY has permissions $mode; ssh will refuse it. Run: chmod 600 $CFG_CLIMWEB_SSH_KEY" ;;
    esac

    log_debug "testing SSH connection to $CFG_CLIMWEB_USER@$CFG_CLIMWEB_HOST"
    local ssh_err
    if ! ssh_err="$(eval "$(_ssh_cmd)" "$CFG_CLIMWEB_USER@$CFG_CLIMWEB_HOST" true 2>&1)"; then
        log_error "cannot reach the ClimWeb server over SSH:"
        log_error "  $ssh_err"
        log_error "See docs/TROUBLESHOOTING.md — the usual causes are a key that"
        log_error "was never added to the ClimWeb server, or a firewall on port $CFG_CLIMWEB_PORT."
        exit 3
    fi

    # Fail early and clearly if the watch root is missing entirely, which nearly
    # always means watch_root points somewhere ClimWeb is not actually reading.
    if ! eval "$(_ssh_cmd)" "$CFG_CLIMWEB_USER@$CFG_CLIMWEB_HOST" \
            "test -d $(printf '%q' "$CFG_CLIMWEB_WATCH_ROOT")" 2>/dev/null; then
        log_warn "watch root $CFG_CLIMWEB_WATCH_ROOT does not exist on the ClimWeb server yet."
        log_warn "It will be created, but double-check it matches the 'Watch Root Path'"
        log_warn "on the Product snippet in the CMS admin, otherwise nothing will be ingested."
    fi
}

# rsync_send VARIABLE_NAME FORMAT SRC DEST MAX_AGE_DAYS DELETE_REMOTE
rsync_send() {
    local variable_name="$1" fmt="$2" src="$3" dest="$4" max_age="$5" delete_remote="$6"
    local list rc=0

    list="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$list'" RETURN

    list_source_files "$src" "$fmt" "$max_age" > "$list"

    local n
    n="$(grep -c . < "$list" || true)"
    if [ "$n" -eq 0 ]; then
        log_info "  nothing to send (no .$fmt files modified in the last ${max_age:-0} day(s))"
        return 0
    fi
    log_debug "  $n candidate file(s)"

    local -a opts=(
        --files-from="$list"
        --times --links --safe-links
        --chmod="$CFG_DEFAULTS_CHMOD"
        --partial --partial-dir=.climweb-sync-partial
        --human-readable
        --stats
    )

    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        # A rehearsal must leave no trace, so skip the mkdir below: --rsync-path
        # runs on the remote even under --dry-run and would create directories.
        opts+=(--dry-run)
    else
        # Create the destination tree on the first run, so nobody has to log in
        # to the ClimWeb server and mkdir it by hand.
        opts+=(--rsync-path="mkdir -p $(printf '%q' "$dest") && rsync")
    fi

    [ "${CFG_DEFAULTS_BWLIMIT:-0}" != "0" ] && opts+=(--bwlimit="$CFG_DEFAULTS_BWLIMIT")
    is_true "$delete_remote" && opts+=(--delete)
    [ "${VERBOSE:-0}" -eq 1 ] && opts+=(--verbose --itemize-changes)

    opts+=(-e "$(_ssh_cmd)")

    if ! rsync "${opts[@]}" "$src/" "$CFG_CLIMWEB_USER@$CFG_CLIMWEB_HOST:$dest/" >&2; then
        rc=$?
        case $rc in
            24) log_warn "  a source file vanished mid-copy (code 24); it will be picked up on the next run." ; rc=0 ;;
            23) log_error "  some files could not be transferred (code 23) — usually permission denied writing to $dest on the ClimWeb server" ;;
            12) log_error "  rsync protocol error (code 12) — is rsync installed on the ClimWeb server?" ;;
        esac
    fi

    return $rc
}
