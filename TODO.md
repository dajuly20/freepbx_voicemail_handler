
[ ] Update README.md

    Run shellcheck on scripts
    Read README.md
    Write README.md
    182 lines

    **Topic:** `{MQTT_TOPIC}/{mailbox}` (e.g. `freepbx/voicemail/100`)
    Full details as JSON:


    ```json
    {
        "event": "new_voicemail",
        "context": "default",
        "mailbox": "100",
        "new_count": 1,
        "callerid": "\"Max Mustermann\" <0171234567>",
        "duration": "12",
        "date": "Tue Feb 04 06:30:00 PM CET 2026",
        "file": "/var/spool/asterisk/voicemail/default/100/INBOX/msg0001.wav"
    }
    ```


**Topic:** `{MQTT_TOPIC}/{mailbox}/count` (e.g. `freepbx/voicemail/100/count`)
Plain number, published as **retained** message — ideal for Home Assistant sensors.
### 3. Caller ID (`EVENT_CALLERID`)
**Topic:** `{MQTT_TOPIC}/{mailbox}/callerid` (e.g. `freepbx/voicemail/100/callerid`)
Caller identification string, useful for notification displays.

´´'
"Max Mustermann" <0171234567>
```

## File Structure

| File | Target | Description |
| --- | --- | --- |
| `voicemail-handler.sh` | `/usr/local/bin/voicemail-handler.sh` | Handler script called by Asterisk |
| `mqtt.conf` | `/etc/asterisk/mqtt.conf` | MQTT broker connection settings |
| `voicemail-handler.conf` | `/etc/asterisk/voicemail-handler.conf` | Topic prefix + event configuration |
| `install.sh` | — | Interactive installer |

## Installation

```bash
git clone https://github.com/dajuly20/freepbx_voicemail_handler.git
cd freepbx_voicemail_handler
sudo bash install.sh
```

### What the installer does

The install script runs in five phases. **No changes are applied until you explicitly confirm.**

#### Phase 0 — Verify Asterisk environment

Checks that the system is ready:

- Asterisk binary, version, config directory
- Voicemail spool (`/var/spool/asterisk/voicemail/`)
- `app_voicemail` module loaded
- FreePBX detection (adjusts post-install instructions)
- Source files present

Aborts if Asterisk is not installed or `/etc/asterisk/` is missing.

#### Phase 1 — Check dependencies

- Checks if `mosquitto_pub` (from `mosquitto-clients`) is available

#### Phase 2 — Configuration (interactive)

Only runs on fresh install or when migrating from old config format.

**MQTT Broker:** Host, port, username, password (password input hidden).

**MQTT Topic:** Base topic prefix (default: `freepbx/voicemail`).

**Event selection:** Choose which events publish MQTT messages:

```
1) New voicemail   — full details as JSON
2) Message count   — retained, ideal for HA sensors
3) Caller ID       — for notifications

Enable (space-separated, Enter = all) [1 2 3]:
```

If configs already exist, this phase is skipped and existing settings are kept.

#### Phase 3 — Preview planned changes

Shows a full summary of every planned change with status tags:

| Status | Meaning |
| --- | --- |
| `[NEW]` | File does not exist — will be created |
| `[UPDATE]` | File differs — will be overwritten (backup saved) |
| `[SKIP]` | Already identical — nothing to do |
| `[KEEP]` | Config exists with custom settings — not overwritten |
| `[MIGRATE]` | Old config format detected — will be converted |
| `[CONFLICT]` | `externnotify` set to a different script — manual change required |
| `[INSTALL]` | System package will be installed |
| `[BACKUP]` | File will be backed up before changes |

#### Phase 4 — Confirm & Apply

After confirmation (`y/N`), the installer:

1. Installs `mosquitto-clients` if needed
2. Installs the handler script (`755`, `root:root`)
3. Writes MQTT config (`640`, `root:asterisk`)
4. Writes handler config with event settings (`640`, `root:asterisk`)
5. Configures `externnotify` in `voicemail_custom.conf`

All overwritten files are backed up to `/etc/asterisk/voicemail-handler-backup/`.

### Undo / Restore

```bash
sudo bash install.sh --restore
```

Shows a diff of what will be restored and asks for confirmation.

## Configuration

### MQTT Connection — `/etc/asterisk/mqtt.conf`

```bash
MQTT_HOST="mqtt.mrz.ip"
MQTT_PORT=1883
MQTT_USER=""
MQTT_PASS=""
```

### Events & Topic — `/etc/asterisk/voicemail-handler.conf`

```bash
MQTT_TOPIC="freepbx/voicemail"

EVENT_NEW_VM=true      # Full voicemail details (JSON)
EVENT_COUNT=true       # Message count (retained)
EVENT_CALLERID=true    # Caller ID string
```

Set any event to `false` to disable it.

## Testing

Subscribe to the topic and leave a test voicemail:

```bash
mosquitto_sub -h mqtt.mrz.ip -t 'freepbx/voicemail/#' -v
```

Check logs:

```bash
journalctl -t voicemail-handler -f
```

## How It Works

Asterisk calls the handler via `externnotify` each time a new voicemail is recorded. The script receives the context, mailbox number, and message count as arguments, reads caller metadata from the voicemail `.txt` file, and publishes to MQTT based on the enabled events.
You've hit your limit · resets 1pm (Europe/Berlin)

MQTT Message
Topic: freepbx/voicemail/{mailbox} (e.g. freepbx/voicemail/100)

Payload:
 

Bitte füge hier obendrüber noch ein, wo der Einstiegspunkt ist, und mit welchen parametern was dann welche datei aufruft usw.
You've hit your limit · resets 1pm (Europe/Berlin)