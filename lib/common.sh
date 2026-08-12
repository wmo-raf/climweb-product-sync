# shellcheck shell=bash
#
# common.sh — logging, config loading, validation and path helpers.
# Sourced by climweb-sync; not meant to be executed directly.

# -----------------------------------------------------------------------------
# Logging. Everything goes to stderr so that cron mails only real output, and
# so --check output on stdout stays clean and greppable.
# -----------------------------------------------------------------------------
_ts() { date '+%Y-%m-%d %H:%M:%S%z'; }

log_info()  { printf '%s [info]  %s\n'  "$(_ts)" "$*" >&2; }
log_warn()  { printf '%s [warn]  %s\n'  "$(_ts)" "$*" >&2; }
log_error() { printf '%s [error] %s\n'  "$(_ts)" "$*" >&2; }
log_debug() { [ "${VERBOSE:-0}" -eq 1 ] && printf '%s [debug] %s\n' "$(_ts)" "$*" >&2; return 0; }

die() {
    local code="$1"; shift
    log_error "$*"
    exit "$code"
}

# -----------------------------------------------------------------------------
# Locking: a slow first run must not overlap with the next cron tick.
# Uses flock when available, falls back to an atomic mkdir elsewhere.
# -----------------------------------------------------------------------------
_LOCK_DIR=""

acquire_lock() {
    local lockfile="${TMPDIR:-/tmp}/climweb-sync.lock"

    if command -v flock >/dev/null 2>&1; then
        exec 9>"$lockfile"
        if ! flock -n 9; then
            die 4 "another climweb-sync run is already in progress"
        fi
        return 0
    fi

    _LOCK_DIR="${lockfile}.d"
    if ! mkdir "$_LOCK_DIR" 2>/dev/null; then
        # Clear a stale lock left behind by a killed run.
        if [ -f "$_LOCK_DIR/pid" ] && ! kill -0 "$(cat "$_LOCK_DIR/pid")" 2>/dev/null; then
            log_warn "clearing stale lock from a previous run"
            rm -rf "$_LOCK_DIR"
            mkdir "$_LOCK_DIR" 2>/dev/null || die 4 "could not acquire lock"
        else
            die 4 "another climweb-sync run is already in progress"
        fi
    fi
    echo $$ > "$_LOCK_DIR/pid"
    # shellcheck disable=SC2064
    trap "rm -rf '$_LOCK_DIR'" EXIT
}

# -----------------------------------------------------------------------------
# Config loading
# -----------------------------------------------------------------------------
config_load() {
    local file="$1" parsed

    if [ ! -r "$file" ]; then
        die 2 "config file is not readable: $file"
    fi

    # A config can hold an SSH key path or API token path; warn if it is world
    # readable, since these servers are often shared between several teams.
    local mode
    mode="$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null || echo '')"
    case "$mode" in
        *[2367]) log_warn "$file is world-readable; consider: chmod 640 $file" ;;
    esac

    if ! parsed="$(awk -f "$LIB_DIR/parse_config.awk" "$file")"; then
        die 2 "could not parse $file"
    fi

    # The parser only ever emits NAME='value' with single quotes stripped from
    # values, so this eval cannot execute config content as code.
    eval "$parsed"
}

config_validate() {
    : "${CFG_CLIMWEB_TRANSPORT:=rsync}"
    : "${CFG_DEFAULTS_MAX_AGE_DAYS:=30}"
    : "${CFG_DEFAULTS_DELETE_REMOTE:=false}"
    : "${CFG_DEFAULTS_CHMOD:=F644}"
    : "${CFG_DEFAULTS_BWLIMIT:=0}"
    : "${CFG_CLIMWEB_PORT:=22}"
    : "${CFG_CLIMWEB_VERIFY_TLS:=true}"
    : "${CFG_PRODUCT_COUNT:=0}"

    [ "$CFG_PRODUCT_COUNT" -gt 0 ] || die 2 "no products defined in the config"

    case "$CFG_CLIMWEB_TRANSPORT" in
        rsync)
            require_cfg CFG_CLIMWEB_HOST       "climweb.host"
            require_cfg CFG_CLIMWEB_USER       "climweb.user"
            require_cfg CFG_CLIMWEB_SSH_KEY    "climweb.ssh_key"
            require_cfg CFG_CLIMWEB_WATCH_ROOT "climweb.watch_root"
            [ -r "$CFG_CLIMWEB_SSH_KEY" ] || die 2 "SSH key not readable: $CFG_CLIMWEB_SSH_KEY"
            case "$CFG_CLIMWEB_WATCH_ROOT" in
                /*) ;;
                *)  die 2 "climweb.watch_root must be an absolute path on the ClimWeb server (got '$CFG_CLIMWEB_WATCH_ROOT'). If the CMS shows a relative path, prefix it with the ClimWeb MEDIA_ROOT." ;;
            esac
            ;;
        https)
            require_cfg CFG_CLIMWEB_BASE_URL   "climweb.base_url"
            require_cfg CFG_CLIMWEB_TOKEN_FILE "climweb.token_file"
            [ -r "$CFG_CLIMWEB_TOKEN_FILE" ] || die 2 "token file not readable: $CFG_CLIMWEB_TOKEN_FILE"
            case "$CFG_CLIMWEB_BASE_URL" in
                https://*) ;;
                http://*)  log_warn "base_url uses plain http; the upload token will cross the network in the clear" ;;
                *) die 2 "climweb.base_url must start with https://" ;;
            esac
            CFG_CLIMWEB_BASE_URL="${CFG_CLIMWEB_BASE_URL%/}"
            ;;
        *)
            die 2 "unknown transport '$CFG_CLIMWEB_TRANSPORT' (expected rsync or https)"
            ;;
    esac

    # Validate every product up front, so a typo in the last entry is reported
    # before the first byte is sent rather than ten minutes later.
    local i var fmt src
    for i in $(seq 1 "$CFG_PRODUCT_COUNT"); do
        eval "var=\${CFG_PRODUCT_${i}_VARIABLE_NAME:-}"
        eval "fmt=\${CFG_PRODUCT_${i}_FORMAT:-}"
        eval "src=\${CFG_PRODUCT_${i}_SRC_PATH:-}"
        [ -n "$var" ] || die 2 "product #$i is missing 'variable_name'"
        [ -n "$fmt" ] || die 2 "product '$var' is missing 'format'"
        [ -n "$src" ] || die 2 "product '$var' is missing 'src_path'"
        case "$var" in
            *[!a-zA-Z0-9_-]*) die 2 "product variable_name '$var' contains characters ClimWeb will not accept; it must match the CMS 'Variable Name' slug (letters, digits, - and _)" ;;
        esac
        case "$fmt" in
            *[!a-zA-Z0-9]*) die 2 "product '$var' has an invalid format '$fmt'; use a bare extension such as pdf or png" ;;
        esac
        case "$src" in
            /*) ;;
            *)  die 2 "product '$var' src_path must be an absolute path (got '$src')" ;;
        esac
    done
}

require_cfg() {
    local name="$1" label="$2" value
    eval "value=\${$name:-}"
    [ -n "$value" ] || die 2 "missing required setting '$label' in the config"
}

# -----------------------------------------------------------------------------
# Per-product accessors. Returns 1 when the product is disabled.
# -----------------------------------------------------------------------------
product_load() {
    local i="$1" enabled
    eval "P_VARIABLE_NAME=\${CFG_PRODUCT_${i}_VARIABLE_NAME:-}"
    eval "P_FORMAT=\${CFG_PRODUCT_${i}_FORMAT:-}"
    eval "P_SRC_PATH=\${CFG_PRODUCT_${i}_SRC_PATH:-}"
    eval "P_MAX_AGE_DAYS=\${CFG_PRODUCT_${i}_MAX_AGE_DAYS:-$CFG_DEFAULTS_MAX_AGE_DAYS}"
    eval "P_DELETE_REMOTE=\${CFG_PRODUCT_${i}_DELETE_REMOTE:-$CFG_DEFAULTS_DELETE_REMOTE}"
    eval "enabled=\${CFG_PRODUCT_${i}_ENABLED:-true}"

    P_FORMAT="$(printf '%s' "$P_FORMAT" | tr '[:upper:]' '[:lower:]')"
    P_SRC_PATH="${P_SRC_PATH%/}"

    case "$enabled" in
        false|no|0) log_debug "$P_VARIABLE_NAME is disabled, skipping"; return 1 ;;
    esac
    return 0
}

is_true() {
    case "$1" in true|yes|1) return 0 ;; *) return 1 ;; esac
}

# -----------------------------------------------------------------------------
# The one path rule that matters.
#
# climweb/pages/products/tasks.py::_ingest_product walks
#     <watch_root>/<variable_name>/<format>/
# and matches each file's path, relative to that directory, against the item
# type's filename convention. Deriving the destination here rather than letting
# the operator type it is what keeps the two sides from drifting apart.
# -----------------------------------------------------------------------------
dest_path_for() {
    local variable_name="$1" format="$2"
    printf '%s/%s/%s' "${CFG_CLIMWEB_WATCH_ROOT%/}" "$variable_name" "$format"
}

# -----------------------------------------------------------------------------
# Build the list of files to send, as paths relative to src_path.
#
# Doing the selection with find (rather than rsync --include rules) gives one
# code path that handles both the extension filter and the age filter, and it
# preserves subdirectories such as the {yyyy}/ folders ClimWeb conventions use.
# -----------------------------------------------------------------------------
list_source_files() {
    local src="$1" fmt="$2" max_age="$3"
    local -a find_args=("$src" -type f -iname "*.${fmt}")

    if [ -n "$max_age" ] && [ "$max_age" != "0" ]; then
        find_args+=(-mtime "-${max_age}")
    fi

    # Skip partially written files: a bulletin still being generated must not be
    # copied half-formed, or ClimWeb will ingest a truncated PDF.
    find_args+=(! -name '.*' ! -name '*.tmp' ! -name '*.part')

    local f
    while IFS= read -r -d '' f; do
        printf '%s\n' "${f#"$src"/}"
    done < <(find "${find_args[@]}" -print0 2>/dev/null | sort -z)
}

count_source_files() {
    list_source_files "$1" "$2" "$3" | grep -c . || true
}
