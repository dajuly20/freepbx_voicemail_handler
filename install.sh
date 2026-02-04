#!/bin/bash
# install.sh - Install voicemail MQTT handler for FreePBX/Asterisk
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HANDLER_SRC="${SCRIPT_DIR}/voicemail-handler.sh"
CONF_SRC="${SCRIPT_DIR}/voicemail-handler.conf"
HANDLER_DEST="/usr/local/bin/voicemail-handler.sh"
CONFIG_DEST="/etc/asterisk/voicemail-handler.conf"
VM_CONF="/etc/asterisk/voicemail_custom.conf"
BACKUP_DIR="/etc/asterisk/voicemail-handler-backup"

# ── Colors ────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    DIM='\033[2m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' DIM='' BOLD='' NC=''
fi

# ── Helper functions ──────────────────────────────────────────────

info()    { echo -e "  ${CYAN}$1${NC}"; }
ok()      { echo -e "  ${GREEN}$1${NC}"; }
warn()    { echo -e "  ${YELLOW}WARNING:${NC} $1"; }
err()     { echo -e "  ${RED}ERROR:${NC} $1"; }
heading() { echo -e "${BOLD}$1${NC}"; }

tag_new()      { echo -e "  ${GREEN}[NEW]${NC} $1"; }
tag_update()   { echo -e "  ${BLUE}[UPDATE]${NC} $1"; }
tag_skip()     { echo -e "  ${DIM}[SKIP]${NC} ${DIM}$1${NC}"; }
tag_keep()     { echo -e "  ${YELLOW}[KEEP]${NC} $1"; }
tag_conflict() { echo -e "  ${RED}[CONFLICT]${NC} $1"; }
tag_install()  { echo -e "  ${GREEN}[INSTALL]${NC} $1"; }
tag_backup()   { echo -e "  ${CYAN}[BACKUP]${NC} $1"; }

# Backup a file before overwriting
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        mkdir -p "$BACKUP_DIR"
        local basename
        basename=$(basename "$file")
        cp "$file" "${BACKUP_DIR}/${basename}"
        tag_backup "Saved ${file} -> ${BACKUP_DIR}/${basename}"
    fi
}

# ── Check root ────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}ERROR: This script must be run as root (sudo $0)${NC}"
    exit 1
fi

# ── --restore: Undo installation from backup ──────────────────────

if [[ "${1:-}" == "--restore" ]]; then
    echo ""
    heading "=== FreePBX Voicemail MQTT Handler - Restore ==="
    echo ""

    if [[ ! -d "$BACKUP_DIR" ]]; then
        err "No backup found at ${BACKUP_DIR}/"
        echo "  Nothing to restore."
        exit 1
    fi

    echo "Backup directory: ${BACKUP_DIR}/"
    echo ""

    RESTORE_COUNT=0

    for backup_file in "${BACKUP_DIR}"/*; do
        [[ -f "$backup_file" ]] || continue
        basename=$(basename "$backup_file")

        # Map backup filename back to original path
        case "$basename" in
            voicemail-handler.sh)    target="$HANDLER_DEST" ;;
            voicemail-handler.conf)  target="$CONFIG_DEST" ;;
            voicemail_custom.conf)   target="$VM_CONF" ;;
            *)                       target=""; warn "Unknown backup file: ${basename}, skipping" ;;
        esac

        if [[ -n "$target" ]]; then
            if [[ -f "$target" ]]; then
                heading "--- ${target} ---"
                if diff -q "$backup_file" "$target" &>/dev/null; then
                    tag_skip "Already matches backup"
                else
                    tag_update "Will be restored from backup:"
                    echo ""
                    diff -u "$target" "$backup_file" --label "current: ${target}" --label "backup: ${backup_file}" || true
                    RESTORE_COUNT=$((RESTORE_COUNT + 1))
                fi
            else
                heading "--- ${target} ---"
                tag_new "File was removed, will be restored from backup"
                RESTORE_COUNT=$((RESTORE_COUNT + 1))
            fi
            echo ""
        fi
    done

    if [[ $RESTORE_COUNT -eq 0 ]]; then
        ok "Nothing to restore - all files match the backup."
        exit 0
    fi

    echo -e "${BOLD}${RESTORE_COUNT} file(s) to restore${NC}"
    echo ""
    read -r -p "Restore these files? [y/N] " REPLY
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi

    echo ""
    for backup_file in "${BACKUP_DIR}"/*; do
        [[ -f "$backup_file" ]] || continue
        basename=$(basename "$backup_file")

        case "$basename" in
            voicemail-handler.sh)    target="$HANDLER_DEST" ;;
            voicemail-handler.conf)  target="$CONFIG_DEST" ;;
            voicemail_custom.conf)   target="$VM_CONF" ;;
            *)                       target="" ;;
        esac

        if [[ -n "$target" ]]; then
            cp "$backup_file" "$target"
            ok "Restored: ${target}"
        fi
    done

    echo ""
    heading "=== Restore complete ==="
    echo ""
    echo "Reload Asterisk to apply: asterisk -rx 'voicemail reload'"
    echo ""
    exit 0
fi

echo ""
heading "=== FreePBX Voicemail MQTT Handler - Install ==="
echo ""

# ── Phase 0: Verify Asterisk environment ──────────────────────────

heading "[0/4] Verifying Asterisk environment..."

# Check Asterisk binary
if ! command -v asterisk &>/dev/null; then
    err "Asterisk not found. Is Asterisk installed?"
    echo "  Looked for: asterisk in PATH"
    exit 1
fi
AST_BIN=$(command -v asterisk)
ok "Asterisk binary: ${AST_BIN}"

# Get Asterisk version
AST_VERSION=$(asterisk -V 2>/dev/null || true)
if [[ -z "$AST_VERSION" ]]; then
    warn "Could not determine Asterisk version"
else
    ok "Version: ${AST_VERSION}"
fi

# Check /etc/asterisk/ exists
if [[ ! -d /etc/asterisk ]]; then
    err "/etc/asterisk/ not found. Non-standard Asterisk installation?"
    exit 1
fi
ok "Config dir: /etc/asterisk/ exists"

# Check voicemail spool directory
VM_SPOOL="/var/spool/asterisk/voicemail"
if [[ ! -d "$VM_SPOOL" ]]; then
    warn "${VM_SPOOL} not found"
    echo "  This directory is created when the first mailbox is configured."
    echo "  Make sure app_voicemail is loaded and mailboxes are configured."
else
    ok "Voicemail spool: ${VM_SPOOL} exists"
fi

# Check app_voicemail module
if asterisk -rx 'core waitfullybooted' &>/dev/null; then
    VM_MODULE=$(asterisk -rx 'module show like app_voicemail' 2>/dev/null || true)
    if echo "$VM_MODULE" | grep -q "app_voicemail"; then
        ok "Module: app_voicemail loaded"
    else
        warn "app_voicemail module not loaded!"
        echo "  externnotify will not work without it."
        echo "  Try: asterisk -rx 'module load app_voicemail.so'"
    fi
else
    warn "Asterisk not running - skipping module check"
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
    ok "FreePBX detected${FWCONSOLE_VER:+ (${FWCONSOLE_VER})}"
    info "Using voicemail_custom.conf (FreePBX-safe)"
else
    info "FreePBX not detected (vanilla Asterisk)"
    info "Using voicemail_custom.conf (safe for both)"
fi

# Check source files exist
if [[ ! -f "$HANDLER_SRC" ]]; then
    err "Source file not found: ${HANDLER_SRC}"
    exit 1
fi
if [[ ! -f "$CONF_SRC" ]]; then
    err "Source file not found: ${CONF_SRC}"
    exit 1
fi

echo ""

# ── Phase 1: Check dependencies ──────────────────────────────────

heading "[1/4] Checking dependencies..."
NEED_MOSQUITTO=false
if ! command -v mosquitto_pub &>/dev/null; then
    NEED_MOSQUITTO=true
    warn "mosquitto_pub not found - will be installed"
else
    ok "mosquitto_pub found"
fi

echo ""

# ── Phase 2: Preview all planned changes ──────────────────────────

echo -e "${BOLD}============================================${NC}"
echo -e "${BOLD}  Planned changes (nothing applied yet)${NC}"
echo -e "${BOLD}============================================${NC}"
echo ""

CHANGES=0

# --- Handler script ---
heading "--- ${HANDLER_DEST} ---"
if [[ -f "$HANDLER_DEST" ]]; then
    if diff -q "$HANDLER_SRC" "$HANDLER_DEST" &>/dev/null; then
        tag_skip "Already up to date"
    else
        tag_update "File exists, will be overwritten"
        tag_backup "Current version will be saved to ${BACKUP_DIR}/"
        echo ""
        diff -u "$HANDLER_DEST" "$HANDLER_SRC" --label "current: ${HANDLER_DEST}" --label "new: ${HANDLER_SRC}" || true
        CHANGES=$((CHANGES + 1))
    fi
else
    tag_new "File does not exist, will be created"
    echo ""
    diff -u /dev/null "$HANDLER_SRC" --label "(does not exist)" --label "new: ${HANDLER_DEST}" || true
    CHANGES=$((CHANGES + 1))
fi
echo ""

# --- Config file ---
heading "--- ${CONFIG_DEST} ---"
if [[ -f "$CONFIG_DEST" ]]; then
    if diff -q "$CONF_SRC" "$CONFIG_DEST" &>/dev/null; then
        tag_skip "Already up to date"
    else
        tag_keep "Config exists with your settings (not overwritten)"
        echo "  A copy of the new default will be saved as ${CONFIG_DEST}.new"
        echo ""
        diff -u "$CONFIG_DEST" "$CONF_SRC" --label "current: ${CONFIG_DEST}" --label "new default: ${CONF_SRC}" || true
        CHANGES=$((CHANGES + 1))
    fi
else
    tag_new "File does not exist, will be created"
    echo ""
    diff -u /dev/null "$CONF_SRC" --label "(does not exist)" --label "new: ${CONFIG_DEST}" || true
    CHANGES=$((CHANGES + 1))
fi
echo ""

# --- voicemail_custom.conf ---
heading "--- ${VM_CONF} ---"
if [[ ! -f "$VM_CONF" ]]; then
    tag_new "File does not exist, will be created with:"
    echo ""
    echo -e "  ${GREEN}+[general]${NC}"
    echo -e "  ${GREEN}+externnotify=${HANDLER_DEST}${NC}"
    CHANGES=$((CHANGES + 1))
elif grep -q "^externnotify=${HANDLER_DEST}$" "$VM_CONF"; then
    tag_skip "externnotify already configured correctly"
elif grep -q "^externnotify=" "$VM_CONF"; then
    CURRENT=$(grep "^externnotify=" "$VM_CONF" | head -1)
    tag_conflict "externnotify already set to a different value:"
    echo -e "    Current: ${RED}${CURRENT}${NC}"
    echo -e "    Wanted:  ${GREEN}externnotify=${HANDLER_DEST}${NC}"
    echo "  Will NOT overwrite automatically - manual change required"
elif grep -q "^\[general\]" "$VM_CONF"; then
    tag_update "Will add externnotify to existing [general] section:"
    tag_backup "Current version will be saved to ${BACKUP_DIR}/"
    echo ""
    echo "   [general]"
    echo -e "  ${GREEN}+externnotify=${HANDLER_DEST}${NC}"
    CHANGES=$((CHANGES + 1))
else
    tag_update "Will append [general] section with externnotify:"
    tag_backup "Current version will be saved to ${BACKUP_DIR}/"
    echo ""
    echo -e "  ${GREEN}+[general]${NC}"
    echo -e "  ${GREEN}+externnotify=${HANDLER_DEST}${NC}"
    CHANGES=$((CHANGES + 1))
fi
echo ""

# --- mosquitto-clients ---
if [[ "$NEED_MOSQUITTO" == true ]]; then
    heading "--- Package: mosquitto-clients ---"
    tag_install "apt-get install mosquitto-clients"
    echo ""
    CHANGES=$((CHANGES + 1))
fi

echo -e "${BOLD}============================================${NC}"

if [[ $CHANGES -eq 0 ]]; then
    echo -e "  ${GREEN}Nothing to do - everything is already installed.${NC}"
    echo -e "${BOLD}============================================${NC}"
    echo ""
    exit 0
fi

echo -e "  ${BOLD}${CHANGES} change(s) to apply${NC}"
echo -e "${BOLD}============================================${NC}"
echo ""

if [[ -d "$BACKUP_DIR" ]]; then
    info "Previous backup exists in ${BACKUP_DIR}/"
    info "It will be overwritten with the current state."
    echo ""
fi

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
    heading "[1/4] Installing mosquitto-clients..."
    apt-get update -qq && apt-get install -y -qq mosquitto-clients
    ok "Done"
else
    heading "[1/4] mosquitto_pub already installed"
fi

# Install handler script
heading "[2/4] Installing handler script -> ${HANDLER_DEST}"
if [[ -f "$HANDLER_DEST" ]] && diff -q "$HANDLER_SRC" "$HANDLER_DEST" &>/dev/null; then
    tag_skip "Already up to date"
else
    backup_file "$HANDLER_DEST"
    cp "$HANDLER_SRC" "$HANDLER_DEST"
    chmod 755 "$HANDLER_DEST"
    chown root:root "$HANDLER_DEST"
    ok "Installed"
fi

# Install config
heading "[3/4] Installing config -> ${CONFIG_DEST}"
if [[ -f "$CONFIG_DEST" ]]; then
    if diff -q "$CONF_SRC" "$CONFIG_DEST" &>/dev/null; then
        tag_skip "Already up to date"
    else
        ok "Config exists, keeping your settings"
        cp "$CONF_SRC" "${CONFIG_DEST}.new"
        ok "New default saved as ${CONFIG_DEST}.new"
    fi
else
    cp "$CONF_SRC" "$CONFIG_DEST"
    chmod 640 "$CONFIG_DEST"
    chown root:asterisk "$CONFIG_DEST"
    ok "Installed"
fi

# Configure externnotify
heading "[4/4] Configuring externnotify in ${VM_CONF}"
if [[ ! -f "$VM_CONF" ]]; then
    cat > "$VM_CONF" <<EOF
[general]
externnotify=${HANDLER_DEST}
EOF
    chown asterisk:asterisk "$VM_CONF"
    ok "Created with externnotify"
elif grep -q "^externnotify=${HANDLER_DEST}$" "$VM_CONF"; then
    tag_skip "Already configured correctly"
elif grep -q "^externnotify=" "$VM_CONF"; then
    warn "externnotify set to different value - manual change required"
elif grep -q "^\[general\]" "$VM_CONF"; then
    backup_file "$VM_CONF"
    sed -i "/^\[general\]/a externnotify=${HANDLER_DEST}" "$VM_CONF"
    ok "Added externnotify to [general] section"
else
    backup_file "$VM_CONF"
    echo "" >> "$VM_CONF"
    echo "[general]" >> "$VM_CONF"
    echo "externnotify=${HANDLER_DEST}" >> "$VM_CONF"
    ok "Appended [general] section with externnotify"
fi

echo ""
heading "=== Installation complete ==="
echo ""

if [[ -d "$BACKUP_DIR" ]]; then
    info "Backups saved in: ${BACKUP_DIR}/"
    echo -e "  To undo: ${BOLD}sudo bash $(realpath "$0") --restore${NC}"
    echo ""
fi

echo "Next steps:"
if [[ "$FREEPBX_DETECTED" == true ]]; then
    echo "  1. Reload: fwconsole reload (or: asterisk -rx 'voicemail reload')"
else
    echo "  1. Reload Asterisk: asterisk -rx 'voicemail reload'"
fi
echo "  2. Test: leave a voicemail and check: journalctl -t voicemail-handler"
echo "  3. Subscribe to MQTT to verify: mosquitto_sub -h mqtt.mrz.ip -t 'freepbx/voicemail/#'"
echo ""
