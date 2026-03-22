#!/bin/bash
# ===========================================================================
#  Test: plr.sh must not match Z-values inside base64 thumbnail comments.
#
#  Reproduces the exact failure scenario where "Z5.8" as an unescaped regex
#  matched "Z5s8" inside a base64-encoded slicer thumbnail comment, causing
#  SET_KINEMATIC_POSITION to receive garbage instead of a numeric Z value.
#
#  Run:  bash tests/test_plr_thumbnail_regex.sh
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# ---- Set up an isolated tmp directory (cleaned up on exit) -----------------
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# plr.sh template uses {USER_HOME}/printer_data/... paths
PLR_OUTDIR="$TMPDIR/printer_data/gcodes/plr"
GCODE_DIR="$TMPDIR/printer_data/gcodes"
CONFIG_DIR="$TMPDIR/printer_data/config"
mkdir -p "$PLR_OUTDIR" "$GCODE_DIR" "$CONFIG_DIR"

GCODE_FILE="$GCODE_DIR/testfile.gcode"
VARIABLES="$CONFIG_DIR/variables.cfg"

# ---- Prepare a self-contained copy of plr.sh with paths pointing to TMPDIR -
PLR_SH="$TMPDIR/plr.sh"
sed "s|{USER_HOME}|${TMPDIR}|g" "$REPO_DIR/plr.sh" > "$PLR_SH"
chmod +x "$PLR_SH"

PASS=0
FAIL=0

run_test() {
    local test_name="$1"
    local z_height="$2"
    local gcode_content="$3"
    local expect_pattern="$4"   # regex the first line of output must match

    echo -n "  $test_name ... "

    # Write gcode + variables
    echo "$gcode_content" > "$GCODE_FILE"
    cat > "$VARIABLES" << VARS
[Variables]
last_file = 'testfile.gcode'
filepath = '${GCODE_FILE}'
VARS

    # Clear previous output
    rm -f "$PLR_OUTDIR/testfile.gcode"

    # Run plr.sh with the given Z height
    bash "$PLR_SH" "$z_height" "testfile.gcode" >/dev/null 2>&1 || true

    local output_file="$PLR_OUTDIR/testfile.gcode"
    if [ ! -f "$output_file" ]; then
        echo "FAIL (no output file created)"
        FAIL=$((FAIL + 1))
        return
    fi

    local first_line
      first_line=$(grep -v '^;' "$output_file" | head -1)

    if echo "$first_line" | grep -qE "$expect_pattern"; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL"
        echo "    Expected pattern: $expect_pattern"
        echo "    Got:              $first_line"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== PLR thumbnail regex tests ==="

# --------------------------------------------------------------------------
# Test 1: Thumbnail base64 contains 'Z5s8' which matches unescaped /Z5.8/
#          but must NOT match with the fix.
# --------------------------------------------------------------------------
run_test \
    "base64_Z5s8_must_not_match" \
    "5.8" \
    "; thumbnail begin
; iVBORw0KGgoAAAANSUhEUgAAAOYAAABuCAYAAAAziW8OAAAO
; ZI55OpUPKbGxGatwfIcV98PSdbvE27bKTc46iS+3h9PwNo5QzG7LnvUycHFBmC1bgvsb7Pmf8ZQCkk
; MpZ5s8/7Lbf49Syk6Np+yzNMqqyvLjusblx3Vr9I7Ln3L0lP4yuj9z7w7EvEXzOCGZ5WItX4uJ48V
; thumbnail end
G1 X10 Y10 Z0.2 E0.5 F3000
G1 X20 Y20 Z0.4 E1.0
G1 X30 Y30 Z1.0 E2.0
G1 X40 Y40 Z2.0 E3.0
G1 X50 Y50 Z3.0 E4.0
G1 X60 Y60 Z4.0 E5.0
G1 X70 Y70 Z5.0 E6.0
G1 X80 Y80 Z5.4 E7.0
G1 X90 Y90 Z5.8 E8.0
G1 X100 Y100 Z6.2 E9.0
G1 X110 Y110 Z6.6 E10.0" \
    "^SET_KINEMATIC_POSITION Z=[0-9]+\.?[0-9]*$"

# --------------------------------------------------------------------------
# Test 2: Simple gcode without thumbnails — basic Z extraction must work.
# --------------------------------------------------------------------------
run_test \
    "simple_gcode_no_thumbnail" \
    "3.0" \
    "G1 X10 Y10 Z0.2 E0.5 F3000
G1 X20 Y20 Z1.0 E1.0
G1 X30 Y30 Z2.0 E2.0
G1 X40 Y40 Z3.0 E3.0
G1 X50 Y50 Z3.4 E4.0
G1 X60 Y60 Z4.0 E5.0" \
    "^SET_KINEMATIC_POSITION Z=3\.4$"

# --------------------------------------------------------------------------
# Test 3: Dot escape — Z=1.2 must not match Z1X2 in base64.
# --------------------------------------------------------------------------
run_test \
    "dot_escape_Z1X2_must_not_match" \
    "1.2" \
    "; thumbnail begin
; aaabbbZ1X2cccdddeee
; thumbnail end
G1 X10 Y10 Z0.2 E0.5
G1 X20 Y20 Z0.6 E1.0
G1 X30 Y30 Z1.0 E2.0
G1 X40 Y40 Z1.2 E3.0
G1 X50 Y50 Z1.6 E4.0
G1 X60 Y60 Z2.0 E5.0" \
    "^SET_KINEMATIC_POSITION Z=1\.6$"

# --------------------------------------------------------------------------
# Test 4: Tool detection — LAST_TOOL must be extracted correctly.
# --------------------------------------------------------------------------
run_test \
    "tool_detection_T4" \
    "2.0" \
    "T4
G1 X10 Y10 Z0.2 E0.5
G1 X20 Y20 Z1.0 E1.0
G1 X30 Y30 Z2.0 E2.0
G1 X40 Y40 Z2.4 E3.0
G1 X50 Y50 Z3.0 E4.0" \
    "^SET_KINEMATIC_POSITION Z=2\.4$"

# Also verify _PLR_PRIME_NOZZLE T=4 is in the output
echo -n "  tool_detection_T4_prime_line ... "
if grep -q "_PLR_PRIME_NOZZLE T=4" "$PLR_OUTDIR/testfile.gcode"; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL (_PLR_PRIME_NOZZLE T=4 not found)"
    FAIL=$((FAIL + 1))
fi

# --------------------------------------------------------------------------
# Test 5: Multiple thumbnails + many Z-matching patterns in base64.
# --------------------------------------------------------------------------
run_test \
    "heavy_base64_pollution" \
    "10.2" \
    "; thumbnail begin 400x300
; AAAZ10X2BBBcZ10q2dddZ10R2eee
; fffZ10g2hhhZ10S2iiiZ10A2jjj
; kkkZ10t2lllZ10u2mmmZ10v2nnn
; thumbnail end
; thumbnail begin 32x32
; oooZ10p2qqqZ10y2rrrZ10w2sss
; thumbnail end
G1 X10 Y10 Z0.2 E0.5
G1 X30 Y30 Z5.0 E2.0
G1 X50 Y50 Z10.0 E4.0
G1 X60 Y60 Z10.2 E5.0
G1 X70 Y70 Z10.6 E6.0
G1 X80 Y80 Z11.0 E7.0" \
    "^SET_KINEMATIC_POSITION Z=10\.6$"

# --------------------------------------------------------------------------# Test 6: Thumbnail block must be preserved in recovery file.
# ----------------------------------------------------------------------
run_test \
    "thumbnail_preserved_in_output" \
    "2.0" \
    "; thumbnail begin 230x110 4992
; iVBORw0KGgoAAAANSUhEUgAAAOY+base64data
; thumbnail end
G1 X10 Y10 Z0.2 E0.5
G1 X20 Y20 Z1.0 E1.0
G1 X30 Y30 Z2.0 E2.0
G1 X40 Y40 Z2.4 E3.0
G1 X50 Y50 Z3.0 E4.0" \
    "^SET_KINEMATIC_POSITION Z=2\\.4$"

# Verify the thumbnail block is present in the output
echo -n "  thumbnail_block_in_output ... "
if grep -q '^; thumbnail begin' "$PLR_OUTDIR/testfile.gcode" && \
   grep -q '^; thumbnail end' "$PLR_OUTDIR/testfile.gcode" && \
   grep -q 'base64data' "$PLR_OUTDIR/testfile.gcode"; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL (thumbnail block not found in recovery file)"
    FAIL=$((FAIL + 1))
fi

# Verify no thumbnail is emitted when original has none
run_test \
    "no_thumbnail_no_junk" \
    "1.0" \
    "G1 X10 Y10 Z0.2 E0.5
G1 X20 Y20 Z1.0 E1.0
G1 X30 Y30 Z1.4 E2.0" \
    "^SET_KINEMATIC_POSITION Z=1\\.4$"

echo -n "  no_thumbnail_clean_output ... "
if ! grep -q '^; thumbnail' "$PLR_OUTDIR/testfile.gcode"; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL (unexpected thumbnail in output)"
    FAIL=$((FAIL + 1))
fi

# ----------------------------------------------------------------------# Summary
# --------------------------------------------------------------------------

# Helper: write gcode with Windows \r\n line endings
write_crlf_gcode() {
    local file="$1"
    local content="$2"
    # Write with \n then convert to \r\n
    echo "$content" > "$file"
    sed -i 's/$/\r/' "$file"
}

# Helper: check that no line in the output contains a trailing \r
check_no_cr() {
    local file="$1"
    if grep -qP '\r' "$file" 2>/dev/null; then
        return 1
    fi
    return 0
}

# --------------------------------------------------------------------------
# Test 9: Windows \r\n line endings — Z extraction must be clean.
# --------------------------------------------------------------------------
echo -n "  crlf_z_extraction ... "
write_crlf_gcode "$GCODE_FILE" "G1 X10 Y10 Z0.2 E0.5
G1 X20 Y20 Z1.0 E1.0
G1 X30 Y30 Z2.0 E2.0
G1 X40 Y40 Z2.4 E3.0
G1 X50 Y50 Z3.0 E4.0"
cat > "$VARIABLES" << VARS
[Variables]
last_file = 'testfile.gcode'
filepath = '${GCODE_FILE}'
VARS
rm -f "$PLR_OUTDIR/testfile.gcode"
bash "$PLR_SH" "2.0" "testfile.gcode" >/dev/null 2>&1 || true
first_z=$(grep -v '^;' "$PLR_OUTDIR/testfile.gcode" | head -1)
if echo "$first_z" | grep -qE '^SET_KINEMATIC_POSITION Z=2\.4$' && check_no_cr "$PLR_OUTDIR/testfile.gcode"; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL"
    echo "    Got: $(echo "$first_z" | cat -A)"
    FAIL=$((FAIL + 1))
fi

# --------------------------------------------------------------------------
# Test 10: Windows \r\n — E-value extraction must not contain \r.
# --------------------------------------------------------------------------
echo -n "  crlf_e_value_clean ... "
if grep -q '^G92 E' "$PLR_OUTDIR/testfile.gcode"; then
    e_line=$(grep '^G92 E' "$PLR_OUTDIR/testfile.gcode" | head -1)
    if echo "$e_line" | grep -qP '\r'; then
        echo "FAIL (\\r leaked into E-value)"
        echo "    Got: $(echo "$e_line" | cat -A)"
        FAIL=$((FAIL + 1))
    else
        echo "PASS"
        PASS=$((PASS + 1))
    fi
elif grep -q '^M83' "$PLR_OUTDIR/testfile.gcode"; then
    m_line=$(grep '^M83' "$PLR_OUTDIR/testfile.gcode" | head -1)
    if echo "$m_line" | grep -qP '\r'; then
        echo "FAIL (\\r leaked into M83)"
        echo "    Got: $(echo "$m_line" | cat -A)"
        FAIL=$((FAIL + 1))
    else
        echo "PASS"
        PASS=$((PASS + 1))
    fi
else
    echo "PASS (no E/M83 line — M83 mode with G92 E0)"
    PASS=$((PASS + 1))
fi

# --------------------------------------------------------------------------
# Test 11: Windows \r\n with thumbnails — both thumbnail and Z must work.
# --------------------------------------------------------------------------
echo -n "  crlf_with_thumbnail ... "
write_crlf_gcode "$GCODE_FILE" "; thumbnail begin 230x110 100
; iVBORw0KGgoAAAA+crlf_test_data
; thumbnail end
G1 X10 Y10 Z0.2 E0.5
G1 X20 Y20 Z1.0 E1.0
G1 X30 Y30 Z2.0 E2.0
G1 X40 Y40 Z2.4 E3.0"
cat > "$VARIABLES" << VARS
[Variables]
last_file = 'testfile.gcode'
filepath = '${GCODE_FILE}'
VARS
rm -f "$PLR_OUTDIR/testfile.gcode"
bash "$PLR_SH" "2.0" "testfile.gcode" >/dev/null 2>&1 || true
has_thumb=$(grep -c '^; thumbnail begin' "$PLR_OUTDIR/testfile.gcode" || true)
z_ok=$(grep -v '^;' "$PLR_OUTDIR/testfile.gcode" | head -1)
if [ "$has_thumb" -ge 1 ] && echo "$z_ok" | grep -qE '^SET_KINEMATIC_POSITION Z=2\.4$' && check_no_cr "$PLR_OUTDIR/testfile.gcode"; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL"
    echo "    thumbnail_count=$has_thumb  first_z=$(echo "$z_ok" | cat -A)"
    FAIL=$((FAIL + 1))
fi

# --------------------------------------------------------------------------
# Test 12: Z at first layer (Z=0.2) — common edge case.
#          Real gcode always has slicer preamble before first G1 Z move.
# --------------------------------------------------------------------------
run_test \
    "first_layer_Z0.2" \
    "0.2" \
    "; generated by OrcaSlicer
G28
M190 S60
G1 X10 Y10 Z0.2 E0.5
G1 X20 Y20 Z0.4 E1.0
G1 X30 Y30 Z0.6 E2.0" \
    "^SET_KINEMATIC_POSITION Z=0\\.4$"

# --------------------------------------------------------------------------
# Test 13: Z with trailing zeros in gcode (Z5.400 when searching for 5.4).
# --------------------------------------------------------------------------
run_test \
    "trailing_zeros_Z5.400" \
    "5.4" \
    "G1 X10 Y10 Z0.200 E0.5
G1 X20 Y20 Z2.600 E1.0
G1 X30 Y30 Z5.400 E2.0
G1 X40 Y40 Z5.800 E3.0
G1 X50 Y50 Z6.200 E4.0" \
    "^SET_KINEMATIC_POSITION Z=5\\.800$"

# --------------------------------------------------------------------------
# Test 14: M83 relative extrusion mode — G92 E0 + M83 must appear.
# --------------------------------------------------------------------------
echo -n "  m83_relative_extrusion ... "
echo "M83
G1 X10 Y10 Z0.2 E0.5
G1 X20 Y20 Z1.0 E1.0
G1 X30 Y30 Z2.0 E2.0
G1 X40 Y40 Z2.4 E3.0" > "$GCODE_FILE"
cat > "$VARIABLES" << VARS
[Variables]
last_file = 'testfile.gcode'
filepath = '${GCODE_FILE}'
VARS
rm -f "$PLR_OUTDIR/testfile.gcode"
bash "$PLR_SH" "2.0" "testfile.gcode" >/dev/null 2>&1 || true
if grep -q '^G92 E0$' "$PLR_OUTDIR/testfile.gcode" && grep -q '^M83$' "$PLR_OUTDIR/testfile.gcode"; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL (expected G92 E0 + M83 in output)"
    grep -E '^(G92|M83)' "$PLR_OUTDIR/testfile.gcode" || echo "    (none found)"
    FAIL=$((FAIL + 1))
fi

# --------------------------------------------------------------------------
# Test 15: Large Z value (Z100.2) — must not be confused by substring match.
# --------------------------------------------------------------------------
run_test \
    "large_Z_100.2" \
    "100.2" \
    "G1 X10 Y10 Z0.2 E0.5
G1 X20 Y20 Z50.0 E1.0
G1 X30 Y30 Z100.0 E2.0
G1 X40 Y40 Z100.2 E3.0
G1 X50 Y50 Z100.4 E4.0
G1 X60 Y60 Z100.6 E5.0" \
    "^SET_KINEMATIC_POSITION Z=100\\.4$"

# --------------------------------------------------------------------------
# Test 16: Recovery command ordering — safety-critical sequence validation.
#
# The recovery file MUST follow this exact order:
#   1. SET_KINEMATIC_POSITION Z=...   (tell Klipper the current Z)
#   2. G91 + G1 Z10 + G90            (lift nozzle away from part)
#   3. G28 X Y                       (home X/Y while safely above part)
#   4. _PLR_PRIME_NOZZLE             (prime — safe because homed + Z lifted)
#   5. G92 E... or G92 E0 + M83      (restore extruder position)
#   6. G91 + G1 Z-5 + G90            (lower back toward part)
#   7. G1 X... Y... Z...             (resume printing gcode)
#
# Wrong order = crash, blob, or layer shift.
# --------------------------------------------------------------------------
echo -n "  recovery_command_ordering ... "
echo "T2
; comment line
G28
M190 S60
M83
G1 X10 Y10 Z0.2 E0.5
G1 X20 Y20 Z1.0 E1.0
G1 X30 Y30 Z2.0 E2.0
G1 X40 Y40 Z2.4 E3.0
G1 X50 Y50 Z3.0 E4.0
G1 X60 Y60 Z3.4 E5.0" > "$GCODE_FILE"
cat > "$VARIABLES" << VARS
[Variables]
last_file = 'testfile.gcode'
filepath = '${GCODE_FILE}'
VARS
rm -f "$PLR_OUTDIR/testfile.gcode"
bash "$PLR_SH" "2.0" "testfile.gcode" >/dev/null 2>&1 || true

# Extract the command keywords in order (skip thumbnail/comment lines and blanks)
ORDER=$(grep -v '^;' "$PLR_OUTDIR/testfile.gcode" \
    | grep -v '^$' \
    | sed -n \
        -e 's/^\(SET_KINEMATIC_POSITION\) .*/\1/p' \
        -e 's/^\(M118\) .*/\1/p' \
        -e '/^G91$/p' \
        -e '/^G1 Z10$/p' \
        -e '/^G1 Z-5$/p' \
        -e '/^G90$/p' \
        -e 's/^\(G28\) .*/\1/p' \
        -e 's/^\(_PLR_PRIME_NOZZLE\).*/\1/p' \
        -e 's/^\(G92 E\).*/\1/p' \
        -e '/^M83$/p' \
    | tr '\n' '|' \
    | sed 's/|$//')

EXPECTED="SET_KINEMATIC_POSITION|M118|G91|G1 Z10|G90|G28|_PLR_PRIME_NOZZLE|G92 E|M83|G91|G1 Z-5|G90"

if [ "$ORDER" = "$EXPECTED" ]; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL"
    echo "    Expected: $EXPECTED"
    echo "    Got:      $ORDER"
    FAIL=$((FAIL + 1))
fi

# --------------------------------------------------------------------------
# Test 17: Ordering — _PLR_PRIME_NOZZLE must come AFTER G28 X Y.
#          Redundant safety check: prime without homing = crash.
# --------------------------------------------------------------------------
echo -n "  prime_after_home ... "
HOME_LINE=$(grep -n '^G28 X Y' "$PLR_OUTDIR/testfile.gcode" | head -1 | cut -d: -f1)
PRIME_LINE=$(grep -n '^_PLR_PRIME_NOZZLE' "$PLR_OUTDIR/testfile.gcode" | head -1 | cut -d: -f1)
if [ -n "$HOME_LINE" ] && [ -n "$PRIME_LINE" ] && [ "$PRIME_LINE" -gt "$HOME_LINE" ]; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL (prime on line $PRIME_LINE, home on line $HOME_LINE)"
    FAIL=$((FAIL + 1))
fi

# --------------------------------------------------------------------------
# Test 18: Ordering — SET_KINEMATIC_POSITION must be BEFORE G1 Z10 lift.
#          Without it Klipper doesn't know Z position → wrong lift height.
# --------------------------------------------------------------------------
echo -n "  set_z_before_lift ... "
SKP_LINE=$(grep -n '^SET_KINEMATIC_POSITION' "$PLR_OUTDIR/testfile.gcode" | head -1 | cut -d: -f1)
LIFT_LINE=$(grep -n '^G1 Z10$' "$PLR_OUTDIR/testfile.gcode" | head -1 | cut -d: -f1)
if [ -n "$SKP_LINE" ] && [ -n "$LIFT_LINE" ] && [ "$SKP_LINE" -lt "$LIFT_LINE" ]; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL (SET_KINEMATIC on line $SKP_LINE, lift on line $LIFT_LINE)"
    FAIL=$((FAIL + 1))
fi

# --------------------------------------------------------------------------
# Test 19: Ordering — E-position restore must be AFTER prime, BEFORE Z lower.
#          Wrong order = wrong extrusion amount at resume point.
# --------------------------------------------------------------------------
echo -n "  e_restore_between_prime_and_lower ... "
E_LINE=$(grep -n '^G92 E' "$PLR_OUTDIR/testfile.gcode" | head -1 | cut -d: -f1)
LOWER_LINE=$(grep -n '^G1 Z-5$' "$PLR_OUTDIR/testfile.gcode" | head -1 | cut -d: -f1)
if [ -n "$PRIME_LINE" ] && [ -n "$E_LINE" ] && [ -n "$LOWER_LINE" ] && \
   [ "$E_LINE" -gt "$PRIME_LINE" ] && [ "$E_LINE" -lt "$LOWER_LINE" ]; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL (prime=$PRIME_LINE, E_restore=$E_LINE, lower=$LOWER_LINE)"
    FAIL=$((FAIL + 1))
fi

# --------------------------------------------------------------------------
# Test 20: Ordering — resumed gcode must come AFTER the Z-5 lower.
# --------------------------------------------------------------------------
echo -n "  gcode_after_lower ... "
LAST_G90_LINE=$(grep -n '^G90$' "$PLR_OUTDIR/testfile.gcode" | tail -1 | cut -d: -f1)
FIRST_RESUME_LINE=$(grep -n '^G1 X' "$PLR_OUTDIR/testfile.gcode" | head -1 | cut -d: -f1)
if [ -n "$LAST_G90_LINE" ] && [ -n "$FIRST_RESUME_LINE" ] && [ "$FIRST_RESUME_LINE" -gt "$LAST_G90_LINE" ]; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL (last G90=$LAST_G90_LINE, first resume G1=$FIRST_RESUME_LINE)"
    FAIL=$((FAIL + 1))
fi

# ==========================================================================
# Z FORMAT MISMATCH TESTS
#
# OrcaSlicer omits trailing ".0" for integer Z heights (Z6 instead of Z6.0)
# and omits leading "0" for sub-1 Z (Z.2 instead of Z0.2).
# LOG_Z in Klipper always reports the full float (6.0, 0.2).
# plr.sh must handle this mismatch.
# ==========================================================================

# --------------------------------------------------------------------------
# Test 21: Integer Z — LOG_Z says 6.0, gcode has Z6 (no decimal).
#          This is the exact scenario that caused the double-PLR crash.
# --------------------------------------------------------------------------
run_test \
    "integer_Z_6.0_vs_Z6" \
    "6.0" \
    "; generated by OrcaSlicer
G28
M190 S60
M83
G1 X10 Y10 Z.2 E0.5
G1 X20 Y20 Z2 E1.0
G1 X30 Y30 Z4 E2.0
G1 X40 Y40 Z6 E3.0
G1 X50 Y50 Z6.2 E4.0
G1 X60 Y60 Z6.4 E5.0
G1 X70 Y70 Z8 E6.0" \
    "^SET_KINEMATIC_POSITION Z="

# --------------------------------------------------------------------------
# Test 22: Integer Z — verify the resumed Z value is ABOVE the failure Z.
#          Must not resume at Z=.2 (crash into part).
# --------------------------------------------------------------------------
echo -n "  integer_Z_resume_above_failure ... "
z_val=$(grep -v '^;' "$PLR_OUTDIR/testfile.gcode" | head -1 | sed -n 's/SET_KINEMATIC_POSITION Z=//p')
if [ -n "$z_val" ] && python3 -c "import sys; sys.exit(0 if float('$z_val') > 6.0 else 1)" 2>/dev/null; then
    echo "PASS (Z=$z_val)"
    PASS=$((PASS + 1))
else
    echo "FAIL (resumed Z=$z_val, should be > 6.0)"
    FAIL=$((FAIL + 1))
fi

# --------------------------------------------------------------------------
# Test 23: Integer Z — appended gcode must NOT contain earlier layers.
#          If Z.2 or Z2 appears in the appended gcode, the nozzle would
#          crash from the lift height down into the already-printed part.
# --------------------------------------------------------------------------
echo -n "  integer_Z_no_early_layers ... "
# Lines after the last G90 are the appended gcode
LAST_G90=$(grep -n '^G90$' "$PLR_OUTDIR/testfile.gcode" | tail -1 | cut -d: -f1)
if [ -n "$LAST_G90" ]; then
    early_z=$(tail -n +"$((LAST_G90 + 1))" "$PLR_OUTDIR/testfile.gcode" | grep -cP '(^G1 .* Z[.]2|^G1 .* Z2[^0-9.]|^G1 .* Z4[^0-9.])' || true)
    if [ "$early_z" -eq 0 ]; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL ($early_z lines with Z < 6.0 found in appended gcode)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL (no G90 found)"
    FAIL=$((FAIL + 1))
fi

# --------------------------------------------------------------------------
# Test 24: Leading zero omitted — LOG_Z says 0.2, gcode has Z.2.
# --------------------------------------------------------------------------
run_test \
    "leading_zero_Z0.2_vs_Z.2" \
    "0.2" \
    "; generated by OrcaSlicer
G28
M190 S60
G1 X10 Y10 Z.2 E0.5
G1 X20 Y20 Z.4 E1.0
G1 X30 Y30 Z.6 E2.0" \
    "^SET_KINEMATIC_POSITION Z="

echo -n "  leading_zero_resume_above_failure ... "
z_val=$(grep -v '^;' "$PLR_OUTDIR/testfile.gcode" | head -1 | sed -n 's/SET_KINEMATIC_POSITION Z=//p')
if [ -n "$z_val" ] && python3 -c "import sys; sys.exit(0 if float('$z_val') > 0.2 else 1)" 2>/dev/null; then
    echo "PASS (Z=$z_val)"
    PASS=$((PASS + 1))
else
    echo "FAIL (resumed Z=$z_val, should be > 0.2)"
    FAIL=$((FAIL + 1))
fi

# ==========================================================================
# DOUBLE AND TRIPLE PLR BACK-TO-BACK TESTS
#
# Simulate the exact real scenario:
# 1. Original print crashes at Z=2.4 → PLR generates recovery #1
# 2. Recovery #1 crashes at Z=6.0 → PLR generates recovery #2 (from original)
# 3. Recovery #2 crashes at Z=10.0 → PLR generates recovery #3 (from original)
#
# Each recovery must:
#   - Use the ORIGINAL gcode (not the previous recovery file)
#   - Find the correct Z (even integer Z like Z6 = 6.0)
#   - Not include earlier layers in the appended gcode
#   - Have correct command ordering
# ==========================================================================

# --------------------------------------------------------------------------
# Test 26: Double PLR — first at Z=2.4, then at Z=6.0 (integer Z).
# --------------------------------------------------------------------------
echo -n "  double_plr_z2.4_then_z6.0 ... "

# OrcaSlicer-style gcode: integer Z heights omit ".0"
BENCHY_GCODE="; generated by OrcaSlicer
; thumbnail begin 32x32 100
; iVBORw0KGgoAAAA+test_double_plr
; thumbnail end
G28
M190 S60
M83
T4
G1 X10 Y10 Z.2 E0.5
G1 X20 Y20 Z.4 E1.0
G1 X30 Y30 Z1 E2.0
G1 X40 Y40 Z1.2 E3.0
G1 X50 Y50 Z2 E4.0
G1 X60 Y60 Z2.2 E5.0
G1 X70 Y70 Z2.4 E6.0
G1 X80 Y80 Z2.6 E7.0
G1 X90 Y90 Z4 E8.0
G1 X100 Y100 Z4.2 E9.0
G1 X110 Y110 Z6 E10.0
G1 X120 Y120 Z6.2 E11.0
G1 X130 Y130 Z6.4 E12.0
G1 X140 Y140 Z8 E13.0
G1 X150 Y150 Z8.2 E14.0
G1 X160 Y160 Z10 E15.0
G1 X170 Y170 Z10.2 E16.0"

echo "$BENCHY_GCODE" > "$GCODE_FILE"
cat > "$VARIABLES" << VARS
[Variables]
last_file = 'testfile.gcode'
filepath = '${GCODE_FILE}'
VARS
rm -f "$PLR_OUTDIR/testfile.gcode"

# --- PLR #1: crash at Z=2.4 ---
bash "$PLR_SH" "2.4" "testfile.gcode" >/dev/null 2>&1 || true

# Verify PLR #1 recovery file
plr1_z=$(grep -v '^;' "$PLR_OUTDIR/testfile.gcode" | head -1 | sed -n 's/SET_KINEMATIC_POSITION Z=//p')
plr1_ok=false
if [ -n "$plr1_z" ] && python3 -c "import sys; sys.exit(0 if float('$plr1_z') > 2.4 else 1)" 2>/dev/null; then
    plr1_ok=true
fi

# --- PLR #2: crash at Z=6.0 (integer Z!) ---
# variables.cfg still points to original (save_last_file skips /plr/)
bash "$PLR_SH" "6.0" "testfile.gcode" >/dev/null 2>&1 || true

# Verify PLR #2 recovery file
plr2_z=$(grep -v '^;' "$PLR_OUTDIR/testfile.gcode" | head -1 | sed -n 's/SET_KINEMATIC_POSITION Z=//p')
plr2_ok=false
if [ -n "$plr2_z" ] && python3 -c "import sys; sys.exit(0 if float('$plr2_z') > 6.0 else 1)" 2>/dev/null; then
    plr2_ok=true
fi

# Check NO early-layer gcode in PLR #2
plr2_last_g90=$(grep -n '^G90$' "$PLR_OUTDIR/testfile.gcode" | tail -1 | cut -d: -f1)
plr2_early=0
if [ -n "$plr2_last_g90" ]; then
    plr2_early=$(tail -n +"$((plr2_last_g90 + 1))" "$PLR_OUTDIR/testfile.gcode" | grep -cP '(Z[.]2|Z[.]4| Z1 | Z2 | Z2\.4| Z4 )' || true)
fi

if $plr1_ok && $plr2_ok && [ "$plr2_early" -eq 0 ]; then
    echo "PASS (PLR#1 Z=$plr1_z, PLR#2 Z=$plr2_z)"
    PASS=$((PASS + 1))
else
    echo "FAIL"
    echo "    PLR#1: Z=$plr1_z ok=$plr1_ok"
    echo "    PLR#2: Z=$plr2_z ok=$plr2_ok early_layers=$plr2_early"
    FAIL=$((FAIL + 1))
fi

# --------------------------------------------------------------------------
# Test 27: Triple PLR — Z=2.4, then Z=6.0, then Z=10.0 (all integer Zs).
# --------------------------------------------------------------------------
echo -n "  triple_plr_z2.4_z6.0_z10.0 ... "
echo "$BENCHY_GCODE" > "$GCODE_FILE"
cat > "$VARIABLES" << VARS
[Variables]
last_file = 'testfile.gcode'
filepath = '${GCODE_FILE}'
VARS
rm -f "$PLR_OUTDIR/testfile.gcode"

# PLR #1: Z=2.4
bash "$PLR_SH" "2.4" "testfile.gcode" >/dev/null 2>&1 || true
plr1_z=$(grep -v '^;' "$PLR_OUTDIR/testfile.gcode" | head -1 | sed -n 's/SET_KINEMATIC_POSITION Z=//p')

# PLR #2: Z=6.0
bash "$PLR_SH" "6.0" "testfile.gcode" >/dev/null 2>&1 || true
plr2_z=$(grep -v '^;' "$PLR_OUTDIR/testfile.gcode" | head -1 | sed -n 's/SET_KINEMATIC_POSITION Z=//p')

# PLR #3: Z=10.0
bash "$PLR_SH" "10.0" "testfile.gcode" >/dev/null 2>&1 || true
plr3_z=$(grep -v '^;' "$PLR_OUTDIR/testfile.gcode" | head -1 | sed -n 's/SET_KINEMATIC_POSITION Z=//p')

# Check PLR#3 has no early layers
plr3_last_g90=$(grep -n '^G90$' "$PLR_OUTDIR/testfile.gcode" | tail -1 | cut -d: -f1)
plr3_early=0
if [ -n "$plr3_last_g90" ]; then
    plr3_early=$(tail -n +"$((plr3_last_g90 + 1))" "$PLR_OUTDIR/testfile.gcode" | grep -cP '(Z[.]2|Z1 |Z2 |Z4 |Z6 |Z8 )' || true)
fi

all_ok=true
for z_pair in "1:$plr1_z:2.4" "2:$plr2_z:6.0" "3:$plr3_z:10.0"; do
    num=$(echo "$z_pair" | cut -d: -f1)
    got=$(echo "$z_pair" | cut -d: -f2)
    min=$(echo "$z_pair" | cut -d: -f3)
    if [ -z "$got" ] || ! python3 -c "import sys; sys.exit(0 if float('$got') > float('$min') else 1)" 2>/dev/null; then
        all_ok=false
    fi
done

if $all_ok && [ "$plr3_early" -eq 0 ]; then
    echo "PASS (PLR#1=$plr1_z PLR#2=$plr2_z PLR#3=$plr3_z)"
    PASS=$((PASS + 1))
else
    echo "FAIL"
    echo "    PLR#1=$plr1_z PLR#2=$plr2_z PLR#3=$plr3_z early_layers=$plr3_early"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
