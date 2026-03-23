# PLR Klipper (Anycubic Kobra / ACEPRO Edition)

KlipperPLR(forked from [YUMI_PLR](https://github.com/Yumi-Lab/YUMI_PLR/)) is a simple print recovery system for Klipper, a 3D printer firmware. It allows you to resume prints after a power loss or other types of MCU disconnection interruption. Please note there is no guarantee that it will work in 100% of cases because the Z-axis must not have moved, so do not touch the machine in case of a power cut.

This fork of PLR Klipper has been adapted and bugfixed to be compatible with the Anycubic Kobra & ACEPRO devices (if they run my Kobra-S1 vanilla-klipper fork (https://github.com/Kobra-S1/klipper-kobra-s1/tree/Kobra-S1-Dev) and ACEPRO driver fork (https://github.com/Kobra-S1/ACEPRO/tree/dev))

Make sure to have the latest configuration files for vanilla-klipper in place, as they have slight adaption to better incoporate with KlipperPLR at print cancelation.

## Prerequisites
having already installed Klipper, Moonraker, and Mainsail (you can use Kiauh, but use the Kobra-S1 dev branch for klipper).

To install KlipperPLR Klipper, follow the steps below:

## Installation
* Clone the Kobra-S1 KlipperPLR Klipperrepository from GitHub to your local machine:
    ```bash
    git clone https://github.com/Kobra-S1/KlipperPLR.git
    cd KlipperPLR
    ./install.sh
    ```

The installer will prompt you for the path to your `printer.cfg` (defaults to `~/printer_data/config/printer.cfg` — press Enter to accept, or type a custom path). It then automatically:
- Adds `[include plr.cfg]` to the top of your `printer.cfg`.
- Patches your `CANCEL_PRINT` and/or `PRINT_END` macros (if they exist) to call `clear_last_file` on cancel/end, so PLR state is cleared and no false recovery prompt appears on the next restart. Already-patched macros are skipped (safe to re-run).

When run non-interactively (e.g. via Moonraker's `update_manager`), the default path is used automatically without prompting.

* start-gcode add in your slicer:
    ```bash
    G31
    save_last_file
    SAVE_VARIABLE VARIABLE=was_interrupted VALUE=True
    ```

* end-gcode add in your slicer:
    ```bash
    SAVE_VARIABLE VARIABLE=was_interrupted VALUE=False
    clear_last_file
    G31
    ```
* Before layer change G-gcode add in your slicer:
    ```bash
    LOG_Z
    ```
* To resume printing after a power cut, this fork will show you a dialog to query if you want to continue the print or not. You can also simply execute the 'RESUME_INTERRUPTED' macro in the MAINSAIL console or via the Macro button on the MAINSAIL dashboard.

## How It Works

### Recording
Before each layer change, the `LOG_Z` macro saves the current Z height, extruder temperature, bed temperature, fan speed, and active tool to `variables.cfg`. The slicer start-gcode marks the print as "interrupted" via `SAVE_VARIABLE`, and the end-gcode clears that flag.

### Detection
On Klipper startup, a `CHECK_PLR_STATE` delayed gcode checks if `was_interrupted` is still `True`. If so — and the printer is in `Idle`/`Ready` state — it shows a prompt to resume.

### Recovery
When `RESUME_INTERRUPTED` is triggered:
1. Bed and extruder are heated to the saved temperatures, fan speed is restored.
2. `plr.sh` generates a recovery gcode file from the original file:
   - Extracts thumbnail blocks for preview in Mainsail/KlipperScreen.
   - Finds the last logged Z height in the original gcode, replays from that layer onward.
   - Prepends `SET_KINEMATIC_POSITION Z=...` so Klipper knows the nozzle position without homing Z.
   - Lifts Z by 10mm, homes X/Y, primes the nozzle (with tool restore if multi-material), then lowers back.
3. Klipper prints the recovery file via `SDCARD_PRINT_FILE`.

### Limitations
- **Z must not move during power loss.** If the Z axis drops (e.g. belt-driven Z without a brake), the nozzle height will be wrong and the print will fail.
- **The interrupted layer bonds weakly.** The part cools to room temperature during recovery. The replayed layer re-traces already-printed paths to fill gaps, but hot-to-cold adhesion is inherently weaker than normal layer-to-layer bonding.
- **No X/Y position recovery.** The exact X/Y position at the moment of failure is not saved. Recovery resumes from the start of the interrupted layer.
- **Single power loss per layer.** `LOG_Z` runs before each layer change, so only the last completed layer change is recorded. A failure between two `LOG_Z` calls replays from the earlier one.

## Known Bugs:
None




