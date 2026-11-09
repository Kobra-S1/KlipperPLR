#!/bin/bash
# ===========================================================================
#  Test: plr.sh rebuilds from the path RESUME_INTERRUPTED hands it, wherever
#  [save_variables] keeps its file. A setup can point that section elsewhere
#  (ACE Pro configs use saved_variables.cfg), so the variables file is never
#  read; a print from a subfolder has to recover all the same.
#
#  Run:  bash tests/test_plr_file_path.sh
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PLR_OUTDIR="$TMPDIR/printer_data/gcodes/plr"
GCODE_DIR="$TMPDIR/printer_data/gcodes"
mkdir -p "$PLR_OUTDIR" "$GCODE_DIR/sub dir" "$TMPDIR/printer_data/config"

PLR_SH="$TMPDIR/plr.sh"
sed "s|{USER_HOME}|${TMPDIR}|g" "$REPO_DIR/plr.sh" > "$PLR_SH"

PASS=0
FAIL=0

write_gcode() {
    printf 'G1 X10 Z1.0 E1\nG1 X20 Z2.0 E2\nG1 X30 Z3.0 E3\n' > "$1"
}

check_recovered() {
    local test_name="$1" output="$PLR_OUTDIR/$2"
    echo -n "  $test_name ... "
    if [ -f "$output" ] && grep -qE '^SET_KINEMATIC_POSITION Z=3(\.0)?$' "$output"; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL (no recovery file resuming at Z=3 in $output)"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== PLR file path tests ==="

write_gcode "$GCODE_DIR/sub dir/nested.gcode"
bash "$PLR_SH" "2.0" "nested.gcode" "$GCODE_DIR/sub dir/nested.gcode" >/dev/null 2>&1 || true
check_recovered "subfolder_path_with_space" "nested.gcode"

write_gcode "$GCODE_DIR/rooted.gcode"
bash "$PLR_SH" "2.0" "rooted.gcode" >/dev/null 2>&1 || true
check_recovered "no_path_means_gcodes_root" "rooted.gcode"

write_gcode "$GCODE_DIR/empty_path.gcode"
bash "$PLR_SH" "2.0" "empty_path.gcode" "" >/dev/null 2>&1 || true
check_recovered "empty_path_means_gcodes_root" "empty_path.gcode"

# A file left over from another [save_variables] location names another job.
write_gcode "$GCODE_DIR/sub dir/current.gcode"
cat > "$TMPDIR/printer_data/config/variables.cfg" << VARS
[Variables]
last_file = 'stale.gcode'
filepath = '$GCODE_DIR/stale.gcode'
VARS
bash "$PLR_SH" "2.0" "current.gcode" "$GCODE_DIR/sub dir/current.gcode" >/dev/null 2>&1 || true
check_recovered "stale_variables_file_ignored" "current.gcode"

echo -n "  macro_passes_saved_path ... "
if grep -qE 'RUN_SHELL_COMMAND CMD=POWER_LOSS_RESUME PARAMS=.*\{filepath\}' "$REPO_DIR/plr.cfg"; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL (RESUME_INTERRUPTED does not pass {filepath})"
    FAIL=$((FAIL + 1))
fi

# Renders the macro as Klipper does, with undefined names raising.
echo -n "  macro_renders_with_and_without_gcode_file ... "
if python3 - "$REPO_DIR/plr.cfg" << 'PY_RENDER'
import sys

import jinja2

section = open(sys.argv[1]).read().split("[gcode_macro RESUME_INTERRUPTED]")[1].split("\n[")[0]
template = jinja2.Environment("{%", "%}", "{", "}", undefined=jinja2.StrictUndefined).from_string(
    section.split("=", 1)[1]
)


def rendered_command(params, variables):
    printer = {"save_variables": {"variables": {"power_resume_z": 2.0, **variables}}}
    text = template.render(printer=printer, params=params)
    return next(line.strip() for line in text.splitlines() if "POWER_LOSS_RESUME" in line)


saved = {"last_file": "a b.gcode", "filepath": "/g/sub/a b.gcode"}
assert '2.0 \\"a b.gcode\\" \\"/g/sub/a b.gcode\\"' in rendered_command({}, saved)
assert '2.0 \\"other.gcode\\" \\"\\"' in rendered_command({"GCODE_FILE": "other.gcode"}, saved)
assert '2.0 \\"a.gcode\\" \\"\\"' in rendered_command({}, {"last_file": "a.gcode"})
PY_RENDER
then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL (RESUME_INTERRUPTED did not render; needs python3-jinja2)"
    FAIL=$((FAIL + 1))
fi

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
