#!/usr/bin/env bash
#
# run-tests.sh — self-contained tests. No network, no ClimWeb server needed.
#
# The rsync transport is exercised for real by putting a fake `ssh` on PATH that
# runs the remote command locally. That means the tests cover the actual rsync
# invocation, including the --files-from list and the --rsync-path mkdir that
# creates the destination tree on a first run.
#
#   ./tests/run-tests.sh

# shellcheck source-path=SCRIPTDIR/..

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; fail=$((fail+1)); }

check() { # check DESCRIPTION EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected [$2], got [$3]"; fi
}

# -----------------------------------------------------------------------------
echo
echo "config parser"
echo "-------------"

parse() { awk -f "$REPO/lib/parse_config.awk" "$1" 2>&1; }

out="$(parse "$REPO/config.example.yaml")"
check "parses the shipped example" "0" "$?"
check "reads transport"      "CFG_CLIMWEB_TRANSPORT='rsync'"     "$(grep '^CFG_CLIMWEB_TRANSPORT=' <<<"$out")"
check "reads watch_root"     "CFG_CLIMWEB_WATCH_ROOT='/home/cms/climweb/climweb/media/products'" "$(grep '^CFG_CLIMWEB_WATCH_ROOT=' <<<"$out")"
check "counts products"      "CFG_PRODUCT_COUNT='2'"             "$(grep '^CFG_PRODUCT_COUNT=' <<<"$out")"
check "first product name"   "CFG_PRODUCT_1_VARIABLE_NAME='weekly_rainfall'" "$(grep '^CFG_PRODUCT_1_VARIABLE_NAME=' <<<"$out")"
check "second product src"   "CFG_PRODUCT_2_SRC_PATH='/home/username/data/seasrainfall'" "$(grep '^CFG_PRODUCT_2_SRC_PATH=' <<<"$out")"
check "commented-out product is ignored" "" "$(grep '^CFG_PRODUCT_3_' <<<"$out")"

# Typos must be rejected rather than silently dropped.
printf 'climweb:\n  hostt: x\n' > "$WORK/bad1.yaml"
parse "$WORK/bad1.yaml" >/dev/null 2>&1
check "rejects an unknown key" "2" "$?"

printf 'climwebb:\n  host: x\n' > "$WORK/bad2.yaml"
parse "$WORK/bad2.yaml" >/dev/null 2>&1
check "rejects an unknown section" "2" "$?"

printf 'climweb:\n\thost: x\n' > "$WORK/bad3.yaml"
parse "$WORK/bad3.yaml" >/dev/null 2>&1
check "rejects tab indentation" "2" "$?"

printf 'climweb:\n  host: x\nproducts:\n  variable_name: y\n' > "$WORK/bad4.yaml"
parse "$WORK/bad4.yaml" >/dev/null 2>&1
check "rejects a product without '- '" "2" "$?"

printf 'climweb:\n  host: a.example.org  # inline comment\n' > "$WORK/cmt.yaml"
check "strips inline comments" "CFG_CLIMWEB_HOST='a.example.org'" "$(parse "$WORK/cmt.yaml" | grep '^CFG_CLIMWEB_HOST=')"

printf 'climweb:\n  host: "quoted.example.org"\n' > "$WORK/q.yaml"
check "strips double quotes" "CFG_CLIMWEB_HOST='quoted.example.org'" "$(parse "$WORK/q.yaml" | grep '^CFG_CLIMWEB_HOST=')"

# -----------------------------------------------------------------------------
echo
echo "path derivation"
echo "---------------"

# These three are read by the functions in common.sh, not by this script, which
# is why shellcheck cannot see the use.
# shellcheck disable=SC2034
LIB_DIR="$REPO/lib"
# shellcheck disable=SC2034
VERBOSE=0
# shellcheck source=lib/common.sh
. "$REPO/lib/common.sh"

# shellcheck disable=SC2034
CFG_CLIMWEB_WATCH_ROOT="/home/cms/climweb/climweb/media/products"
check "matches what _ingest_product scans" \
    "/home/cms/climweb/climweb/media/products/weekly_rainfall/pdf" \
    "$(dest_path_for weekly_rainfall pdf)"

# shellcheck disable=SC2034
CFG_CLIMWEB_WATCH_ROOT="/home/cms/media/products/"
check "tolerates a trailing slash on watch_root" \
    "/home/cms/media/products/daily_forecast/png" \
    "$(dest_path_for daily_forecast png)"

# -----------------------------------------------------------------------------
echo
echo "source file selection"
echo "---------------------"

SRC="$WORK/src"
mkdir -p "$SRC/2026"
touch "$SRC/bulletin_01-08-2026.pdf" "$SRC/bulletin_02-08-2026.pdf"
touch "$SRC/2026/bulletin_03-08-2026.pdf"
touch "$SRC/notes.txt" "$SRC/draft.pdf.tmp" "$SRC/.hidden.pdf"
touch -d '400 days ago' "$SRC/ancient.pdf" 2>/dev/null || touch -t 202501010000 "$SRC/ancient.pdf"

got="$(list_source_files "$SRC" pdf 30 | sort | tr '\n' ' ')"
check "picks up pdfs, keeps subdirs, skips other formats/temp/old files" \
    "2026/bulletin_03-08-2026.pdf bulletin_01-08-2026.pdf bulletin_02-08-2026.pdf " "$got"

got="$(list_source_files "$SRC" pdf 0 | grep -c ancient)"
check "max_age_days: 0 includes old files" "1" "$got"

check "count_source_files agrees" "3" "$(count_source_files "$SRC" pdf 30)"

# -----------------------------------------------------------------------------
echo
echo "rsync transport (via a local ssh shim)"
echo "--------------------------------------"

# Fake ssh: drop the options and the host, run whatever rsync asked for.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/ssh" <<'SHIM'
#!/usr/bin/env bash
# ssh [options] [user@]host command...
# Skip the options and the host, then run the command locally.
while [ $# -gt 0 ]; do
    case "$1" in
        # options that take a separate value
        -i|-p|-o|-l|-e|-c|-b|-D|-E|-F|-I|-J|-L|-m|-O|-Q|-R|-S|-W|-w) shift 2 ;;
        -*) shift ;;
        *)  shift; break ;;   # this was the host; the rest is the command
    esac
done
exec bash -c "$*"
SHIM
chmod +x "$WORK/bin/ssh"

WATCH="$WORK/watch"
cat > "$WORK/config.yaml" <<EOF
climweb:
  transport: rsync
  host: localhost
  user: tester
  ssh_key: $WORK/fake_key
  watch_root: $WATCH
defaults:
  max_age_days: 30
products:
  - variable_name: weekly_rainfall
    format: pdf
    src_path: $SRC
EOF
touch "$WORK/fake_key"; chmod 600 "$WORK/fake_key"

export PATH="$WORK/bin:$PATH"
export CLIMWEB_SYNC_STATE_DIR="$WORK/state"

"$REPO/climweb-sync" -c "$WORK/config.yaml" --dry-run > "$WORK/dry.out" 2>&1
check "dry run exits cleanly" "0" "$?"
if [ -d "$WATCH" ]; then no "dry run transfers nothing" "watch root was created"; else ok "dry run transfers nothing"; fi

"$REPO/climweb-sync" -c "$WORK/config.yaml" -v > "$WORK/run.out" 2>&1
rc=$?
check "real run exits cleanly" "0" "$rc"
[ "$rc" -ne 0 ] && sed 's/^/       | /' "$WORK/run.out"

DEST="$WATCH/weekly_rainfall/pdf"
if [ -f "$DEST/bulletin_01-08-2026.pdf" ]; then ok "file landed in the derived path"; else no "file landed in the derived path" "$DEST is missing the file"; fi
if [ -f "$DEST/2026/bulletin_03-08-2026.pdf" ]; then ok "subdirectory preserved for {yyyy}/ conventions"; else no "subdirectory preserved for {yyyy}/ conventions"; fi
if [ -f "$DEST/notes.txt" ]; then no "non-matching formats excluded" "notes.txt was copied"; else ok "non-matching formats excluded"; fi
if [ -f "$DEST/ancient.pdf" ]; then no "files older than max_age_days excluded" "ancient.pdf was copied"; else ok "files older than max_age_days excluded"; fi

mode="$(stat -c '%a' "$DEST/bulletin_01-08-2026.pdf" 2>/dev/null)"
check "chmod applied so ClimWeb can read the file" "644" "$mode"

# A second run must be a no-op, which is what makes an hourly cron job safe.
"$REPO/climweb-sync" -c "$WORK/config.yaml" -v > "$WORK/run2.out" 2>&1
if grep -qE '^(<f|>f)' "$WORK/run2.out"; then
    no "second run re-transfers nothing" "$(grep -E '^(<f|>f)' "$WORK/run2.out" | head -3)"
else
    ok "second run re-transfers nothing"
fi

# --only should filter
"$REPO/climweb-sync" -c "$WORK/config.yaml" --only nonexistent > "$WORK/only.out" 2>&1
if grep -q '0 product(s) synced' "$WORK/only.out"; then ok "--only filters products"; else no "--only filters products" "$(tail -2 "$WORK/only.out")"; fi

# --check should report the plan without transferring
"$REPO/climweb-sync" -c "$WORK/config.yaml" --check > "$WORK/check.out" 2>/dev/null
if grep -q "$DEST" "$WORK/check.out"; then ok "--check prints the resolved destination"; else no "--check prints the resolved destination" "$(cat "$WORK/check.out")"; fi

# -----------------------------------------------------------------------------
echo
echo "config validation"
echo "-----------------"

sed 's|watch_root: .*|watch_root: media/products|' "$WORK/config.yaml" > "$WORK/rel.yaml"
"$REPO/climweb-sync" -c "$WORK/rel.yaml" --check >/dev/null 2>&1
check "rejects a relative watch_root" "2" "$?"

sed 's|src_path: .*|src_path: data/rainfall|' "$WORK/config.yaml" > "$WORK/relsrc.yaml"
"$REPO/climweb-sync" -c "$WORK/relsrc.yaml" --check >/dev/null 2>&1
check "rejects a relative src_path" "2" "$?"

sed 's|format: pdf|format: .pdf|' "$WORK/config.yaml" > "$WORK/badfmt.yaml"
"$REPO/climweb-sync" -c "$WORK/badfmt.yaml" --check >/dev/null 2>&1
check "rejects a format written as .pdf" "2" "$?"

# -----------------------------------------------------------------------------
echo
printf '%d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
