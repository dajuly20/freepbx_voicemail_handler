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

### What the installer does

The install script runs in four phases. **No changes are applied until you explicitly confirm.**

#### Phase 0 — Verify Asterisk environment

The installer checks that the system is ready:

- **Asterisk binary** — Is `asterisk` in PATH?
- **Asterisk version** — Detected via `asterisk -V` and displayed for reference
- **Config directory** — Does `/etc/asterisk/` exist?
- **Voicemail spool** — Does `/var/spool/asterisk/voicemail/` exist? (Warning if not — the directory is created when the first mailbox is configured)
- **app_voicemail module** — Is the voicemail module loaded in the running Asterisk instance? (Skipped if Asterisk is not running)
- **FreePBX detection** — Checks for `fwconsole` and `/var/www/html/admin`. If FreePBX is detected, the post-install instructions include `fwconsole reload`
- **Source files** — Are `voicemail-handler.sh` and `voicemail-handler.conf` present in the repo?

The installer aborts with an error if Asterisk is not installed or `/etc/asterisk/` is missing.

#### Phase 1 — Check dependencies

- Checks if `mosquitto_pub` (from `mosquitto-clients`) is available

#### Phase 2 — Preview planned changes

Before touching any file, the installer shows a full summary of every planned change. Each file is marked with a status:

| Status       | Meaning |
|--------------|---------|
| `[NEW]`      | File does not exist yet — will be created. Shows a unified diff against `/dev/null`. |
| `[UPDATE]`   | File exists but differs — shows a unified diff of old vs. new. |
| `[SKIP]`     | File already exists and is identical — nothing to do. |
| `[KEEP]`     | Config file exists with custom settings — will **not** be overwritten. A `.new` copy is saved for reference. |
| `[CONFLICT]` | `externnotify` is already set to a different script — will **not** be changed automatically. |
| `[INSTALL]`  | A system package needs to be installed (`mosquitto-clients`). |

Files checked:

| File | Description |
|------|-------------|
| `/usr/local/bin/voicemail-handler.sh` | The handler script called by Asterisk |
| `/etc/asterisk/voicemail-handler.conf` | MQTT broker configuration |
| `/etc/asterisk/voicemail_custom.conf` | Asterisk voicemail config (`externnotify` directive) |

If there are no changes needed, the installer exits with "Nothing to do".

#### Phase 3 — Confirm

```
Apply these changes? [y/N]
```

Nothing is written until you answer `y`. Any other input aborts.

#### Phase 4 — Apply changes

Only after confirmation, the installer:

1. **Installs `mosquitto-clients`** via `apt-get` (if not already present)
2. **Copies the handler script** to `/usr/local/bin/voicemail-handler.sh` (mode `755`, owner `root:root`)
3. **Copies the config** to `/etc/asterisk/voicemail-handler.conf` (mode `640`, owner `root:asterisk`) — or saves a `.new` reference copy if the config already exists
4. **Configures `externnotify`** in `/etc/asterisk/voicemail_custom.conf`:
   - Creates the file with a `[general]` section if it doesn't exist
   - Adds the directive to an existing `[general]` section
   - Warns (without changing) if `externnotify` is already set to something else

### After installation

Reload the voicemail module so Asterisk picks up the `externnotify` setting:

```bash
# FreePBX
fwconsole reload

# or vanilla Asterisk
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
