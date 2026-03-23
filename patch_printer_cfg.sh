#!/bin/bash
# ===========================================================================
#  patch_printer_cfg.sh — Inject clear_last_file into CANCEL_PRINT / PRINT_END
#
#  Scans a Klipper printer.cfg for [gcode_macro CANCEL_PRINT] and
#  [gcode_macro PRINT_END].  If a macro exists and does NOT already call
#  clear_last_file, the following block is inserted right after the
#  "gcode:" (or "gcode =") directive:
#
#      # Clear Power Loss Recovery state to prevent false prompts on restart, if PLR is installed
#      {% if "gcode_macro clear_last_file" in printer %}
#          clear_last_file
#      {% endif %}
#
#  Usage:  bash patch_printer_cfg.sh /path/to/printer.cfg
#  Exit 0 on success (even if nothing was patched).
# ===========================================================================
set -euo pipefail

PRINTER_CFG="${1:?Usage: patch_printer_cfg.sh <path-to-printer.cfg>}"

if [ ! -f "$PRINTER_CFG" ]; then
    echo "Error: File not found: $PRINTER_CFG" >&2
    exit 1
fi

# -------------------------------------------------------------------
# patch_macro  <file>  <MACRO_NAME>
#   Returns 0 if the macro was patched, 1 if skipped.
# -------------------------------------------------------------------
patch_macro() {
    local file="$1"
    local macro_name="$2"

    # 1. Locate section header
    local header_line
    header_line=$(grep -n "^\[gcode_macro ${macro_name}\]" "$file" \
                  | head -1 | cut -d: -f1) || true

    if [ -z "$header_line" ]; then
        echo "  [SKIP] [gcode_macro ${macro_name}] not found."
        return 1
    fi

    # 2. Find where this section ends (next [section] header or EOF)
    local total_lines
    total_lines=$(awk 'END{print NR}' "$file")

    local next_offset
    next_offset=$(tail -n +"$((header_line + 1))" "$file" \
                  | grep -n '^\[' | head -1 | cut -d: -f1) || true

    local end_line
    if [ -z "$next_offset" ]; then
        end_line=$total_lines
    else
        end_line=$((header_line + next_offset - 1))
    fi

    # 3. Already patched?
    if sed -n "${header_line},${end_line}p" "$file" | grep -qi "clear_last_file"; then
        echo "  [SKIP] [gcode_macro ${macro_name}] already contains clear_last_file."
        return 1
    fi

    # 4. Find the "gcode:" / "gcode =" line inside this section
    local gcode_offset
    gcode_offset=$(sed -n "${header_line},${end_line}p" "$file" \
                   | grep -n '^gcode[[:space:]]*[:=]' | head -1 | cut -d: -f1) || true

    if [ -z "$gcode_offset" ]; then
        echo "  [SKIP] [gcode_macro ${macro_name}] has no gcode directive."
        return 1
    fi

    local abs_gcode_line=$((header_line + gcode_offset - 1))

    # 5. Build patched file
    local tmp
    tmp=$(mktemp)

    {
        head -n "$abs_gcode_line" "$file"
        printf '%s\n' \
            '    # Clear Power Loss Recovery state to prevent false prompts on restart, if PLR is installed' \
            '    {% if "gcode_macro clear_last_file" in printer %}' \
            '        clear_last_file' \
            '    {% endif %}' \
            ''
        tail -n +"$((abs_gcode_line + 1))" "$file"
    } > "$tmp"

    mv "$tmp" "$file"

    echo "  [OK] Patched [gcode_macro ${macro_name}]."
    return 0
}

# -------------------------------------------------------------------
echo "Patching ${PRINTER_CFG} ..."

patched=0
for macro in CANCEL_PRINT PRINT_END; do
    if patch_macro "$PRINTER_CFG" "$macro"; then
        patched=$((patched + 1))
    fi
done

echo "Done. ${patched} macro(s) patched."
