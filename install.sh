#!/bin/bash
# install.sh - Install voicemail MQTT handler for FreePBX/Asterisk
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HANDLER_SRC="${SCRIPT_DIR}/voicemail-handler.sh"
CONF_SRC="${SCRIPT_DIR}/voicemail-handler.conf"
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

# ── Phase 0: Verify Asterisk environment ──────────────────────────

echo "[0/4] Verifying Asterisk environment..."

# Check Asterisk binary
if ! command -v asterisk &>/dev/null; then
    echo "  ERROR: Asterisk not found. Is Asterisk installed?"
    echo "  Looked for: asterisk in PATH"
    exit 1
fi
AST_BIN=$(command -v asterisk)
echo "  Asterisk binary: ${AST_BIN}"

# Get Asterisk version
AST_VERSION=$(asterisk -V 2>/dev/null || true)
if [[ -z "$AST_VERSION" ]]; then
    echo "  WARNING: Could not determine Asterisk version"
else
    echo "  Version: ${AST_VERSION}"
fi

# Check /etc/asterisk/ exists
if [[ ! -d /etc/asterisk ]]; then
    echo "  ERROR: /etc/asterisk/ not found. Non-standard Asterisk installation?"
    exit 1
fi
echo "  Config dir: /etc/asterisk/ exists"

# Check voicemail spool directory
VM_SPOOL="/var/spool/asterisk/voicemail"
if [[ ! -d "$VM_SPOOL" ]]; then
    echo "  WARNING: ${VM_SPOOL} not found"
    echo "  This directory is created when the first mailbox is configured."
    echo "  Make sure app_voicemail is loaded and mailboxes are configured."
else
    echo "  Voicemail spool: ${VM_SPOOL} exists"
fi

# Check app_voicemail module
if asterisk -rx 'core waitfullybooted' &>/dev/null; then
    VM_MODULE=$(asterisk -rx 'module show like app_voicemail' 2>/dev/null || true)
    if echo "$VM_MODULE" | grep -q "app_voicemail"; then
        echo "  Module: app_voicemail loaded"
    else
        echo "  WARNING: app_voicemail module not loaded!"
        echo "  externnotify will not work without it."
        echo "  Try: asterisk -rx 'module load app_voicemail.so'"
    fi
else
    echo "  WARNING: Asterisk not running - skipping module check"
    echo "  Verify app_voicemail is loaded after starting Asterisk"
fi

# Detect FreePBX
FREEPBX_DETECTED=false
if [[ -d /var/www/html/admin ]] || command -v fwconsole &>/dev/null; then
    FREEPBX_DETECTED=true
    FWCONSOLE_VER=""
    if command -v fwconsole &>/dev/null; then
        FWCONSOLE_VER=$(fwconsole --version 2>/dev/null || true)
    fi
    echo "  FreePBX detected${FWCONSOLE_VER:+ (${FWCONSOLE_VER})}"
    echo "  Using voicemail_custom.conf (FreePBX-safe)"
else
    echo "  FreePBX not detected (vanilla Asterisk)"
    echo "  Using voicemail_custom.conf (safe for both)"
fi

# Check source files exist
if [[ ! -f "$HANDLER_SRC" ]]; then
    echo "  ERROR: Source file not found: ${HANDLER_SRC}"
    exit 1
fi
if [[ ! -f "$CONF_SRC" ]]; then
    echo "  ERROR: Source file not found: ${CONF_SRC}"
    exit 1
fi

echo ""

# ── Phase 1: Check dependencies ──────────────────────────────────

echo "[1/4] Checking dependencies..."
NEED_MOSQUITTO=false
if ! command -v mosquitto_pub &>/dev/null; then
    NEED_MOSQUITTO=true
    echo "  mosquitto_pub not found - will be installed"
else
    echo "  mosquitto_pub found"
fi

echo ""

# ── Phase 2: Preview all planned changes ──────────────────────────

echo "============================================"
echo "  Planned changes (nothing applied yet)"
echo "============================================"
echo ""

CHANGES=0

# --- Handler script ---
echo "--- ${HANDLER_DEST} ---"
if [[ -f "$HANDLER_DEST" ]]; then
    if diff -q "$HANDLER_SRC" "$HANDLER_DEST" &>/dev/null; then
        echo "  [SKIP] Already up to date"
    else
        echo "  [UPDATE] File exists, will be overwritten"
        echo ""
        diff -u "$HANDLER_DEST" "$HANDLER_SRC" --label "current: ${HANDLER_DEST}" --label "new: ${HANDLER_SRC}" || true
        CHANGES=$((CHANGES + 1))
    fi
else
    echo "  [NEW] File does not exist, will be created"
    echo ""
    diff -u /dev/null "$HANDLER_SRC" --label "(does not exist)" --label "new: ${HANDLER_DEST}" || true
    CHANGES=$((CHANGES + 1))
fi
echo ""

# --- Config file ---
echo "--- ${CONFIG_DEST} ---"
if [[ -f "$CONFIG_DEST" ]]; then
    if diff -q "$CONF_SRC" "$CONFIG_DEST" &>/dev/null; then
        echo "  [SKIP] Already up to date"
    else
        echo "  [KEEP] Config exists with your settings (not overwritten)"
        echo "  A copy of the new default will be saved as ${CONFIG_DEST}.new"
        echo ""
        diff -u "$CONFIG_DEST" "$CONF_SRC" --label "current: ${CONFIG_DEST}" --label "new default: ${CONF_SRC}" || true
        CHANGES=$((CHANGES + 1))
    fi
else
    echo "  [NEW] File does not exist, will be created"
    echo ""
    diff -u /dev/null "$CONF_SRC" --label "(does not exist)" --label "new: ${CONFIG_DEST}" || true
    CHANGES=$((CHANGES + 1))
fi
echo ""

# --- voicemail_custom.conf ---
echo "--- ${VM_CONF} ---"
if [[ ! -f "$VM_CONF" ]]; then
    echo "  [NEW] File does not exist, will be created with:"
    echo ""
    echo "  +[general]"
    echo "  +externnotify=${HANDLER_DEST}"
    CHANGES=$((CHANGES + 1))
elif grep -q "^externnotify=${HANDLER_DEST}$" "$VM_CONF"; then
    echo "  [SKIP] externnotify already configured correctly"
elif grep -q "^externnotify=" "$VM_CONF"; then
    CURRENT=$(grep "^externnotify=" "$VM_CONF" | head -1)
    echo "  [CONFLICT] externnotify already set to a different value:"
    echo "    Current: ${CURRENT}"
    echo "    Wanted:  externnotify=${HANDLER_DEST}"
    echo "  Will NOT overwrite automatically - manual change required"
elif grep -q "^\[general\]" "$VM_CONF"; then
    echo "  [UPDATE] Will add externnotify to existing [general] section:"
    echo ""
    echo "   [general]"
    echo "  +externnotify=${HANDLER_DEST}"
    CHANGES=$((CHANGES + 1))
else
    echo "  [UPDATE] Will append [general] section with externnotify:"
    echo ""
    echo "  +[general]"
    echo "  +externnotify=${HANDLER_DEST}"
    CHANGES=$((CHANGES + 1))
fi
echo ""

# --- mosquitto-clients ---
if [[ "$NEED_MOSQUITTO" == true ]]; then
    echo "--- Package: mosquitto-clients ---"
    echo "  [INSTALL] apt-get install mosquitto-clients"
    echo ""
    CHANGES=$((CHANGES + 1))
fi

echo "============================================"

if [[ $CHANGES -eq 0 ]]; then
    echo "  Nothing to do - everything is already installed."
    echo "============================================"
    echo ""
    exit 0
fi

echo "  ${CHANGES} change(s) to apply"
echo "============================================"
echo ""

# ── Phase 3: Confirm ─────────────────────────────────────────────

read -r -p "Apply these changes? [y/N] " REPLY
if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo ""

# ── Phase 4: Apply changes ───────────────────────────────────────

# Install mosquitto-clients if needed
if [[ "$NEED_MOSQUITTO" == true ]]; then
    echo "[1/4] Installing mosquitto-clients..."
    apt-get update -qq && apt-get install -y -qq mosquitto-clients
    echo "  Done"
else
    echo "[1/4] mosquitto_pub already installed"
fi

# Install handler script
echo "[2/4] Installing handler script -> ${HANDLER_DEST}"
if [[ -f "$HANDLER_DEST" ]] && diff -q "$HANDLER_SRC" "$HANDLER_DEST" &>/dev/null; then
    echo "  Already up to date, skipping"
else
    cp "$HANDLER_SRC" "$HANDLER_DEST"
    chmod 755 "$HANDLER_DEST"
    chown root:root "$HANDLER_DEST"
    echo "  Installed"
fi

# Install config
echo "[3/4] Installing config -> ${CONFIG_DEST}"
if [[ -f "$CONFIG_DEST" ]]; then
    if diff -q "$CONF_SRC" "$CONFIG_DEST" &>/dev/null; then
        echo "  Already up to date, skipping"
    else
        echo "  Config exists, keeping your settings"
        cp "$CONF_SRC" "${CONFIG_DEST}.new"
        echo "  New default saved as ${CONFIG_DEST}.new"
    fi
else
    cp "$CONF_SRC" "$CONFIG_DEST"
    chmod 640 "$CONFIG_DEST"
    chown root:asterisk "$CONFIG_DEST"
    echo "  Installed"
fi

# Configure externnotify
echo "[4/4] Configuring externnotify in ${VM_CONF}"
if [[ ! -f "$VM_CONF" ]]; then
    cat > "$VM_CONF" <<EOF
[general]
externnotify=${HANDLER_DEST}
EOF
    chown asterisk:asterisk "$VM_CONF"
    echo "  Created with externnotify"
elif grep -q "^externnotify=${HANDLER_DEST}$" "$VM_CONF"; then
    echo "  Already configured correctly"
elif grep -q "^externnotify=" "$VM_CONF"; then
    echo "  WARNING: externnotify set to different value - manual change required"
elif grep -q "^\[general\]" "$VM_CONF"; then
    sed -i "/^\[general\]/a externnotify=${HANDLER_DEST}" "$VM_CONF"
    echo "  Added externnotify to [general] section"
else
    echo "" >> "$VM_CONF"
    echo "[general]" >> "$VM_CONF"
    echo "externnotify=${HANDLER_DEST}" >> "$VM_CONF"
    echo "  Appended [general] section with externnotify"
fi

echo ""
echo "=== Installation complete ==="
echo ""
echo "Next steps:"
if [[ "$FREEPBX_DETECTED" == true ]]; then
    echo "  1. Reload: fwconsole reload (or: asterisk -rx 'voicemail reload')"
else
    echo "  1. Reload Asterisk: asterisk -rx 'voicemail reload'"
fi
echo "  2. Test: leave a voicemail and check: journalctl -t voicemail-handler"
echo "  3. Subscribe to MQTT to verify: mosquitto_sub -h mqtt.mrz.ip -t 'freepbx/voicemail/#'"
echo ""
