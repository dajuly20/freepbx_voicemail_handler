#!/bin/bash
# verify.sh - Verify and test voicemail MQTT handler installation
set -euo pipefail

# Colors
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
fi

ok()   { echo -e "  ${GREEN}✔${NC}  $1"; }
err()  { echo -e "  ${RED}✖${NC}  ${RED}$1${NC}"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  ${YELLOW}$1${NC}"; }
info() { echo -e "  ${CYAN}ℹ${NC}  $1"; }

echo ""
echo -e "${BOLD}🔍 FreePBX Voicemail MQTT Handler — Verification${NC}"
echo ""

ERRORS=0

# ── Step 1: Reload Asterisk config ───────────────────────────────

echo -e "${BOLD}[1/5] Reloading Asterisk config...${NC}"
echo ""

if [[ $EUID -ne 0 ]]; then
    err "Not running as root — skipping reload"
    warn "Run: sudo fwconsole reload  OR  sudo asterisk -rx 'voicemail reload'"
    ERRORS=$((ERRORS + 1))
else
    if command -v fwconsole &>/dev/null; then
        fwconsole reload >/dev/null 2>&1 && ok "fwconsole reload: success" || { err "fwconsole reload failed"; ERRORS=$((ERRORS + 1)); }
    else
        asterisk -rx 'voicemail reload' >/dev/null 2>&1 && ok "asterisk voicemail reload: success" || { err "Asterisk reload failed"; ERRORS=$((ERRORS + 1)); }
    fi
fi

# ── Step 2: Verify files ──────────────────────────────────────────

echo ""
echo -e "${BOLD}[2/5] Verifying installation...${NC}"
echo ""

# Handler script
if [[ -f /usr/local/bin/voicemail-handler.sh ]]; then
    if [[ -x /usr/local/bin/voicemail-handler.sh ]]; then
        ok "/usr/local/bin/voicemail-handler.sh (executable)"
    else
        err "/usr/local/bin/voicemail-handler.sh (not executable)"
        ERRORS=$((ERRORS + 1))
    fi
else
    err "/usr/local/bin/voicemail-handler.sh (missing)"
    ERRORS=$((ERRORS + 1))
fi

# MQTT config
if [[ -f /etc/asterisk/mqtt.conf ]]; then
    if [[ -r /etc/asterisk/mqtt.conf ]]; then
        ok "/etc/asterisk/mqtt.conf (readable)"
    else
        err "/etc/asterisk/mqtt.conf (not readable)"
        ERRORS=$((ERRORS + 1))
    fi
else
    err "/etc/asterisk/mqtt.conf (missing)"
    ERRORS=$((ERRORS + 1))
fi

# Handler config
if [[ -f /etc/asterisk/voicemail-handler.conf ]]; then
    if [[ -r /etc/asterisk/voicemail-handler.conf ]]; then
        ok "/etc/asterisk/voicemail-handler.conf (readable)"
    else
        err "/etc/asterisk/voicemail-handler.conf (not readable)"
        ERRORS=$((ERRORS + 1))
    fi
else
    err "/etc/asterisk/voicemail-handler.conf (missing)"
    ERRORS=$((ERRORS + 1))
fi

# voicemail_custom.conf
if [[ -f /etc/asterisk/voicemail_custom.conf ]]; then
    if grep -q "^externnotify=/usr/local/bin/voicemail-handler.sh" /etc/asterisk/voicemail_custom.conf 2>/dev/null; then
        ok "/etc/asterisk/voicemail_custom.conf (externnotify configured)"
    else
        err "/etc/asterisk/voicemail_custom.conf (externnotify not configured)"
        ERRORS=$((ERRORS + 1))
    fi
else
    err "/etc/asterisk/voicemail_custom.conf (missing)"
    ERRORS=$((ERRORS + 1))
fi

# mosquitto_pub
if command -v mosquitto_pub &>/dev/null; then
    ok "mosquitto_pub (installed)"
else
    err "mosquitto_pub (not found)"
    ERRORS=$((ERRORS + 1))
fi

# ── Step 3: Parse config ──────────────────────────────────────────

echo ""
echo -e "${BOLD}[3/5] Reading configuration...${NC}"
echo ""

if [[ -f /etc/asterisk/mqtt.conf ]]; then
    # shellcheck source=/dev/null
    source /etc/asterisk/mqtt.conf 2>/dev/null || true

    if [[ -n "${MQTT_HOST:-}" ]]; then
        ok "MQTT_HOST=${MQTT_HOST}"
    else
        err "MQTT_HOST not set in mqtt.conf"
        ERRORS=$((ERRORS + 1))
    fi

    ok "MQTT_PORT=${MQTT_PORT:-1883}"

    if [[ -n "${MQTT_USER:-}" ]]; then
        ok "MQTT_USER=${MQTT_USER} (auth enabled)"
    else
        info "MQTT_USER not set (no auth)"
    fi
fi

if [[ -f /etc/asterisk/voicemail-handler.conf ]]; then
    # shellcheck source=/dev/null
    source /etc/asterisk/voicemail-handler.conf 2>/dev/null || true
    ok "MQTT_TOPIC=${MQTT_TOPIC:-freepbx/voicemail}"
    ok "EVENT_NEW_VM=${EVENT_NEW_VM:-true}"
    ok "EVENT_COUNT=${EVENT_COUNT:-true}"
    ok "EVENT_CALLERID=${EVENT_CALLERID:-true}"
fi

# ── Step 4: Test MQTT connection ──────────────────────────────────

echo ""
echo -e "${BOLD}[4/5] Testing MQTT connection...${NC}"
echo ""

if [[ -z "${MQTT_HOST:-}" ]]; then
    err "Cannot test MQTT — MQTT_HOST not configured"
    ERRORS=$((ERRORS + 1))
else
    TEST_TOPIC="${MQTT_TOPIC:-freepbx/voicemail}/test"
    TEST_PAYLOAD="Test from verify.sh at $(date +%s)"

    MQTT_CMD=(mosquitto_pub -h "$MQTT_HOST" -p "${MQTT_PORT:-1883}" -t "$TEST_TOPIC" -m "$TEST_PAYLOAD")

    if [[ -n "${MQTT_USER:-}" ]]; then
        MQTT_CMD+=(-u "$MQTT_USER")
        [[ -n "${MQTT_PASS:-}" ]] && MQTT_CMD+=(-P "$MQTT_PASS")
    fi

    if "${MQTT_CMD[@]}" 2>/dev/null; then
        ok "MQTT publish successful to ${MQTT_HOST}:${MQTT_PORT:-1883}"
        info "Topic: ${TEST_TOPIC}"
    else
        err "MQTT publish failed to ${MQTT_HOST}:${MQTT_PORT:-1883}"
        warn "Check: Is the MQTT broker running? Are credentials correct?"
        ERRORS=$((ERRORS + 1))
    fi
fi

# ── Step 5: Dry-run test ──────────────────────────────────────────

echo ""
echo -e "${BOLD}[5/5] Testing handler script (dry-run)...${NC}"
echo ""

# Check if we can simulate a call
if [[ ! -d /var/spool/asterisk/voicemail ]]; then
    warn "Voicemail spool directory not found — cannot dry-run test"
    info "Leave a real voicemail to test the handler"
else
    # Look for any existing voicemail to test with
    SAMPLE_VM=$(find /var/spool/asterisk/voicemail -name "msg*.txt" 2>/dev/null | head -1)

    if [[ -n "$SAMPLE_VM" ]]; then
        # Extract context and mailbox from path
        # Path format: /var/spool/asterisk/voicemail/{context}/{mailbox}/INBOX/msg0000.txt
        VM_PATH=$(dirname "$SAMPLE_VM")
        MAILBOX=$(basename "$(dirname "$VM_PATH")")
        CONTEXT=$(basename "$(dirname "$(dirname "$VM_PATH")")")

        info "Found existing voicemail for testing:"
        info "  Context: ${CONTEXT}, Mailbox: ${MAILBOX}"
        echo ""

        if [[ $EUID -eq 0 ]]; then
            info "Simulating handler call..."
            /usr/local/bin/voicemail-handler.sh "$CONTEXT" "$MAILBOX" 1
            ok "Handler executed successfully"
            info "Check MQTT topic: ${MQTT_TOPIC:-freepbx/voicemail}/${MAILBOX}"
        else
            warn "Not root — cannot execute handler directly"
            info "To test manually: sudo /usr/local/bin/voicemail-handler.sh ${CONTEXT} ${MAILBOX} 1"
        fi
    else
        info "No existing voicemails found for dry-run test"
        info "Leave a test voicemail to trigger the handler"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
if [[ $ERRORS -eq 0 ]]; then
    echo -e "${BOLD}║   ${GREEN}✅ Verification passed — all checks OK${NC}${BOLD}      ║${NC}"
else
    echo -e "${BOLD}║   ${RED}❌ Verification failed — ${ERRORS} error(s)${NC}${BOLD}          ║${NC}"
fi
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

if [[ $ERRORS -eq 0 ]]; then
    echo -e "${BOLD}Next steps:${NC}"
    echo ""
    echo "  📞 Leave a test voicemail"
    echo "  📊 Monitor logs:    journalctl -t voicemail-handler -f"
    echo "  📡 Subscribe MQTT:  mosquitto_sub -h ${MQTT_HOST:-localhost} -t '${MQTT_TOPIC:-freepbx/voicemail}/#' -v"
    echo ""
fi

exit $ERRORS
