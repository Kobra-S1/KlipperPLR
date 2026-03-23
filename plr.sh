#!/bin/bash
mkdir -p {USER_HOME}/printer_data/gcodes/plr/

filepath=$(sed -n "s/.*filepath *= *'\([^']*\)'.*/\1/p" {USER_HOME}/printer_data/config/variables.cfg)
filepath=$(printf "$filepath")

last_file=$(sed -n "s/.*last_file *= *'\([^']*\)'.*/\1/p" {USER_HOME}/printer_data/config/variables.cfg)
last_file=$(printf "$last_file")

# Fallback to macro parameter if variables.cfg extraction fails or is empty
if [ -z "$last_file" ] && [ -n "$2" ]; then
    last_file="$2"
    filepath="{USER_HOME}/printer_data/gcodes/${last_file}"
fi

echo "$last_file"
plr=$last_file
echo "plr=$plr"
PLR_PATH={USER_HOME}/printer_data/gcodes/plr/

# Build a sed-compatible regex pattern for the Z height that handles format
# variations between Klipper's float representation and slicer gcode output:
#
#   Klipper LOG_Z    Slicer gcode    Issue
#   ─────────────    ────────────    ─────
#   6.0              Z6              OrcaSlicer omits trailing ".0"
#   0.2              Z.2             OrcaSlicer omits leading "0"
#   2.4              Z2.4            Normal case (no mismatch)
#
# We also escape dots so "Z5.8" doesn't match "Z5s8" in base64 thumbnails.
build_z_pattern() {
    local z_val="$1"
    local int_part="${z_val%%.*}"
    local dec_part="${z_val#*.}"

    # Trailing zeros after the last significant digit are optional in gcode.
    # E.g. Klipper reports 5.4 but gcode may have Z5.400.  We append 0* to
    # allow any number of trailing zeros.
    if [ "$dec_part" = "0" ]; then
        # Integer Z (e.g. 6.0): match "Z6.0", "Z6.00", or "Z6" (not Z60, Z6.2)
        echo "Z${int_part}"'\(\.0\+\)\{0,1\}\([^0-9.]\|$\)'
    elif [ "$int_part" = "0" ]; then
        # Sub-1.0 Z (e.g. 0.2): match "Z0.2", "Z0.200", or "Z.2" (not Z0.20x)
        local dec_esc="${dec_part//./\\.}"
        echo "Z0\{0,1\}\.${dec_esc}0*"'\([^0-9]\|$\)'
    else
        # Normal (e.g. 2.4): match "Z2.4", "Z2.400" (not Z2.44)
        local z_esc="${z_val//./\\.}"
        echo "Z${z_esc}0*"'\([^0-9]\|$\)'
    fi
}

Z_PAT=$(build_z_pattern "$1")

cat "${filepath}" > {USER_HOME}/plrtmpA.$$

# Normalise Windows line endings (\r\n → \n).  Slicers on Windows (OrcaSlicer,
# PrusaSlicer, Cura) commonly produce \r\n.  A stray \r would silently corrupt
# extracted values such as "G92 E3.0\r", causing Klipper parse errors.
sed -i 's/\r$//' {USER_HOME}/plrtmpA.$$

# Preserve slicer thumbnail block(s) so Mainsail/Fluidd can show a preview image
# for the recovery file.
sed -n '/^; thumbnail begin/,/^; thumbnail end/p' {USER_HOME}/plrtmpA.$$ > ${PLR_PATH}/"${plr}"

# Strip the file up to the exact failed Z height, output SET_KINEMATIC_POSITION.
# Anchor to non-comment lines (^[^;]) so embedded PNG/thumbnail lines are ignored.
# Then filter remaining comment lines before searching for the first real Z move.
cat {USER_HOME}/plrtmpA.$$ \
  | sed -e '1,/^[^;].*'"${Z_PAT}"'/ d' \
  | grep -v '^;' \
  | sed -ne '/ Z/,$ p' \
  | grep -m 1 ' Z' \
  | sed -ne 's/.* Z\([^ ]*\).*/SET_KINEMATIC_POSITION Z=\1/p' \
  >> ${PLR_PATH}/"${plr}"

echo 'M118 Resuming print movements...' >> ${PLR_PATH}/"${plr}"

# Find last Extruder position safely.
# We need the E value just BEFORE the replay start point (last Z_PAT match),
# so the extruder position matches what the slicer expected at that point.
BG_EX=$(tac {USER_HOME}/plrtmpA.$$ | sed -ne '/^[^;].*'"${Z_PAT}"'/,$ p' | tail -n+2 | grep -v '^;' | grep -m1 ' E[0-9]' | sed -ne 's/.* E\([^ ]*\)/G92 E\1/p')
if [ "${BG_EX}" = "" ]; then
  BG_EX=$(cat {USER_HOME}/plrtmpA.$$ | sed '/^[^;].*'"${Z_PAT}"'/q' | grep -v '^;' | tac | grep -m1 ' E[0-9]' | sed -ne 's/.* E\([^ ]*\)/G92 E\1/p')
fi
M83=$(cat {USER_HOME}/plrtmpA.$$ | sed '/^[^;].*'"${Z_PAT}"'/q' | sed -ne '/\(M83\)/p')

# Movement commands to prepare for homing while detaching from part
echo 'G91' >> ${PLR_PATH}/"${plr}"
echo 'G1 Z10' >> ${PLR_PATH}/"${plr}"
echo 'G90' >> ${PLR_PATH}/"${plr}"

# Home X and Y
echo 'G28 X Y' >> ${PLR_PATH}/"${plr}"

# Find last used Tool before the failure
LAST_TOOL=$(cat {USER_HOME}/plrtmpA.$$ | sed -e '/^[^;].*'"${Z_PAT}"'/q' | grep -Eo '^T[0-9]+' | tail -n 1 | tr -d 'T')

# Execute custom priming macro while safely homed and away from the print, passing the active tool
if [ -n "$LAST_TOOL" ]; then
    echo "_PLR_PRIME_NOZZLE T=${LAST_TOOL}" >> ${PLR_PATH}/"${plr}"
else
    echo "_PLR_PRIME_NOZZLE" >> ${PLR_PATH}/"${plr}"
fi

# NOW restore the expected Extruder E-position for the failed layer BEFORE moving back!
if [ -n "${M83}" ]; then
  echo 'G92 E0' >> ${PLR_PATH}/"${plr}"
  echo ${M83} >> ${PLR_PATH}/"${plr}"
else
  echo ${BG_EX} >> ${PLR_PATH}/"${plr}"
fi

# Lower Z back to a safe travel height above the part
echo 'G91' >> ${PLR_PATH}/"${plr}"
echo 'G1 Z-5' >> ${PLR_PATH}/"${plr}"
echo 'G90' >> ${PLR_PATH}/"${plr}"

# Replay from the interrupted Z layer.  Previous code skipped the entire
# layer that was printing when power failed, causing the resume layer to bond
# poorly to a partially-printed surface.  By including the Z_PAT line and
# everything after it, the nozzle re-traces already-printed paths (harmless —
# adds material on top) and fills in the missing parts of the interrupted layer.
tac {USER_HOME}/plrtmpA.$$ | sed -e '/^[^;].*'"${Z_PAT}"'/q' | tac | sed -ne '/ Z/,$ p' >> ${PLR_PATH}/"${plr}"

rm {USER_HOME}/plrtmpA.$$

# Ask Moonraker to scan the recovery file metadata now, so the thumbnail is
# available to KlipperScreen before SDCARD_PRINT_FILE starts.  Without this,
# KlipperScreen shows no preview because inotify-based scanning hasn't finished.
curl -s "http://localhost:7125/server/files/metadata?filename=plr/${plr}" > /dev/null 2>&1 || true
