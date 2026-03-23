#!/bin/bash

OWNER=""

# Get the path & user from env
if [ -n "$SUDO_USER" ]; then
    echo "Script executed with sudo — real user is $SUDO_USER"
    if [ "$SUDO_USER" = "runner" ]; then
        USER_HOME="/home/pi"
        OWNER="pi"
    else
        USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        OWNER="$SUDO_USER"
    fi
else
    USER_HOME=$(getent passwd "$USER" | cut -d: -f6)
    OWNER="$USER"
    echo "Script executed without sudo — user is $USER"
fi

echo "User's home directory: $USER_HOME"
echo "Owner for chown: $OWNER"

# Define the Klipper directory using USER_HOME instead of HOME
KLIPPER_DIR="$USER_HOME/klipper"
echo "Klipper directory: $KLIPPER_DIR"

# Define the project directory
PROJECT_DIR="$PWD"
echo "Project directory: $PROJECT_DIR"

# Prompt for printer.cfg path (skip prompt if non-interactive, e.g. moonraker update_manager)
DEFAULT_PRINTER_CFG="$USER_HOME/printer_data/config/printer.cfg"
if [ -t 0 ]; then
    echo ""
    read -rp "Path to printer.cfg [$DEFAULT_PRINTER_CFG]: " USER_PRINTER_CFG
    PRINTER_CFG="${USER_PRINTER_CFG:-$DEFAULT_PRINTER_CFG}"
else
    PRINTER_CFG="$DEFAULT_PRINTER_CFG"
fi

# Derive directories from the chosen printer.cfg path
CONFIG_DIR="$(dirname "$PRINTER_CFG")"
PRINTER_DATA_DIR="$(dirname "$CONFIG_DIR")"

echo "printer.cfg:          $PRINTER_CFG"
echo "Config directory:     $CONFIG_DIR"
echo "Printer data directory: $PRINTER_DATA_DIR"

# Validate that the config directory exists (or can be created)
if [ ! -d "$CONFIG_DIR" ]; then
    echo "Config directory does not exist, creating: $CONFIG_DIR"
    mkdir -p "$CONFIG_DIR"
fi

# Create the variables.cfg file in the config directory, if it doesn't exist
if [ ! -f "$CONFIG_DIR/variables.cfg" ]; then
  touch "$CONFIG_DIR/variables.cfg" && echo "variables.cfg created successfully." || echo "Error creating variables.cfg."
fi

# Copy the project files to the config directory
cp -f $PROJECT_DIR/plr.cfg "$CONFIG_DIR/" && echo "plr.cfg copied successfully." || echo "Error copying plr.cfg."
# Auto replace path
sed -i -E "s|\{USER_HOME\}|$USER_HOME|i" "$CONFIG_DIR/plr.cfg"
sed -i -E "s|\{PLR_DIR\}|$PRINTER_DATA_DIR/plr|i" "$CONFIG_DIR/plr.cfg"

cp -f $PROJECT_DIR/gcode_shell_command.py $KLIPPER_DIR/klippy/extras/ && echo "gcode_shell_command.py copied successfully." || echo "Error copying gcode_shell_command.py."

# Use rsync to copy, overwriting existing files and create the folder if it does not exist
rsync $PROJECT_DIR/plr.sh "$PRINTER_DATA_DIR/plr/" && echo "plr.sh copied successfully." || echo "Error copying plr.sh."
rsync $PROJECT_DIR/clear_plr.sh "$PRINTER_DATA_DIR/plr/" && echo "clear_plr.sh copied successfully." || echo "Error copying clear_plr.sh."
# Auto replace path
sed -i -E "s|\{USER_HOME\}|$USER_HOME|i" "$PRINTER_DATA_DIR/plr/plr.sh"
sed -i -E "s|\{USER_HOME\}|$USER_HOME|i" "$PRINTER_DATA_DIR/plr/clear_plr.sh"
# Make plr.sh & clear_plr.sh executable
chmod +x "$PRINTER_DATA_DIR/plr/plr.sh" && echo "plr.sh made executable." || echo "Error making plr.sh executable."
chmod +x "$PRINTER_DATA_DIR/plr/clear_plr.sh" && echo "clear_plr.sh made executable." || echo "Error making clear_plr.sh executable."

# Check if printer.cfg exists, create it if it doesn't
if [ ! -f "$PRINTER_CFG" ]; then
    touch "$PRINTER_CFG" && echo "printer.cfg created successfully." || echo "Error creating printer.cfg."
fi

# Check if the file exists
if [ ! -f "$PRINTER_CFG" ]; then
  echo "Error: $PRINTER_CFG does not exist."
fi

# Check if the string is already present in the file
if grep -Fxq '[include plr.cfg]' "$PRINTER_CFG"; then
    echo "The string [include plr.cfg] is already present in the file."
else
    # Create a temporary file
    temp_file=$(mktemp)

    # Add the line [include plr.cfg] at the beginning of the file
    echo "[include plr.cfg]" > "$temp_file"
    cat "$PRINTER_CFG" >> "$temp_file"

    # Replace the original file with the temporary file
    mv "$temp_file" "$PRINTER_CFG"

    # Check if the string was added successfully
    if grep -q '[include plr.cfg]' "$PRINTER_CFG"; then
        echo "The string [include plr.cfg] was successfully added."
    else
        echo "Error: the string [include plr.cfg] was not added."
    fi
fi

# Patch CANCEL_PRINT and PRINT_END macros to call clear_last_file
echo "Checking CANCEL_PRINT / PRINT_END macros for PLR clear_last_file call..."
bash "$PROJECT_DIR/patch_printer_cfg.sh" "$PRINTER_CFG"

# Check if the variables.cfg file exists
if [ ! -f "$CONFIG_DIR/variables.cfg" ]; then
  echo "The file $CONFIG_DIR/variables.cfg does not exist. Creating..."
  touch "$CONFIG_DIR/variables.cfg"

  if [ -f "$CONFIG_DIR/variables.cfg" ]; then
    echo "The file $CONFIG_DIR/variables.cfg was created successfully."
  else
    echo "Error: Creating the file $CONFIG_DIR/variables.cfg failed."
  fi
else
  echo "The file $CONFIG_DIR/variables.cfg already exists."
fi

# Check if the moonraker.conf file exists
if [ ! -f "$CONFIG_DIR/moonraker.conf" ]; then
    echo "The file moonraker.conf does not exist, creating the file..."
    touch "$CONFIG_DIR/moonraker.conf"
fi

# Check if the string [include update_plr.cfg] is already present in the file
if grep -Fxq "[include update_plr.cfg]" "$CONFIG_DIR/moonraker.conf"; then
    echo "The string [include update_plr.cfg] is already present in the file moonraker.conf."
else
    echo "Adding the string [include update_plr.cfg] to the file moonraker.conf..."
    temp_file=$(mktemp)
    echo "[include update_plr.cfg]" > "$temp_file"
    cat "$CONFIG_DIR/moonraker.conf" >> "$temp_file"
    mv "$temp_file" "$CONFIG_DIR/moonraker.conf"
fi

# Check if the update_plr.cfg file exists
if [ -f "$CONFIG_DIR/update_plr.cfg" ]; then
    echo "The file update_plr.cfg already exists, deleting the file..."
    rm "$CONFIG_DIR/update_plr.cfg"
fi

# Create a new update_plr.cfg file
echo "Creating a new update_plr.cfg file..."
cat > "$CONFIG_DIR/update_plr.cfg" << EOF
# plr-klipper update_manager entry
[update_manager KlipperPLR]
type: git_repo
path: ~/KlipperPLR
origin: https://github.com/bigtreetech/KlipperPLR.git
primary_branch: main
install_script: install.sh
is_system_service: False

EOF

# Fix ownership if running under sudo
if [ -n "$SUDO_USER" ]; then
    echo "Fixing ownership for $OWNER..."
    chown -R "$OWNER":"$OWNER" "$CONFIG_DIR/"
    chown -R "$OWNER":"$OWNER" "$PRINTER_DATA_DIR/plr/"
    echo "Ownership fixed."
fi

echo "Installation complete"
