#!/usr/bin/awk -f
#
# parse_config.awk — turns the climweb-sync YAML subset into shell assignments.
#
# This is deliberately NOT a general YAML parser. It understands exactly the
# shape documented in config.example.yaml:
#
#   climweb:            -> CFG_CLIMWEB_<KEY>
#     key: value
#   defaults:           -> CFG_DEFAULTS_<KEY>
#     key: value
#   products:           -> CFG_PRODUCT_<N>_<KEY>, plus CFG_PRODUCT_COUNT
#     - key: value
#       key: value
#
# Anything outside that shape is a hard error, which is the point: a country's
# IT team gets a clear line number instead of a silent misconfiguration that
# makes bulletins quietly stop appearing on the website.

function fail(msg) {
    printf "config error, line %d: %s\n", NR, msg > "/dev/stderr"
    printf "  %s\n", $0 > "/dev/stderr"
    exit 2
}

BEGIN {
    section = ""
    nprod = 0
    # Keys accepted in each section. Typos are rejected rather than ignored.
    ok_climweb  = " transport host user port ssh_key watch_root base_url token_file verify_tls "
    ok_defaults = " max_age_days delete_remote chmod bwlimit "
    ok_product  = " variable_name format src_path max_age_days delete_remote enabled "
}

{
    line = $0

    # Strip comments: '#' at start of line, or '#' preceded by whitespace.
    if (match(line, /(^|[ \t])#/)) {
        line = substr(line, 1, RSTART + RLENGTH - 2)
    }

    sub(/[ \t]+$/, "", line)
    if (line ~ /^[ \t]*$/) next
    if (line ~ /\t/) fail("tabs are not allowed; indent with spaces")
    if (line ~ /'/) fail("single quotes are not supported in this config; use double quotes or none")

    indent = match(line, /[^ ]/) - 1
    body = substr(line, indent + 1)

    # ---- top-level section header ----------------------------------------
    if (indent == 0) {
        if (body !~ /^[A-Za-z_][A-Za-z0-9_-]*:$/)
            fail("expected a section header such as 'climweb:', 'defaults:' or 'products:'")
        section = substr(body, 1, length(body) - 1)
        if (section != "climweb" && section != "defaults" && section != "products")
            fail("unknown section '" section "' (expected climweb, defaults or products)")
        next
    }

    if (section == "") fail("value found before any section header")

    # ---- work out which variable prefix this line belongs to -------------
    if (section == "products") {
        if (body ~ /^-[ \t]+/) {
            nprod++
            sub(/^-[ \t]+/, "", body)
        } else if (nprod == 0) {
            fail("each product must start with '- ' (a YAML list item)")
        }
        prefix = "CFG_PRODUCT_" nprod "_"
        allowed = ok_product
    } else if (section == "climweb") {
        prefix = "CFG_CLIMWEB_"
        allowed = ok_climweb
    } else {
        prefix = "CFG_DEFAULTS_"
        allowed = ok_defaults
    }

    # ---- key: value -------------------------------------------------------
    p = index(body, ":")
    if (p == 0) fail("expected 'key: value'")

    key = substr(body, 1, p - 1)
    val = substr(body, p + 1)
    sub(/^[ \t]+/, "", val)
    sub(/[ \t]+$/, "", val)

    if (key !~ /^[A-Za-z_][A-Za-z0-9_-]*$/) fail("invalid key '" key "'")
    if (val == "") fail("key '" key "' has no value (nested blocks are not supported)")

    # Strip one layer of surrounding double quotes.
    if (val ~ /^".*"$/) val = substr(val, 2, length(val) - 2)

    if (index(allowed, " " key " ") == 0)
        fail("unknown key '" key "' in section '" section "'")

    gsub(/-/, "_", key)
    printf "%s%s='%s'\n", prefix, toupper(key), val
}

END {
    printf "CFG_PRODUCT_COUNT='%d'\n", nprod
}
