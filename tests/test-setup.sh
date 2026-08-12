#!/usr/bin/env bash
#
# test-setup.sh — exercises the guided setup wizard.
#
# The ClimWeb API is stood in for by tests/curl_shim.sh rather than a real
# server, so these tests need no network. Everything the wizard writes is
# redirected into a temporary root: running this never touches /etc or installs
# a cron job on the machine under test.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok() { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; fail=$((fail+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected [$2], got [$3]"; fi; }

echo
echo "setup wizard"
echo "------------"

VALID_CODE="K7FA-2C9D-TX43"
WATCH="$WORK/watch"
FAKE_ROOT="$WORK/root"
mkdir -p "$FAKE_ROOT/etc" "$WATCH" "$WORK/shim"

# --- put the shim on PATH as 'curl' -----------------------------------------
mkdir -p "$WORK/bin"
cp "$REPO/tests/curl_shim.sh" "$WORK/bin/curl"
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"
export SHIM_DIR="$WORK/shim"
export SHIM_WATCH="$WATCH"
export SHIM_VALID_CODE="$VALID_CODE"

# --- source files ------------------------------------------------------------
SRC="$WORK/data/wkrainfall"
mkdir -p "$SRC/2026"
printf 'PDF-A' > "$SRC/bulletin_01-08-2026.pdf"
printf 'PDF-B' > "$SRC/2026/bulletin_03-08-2026.pdf"
printf 'notes' > "$SRC/readme.txt"

# --- a copy of the wizard with its absolute paths redirected ----------------
sed \
    -e "s|/etc/climweb-sync|$FAKE_ROOT/etc/climweb-sync|g" \
    -e "s|/var/log/climweb-sync|$FAKE_ROOT/var/log/climweb-sync|g" \
    -e "s|/var/lib/climweb-sync|$FAKE_ROOT/var/lib/climweb-sync|g" \
    -e "s|/etc/cron.d/climweb-sync|$FAKE_ROOT/etc/cron.d-climweb-sync|g" \
    -e "s|/usr/local/bin/climweb-sync|$REPO/climweb-sync|g" \
    "$REPO/lib/setup.sh" > "$WORK/setup_under_test.sh"

cat > "$WORK/run.sh" <<HARNESS
#!/usr/bin/env bash
set -uo pipefail
LIB_DIR="$REPO/lib"
VERBOSE=0
NO_COLOUR=1
export CLIMWEB_SYNC_READ_STDIN=1
. "\$LIB_DIR/common.sh"
. "$WORK/setup_under_test.sh"
run_setup "\$1" "\$2"
HARNESS
chmod +x "$WORK/run.sh"

# Answers: the source folder, then the schedule choice.
printf '%s\n1\n' "$SRC" | "$WORK/run.sh" "$VALID_CODE" "https://cms.test" > "$WORK/out.txt" 2>&1
rc=$?

check "wizard completes successfully" "0" "$rc"
[ "$rc" -ne 0 ] && sed 's/^/       | /' "$WORK/out.txt" | head -25

grep -q "Weekly Rainfall" "$WORK/out.txt" \
    && ok "shows the product name it discovered" \
    || no "shows the product name it discovered"

grep -q "Found 2 .pdf file" "$WORK/out.txt" \
    && ok "counts the matching source files" \
    || no "counts the matching source files" "$(grep -i 'found' "$WORK/out.txt" | head -2)"

grep -qi "you do not need to know" "$WORK/out.txt" \
    && ok "never asks the operator for the destination" \
    || no "never asks the operator for the destination"

# --- the config it wrote -----------------------------------------------------
CONF="$FAKE_ROOT/etc/climweb-sync/config.yaml"
if [ -f "$CONF" ]; then
    ok "writes a config file"
    check "uses the https transport" "  transport: https" "$(grep '  transport:' "$CONF")"
    check "fills in variable_name from the server" "  - variable_name: weekly_rainfall" "$(grep 'variable_name:' "$CONF")"
    check "fills in format from the server" "    format: pdf" "$(grep '    format:' "$CONF")"
    check "records the folder the operator gave" "    src_path: $SRC" "$(grep 'src_path:' "$CONF")"

    # Whatever the wizard writes must satisfy the tool's own validator.
    CLIMWEB_SYNC_STATE_DIR="$WORK/state" "$REPO/climweb-sync" -c "$CONF" --check >"$WORK/check.txt" 2>&1
    check "the generated config passes --check" "0" "$?"
    grep -qi 'error' "$WORK/check.txt" && sed 's/^/       | /' "$WORK/check.txt" | head -5
else
    no "writes a config file"
fi

TOKEN_FILE="$FAKE_ROOT/etc/climweb-sync/token"
if [ -f "$TOKEN_FILE" ]; then
    ok "saves the token"
    check "token file is not readable by other users" "600" "$(stat -c '%a' "$TOKEN_FILE")"
else
    no "saves the token"
fi

CRON="$FAKE_ROOT/etc/cron.d-climweb-sync"
if [ -f "$CRON" ]; then
    ok "installs a schedule"
    grep -q '17 \* \* \* \*' "$CRON" \
        && ok "the 'several times a day' answer maps to an hourly schedule" \
        || no "the 'several times a day' answer maps to an hourly schedule" "$(grep -v '^#' "$CRON" | tail -1)"
else
    no "installs a schedule"
fi

# --- the test upload really happened ----------------------------------------
if [ -f "$WATCH/weekly_rainfall/pdf/bulletin_01-08-2026.pdf" ]; then
    ok "sends a real test file, into the derived path"
else
    no "sends a real test file" "$(find "$WATCH" -type f 2>/dev/null | head -3)"
fi

grep -q "publish automatically" "$WORK/out.txt" \
    && ok "confirms success in plain language" \
    || no "confirms success in plain language"

# --- a normal run using the generated config --------------------------------
CLIMWEB_SYNC_STATE_DIR="$WORK/state2" "$REPO/climweb-sync" -c "$CONF" -v >"$WORK/sync.txt" 2>&1
check "a normal sync run works with the generated config" "0" "$?"

if [ -f "$WATCH/weekly_rainfall/pdf/2026/bulletin_03-08-2026.pdf" ]; then
    ok "uploads preserve subdirectories"
else
    no "uploads preserve subdirectories" "$(tail -5 "$WORK/sync.txt")"
fi

if [ -f "$WATCH/weekly_rainfall/pdf/readme.txt" ]; then
    no "non-matching formats are not uploaded" "readme.txt was sent"
else
    ok "non-matching formats are not uploaded"
fi

# A second run must be a no-op, which is what makes the hourly schedule safe.
CLIMWEB_SYNC_STATE_DIR="$WORK/state2" "$REPO/climweb-sync" -c "$CONF" >"$WORK/sync2.txt" 2>&1
if grep -q '0 uploaded' "$WORK/sync2.txt"; then
    ok "a second run uploads nothing"
else
    no "a second run uploads nothing" "$(grep -i uploaded "$WORK/sync2.txt" | head -2)"
fi

# --- codes that should be refused -------------------------------------------
printf '%s\n1\n' "$SRC" | "$WORK/run.sh" "WRONGCODEHERE" "https://cms.test" >"$WORK/bad.txt" 2>&1
grep -q "not accepted" "$WORK/bad.txt" \
    && ok "an invalid code is refused with a plain-language explanation" \
    || no "an invalid code is refused clearly" "$(tail -3 "$WORK/bad.txt")"

printf '%s\n1\n' "$SRC" | "$WORK/run.sh" "$VALID_CODE" "https://cms.test" >"$WORK/reuse.txt" 2>&1
grep -q "not accepted" "$WORK/reuse.txt" \
    && ok "a code cannot be used twice" \
    || no "a code cannot be used twice" "$(tail -3 "$WORK/reuse.txt")"

# A code typed in lowercase and without dashes must still work — the alternative
# is a support call about an invisible formatting difference.
rm -f "$SHIM_DIR/used_codes"
printf '%s\n1\n' "$SRC" | "$WORK/run.sh" "k7fa2c9dtx43" "https://cms.test" >"$WORK/loose.txt" 2>&1
grep -q "Weekly Rainfall" "$WORK/loose.txt" \
    && ok "accepts a code typed in lowercase without dashes" \
    || no "accepts a code typed in lowercase without dashes" "$(tail -3 "$WORK/loose.txt")"

rm -f "$SHIM_DIR/used_codes"
printf '%s\n1\n' "$SRC" | SHIM_DOWN=1 "$WORK/run.sh" "$VALID_CODE" "https://cms.test" >"$WORK/down.txt" 2>&1
grep -q "Could not reach" "$WORK/down.txt" \
    && ok "an unreachable server gives an actionable message" \
    || no "an unreachable server gives an actionable message" "$(tail -3 "$WORK/down.txt")"

# --- the operator gives a folder with nothing in it -------------------------
rm -f "$SHIM_DIR/used_codes"
EMPTY="$WORK/empty"; mkdir -p "$EMPTY"
printf '%s\nn\n%s\n1\n' "$EMPTY" "$SRC" | "$WORK/run.sh" "$VALID_CODE" "https://cms.test" >"$WORK/empty.txt" 2>&1
grep -q "No .pdf files found" "$WORK/empty.txt" \
    && ok "warns when the folder holds no matching files, then asks again" \
    || no "warns when the folder holds no matching files" "$(tail -4 "$WORK/empty.txt")"

# --- a folder that does not exist -------------------------------------------
rm -f "$SHIM_DIR/used_codes"
printf '/no/such/folder\n%s\n1\n' "$SRC" | "$WORK/run.sh" "$VALID_CODE" "https://cms.test" >"$WORK/missing.txt" 2>&1
grep -q "There is no folder at" "$WORK/missing.txt" \
    && ok "rejects a folder that does not exist, then asks again" \
    || no "rejects a folder that does not exist" "$(tail -4 "$WORK/missing.txt")"

echo
printf '%d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
