#!/bin/bash
# voicemail-handler.sh - Called by Asterisk externnotify
# Publishes voicemail info via MQTT
# Parameters: $1=context $2=mailbox $3=new_message_count

set -euo pipefail

MQTT_CONF="/etc/asterisk/mqtt.conf"
HANDLER_CONF="/etc/asterisk/voicemail-handler.conf"

# Load MQTT connection config
if [[ ! -f "$MQTT_CONF" ]]; then
    logger -t voicemail-handler "ERROR: Config not found: $MQTT_CONF"
    exit 1
fi
# shellcheck source=/etc/asterisk/mqtt.conf
source "$MQTT_CONF"

# Load handler config
if [[ ! -f "$HANDLER_CONF" ]]; then
    logger -t voicemail-handler "ERROR: Config not found: $HANDLER_CONF"
    exit 1
fi
# shellcheck source=/etc/asterisk/voicemail-handler.conf
source "$HANDLER_CONF"

CONTEXT="${1:-}"
MAILBOX="${2:-}"
NEW_COUNT="${3:-0}"

if [[ -z "$MAILBOX" ]]; then
    logger -t voicemail-handler "ERROR: No mailbox specified"
    exit 1
fi

VM_DIR="/var/spool/asterisk/voicemail/${CONTEXT}/${MAILBOX}/INBOX"

# Find the latest voicemail
LATEST_WAV=$(ls -t "${VM_DIR}"/msg*.wav 2>/dev/null | head -1)
LATEST_TXT="${LATEST_WAV%.wav}.txt"

# Parse caller info from .txt file
CALLERID=""
DURATION=""
ORIGDATE=""
if [[ -f "$LATEST_TXT" ]]; then
    CALLERID=$(grep "^callerid=" "$LATEST_TXT" | cut -d= -f2-)
    DURATION=$(grep "^duration=" "$LATEST_TXT" | cut -d= -f2-)
    ORIGDATE=$(grep "^origdate=" "$LATEST_TXT" | cut -d= -f2-)
fi

logger -t voicemail-handler "New voicemail: mailbox=${MAILBOX} caller=${CALLERID} duration=${DURATION}s"

# ── MQTT publish helper ──────────────────────────────────────────

mqtt_publish() {
    local topic="$1"
    local payload="$2"
    local retain="${3:-}"

    local cmd=(mosquitto_pub -h "$MQTT_HOST" -p "${MQTT_PORT:-1883}" -t "$topic" -m "$payload")

    if [[ -n "${MQTT_USER:-}" ]]; then
        cmd+=(-u "$MQTT_USER")
        [[ -n "${MQTT_PASS:-}" ]] && cmd+=(-P "$MQTT_PASS")
    fi

    [[ "$retain" == "-r" ]] && cmd+=(-r)

    if "${cmd[@]}" 2>/dev/null; then
        logger -t voicemail-handler "MQTT published to ${topic}"
    else
        logger -t voicemail-handler "ERROR: MQTT publish failed for ${topic}"
    fi
}

TOPIC_BASE="${MQTT_TOPIC:-freepbx/voicemail}/${MAILBOX}"

# ── Event: New voicemail (full details) ──────────────────────────

if [[ "${EVENT_NEW_VM:-true}" == "true" ]]; then
    PAYLOAD=$(cat <<EOF
{
    "event": "new_voicemail",
    "context": "${CONTEXT}",
    "mailbox": "${MAILBOX}",
    "new_count": ${NEW_COUNT},
    "callerid": "${CALLERID}",
    "duration": "${DURATION}",
    "date": "${ORIGDATE}",
    "file": "${LATEST_WAV:-}"
}
EOF
)
    mqtt_publish "$TOPIC_BASE" "$PAYLOAD"
fi

# ── Event: Message count (retained) ─────────────────────────────

if [[ "${EVENT_COUNT:-true}" == "true" ]]; then
    mqtt_publish "${TOPIC_BASE}/count" "$NEW_COUNT" "-r"
fi

# ── Event: Caller ID ────────────────────────────────────────────

if [[ "${EVENT_CALLERID:-true}" == "true" ]]; then
    mqtt_publish "${TOPIC_BASE}/callerid" "$CALLERID"
fi
