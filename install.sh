#!/bin/bash
# install.sh - Install voicemail MQTT handler for FreePBX/Asterisk
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HANDLER_DEST="/usr/local/bin/voicemail-handler.sh"
CONFIG_DEST="/etc/asterisk/voicemail-handler.conf"
VM_CONF="/etc/asterisk/voicemail_custom.conf"

# Check root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo $0)"
    exit 1
fi

echo "=== FreePBX Voicemail MQTT Handler - Install ==="
echo ""

# 0. Check dependency
echo "[0/3] Checking dependencies..."
if ! command -v mosquitto_pub &>/dev/null; then
    echo "  mosquitto_pub not found. Installing mosquitto-clients..."
    apt-get update -qq && apt-get install -y -qq mosquitto-clients
    echo "  mosquitto-clients installed"
else
    echo "  mosquitto_pub found"
fi

# 1. Install handler script
echo "[1/3] Installing handler script -> ${HANDLER_DEST}"
cp "${SCRIPT_DIR}/voicemail-handler.sh" "$HANDLER_DEST"
chmod 755 "$HANDLER_DEST"
chown root:root "$HANDLER_DEST"

# 2. Install config (don't overwrite existing)
echo "[2/3] Installing config -> ${CONFIG_DEST}"
if [[ -f "$CONFIG_DEST" ]]; then
    echo "  Config already exists, skipping (keeping your settings)"
    echo "  New config saved as ${CONFIG_DEST}.new for reference"
    cp "${SCRIPT_DIR}/voicemail-handler.conf" "${CONFIG_DEST}.new"
else
    cp "${SCRIPT_DIR}/voicemail-handler.conf" "$CONFIG_DEST"
    chmod 640 "$CONFIG_DEST"
    chown root:asterisk "$CONFIG_DEST"
fi

# 3. Configure externnotify in voicemail_custom.conf
echo "[3/3] Configuring externnotify in ${VM_CONF}"

if [[ ! -f "$VM_CONF" ]]; then
    echo "  Creating ${VM_CONF}"
    cat > "$VM_CONF" <<EOF
[general]
externnotify=${HANDLER_DEST}
EOF
    chown asterisk:asterisk "$VM_CONF"
    echo "  externnotify configured"
elif grep -q "^externnotify=" "$VM_CONF"; then
    CURRENT=$(grep "^externnotify=" "$VM_CONF" | head -1)
    if [[ "$CURRENT" == "externnotify=${HANDLER_DEST}" ]]; then
        echo "  externnotify already configured correctly"
    else
        echo "  WARNING: externnotify already set to something else:"
        echo "    ${CURRENT}"
        echo "  To use this handler, change it to:"
        echo "    externnotify=${HANDLER_DEST}"
    fi
elif grep -q "^\[general\]" "$VM_CONF"; then
    sed -i "/^\[general\]/a externnotify=${HANDLER_DEST}" "$VM_CONF"
    echo "  externnotify added to existing [general] section"
else
    echo "" >> "$VM_CONF"
    echo "[general]" >> "$VM_CONF"
    echo "externnotify=${HANDLER_DEST}" >> "$VM_CONF"
    echo "  [general] section with externnotify added"
fi

echo ""
echo "=== Installation complete ==="
echo ""
echo "Next steps:"
echo "  1. Reload Asterisk: asterisk -rx 'voicemail reload'"
echo "  2. Test: leave a voicemail and check: journalctl -t voicemail-handler"
echo "  3. Subscribe to MQTT to verify: mosquitto_sub -h mqtt.mrz.ip -t 'freepbx/voicemail/#'"
echo ""
