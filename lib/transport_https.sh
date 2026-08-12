# shellcheck shell=bash
#
# transport_https.sh — upload files to the ClimWeb product ingest API.
#
# Use this only when the source server cannot open an outbound SSH connection.
# It uploads each file individually with curl, so it is slower than rsync and
# has no resume; a local state file is what stops it re-uploading everything on
# every run.
#
# The server side of this is specified in docs/SERVER-API.md. Check that your
# ClimWeb version exposes the endpoint before choosing this transport.

_https_token() {
    tr -d '\r\n' < "$CFG_CLIMWEB_TOKEN_FILE"
}

_https_endpoint() {
    printf '%s/api/product-sync/upload/' "$CFG_CLIMWEB_BASE_URL"
}

_curl_base() {
    local -a args=(--silent --show-error --location --max-time 300 --retry 2 --retry-delay 5)
    is_true "$CFG_CLIMWEB_VERIFY_TLS" || args+=(--insecure)
    printf '%s\n' "${args[@]}"
}

https_check() {
    command -v curl >/dev/null 2>&1 || die 2 "curl is not installed on this server (try: sudo apt install curl)"

    local token
    token="$(_https_token)"
    [ -n "$token" ] || die 2 "token file $CFG_CLIMWEB_TOKEN_FILE is empty"

    is_true "$CFG_CLIMWEB_VERIFY_TLS" || log_warn "verify_tls is false — TLS certificates are not being checked"

    local -a curl_args
    mapfile -t curl_args < <(_curl_base)

    # curl itself prints '000' on a failed connection, so appending another with
    # '|| echo 000' would produce '000000' and fall through to the wrong branch.
    local code
    code="$(curl "${curl_args[@]}" -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer $token" \
        "$CFG_CLIMWEB_BASE_URL/api/product-sync/ping/" 2>/dev/null)" || true
    code="${code:-000}"

    case "$code" in
        200) log_debug "API reachable and token accepted" ;;
        401|403) die 3 "the ClimWeb server rejected the token in $CFG_CLIMWEB_TOKEN_FILE (HTTP $code)" ;;
        404) die 3 "the ClimWeb server has no product-sync API at $CFG_CLIMWEB_BASE_URL (HTTP 404). This ClimWeb version may not support the https transport — use transport: rsync instead." ;;
        000) die 3 "could not reach $CFG_CLIMWEB_BASE_URL at all — check DNS, the firewall, and any outbound proxy" ;;
        *)   die 3 "unexpected response from the ClimWeb server (HTTP $code)" ;;
    esac
}

# A file is considered already uploaded when its size and mtime are unchanged.
_state_file() {
    printf '%s/%s.%s.state' "$STATE_DIR" "$1" "$2"
}

_file_fingerprint() {
    local f="$1" size mtime
    size="$(stat -c '%s' "$f" 2>/dev/null || stat -f '%z' "$f")"
    mtime="$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f")"
    printf '%s:%s' "$size" "$mtime"
}

# https_send VARIABLE_NAME FORMAT SRC DEST MAX_AGE_DAYS DELETE_REMOTE
https_send() {
    local variable_name="$1" fmt="$2" src="$3" dest="$4" max_age="$5" delete_remote="$6"
    local state token endpoint rel abs fp sent=0 unchanged=0 failed=0

    state="$(_state_file "$variable_name" "$fmt")"
    touch "$state" 2>/dev/null || true
    token="$(_https_token)"
    endpoint="$(_https_endpoint)"

    local -a curl_args
    mapfile -t curl_args < <(_curl_base)

    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        abs="$src/$rel"
        fp="$(_file_fingerprint "$abs")"

        if grep -Fqx "$fp $rel" "$state" 2>/dev/null; then
            unchanged=$((unchanged + 1))
            continue
        fi

        if [ "${DRY_RUN:-0}" -eq 1 ]; then
            log_info "  would upload $rel"
            sent=$((sent + 1))
            continue
        fi

        local code
        code="$(curl "${curl_args[@]}" -o /dev/null -w '%{http_code}' \
            -X POST \
            -H "Authorization: Bearer $token" \
            -F "variable_name=$variable_name" \
            -F "format=$fmt" \
            -F "relative_path=$rel" \
            -F "file=@$abs" \
            "$endpoint" 2>/dev/null)" || true
        code="${code:-000}"

        case "$code" in
            200|201)
                log_debug "  uploaded $rel"
                # Record only after the server confirms, so an interrupted run
                # retries the file rather than silently skipping it forever.
                printf '%s %s\n' "$fp" "$rel" >> "$state"
                sent=$((sent + 1))
                ;;
            409)
                log_debug "  $rel already present on the server"
                printf '%s %s\n' "$fp" "$rel" >> "$state"
                unchanged=$((unchanged + 1))
                ;;
            413)
                log_error "  $rel rejected as too large by the ClimWeb server (HTTP 413)"
                failed=$((failed + 1))
                ;;
            *)
                log_error "  upload failed for $rel (HTTP $code)"
                failed=$((failed + 1))
                ;;
        esac
    done < <(list_source_files "$src" "$fmt" "$max_age")

    # Drop state entries for files that no longer exist on the source server,
    # otherwise this file grows without bound over the years.
    if [ "${DRY_RUN:-0}" -eq 0 ] && [ -s "$state" ]; then
        local pruned
        pruned="$(mktemp)"
        while IFS= read -r line; do
            [ -f "$src/${line#* }" ] && printf '%s\n' "$line"
        done < "$state" | sort -u > "$pruned"
        mv "$pruned" "$state"
    fi

    log_info "  $sent uploaded, $unchanged unchanged, $failed failed"
    [ "$failed" -eq 0 ]
}
