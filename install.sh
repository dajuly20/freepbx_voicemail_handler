#!/bin/bash
# install.sh - Install voicemail MQTT handler for FreePBX/Asterisk
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HANDLER_SRC="${SCRIPT_DIR}/voicemail-handler.sh"
CONF_SRC="${SCRIPT_DIR}/voicemail-handler.conf"
MQTT_CONF_SRC="${SCRIPT_DIR}/mqtt.conf"
HANDLER_DEST="/usr/local/bin/voicemail-handler.sh"
CONFIG_DEST="/etc/asterisk/voicemail-handler.conf"
MQTT_CONF_DEST="/etc/asterisk/mqtt.conf"
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

info()    { echo -e "  ${CYAN}ℹ${NC}  $1"; }
ok()      { echo -e "  ${GREEN}✔${NC}  $1"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  ${YELLOW}$1${NC}"; }
err()     { echo -e "  ${RED}✖${NC}  ${RED}$1${NC}"; }
heading() { echo -e "\n${BOLD}$1${NC}"; }

tag_new()      { echo -e "  ${GREEN}[NEW]${NC}      $1"; }
tag_update()   { echo -e "  ${BLUE}[UPDATE]${NC}   $1"; }
tag_skip()     { echo -e "  ${DIM}[SKIP]${NC}     ${DIM}$1${NC}"; }
tag_keep()     { echo -e "  ${YELLOW}[KEEP]${NC}     $1"; }
tag_conflict() { echo -e "  ${RED}[CONFLICT]${NC} $1"; }
tag_install()  { echo -e "  ${GREEN}[INSTALL]${NC}  $1"; }
tag_backup()   { echo -e "  ${CYAN}[BACKUP]${NC}   $1"; }
tag_migrate()  { echo -e "  ${BLUE}[MIGRATE]${NC}  $1"; }

# Backup a file before overwriting
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        mkdir -p "$BACKUP_DIR"
        local bname
        bname=$(basename "$file")
        cp "$file" "${BACKUP_DIR}/${bname}"
        tag_backup "Saved ${file} → ${BACKUP_DIR}/${bname}"
    fi
}

# ── Check root ────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}✖  This script must be run as root (sudo $0)${NC}"
    exit 1
fi

# ── --restore: Undo installation from backup ──────────────────────

if [[ "${1:-}" == "--restore" ]]; then
    echo ""
    echo -e "${BOLD}🔄 FreePBX Voicemail MQTT Handler — Restore${NC}"
    echo ""

    if [[ ! -d "$BACKUP_DIR" ]]; then
        err "No backup found at ${BACKUP_DIR}/"
        echo "  Nothing to restore."
        exit 1
    fi

    echo "  Backup directory: ${BACKUP_DIR}/"
    echo ""

    RESTORE_COUNT=0

    for bf in "${BACKUP_DIR}"/*; do
        [[ -f "$bf" ]] || continue
        bname=$(basename "$bf")

        # Map backup filename back to original path
        case "$bname" in
            voicemail-handler.sh)    target="$HANDLER_DEST" ;;
            voicemail-handler.conf)  target="$CONFIG_DEST" ;;
            mqtt.conf)               target="$MQTT_CONF_DEST" ;;
            voicemail_custom.conf)   target="$VM_CONF" ;;
            *)                       target=""; warn "Unknown backup file: ${bname}, skipping" ;;
        esac

        if [[ -n "$target" ]]; then
            heading "── ${target}"
            if [[ -f "$target" ]]; then
                if diff -q "$bf" "$target" &>/dev/null; then
                    tag_skip "Already matches backup"
                else
                    tag_update "Will be restored from backup:"
                    echo ""
                    diff -u "$target" "$bf" --label "current: ${target}" --label "backup: ${bf}" || true
                    RESTORE_COUNT=$((RESTORE_COUNT + 1))
                fi
            else
                tag_new "File was removed, will be restored from backup"
                RESTORE_COUNT=$((RESTORE_COUNT + 1))
            fi
            echo ""
        fi
    done

    if [[ $RESTORE_COUNT -eq 0 ]]; then
        ok "Nothing to restore — all files match the backup."
        exit 0
    fi

    echo -e "  ${BOLD}${RESTORE_COUNT} file(s) to restore${NC}"
    echo ""
    read -r -p "  Restore these files? [y/N] " REPLY
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "  Aborted."
        exit 0
    fi

    echo ""
    for bf in "${BACKUP_DIR}"/*; do
        [[ -f "$bf" ]] || continue
        bname=$(basename "$bf")

        case "$bname" in
            voicemail-handler.sh)    target="$HANDLER_DEST" ;;
            voicemail-handler.conf)  target="$CONFIG_DEST" ;;
            mqtt.conf)               target="$MQTT_CONF_DEST" ;;
            voicemail_custom.conf)   target="$VM_CONF" ;;
            *)                       target="" ;;
        esac

        if [[ -n "$target" ]]; then
            cp "$bf" "$target"
            ok "Restored: ${target}"
        fi
    done

    echo ""
    echo -e "${BOLD}✅ Restore complete${NC}"
    echo ""
    echo "  Reload Asterisk to apply: asterisk -rx 'voicemail reload'"
    echo ""
    exit 0
fi

# ══════════════════════════════════════════════════════════════════
#  Installation
# ══════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}📦 FreePBX Voicemail MQTT Handler — Install${NC}"
echo ""

# ── Phase 0: Verify Asterisk environment ──────────────────────────

heading "⏳ [0/4] Verifying Asterisk environment..."
echo ""

# Check Asterisk binary
if ! command -v asterisk &>/dev/null; then
    err "Asterisk not found. Is Asterisk installed?"
    echo "       Looked for: asterisk in PATH"
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
ok "Config dir: /etc/asterisk/"

# Check voicemail spool directory
VM_SPOOL="/var/spool/asterisk/voicemail"
if [[ ! -d "$VM_SPOOL" ]]; then
    warn "${VM_SPOOL} not found"
    echo "       Created when the first mailbox is configured."
else
    ok "Voicemail spool: ${VM_SPOOL}"
fi

# Check app_voicemail module
if asterisk -rx 'core waitfullybooted' &>/dev/null; then
    VM_MODULE=$(asterisk -rx 'module show like app_voicemail' 2>/dev/null || true)
    if echo "$VM_MODULE" | grep -q "app_voicemail"; then
        ok "Module: app_voicemail loaded"
    else
        warn "app_voicemail module not loaded!"
        echo "       externnotify will not work without it."
        echo "       Try: asterisk -rx 'module load app_voicemail.so'"
    fi
else
    warn "Asterisk not running — skipping module check"
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
else
    info "FreePBX not detected (vanilla Asterisk)"
fi

# Check source files exist
for src_file in "$HANDLER_SRC" "$CONF_SRC" "$MQTT_CONF_SRC"; do
    if [[ ! -f "$src_file" ]]; then
        err "Source file not found: ${src_file}"
        exit 1
    fi
done
ok "Source files present"

# ── Phase 1: Check dependencies ──────────────────────────────────

heading "⏳ [1/4] Checking dependencies..."
echo ""

NEED_MOSQUITTO=false
if ! command -v mosquitto_pub &>/dev/null; then
    NEED_MOSQUITTO=true
    warn "mosquitto_pub not found — will be installed"
else
    ok "mosquitto_pub found"
fi

# ── Phase 2: Configuration ───────────────────────────────────────

heading "⏳ [2/4] Configuration..."
echo ""

# --- Detect old config format (MQTT_HOST in voicemail-handler.conf) ---
OLD_FORMAT=false
DEFAULT_HOST="mqtt.mrz.ip"
DEFAULT_PORT="1883"
DEFAULT_USER=""
DEFAULT_PASS=""
DEFAULT_TOPIC="freepbx/voicemail"

if [[ -f "$CONFIG_DEST" ]] && grep -q "^MQTT_HOST=" "$CONFIG_DEST" 2>/dev/null; then
    OLD_FORMAT=true
    tag_migrate "Old config format detected — MQTT settings will be moved to mqtt.conf"
    echo ""
    # Read existing values as defaults
    # shellcheck source=/dev/null
    source "$CONFIG_DEST"
    DEFAULT_HOST="${MQTT_HOST:-$DEFAULT_HOST}"
    DEFAULT_PORT="${MQTT_PORT:-$DEFAULT_PORT}"
    DEFAULT_USER="${MQTT_USER:-$DEFAULT_USER}"
    DEFAULT_PASS="${MQTT_PASS:-$DEFAULT_PASS}"
    DEFAULT_TOPIC="${MQTT_TOPIC:-$DEFAULT_TOPIC}"
fi

# --- MQTT Broker settings ---
CONFIGURE_MQTT=false
if [[ ! -f "$MQTT_CONF_DEST" ]] || [[ "$OLD_FORMAT" == true ]]; then
    CONFIGURE_MQTT=true
    echo -e "  ${BOLD}🔌 MQTT Broker${NC}"
    echo ""
    read -r -p "     Host [${DEFAULT_HOST}]: " INPUT_HOST
    MQTT_HOST="${INPUT_HOST:-$DEFAULT_HOST}"
    read -r -p "     Port [${DEFAULT_PORT}]: " INPUT_PORT
    MQTT_PORT="${INPUT_PORT:-$DEFAULT_PORT}"
    read -r -p "     Username (Enter = none): " INPUT_USER
    MQTT_USER="${INPUT_USER:-$DEFAULT_USER}"
    if [[ -n "$MQTT_USER" ]]; then
        read -r -s -p "     Password (Enter = none): " INPUT_PASS
        echo ""
        MQTT_PASS="${INPUT_PASS:-$DEFAULT_PASS}"
    else
        MQTT_PASS=""
    fi
    echo ""

    # Generate mqtt.conf content
    GEN_MQTT_CONF="# mqtt.conf - MQTT Broker Connection
# Installed to /etc/asterisk/mqtt.conf

# Broker address
MQTT_HOST=\"${MQTT_HOST}\"
MQTT_PORT=${MQTT_PORT}

# Authentication (leave empty if not required)
MQTT_USER=\"${MQTT_USER}\"
MQTT_PASS=\"${MQTT_PASS}\"
"
else
    ok "MQTT config exists at ${MQTT_CONF_DEST} (keeping)"
    GEN_MQTT_CONF=""
fi

# --- Topic + Event selection ---
CONFIGURE_EVENTS=false
if [[ ! -f "$CONFIG_DEST" ]] || [[ "$OLD_FORMAT" == true ]] || ! grep -q "^EVENT_" "$CONFIG_DEST" 2>/dev/null; then
    CONFIGURE_EVENTS=true

    echo -e "  ${BOLD}📡 MQTT Topic${NC}"
    echo ""
    read -r -p "     Base topic [${DEFAULT_TOPIC}]: " INPUT_TOPIC
    MQTT_TOPIC="${INPUT_TOPIC:-$DEFAULT_TOPIC}"
    echo ""

    echo -e "  ${BOLD}📋 Events${NC}"
    echo ""
    echo "     Which events should publish MQTT messages?"
    echo ""
    echo "     1) 📨 New voicemail   — full details as JSON"
    echo "     2) 🔢 Message count   — retained, ideal for HA sensors"
    echo "     3) 📞 Caller ID       — for notifications"
    echo ""
    read -r -p "     Enable (space-separated, Enter = all) [1 2 3]: " INPUT_EVENTS
    INPUT_EVENTS="${INPUT_EVENTS:-1 2 3}"

    EVENT_NEW_VM=false
    EVENT_COUNT=false
    EVENT_CALLERID=false

    for e in $INPUT_EVENTS; do
        case "$e" in
            1) EVENT_NEW_VM=true ;;
            2) EVENT_COUNT=true ;;
            3) EVENT_CALLERID=true ;;
            *) warn "Unknown event: ${e}, ignoring" ;;
        esac
    done

    echo ""

    # Generate voicemail-handler.conf content
    GEN_HANDLER_CONF="# voicemail-handler.conf - Voicemail Handler Settings
# Installed to /etc/asterisk/voicemail-handler.conf

# MQTT topic prefix (mailbox number gets appended: ${MQTT_TOPIC}/100)
MQTT_TOPIC=\"${MQTT_TOPIC}\"

# ── Events ──────────────────────────────────────────────────────
# Enable (true) or disable (false) individual MQTT events.
# Each event publishes to its own sub-topic.

# New voicemail: full details as JSON
# Topic: {MQTT_TOPIC}/{mailbox}
EVENT_NEW_VM=${EVENT_NEW_VM}

# Message count: number of new messages (retained message)
# Topic: {MQTT_TOPIC}/{mailbox}/count
EVENT_COUNT=${EVENT_COUNT}

# Caller ID: caller identification string
# Topic: {MQTT_TOPIC}/{mailbox}/callerid
EVENT_CALLERID=${EVENT_CALLERID}
"
else
    ok "Handler config exists at ${CONFIG_DEST} (keeping)"
    GEN_HANDLER_CONF=""
fi

# ── Preview all planned changes ──────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   📋 Planned changes (nothing applied yet)   ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"

CHANGES=0

# --- Handler script ---
heading "── ${HANDLER_DEST}"
if [[ -f "$HANDLER_DEST" ]]; then
    if diff -q "$HANDLER_SRC" "$HANDLER_DEST" &>/dev/null; then
        tag_skip "Already up to date"
    else
        tag_update "File exists, will be overwritten"
        tag_backup "Current version will be saved"
        echo ""
        diff -u "$HANDLER_DEST" "$HANDLER_SRC" --label "current: ${HANDLER_DEST}" --label "new: ${HANDLER_SRC}" || true
        CHANGES=$((CHANGES + 1))
    fi
else
    tag_new "Will be created"
    CHANGES=$((CHANGES + 1))
fi

# --- mqtt.conf ---
heading "── ${MQTT_CONF_DEST}"
if [[ "$CONFIGURE_MQTT" == true ]]; then
    if [[ -f "$MQTT_CONF_DEST" ]]; then
        tag_update "Will be overwritten with new settings"
        tag_backup "Current version will be saved"
    else
        tag_new "Will be created with:"
    fi
    echo ""
    echo -e "  ${GREEN}   MQTT_HOST=\"${MQTT_HOST}\"${NC}"
    echo -e "  ${GREEN}   MQTT_PORT=${MQTT_PORT}${NC}"
    if [[ -n "$MQTT_USER" ]]; then
        echo -e "  ${GREEN}   MQTT_USER=\"${MQTT_USER}\"${NC}"
        echo -e "  ${GREEN}   MQTT_PASS=\"****\"${NC}"
    else
        echo -e "  ${DIM}   MQTT_USER=\"\" (no auth)${NC}"
    fi
    CHANGES=$((CHANGES + 1))
elif [[ -f "$MQTT_CONF_DEST" ]]; then
    tag_skip "Already configured"
else
    tag_new "Will be created from template"
    CHANGES=$((CHANGES + 1))
fi

# --- voicemail-handler.conf ---
heading "── ${CONFIG_DEST}"
if [[ "$CONFIGURE_EVENTS" == true ]]; then
    if [[ -f "$CONFIG_DEST" ]]; then
        if [[ "$OLD_FORMAT" == true ]]; then
            tag_migrate "Migrating to new format (events + separate MQTT config)"
        else
            tag_update "Will be overwritten"
        fi
        tag_backup "Current version will be saved"
    else
        tag_new "Will be created with:"
    fi
    echo ""
    echo -e "  ${GREEN}   MQTT_TOPIC=\"${MQTT_TOPIC}\"${NC}"
    echo -e "  ${GREEN}   EVENT_NEW_VM=${EVENT_NEW_VM}${NC}"
    echo -e "  ${GREEN}   EVENT_COUNT=${EVENT_COUNT}${NC}"
    echo -e "  ${GREEN}   EVENT_CALLERID=${EVENT_CALLERID}${NC}"
    CHANGES=$((CHANGES + 1))
elif [[ -f "$CONFIG_DEST" ]]; then
    tag_skip "Already configured"
else
    tag_new "Will be created from template"
    CHANGES=$((CHANGES + 1))
fi

# --- voicemail_custom.conf ---
heading "── ${VM_CONF}"
if [[ ! -f "$VM_CONF" ]]; then
    tag_new "Will be created with:"
    echo ""
    echo -e "     ${GREEN}+[general]${NC}"
    echo -e "     ${GREEN}+externnotify=${HANDLER_DEST}${NC}"
    CHANGES=$((CHANGES + 1))
elif grep -q "^externnotify=${HANDLER_DEST}$" "$VM_CONF"; then
    tag_skip "externnotify already configured correctly"
elif grep -q "^externnotify=" "$VM_CONF"; then
    CURRENT=$(grep "^externnotify=" "$VM_CONF" | head -1)
    tag_conflict "externnotify already set to a different value:"
    echo -e "     Current: ${RED}${CURRENT}${NC}"
    echo -e "     Wanted:  ${GREEN}externnotify=${HANDLER_DEST}${NC}"
    echo "     Will NOT overwrite automatically — manual change required"
elif grep -q "^\[general\]" "$VM_CONF"; then
    tag_update "Will add externnotify to existing [general] section"
    tag_backup "Current version will be saved"
    echo ""
    echo "      [general]"
    echo -e "     ${GREEN}+externnotify=${HANDLER_DEST}${NC}"
    CHANGES=$((CHANGES + 1))
else
    tag_update "Will append [general] section with externnotify"
    tag_backup "Current version will be saved"
    echo ""
    echo -e "     ${GREEN}+[general]${NC}"
    echo -e "     ${GREEN}+externnotify=${HANDLER_DEST}${NC}"
    CHANGES=$((CHANGES + 1))
fi

# --- mosquitto-clients ---
if [[ "$NEED_MOSQUITTO" == true ]]; then
    heading "── Package: mosquitto-clients"
    tag_install "apt-get install mosquitto-clients"
    CHANGES=$((CHANGES + 1))
fi

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
if [[ $CHANGES -eq 0 ]]; then
    echo -e "${BOLD}║   ${GREEN}✅ Nothing to do — already installed.${NC}${BOLD}       ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    exit 0
fi
echo -e "${BOLD}║   ${CHANGES} change(s) to apply                       ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

if [[ -d "$BACKUP_DIR" ]]; then
    info "Previous backup exists in ${BACKUP_DIR}/ — will be overwritten"
    echo ""
fi

# ── Confirm ──────────────────────────────────────────────────────

read -r -p "  Apply these changes? [y/N] " REPLY
if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "  Aborted."
    exit 0
fi

echo ""

# ══════════════════════════════════════════════════════════════════
#  Apply changes
# ══════════════════════════════════════════════════════════════════

# [1/5] Install mosquitto-clients if needed
heading "⏳ [1/5] mosquitto-clients"
if [[ "$NEED_MOSQUITTO" == true ]]; then
    apt-get update -qq && apt-get install -y -qq mosquitto-clients
    ok "Installed"
else
    ok "Already installed"
fi

# [2/5] Install handler script
heading "⏳ [2/5] Handler script → ${HANDLER_DEST}"
if [[ -f "$HANDLER_DEST" ]] && diff -q "$HANDLER_SRC" "$HANDLER_DEST" &>/dev/null; then
    tag_skip "Already up to date"
else
    backup_file "$HANDLER_DEST"
    cp "$HANDLER_SRC" "$HANDLER_DEST"
    chmod 755 "$HANDLER_DEST"
    chown root:root "$HANDLER_DEST"
    ok "Installed"
fi

# [3/5] Install MQTT config
heading "⏳ [3/5] MQTT config → ${MQTT_CONF_DEST}"
if [[ "$CONFIGURE_MQTT" == true ]]; then
    backup_file "$MQTT_CONF_DEST"
    echo "$GEN_MQTT_CONF" > "$MQTT_CONF_DEST"
    chmod 640 "$MQTT_CONF_DEST"
    chown root:asterisk "$MQTT_CONF_DEST"
    ok "Installed"
elif [[ -f "$MQTT_CONF_DEST" ]]; then
    tag_skip "Already configured"
else
    cp "$MQTT_CONF_SRC" "$MQTT_CONF_DEST"
    chmod 640 "$MQTT_CONF_DEST"
    chown root:asterisk "$MQTT_CONF_DEST"
    ok "Installed from template"
fi

# [4/5] Install handler config
heading "⏳ [4/5] Handler config → ${CONFIG_DEST}"
if [[ "$CONFIGURE_EVENTS" == true ]]; then
    backup_file "$CONFIG_DEST"
    echo "$GEN_HANDLER_CONF" > "$CONFIG_DEST"
    chmod 640 "$CONFIG_DEST"
    chown root:asterisk "$CONFIG_DEST"
    ok "Installed"
elif [[ -f "$CONFIG_DEST" ]]; then
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
    ok "Installed from template"
fi

# [5/5] Configure externnotify
heading "⏳ [5/5] externnotify → ${VM_CONF}"
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
    warn "externnotify set to different value — manual change required"
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

# ── Done ──────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   ✅ Installation complete                    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

if [[ -d "$BACKUP_DIR" ]]; then
    info "Backups saved in: ${BACKUP_DIR}/"
    echo -e "     To undo: ${BOLD}sudo bash $(realpath "$0") --restore${NC}"
    echo ""
fi

echo -e "  ${BOLD}Next steps:${NC}"
echo ""
if [[ "$FREEPBX_DETECTED" == true ]]; then
    echo "  1️⃣  Reload config:"
    echo "      fwconsole reload"
    echo "      # or: asterisk -rx 'voicemail reload'"
else
    echo "  1️⃣  Reload Asterisk:"
    echo "      asterisk -rx 'voicemail reload'"
fi
echo ""
echo "  2️⃣  Edit MQTT config if needed:"
echo "      nano ${MQTT_CONF_DEST}"
echo ""
echo "  3️⃣  Leave a test voicemail, then check:"
echo "      journalctl -t voicemail-handler -f"
echo ""

# Determine the topic to show in subscribe command
if [[ -n "${MQTT_TOPIC:-}" ]]; then
    SUB_TOPIC="$MQTT_TOPIC"
elif [[ -f "$CONFIG_DEST" ]]; then
    SUB_TOPIC=$(grep "^MQTT_TOPIC=" "$CONFIG_DEST" 2>/dev/null | cut -d'"' -f2 || echo "freepbx/voicemail")
else
    SUB_TOPIC="freepbx/voicemail"
fi

# Determine the host to show in subscribe command
if [[ -n "${MQTT_HOST:-}" ]]; then
    SUB_HOST="$MQTT_HOST"
elif [[ -f "$MQTT_CONF_DEST" ]]; then
    SUB_HOST=$(grep "^MQTT_HOST=" "$MQTT_CONF_DEST" 2>/dev/null | cut -d'"' -f2 || echo "localhost")
else
    SUB_HOST="localhost"
fi

echo "  4️⃣  Subscribe to MQTT to verify:"
echo "      mosquitto_sub -h ${SUB_HOST} -t '${SUB_TOPIC}/#' -v"
echo ""
