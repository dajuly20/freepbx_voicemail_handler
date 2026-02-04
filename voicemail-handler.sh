#!/bin/bash
# voicemail-handler.sh - Called by Asterisk externnotify
# Publishes voicemail info via MQTT
# Parameters: $1=context $2=mailbox $3=new_message_count

set -euo pipefail

CONFIG_FILE="/etc/asterisk/voicemail-handler.conf"

# Load config
if [[ ! -f "$CONFIG_FILE" ]]; then
    logger -t voicemail-handler "ERROR: Config not found: $CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

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

# Build JSON payload
PAYLOAD=$(cat <<EOF
{
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

# Build mosquitto_pub command
MQTT_CMD=(mosquitto_pub
    -h "$MQTT_HOST"
    -p "${MQTT_PORT:-1883}"
    -t "${MQTT_TOPIC:-freepbx/voicemail}/${MAILBOX}"
    -m "$PAYLOAD"
)

# Add auth if configured
if [[ -n "${MQTT_USER:-}" ]]; then
    MQTT_CMD+=(-u "$MQTT_USER")
    if [[ -n "${MQTT_PASS:-}" ]]; then
        MQTT_CMD+=(-P "$MQTT_PASS")
    fi
fi

# Publish
if "${MQTT_CMD[@]}" 2>/dev/null; then
    logger -t voicemail-handler "MQTT published to ${MQTT_TOPIC:-freepbx/voicemail}/${MAILBOX}"
else
    logger -t voicemail-handler "ERROR: MQTT publish failed"
fi
