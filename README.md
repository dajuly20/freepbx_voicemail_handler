# FreePBX Voicemail MQTT Handler

Publishes new voicemail events from FreePBX/Asterisk to an MQTT broker via `externnotify`.

When a voicemail is recorded, the handler parses caller info and publishes a JSON message to MQTT — ready for Home Assistant, Node-RED, or any other MQTT consumer.

## MQTT Message

**Topic:** `freepbx/voicemail/{mailbox}` (e.g. `freepbx/voicemail/100`)

**Payload:**
```json
{
    "context": "default",
    "mailbox": "100",
    "new_count": 1,
    "callerid": "\"Max Mustermann\" <0171234567>",
    "duration": "12",
    "date": "Tue Feb 04 06:30:00 PM CET 2026",
    "file": "/var/spool/asterisk/voicemail/default/100/INBOX/msg0001.wav"
}
```

## Installation

```bash
git clone https://github.com/dajuly20/freepbx_voicemail_handler.git
cd freepbx_voicemail_handler
sudo bash install.sh
```

The install script will:
1. Install `mosquitto-clients` if not present
2. Copy the handler to `/usr/local/bin/voicemail-handler.sh`
3. Copy the config to `/etc/asterisk/voicemail-handler.conf`
4. Configure `externnotify` in `voicemail_custom.conf`

After installation, reload Asterisk:
```bash
asterisk -rx 'voicemail reload'
```

## Configuration

Edit `/etc/asterisk/voicemail-handler.conf`:

```bash
MQTT_HOST="mqtt.mrz.ip"
MQTT_PORT=1883
MQTT_TOPIC="freepbx/voicemail"

# Optional auth
MQTT_USER=""
MQTT_PASS=""
```

## Testing

Subscribe to the topic and leave a test voicemail:
```bash
mosquitto_sub -h mqtt.mrz.ip -t 'freepbx/voicemail/#'
```

Check logs:
```bash
journalctl -t voicemail-handler
```

## How It Works

Asterisk calls the handler via `externnotify` each time a new voicemail is recorded. The script receives the context, mailbox number, and message count as arguments, reads caller metadata from the voicemail `.txt` file, and publishes it to MQTT using `mosquitto_pub`.
