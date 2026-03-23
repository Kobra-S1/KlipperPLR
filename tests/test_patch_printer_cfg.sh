#!/bin/bash
# ===========================================================================
#  Tests for patch_printer_cfg.sh
#
#  Verifies that the script correctly detects [gcode_macro CANCEL_PRINT]
#  and [gcode_macro PRINT_END], checks whether clear_last_file is already
#  present, and injects the PLR block when needed.
#
#  Run:  bash tests/test_patch_printer_cfg.sh
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PATCH_SCRIPT="$REPO_DIR/patch_printer_cfg.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

# ---- Assertion helpers ----------------------------------------------------

assert_contains() {
    local file="$1"
    local pattern="$2"
    local msg="$3"
    echo -n "  $msg ... "
    if grep -q "$pattern" "$file"; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL (pattern not found: $pattern)"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local file="$1"
    local pattern="$2"
    local msg="$3"
    echo -n "  $msg ... "
    if grep -q "$pattern" "$file"; then
        echo "FAIL (pattern unexpectedly found: $pattern)"
        FAIL=$((FAIL + 1))
    else
        echo "PASS"
        PASS=$((PASS + 1))
    fi
}

assert_count() {
    local file="$1"
    local pattern="$2"
    local expected="$3"
    local msg="$4"
    echo -n "  $msg ... "
    local count
    count=$(grep -c "$pattern" "$file" || true)
    if [ "$count" -eq "$expected" ]; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL (expected $expected occurrences, got $count)"
        FAIL=$((FAIL + 1))
    fi
}

# ---- Test-file helper -----------------------------------------------------

write_cfg() {
    local name="$1"
    local file="$TMPDIR/${name}.cfg"
    cat > "$file"   # read from stdin
    echo "$file"
}

echo "=== patch_printer_cfg.sh tests ==="

# --------------------------------------------------------------------------
# Test 1: CANCEL_PRINT without clear_last_file → should patch
# --------------------------------------------------------------------------
echo "Test 1: Patch CANCEL_PRINT without clear_last_file"
CFG=$(write_cfg test1 <<'EOF'
[gcode_macro CANCEL_PRINT]
description: Cancel
rename_existing: CANCEL_PRINT_BASE
gcode:
    M104 S0
    M140 S0
    CANCEL_PRINT_BASE

[printer]
kinematics: corexy
EOF
)
bash "$PATCH_SCRIPT" "$CFG"
assert_contains "$CFG" "clear_last_file" "clear_last_file was added"
assert_contains "$CFG" 'gcode_macro clear_last_file' "jinja guard was added"

# --------------------------------------------------------------------------
# Test 2: PRINT_END without clear_last_file → should patch
# --------------------------------------------------------------------------
echo "Test 2: Patch PRINT_END without clear_last_file"
CFG=$(write_cfg test2 <<'EOF'
[gcode_macro PRINT_END]
description: Print End
gcode:
    G91
    G1 Z3 F600
    G90
    M104 S0
EOF
)
bash "$PATCH_SCRIPT" "$CFG"
assert_contains "$CFG" "clear_last_file" "clear_last_file was added"

# --------------------------------------------------------------------------
# Test 3: Both macros → should patch both
# --------------------------------------------------------------------------
echo "Test 3: Patch both CANCEL_PRINT and PRINT_END"
CFG=$(write_cfg test3 <<'EOF'
[gcode_macro CANCEL_PRINT]
gcode:
    M104 S0
    CANCEL_PRINT_BASE

[gcode_macro PRINT_END]
gcode:
    G91
    M104 S0
EOF
)
bash "$PATCH_SCRIPT" "$CFG"
assert_count "$CFG" "clear_last_file" 4 "clear_last_file appears 4 times (2 per macro)"

# --------------------------------------------------------------------------
# Test 4: CANCEL_PRINT already has clear_last_file → skip
# --------------------------------------------------------------------------
echo "Test 4: Skip CANCEL_PRINT that already has clear_last_file"
CFG=$(write_cfg test4 <<'EOF'
[gcode_macro CANCEL_PRINT]
gcode:
    clear_last_file
    M104 S0
EOF
)
bash "$PATCH_SCRIPT" "$CFG"
assert_count "$CFG" "clear_last_file" 1 "still only 1 occurrence"

# --------------------------------------------------------------------------
# Test 5: PRINT_END already has full jinja block → skip
# --------------------------------------------------------------------------
echo "Test 5: Skip PRINT_END with full jinja clear_last_file block"
CFG=$(write_cfg test5 <<'EOF'
[gcode_macro PRINT_END]
gcode:
    {% if "gcode_macro clear_last_file" in printer %}
        clear_last_file
    {% endif %}
    M104 S0
EOF
)
bash "$PATCH_SCRIPT" "$CFG"
assert_count "$CFG" "clear_last_file" 2 "still only 2 occurrences"

# --------------------------------------------------------------------------
# Test 6: No target macros in file → skip both
# --------------------------------------------------------------------------
echo "Test 6: No target macros in file"
CFG=$(write_cfg test6 <<'EOF'
[printer]
kinematics: corexy

[gcode_macro MY_MACRO]
gcode:
    M104 S0
EOF
)
bash "$PATCH_SCRIPT" "$CFG"
assert_not_contains "$CFG" "clear_last_file" "no clear_last_file added"

# --------------------------------------------------------------------------
# Test 7: gcode = (equals sign) syntax
# --------------------------------------------------------------------------
echo "Test 7: Macro uses 'gcode =' syntax"
CFG=$(write_cfg test7 <<'EOF'
[gcode_macro CANCEL_PRINT]
gcode =
    M104 S0
    CANCEL_PRINT_BASE
EOF
)
bash "$PATCH_SCRIPT" "$CFG"
assert_contains "$CFG" "clear_last_file" "clear_last_file added with gcode= syntax"

# --------------------------------------------------------------------------
# Test 8: gcode: with no space before colon
# --------------------------------------------------------------------------
echo "Test 8: gcode: with colon (no space)"
CFG=$(write_cfg test8 <<'EOF'
[gcode_macro PRINT_END]
gcode:
    M84
EOF
)
bash "$PATCH_SCRIPT" "$CFG"
assert_contains "$CFG" "clear_last_file" "clear_last_file added with gcode: syntax"

# --------------------------------------------------------------------------
# Test 9: Idempotency — running twice does not double-patch
# --------------------------------------------------------------------------
echo "Test 9: Idempotent — running twice does not double-patch"
CFG=$(write_cfg test9 <<'EOF'
[gcode_macro CANCEL_PRINT]
gcode:
    M104 S0

[gcode_macro PRINT_END]
gcode:
    M84
EOF
)
bash "$PATCH_SCRIPT" "$CFG"
bash "$PATCH_SCRIPT" "$CFG"
assert_count "$CFG" "clear_last_file" 4 "still 4 occurrences after double run"

# --------------------------------------------------------------------------
# Test 10: Mixed — one already patched, one not
# --------------------------------------------------------------------------
echo "Test 10: Mixed — CANCEL_PRINT patched, PRINT_END not"
CFG=$(write_cfg test10 <<'EOF'
[gcode_macro CANCEL_PRINT]
gcode:
    {% if "gcode_macro clear_last_file" in printer %}
        clear_last_file
    {% endif %}
    M104 S0

[gcode_macro PRINT_END]
gcode:
    G91
    M104 S0
EOF
)
bash "$PATCH_SCRIPT" "$CFG"
assert_count "$CFG" "clear_last_file" 4 "4 total (2 existing + 2 new)"

# --------------------------------------------------------------------------
# Test 11: Other macros are not modified
# --------------------------------------------------------------------------
echo "Test 11: Other macros are not modified"
CFG=$(write_cfg test11 <<'EOF'
[gcode_macro MY_CUSTOM_MACRO]
gcode:
    M104 S0

[gcode_macro CANCEL_PRINT]
gcode:
    CANCEL_PRINT_BASE

[gcode_macro ANOTHER_MACRO]
gcode:
    G28
EOF
)
bash "$PATCH_SCRIPT" "$CFG"
assert_count "$CFG" "clear_last_file" 2 "only 2 occurrences (in CANCEL_PRINT only)"

# --------------------------------------------------------------------------
# Test 12: Macro at end of file (no trailing newline)
# --------------------------------------------------------------------------
echo "Test 12: Macro at end of file (no trailing newline)"
CFG="$TMPDIR/test12.cfg"
printf '[gcode_macro PRINT_END]\ngcode:\n    M84' > "$CFG"
bash "$PATCH_SCRIPT" "$CFG"
assert_contains "$CFG" "clear_last_file" "clear_last_file added at end of file"

# --------------------------------------------------------------------------
# Test 13: Block inserted right after gcode: line, before existing commands
# --------------------------------------------------------------------------
echo "Test 13: Block position — right after gcode:"
CFG=$(write_cfg test13 <<'EOF'
[gcode_macro CANCEL_PRINT]
gcode:
    FIRST_COMMAND
    M104 S0
EOF
)
bash "$PATCH_SCRIPT" "$CFG"
line_clear=$(grep -n "clear_last_file" "$CFG" | head -1 | cut -d: -f1)
line_first=$(grep -n "FIRST_COMMAND" "$CFG" | head -1 | cut -d: -f1)
echo -n "  block inserted before existing commands ... "
if [ "$line_clear" -lt "$line_first" ]; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL (clear_last_file at line $line_clear, FIRST_COMMAND at $line_first)"
    FAIL=$((FAIL + 1))
fi

# --------------------------------------------------------------------------
# Test 14: Real-world printer.cfg structure (multiple sections)
# --------------------------------------------------------------------------
echo "Test 14: Real-world printer.cfg structure"
CFG=$(write_cfg test14 <<'EOF'
[include mainsail.cfg]
[include printer_generic_macros.cfg]

[gcode_macro _CLIENT_VARIABLE]
variable_use_custom_pos: True
gcode:

[gcode_macro CANCEL_PRINT]
description: CANCEL_PRINT
rename_existing: CANCEL_PRINT_BASE
gcode:
    RESPOND TYPE=command MSG=action:prompt_end
    G91
    G1 Z3 F600
    G90
    M104 S0
    M140 S0
    M106 S0
    M84
    CANCEL_PRINT_BASE

[gcode_macro M204]
rename_existing: M204.1
gcode:
    M204.1 S{params.S|default(params.P)|default(5000)}

[gcode_macro PRINT_END]
description: PRINT_END
gcode:
    G91
    G1 Z3 F600
    G90
    M104 S0
    M140 S0
    M106 S0
    M84
EOF
)
bash "$PATCH_SCRIPT" "$CFG"
assert_count "$CFG" "clear_last_file" 4 "both macros patched"

# Verify _CLIENT_VARIABLE section was NOT touched
# Extract its section and check it has no clear_last_file
echo -n "  _CLIENT_VARIABLE not patched ... "
client_header=$(grep -n '^\[gcode_macro _CLIENT_VARIABLE\]' "$CFG" | head -1 | cut -d: -f1)
client_next=$(tail -n +"$((client_header + 1))" "$CFG" | grep -n '^\[' | head -1 | cut -d: -f1)
client_end=$((client_header + client_next - 1))
if sed -n "${client_header},${client_end}p" "$CFG" | grep -q "clear_last_file"; then
    echo "FAIL (clear_last_file found in _CLIENT_VARIABLE)"
    FAIL=$((FAIL + 1))
else
    echo "PASS"
    PASS=$((PASS + 1))
fi

# --------------------------------------------------------------------------
# Test 15: clear_last_file in another macro should NOT prevent patching target
# --------------------------------------------------------------------------
echo "Test 15: clear_last_file in unrelated macro does not block target"
CFG=$(write_cfg test15 <<'EOF'
[gcode_macro SOME_OTHER_MACRO]
gcode:
    clear_last_file

[gcode_macro CANCEL_PRINT]
gcode:
    M104 S0
EOF
)
bash "$PATCH_SCRIPT" "$CFG"
# CANCEL_PRINT should be patched (2 new occurrences) + 1 in SOME_OTHER_MACRO = 3 total
assert_count "$CFG" "clear_last_file" 3 "3 total (1 existing + 2 new in CANCEL_PRINT)"

# --------------------------------------------------------------------------
# Test 16: Macro with extra whitespace around gcode directive
# --------------------------------------------------------------------------
echo "Test 16: 'gcode :' with space before colon"
CFG=$(write_cfg test16 <<'EOF'
[gcode_macro CANCEL_PRINT]
gcode :
    M104 S0
EOF
)
bash "$PATCH_SCRIPT" "$CFG"
assert_contains "$CFG" "clear_last_file" "clear_last_file added with 'gcode :' syntax"

# --------------------------------------------------------------------------
# Test 17: Triple run — still idempotent
# --------------------------------------------------------------------------
echo "Test 17: Triple run idempotency"
CFG=$(write_cfg test17 <<'EOF'
[gcode_macro PRINT_END]
gcode:
    M84
EOF
)
bash "$PATCH_SCRIPT" "$CFG"
bash "$PATCH_SCRIPT" "$CFG"
bash "$PATCH_SCRIPT" "$CFG"
assert_count "$CFG" "clear_last_file" 2 "still 2 after triple run"

# --------------------------------------------------------------------------
# Test 18: Empty file — should not crash
# --------------------------------------------------------------------------
echo "Test 18: Empty file — no crash"
CFG="$TMPDIR/test18.cfg"
touch "$CFG"
echo -n "  empty file does not crash ... "
if bash "$PATCH_SCRIPT" "$CFG" >/dev/null 2>&1; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL (script crashed on empty file)"
    FAIL=$((FAIL + 1))
fi

# --------------------------------------------------------------------------
# Test 19: File with only comments — no macros
# --------------------------------------------------------------------------
echo "Test 19: File with only comments"
CFG=$(write_cfg test19 <<'EOF'
# This is a comment
# Another comment
# No macros here
EOF
)
bash "$PATCH_SCRIPT" "$CFG"
assert_not_contains "$CFG" "clear_last_file" "no clear_last_file added"

# --------------------------------------------------------------------------
# Test 20: Verify injected block structure is correct
# --------------------------------------------------------------------------
echo "Test 20: Verify exact injected block structure"
CFG=$(write_cfg test20 <<'EOF'
[gcode_macro CANCEL_PRINT]
gcode:
    M104 S0
EOF
)
bash "$PATCH_SCRIPT" "$CFG"
# Check each line of the injected block exists in order
echo -n "  comment line present ... "
if grep -q '# Clear Power Loss Recovery state' "$CFG"; then
    echo "PASS"; PASS=$((PASS + 1))
else
    echo "FAIL"; FAIL=$((FAIL + 1))
fi
echo -n "  jinja if-guard present ... "
if grep -q '{% if "gcode_macro clear_last_file" in printer %}' "$CFG"; then
    echo "PASS"; PASS=$((PASS + 1))
else
    echo "FAIL"; FAIL=$((FAIL + 1))
fi
echo -n "  clear_last_file call present ... "
if grep -q '^        clear_last_file$' "$CFG"; then
    echo "PASS"; PASS=$((PASS + 1))
else
    echo "FAIL"; FAIL=$((FAIL + 1))
fi
echo -n "  jinja endif present ... "
if grep -q '{% endif %}' "$CFG"; then
    echo "PASS"; PASS=$((PASS + 1))
else
    echo "FAIL"; FAIL=$((FAIL + 1))
fi

# --------------------------------------------------------------------------
# Test 21: SAVE_CONFIG block at end — macros in it are not real
#          (SAVE_CONFIG uses #*# prefix — no gcode_macro there normally,
#           but verify the script doesn't break with that block present)
# --------------------------------------------------------------------------
echo "Test 21: File with SAVE_CONFIG block"
CFG=$(write_cfg test21 <<'EOF'
[gcode_macro CANCEL_PRINT]
gcode:
    M104 S0

#*# <---------------------- SAVE_CONFIG ---------------------->
#*# DO NOT EDIT THIS BLOCK OR BELOW.
#*#
#*# [probe_ks1]
#*# z_offset = -0.042
EOF
)
bash "$PATCH_SCRIPT" "$CFG"
assert_count "$CFG" "clear_last_file" 2 "CANCEL_PRINT patched, SAVE_CONFIG untouched"
assert_contains "$CFG" "SAVE_CONFIG" "SAVE_CONFIG block preserved"

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
