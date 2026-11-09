#!/bin/bash
# ===========================================================================
#  Test: the macros that own last_file also own was_interrupted, so the two
#  cannot disagree after a cancel or a "Clear PLR State".
#
#  Reads the macro bodies out of plr.cfg; Klipper itself does not run here.
#
#  Run:  bash tests/test_was_interrupted_flag.sh
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLR_CFG="$(dirname "$SCRIPT_DIR")/plr.cfg"

PASS=0
FAIL=0

macro_body() {
    sed -n "/^\[gcode_macro $1\]/,/^\[/p" "$PLR_CFG"
}

check() {
    local test_name="$1" macro="$2" expected="$3"
    echo -n "  $test_name ... "
    if macro_body "$macro" | grep -qE "^\s*SAVE_VARIABLE VARIABLE=was_interrupted VALUE=$expected\s*$"; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL (no was_interrupted=$expected in $macro)"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== was_interrupted flag tests ==="
check "save_last_file_sets_flag" save_last_file True
check "clear_last_file_clears_flag" clear_last_file False

echo -n "  recovery_run_leaves_flag_alone ... "
# save_last_file's /plr/ branch keeps the saved path for a second power loss;
# the flag has to stay set with it, so it is only written in the else branch.
if macro_body save_last_file | sed -n '/{% if .\/plr\/. in filepath %}/,/{% else %}/p' | grep -q was_interrupted; then
    echo "FAIL (flag written in the /plr/ branch)"
    FAIL=$((FAIL + 1))
else
    echo "PASS"
    PASS=$((PASS + 1))
fi

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
