#!/usr/bin/env bash
#
# check-portability.sh — refuse constructs that break on older or non-GNU systems.
#
# This tool runs on whatever a national met service happens to have: an old
# CentOS box, a BSD userland, or a Mac someone is testing from. Two families of
# problem are easy to introduce and only show up on the target machine:
#
#   * bash 4 builtins — macOS still ships bash 3.2, so mapfile, readarray,
#     associative arrays and ${var,,} are all unavailable
#   * GNU-only tool flags — sort -z, readlink -f, stat -c, sed -i, date -d,
#     find -printf all differ or are missing on BSD
#
# CI runs on Ubuntu, so neither family is caught by simply running the tests.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1

fail=0

report() { # report DESCRIPTION FILE:LINE MATCH
    printf '  \033[31mFAIL\033[0m %s\n         %s\n         %s\n' "$1" "$2" "$3"
    fail=$((fail + 1))
}

# scan PATTERN DESCRIPTION [ALLOW_PATTERN]
# ALLOW_PATTERN marks lines that pair the construct with a portable fallback.
scan() {
    local pattern="$1" description="$2" allow="${3:-}"
    local hit file line text

    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        file="${hit%%:*}"
        line="$(printf '%s' "$hit" | cut -d: -f2)"
        text="$(printf '%s' "$hit" | cut -d: -f3-)"

        # Comments explaining why something is avoided are not violations.
        case "$(printf '%s' "$text" | sed 's/^[[:space:]]*//')" in
            '#'*) continue ;;
        esac
        if [ -n "$allow" ] && printf '%s' "$text" | grep -Eq "$allow"; then
            continue
        fi
        report "$description" "$file:$line" "$(printf '%s' "$text" | sed 's/^[[:space:]]*//')"
    done < <(grep -rnE "$pattern" \
                --include='*.sh' --include='climweb-sync' --include='install.sh' \
                . 2>/dev/null | grep -v '^./tests/check-portability.sh:')
}

echo
echo "portability"
echo "-----------"

# --- bash 4 only -------------------------------------------------------------
scan '\bmapfile\b|\breadarray\b' \
    "mapfile/readarray are bash 4; macOS ships bash 3.2"
scan 'declare -A|local -A' \
    "associative arrays are bash 4; macOS ships bash 3.2"
scan '\$\{[A-Za-z_][A-Za-z0-9_]*,,\}|\$\{[A-Za-z_][A-Za-z0-9_]*\^\^\}' \
    'case conversion is bash 4; use tr instead'

# --- GNU-only flags ----------------------------------------------------------
scan '\bsort -z|\bsort --zero-terminated' \
    "sort -z is GNU-only; sort the newline-delimited output instead"
scan '\breadlink -f\b' \
    "readlink -f is GNU-only; follow symlinks in a loop instead"
scan '\bsed -i\b' \
    "sed -i differs on BSD (needs an argument); write to a temp file instead"
scan '\bdate -d\b' \
    "date -d is GNU-only"
scan 'find [^|]*-printf' \
    "find -printf is GNU-only; use -print0 and strip the prefix"
scan '\bgrep -P\b' \
    "grep -P is GNU-only; use -E"
# stat differs between GNU and BSD, so every use needs both spellings.
scan '\bstat -c\b' \
    "stat -c is GNU-only; pair it with a 'stat -f' fallback" \
    "stat -f"

if [ "$fail" -eq 0 ]; then
    printf '  \033[32mok\033[0m   no bash-4 or GNU-only constructs in portable code\n\n'
    exit 0
fi

printf '\n%d portability problem(s)\n\n' "$fail"
exit 1
