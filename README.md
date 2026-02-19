# Shell Access Manager for ISPConfig

Automated time-limited SSH shell user management for ISPConfig 3.3.x servers.  
Automatically disables shell users after idle timeout or hard time limit via ISPConfig Remote API.

**Magyar leírás lentebb / Hungarian description below.**

---

## Features

- **Idle timeout** – Automatically disables shell users after configurable inactivity period (default: 3 hours)
- **Hard time limit** – Maximum session lifetime regardless of activity (default: 8 hours)
- **ISPConfig API integration** – Uses the official Remote JSON API, keeping the ISPConfig panel in sync
- **Jailkit on disable** – Automatically sets chroot to jailkit when disabling (restricts user to their own directory)
- **DB fallback** – Falls back to direct database updates if the API is unavailable
- **Email notifications** – Alerts on enable, disable, and errors
- **Logging** – Syslog + dedicated log file with logrotate
- **Concurrent safety** – Lock file prevents parallel monitor execution

## How It Works

```
┌─────────────┐    ┌──────────────────┐    ┌─────────────────────┐
│  enable.sh   │───>│  ISPConfig API    │───>│  Shell user active  │
│  (manual)    │    │  active = 'y'     │    │  SSH login allowed  │
└─────────────┘    └──────────────────┘    └─────────┬───────────┘
                                                      │
                    ┌──────────────────┐              │
                    │  monitor (cron)   │<─────────────┘
                    │  */10 * * * *     │  checks:
                    └────────┬─────────┘  - active SSH sessions?
                             │            - last activity time?
                    ┌────────▼─────────┐  - hard limit expired?
                    │  IDLE > 3h?       │
                    │  HARD > limit?    │
                    └────────┬─────────┘
                             │ YES
                    ┌────────▼─────────┐    ┌─────────────────────┐
                    │  disable.sh       │───>│  ISPConfig API      │
                    │  (automatic)      │    │  active = 'n'       │
                    └──────────────────┘    │  chroot = jailkit   │
                                           │  + session kill      │
                                           │  + email alert       │
                                           └─────────────────────┘
```

## Requirements

- ISPConfig 3.3.x
- `curl`, `jq`, `mysql-client` (or `mariadb-client`), `at`
- ISPConfig Remote API enabled (System → Server Config → Security → Enable Remote API)

## Installation

```bash
git clone https://github.com/YOUR_USERNAME/shell-access-manager-ispconfig.git
cd shell-access-manager-ispconfig
sudo ./install.sh
```

The installer will:
1. Check and install dependencies
2. Copy scripts to `/usr/local/shell-access-manager/`
3. Create state directory and log file
4. Set up logrotate
5. Add cron job (every 10 minutes)

## Post-Install Setup

### 1. Create ISPConfig Remote API User

ISPConfig Panel → System → Remote Users → Add new Remote User

- **Username:** `shell_manager`
- **Password:** strong password
- **Functions:** check only **Sites Shell-User functions**

### 2. Edit Configuration

```bash
nano /usr/local/shell-access-manager/shell-access-manager.conf
```

Required changes:
- `API_PASS` – the password you just set
- `NOTIFY_EMAIL` – your email address

Optional:
- `IDLE_LIMIT` – inactivity timeout in seconds (default: 10800 = 3 hours)
- `HARD_LIMIT` – maximum lifetime in seconds (default: 28800 = 8 hours)

### 3. Create Symlinks (optional)

```bash
ln -s /usr/local/shell-access-manager/enable-shell-user.sh /usr/local/bin/shell-enable
ln -s /usr/local/shell-access-manager/disable-shell-user.sh /usr/local/bin/shell-disable
ln -s /usr/local/shell-access-manager/status.sh /usr/local/bin/shell-status
```

## Usage

### Enable Shell Access
```bash
shell-enable <username> [hours]

# Examples:
shell-enable web1 3        # Enable for 3 hours
shell-enable web1           # Enable with default hard limit
```

### Disable Shell Access
```bash
shell-disable <username> [reason]

# Examples:
shell-disable web1
shell-disable web1 "deploy finished"
```

### Check Status
```bash
shell-status              # All users
shell-status web1          # Specific user
```

### Sample Output
```
╔══════════════════════════════════════════════════════════════════╗
║              Shell Access Manager - Status                      ║
╚══════════════════════════════════════════════════════════════════╝

| User   | Active | Chroot  | Website        |
|--------|--------|---------|----------------|
| web1   | y      | jailkit | example.com    |
| web2   | n      | jailkit | example.org    |

  👤 web1
     Enabled at:   2026-02-19 18:14 (0h 30m)
     Hard limit:   3h 0m (remaining: 2h 30m)
     Activity:     Idle: 0h 10m (remaining: 2h 50m)
     Sessions:     0 active
```

## Files

| File | Description |
|------|-------------|
| `shell-access-manager.conf.example` | Example configuration |
| `lib-functions.sh` | Shared functions and API wrapper |
| `enable-shell-user.sh` | Enable shell access |
| `disable-shell-user.sh` | Disable shell access |
| `monitor-idle-users.sh` | Cron job: idle monitor |
| `status.sh` | Status display |
| `install.sh` | Installer script |

## Security Notes

- Config file is chmod 600 (only root can read the API password)
- Remote API user has minimal permissions (Shell User Get + Update only)
- Disable gracefully terminates active sessions (HUP → TERM → KILL)
- Jailkit chroot is enforced on disable
- Lock file prevents concurrent monitor execution
- Logrotate configured (weekly, 12 weeks retention)

## ISPConfig API Format

This tool uses the ISPConfig 3.3.x JSON API format where the method name is passed as a URL query parameter and parameters are sent as JSON body:

```bash
curl -sk -X POST "https://localhost:8080/remote/json.php?login" \
  -H "Content-Type: application/json" \
  -d '{"username":"api_user","password":"api_pass"}'
```

## License

MIT License – See [LICENSE](LICENSE)

## Contributing

Pull requests are welcome! Please test on ISPConfig 3.3.x before submitting.

---

# Magyar leírás

## Shell Access Manager ISPConfig-hoz

Automatikus időzített SSH shell user kezelés ISPConfig 3.3.x szerverekhez.

### Funkciók

- **Inaktivitási időtúllépés** – Automatikusan letiltja a shell usert ha megadott ideig inaktív (alapértelmezett: 3 óra)
- **Hard limit** – Maximális session élettartam aktivitástól függetlenül (alapértelmezett: 8 óra)
- **ISPConfig API integráció** – A hivatalos Remote JSON API-t használja, az ISPConfig panel szinkronban marad
- **Jailkit letiltáskor** – Automatikusan jailkit chroot-ba zárja a usert letiltáskor
- **DB fallback** – Ha az API nem elérhető, közvetlen adatbázis-módosítással dolgozik
- **Email értesítések** – Értesít engedélyezéskor, letiltáskor és hiba esetén

### Használat

```bash
shell-enable <felhasználó> [órák]    # Engedélyezés
shell-disable <felhasználó>          # Letiltás
shell-status                          # Állapot
```

### Telepítés

```bash
git clone https://github.com/YOUR_USERNAME/shell-access-manager-ispconfig.git
cd shell-access-manager-ispconfig
sudo ./install.sh
```

Részletes telepítési útmutató fentebb angol nyelven.
