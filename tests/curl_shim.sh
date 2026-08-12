#!/usr/bin/env bash
#
# A stand-in for curl, used by the setup wizard tests.
#
# The wizard talks to ClimWeb over HTTP, and spinning up a real server makes the
# tests depend on loopback networking being available — which it is not in every
# build sandbox. Intercepting curl instead keeps the tests hermetic while still
# exercising the wizard's real argument construction, response parsing, prompt
# flow and file writing.
#
# Behaviour is driven by these variables, exported by the test:
#   SHIM_DIR        scratch directory for state
#   SHIM_WATCH      where "uploaded" files are written
#   SHIM_VALID_CODE the setup code that is accepted
#   SHIM_FORMATS    comma-separated formats the product publishes
#   SHIM_DOWN=1     simulate a server that cannot be reached

set -uo pipefail

# Defaults so these are assigned in-file, not only inherited from the caller.
SHIM_DIR="${SHIM_DIR:-/tmp}"
SHIM_WATCH="${SHIM_WATCH:-/tmp/shim-watch}"
SHIM_VALID_CODE="${SHIM_VALID_CODE:-}"
SHIM_FORMATS="${SHIM_FORMATS:-pdf}"
SHIM_DOWN="${SHIM_DOWN:-0}"

out_file=""
url=""
write_out=""
auth=""
declare -A data=()
declare -A form=()
file_path=""

while [ $# -gt 0 ]; do
    case "$1" in
        -o) out_file="$2"; shift 2 ;;
        -w) write_out="$2"; shift 2 ;;
        -H) case "$2" in Authorization:*) auth="${2#Authorization: }" ;; esac; shift 2 ;;
        -X) shift 2 ;;
        --data-urlencode)
            data["${2%%=*}"]="${2#*=}"; shift 2 ;;
        -F)
            key="${2%%=*}"; value="${2#*=}"
            if [ "$key" = "file" ]; then
                file_path="${value#@}"
            else
                form["$key"]="$value"
            fi
            shift 2 ;;
        --max-time|--retry|--retry-delay) shift 2 ;;
        --silent|--show-error|--location|--insecure) shift ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done

emit() { # emit HTTP_CODE [BODY]
    if [ -n "$out_file" ] && [ "$out_file" != "/dev/null" ]; then
        printf '%s' "${2:-}" > "$out_file"
    fi
    [ -n "$write_out" ] && printf '%s' "$1"
    return 0
}

# --- unreachable server ------------------------------------------------------
if [ "$SHIM_DOWN" = "1" ] || [[ "$url" == *"127.0.0.1:1/"* ]]; then
    # Real curl prints 000 on stdout and exits non-zero. The wizard must cope
    # with exactly this, so reproduce both halves.
    [ -n "$write_out" ] && printf '000'
    exit 7
fi

state="$SHIM_DIR/used_codes"
token="shim-token-0123456789"

# --- POST /api/product-sync/setup/exchange/ ----------------------------------
if [[ "$url" == *"/setup/exchange/"* ]]; then
    raw="${data[code]:-}"
    # Same normalisation the server does: uppercase, drop anything outside the
    # unambiguous alphabet, require exactly 12 characters.
    cleaned="$(printf '%s' "$raw" | tr '[:lower:]' '[:upper:]' | tr -cd 'ACDEFGHJKMNPQRTUVWXYZ2346789')"
    normalised=""
    if [ "${#cleaned}" -eq 12 ]; then
        normalised="${cleaned:0:4}-${cleaned:4:4}-${cleaned:8:4}"
    fi

    if [ -z "$normalised" ] || [ "$normalised" != "$SHIM_VALID_CODE" ] \
       || grep -Fqx "$normalised" "$state" 2>/dev/null; then
        emit 403 '{"error": "invalid_code", "detail": "not valid"}'
        exit 0
    fi

    printf '%s\n' "$normalised" >> "$state"
    emit 200 "PRODUCT_NAME='Weekly Rainfall'
VARIABLE_NAME='weekly_rainfall'
FORMATS='${SHIM_FORMATS}'
FORMAT='${SHIM_FORMATS%%,*}'
INGESTION_ENABLED='true'
WATCH_ROOT='${SHIM_WATCH}'
BASE_URL='https://cms.test'
TOKEN='${token}'
CREDENTIAL_ID='1'
"
    exit 0
fi

# --- GET /api/product-sync/ping/ ---------------------------------------------
if [[ "$url" == *"/ping/"* ]]; then
    if [ "$auth" != "Bearer $token" ]; then
        emit 401 '{"error": "invalid_token"}'
        exit 0
    fi
    emit 200 '{"status": "ok"}'
    exit 0
fi

# --- POST /api/product-sync/upload/ ------------------------------------------
if [[ "$url" == *"/upload/"* ]]; then
    if [ "$auth" != "Bearer $token" ]; then
        emit 401 '{"error": "invalid_token"}'
        exit 0
    fi

    variable_name="${form[variable_name]:-}"
    fmt="${form[format]:-}"
    rel="${form[relative_path]:-}"

    [ "$variable_name" = "weekly_rainfall" ] || { emit 400 '{"error":"wrong_product"}'; exit 0; }
    case ",$SHIM_FORMATS," in
        *",$fmt,"*) ;;
        *) emit 400 '{"error":"bad_format"}'; exit 0 ;;
    esac

    # Mirror the server's containment rule, so the test would catch a client
    # that started sending traversal paths.
    case "$rel" in
        /*|*..*|.*) emit 400 '{"error":"bad_path"}'; exit 0 ;;
    esac

    dest="$SHIM_WATCH/$variable_name/$fmt/$rel"
    mkdir -p "$(dirname "$dest")"
    cp "$file_path" "$dest" 2>/dev/null || { emit 500 '{"error":"write_failed"}'; exit 0; }
    emit 201 '{"status":"stored"}'
    exit 0
fi

emit 404 '{"error": "not_found"}'
exit 0
