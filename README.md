# Shell Access Manager for ISPConfig

Automated time-limited SSH shell user management for ISPConfig 3.3.x servers.  
Automatically disables shell users after idle timeout or hard time limit via ISPConfig Remote API.

**Magyar leírás lentebb / Hungarian description below.**

---

## Features

* **Idle timeout** – Automatically disables shell users after configurable inactivity period (default: 3 hours)
* **Hard time limit** – Maximum session lifetime regardless of activity (default: 8 hours)
* **ISPConfig API integration** – Uses the official Remote JSON API, keeping the ISPConfig panel in sync
* **Jailkit compatible** – Uses `pgrep` for process detection (works with jailkit chroot where `who`/`utmp` does not)
* **Preserves chroot setting** – Only toggles `active`; the user's original chroot value (None / Jailkit) is left untouched
* **DB fallback** – Falls back to direct database updates if the API is unavailable
* **Email notifications** – Alerts on enable, disable, and errors
* **Logging** – Syslog + dedicated log file with logrotate
* **Concurrent safety** – Lock file prevents parallel monitor execution
* **ISPConfig Panel Integration** – Optional web UI with countdown timers, dashboard, and enable/disable buttons (zero ISPConfig files modified!)
* **Update-safe watchdog** – systemd path-unit + hourly timer automatically restore the plugin files within ~30 seconds if an ISPConfig update wipes them

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
                    └────────┬─────────┘  - running processes?
                             │            - last activity time?
                    ┌────────▼─────────┐  - hard limit expired?
                    │  PROCESSES = 0?   │
                    │  IDLE > 3h?       │
                    │  HARD > limit?    │
                    └────────┬─────────┘
                             │ YES
                    ┌────────▼─────────┐    ┌─────────────────────┐
                    │  disable.sh       │───>│  ISPConfig API      │
                    │  (automatic)      │    │  active = 'n'       │
                    └──────────────────┘    │  (chroot untouched) │
                                           │  + session kill      │
                                           │  + email alert       │
                                           └─────────────────────┘
```

### Activity Detection

The monitor uses **`pgrep`** to detect running processes for each shell user. This is critical for ISPConfig servers using **jailkit chroot**, where the traditional `who`/`utmp` mechanism does not work.

- **Any process running** → user is `ACTIVE` → idle timer resets
- **No processes** → idle countdown starts from last activity
- **Enable timestamp floor** → re-enabling a user always resets the idle counter (prevents stale `auth.log` entries from triggering instant disable)

## Requirements

* ISPConfig 3.3.x
* `curl`, `jq`, `mysql-client` (or `mariadb-client`), `at`
* ISPConfig Remote API enabled (System → Server Config → Security → Enable Remote API)

## Installation

```
git clone https://github.com/kalmarr/shell-access-manager-ispconfig.git
cd shell-access-manager-ispconfig
sudo ./install.sh
```

The installer will:

1. Check and install dependencies
2. Copy scripts to `/usr/local/shell-access-manager/`
3. Create state directory and log file
4. Set up logrotate
5. Add cron job (every 10 minutes)
6. **Optionally** install ISPConfig panel integration (if ISPConfig detected)

## Post-Install Setup

### 1. Create ISPConfig Remote API User

ISPConfig Panel → System → Remote Users → Add new Remote User

* **Username:** `shell_manager`
* **Password:** strong password
* **Functions:** check only **Sites Shell-User functions**

### 2. Edit Configuration

```
nano /usr/local/shell-access-manager/shell-access-manager.conf
```

Required changes:

* `API_PASS` – the password you just set
* `NOTIFY_EMAIL` – your email address

Optional:

* `IDLE_LIMIT` – inactivity timeout in seconds (default: 10800 = 3 hours)
* `HARD_LIMIT` – maximum lifetime in seconds (default: 28800 = 8 hours)

### 3. Create Symlinks (optional)

```
ln -s /usr/local/shell-access-manager/enable-shell-user.sh /usr/local/bin/shell-enable
ln -s /usr/local/shell-access-manager/disable-shell-user.sh /usr/local/bin/shell-disable
ln -s /usr/local/shell-access-manager/status.sh /usr/local/bin/shell-status
```

## Usage

### Enable Shell Access

```
shell-enable <username> [hours]

# Examples:
shell-enable web1 3        # Enable for 3 hours
shell-enable web1           # Enable with default hard limit
```

### Disable Shell Access

```
shell-disable <username> [reason]

# Examples:
shell-disable web1
shell-disable web1 "deploy finished"
```

### Check Status

```
shell-status              # All users
shell-status web1          # Specific user
```

---

## ISPConfig Panel Integration (Optional)

A web-based UI that adds countdown timers, status indicators, and enable/disable controls directly into the ISPConfig panel.

### What It Adds

* **SSH-User list page** – 3 new columns: Status (ACTIVE/IDLE/DISABLED), Time Remaining, Access Level
* **SSH-User edit page** – Timer panel with live countdown, process list, and start/restart/disable buttons
* **Shell Timer Dashboard** – Dedicated page accessible from the Sites menu showing all users with real-time status
* **Bulk actions** – Tick several users on the dashboard and start, restart or disable them in one go
* **Auto-refresh** – Dashboard refreshes every 30 seconds, edit page countdown updates every second
* **Stays on the page** – Every action re-renders in place instead of navigating back to the start page

### Bulk Actions on the Dashboard

Each dashboard row has a checkbox (admin only) and each table has a select-all box in its header.
As soon as something is ticked, a sticky action bar appears:

| Button | Effect |
| --- | --- |
| **Indítás 3ó** | Starts every selected user with a 3 hour window |
| **8ó újraindítás** | Restarts the window at 8 hours for every selected user |
| **Letiltás** | Disables every selected user |
| **Kijelölés törlése** | Clears the selection |

One confirmation dialog lists the affected users, then they are processed one after another with a
per-row progress indicator, followed by a summary banner listing any failures. The selection survives
the 30 second auto-refresh, and the refresh pauses while a bulk run is in progress.

**The 8 hour action is a restart, not an extension.** `enable-shell-user.sh` rewrites the state files
and reschedules the `at` job, so both the idle and the hard timer count from the moment the button is
pressed. It never adds time to the current expiry.

#### Why the buttons need `type="button"`

ISPConfig loads every page into `#pageContent`, which sits **inside** its `<form id="pageForm">`.
A `<button>` without an explicit type is a submit button, so clicking one submits that form, reloads
`index.php` and drops the operator on the start page. All panel buttons therefore carry
`type="button"`, use delegated click handlers rather than inline `onclick`, and no code path calls
`location.reload()`.

### How It Works (Update-Safe via Watchdog)

**Zero ISPConfig files are modified.** The integration uses:

1. **Apache `mod_substitute`** – Injects a `<script>` tag into ISPConfig HTML responses via the vhost config (ISPConfig updates don't touch the vhost)
2. **Custom directory** – Plugin files live in `/usr/local/ispconfig/interface/web/shell_timer/`
3. **Sudoers** – Allows the panel process to call enable/disable scripts via `sudo`.
   The grant goes to the user the panel's PHP **actually** runs as, which with the default
   mod_fcgid + suexec setup is the vhost's `SuexecUserGroup`, normally `ispconfig`, **not**
   `www-data`. The installer reads that from the vhost (falling back to the owner of
   `/var/www/php-fcgi-scripts/ispconfig/.php-fcgi-starter`), writes rules for it and for
   `www-data`, and then proves the grant works with
   `runuser -u <user> -- sudo -n -l …` before declaring success. A sudoers file written for the
   wrong user leaves every panel action failing with `sudo: a password is required`, and the file
   existing tells you nothing, which is why the check is a live probe.

#### Update-safe watchdog

Some ISPConfig releases run an `rsync --delete` over `interface/web/`, which can wipe the `shell_timer/` directory. To prevent the plugin from "disappearing" after an update, a **systemd watchdog** is installed alongside it:

* **Template store** – `/usr/local/shell-access-manager/ispconfig-templates/` holds a pristine copy of the plugin files **outside** the ISPConfig tree (so the updater can't touch it).
* **`shell-timer-watchdog.path`** – Reactive systemd path-unit. Triggers as soon as ISPConfig writes a new version (`version.inc.php` changes).
* **`shell-timer-watchdog.service`** – Sleeps 30s (waits for the updater to finish), then runs `ispconfig-redeploy.sh` which idempotently restores any missing or modified plugin file from the template store, re-injects the vhost directive if needed, and reloads Apache only when something actually changed.
* **`shell-timer-watchdog.timer`** – Hourly safety net, in case files vanish without a version bump.

Net effect: after an ISPConfig update, the Timer overlay is back **within ~30 seconds** without any manual action.

Inspect with:
```
systemctl status shell-timer-watchdog.path shell-timer-watchdog.timer
journalctl -t shell-timer-watchdog -n 20
```

### Install ISPConfig Integration

If you skipped it during the main install:

```
sudo bash ispconfig-integration/install.sh install
```

### ISPConfig Integration Status

```
sudo bash ispconfig-integration/install.sh status
```

### Uninstall ISPConfig Integration

```
sudo bash ispconfig-integration/install.sh uninstall
```

This only removes the panel integration; the base shell access manager remains installed.

---

## Files

| File | Description |
| --- | --- |
| `shell-access-manager.conf.example` | Example configuration |
| `lib-functions.sh` | Shared functions and API wrapper |
| `enable-shell-user.sh` | Enable shell access |
| `disable-shell-user.sh` | Disable shell access |
| `monitor-idle-users.sh` | Cron job: idle monitor |
| `status.sh` | Status display |
| `install.sh` | Installer script (with optional ISPConfig integration) |
| `ispconfig-integration/` | ISPConfig panel integration |
| `ispconfig-integration/install.sh` | ISPConfig integration installer |
| `ispconfig-integration/shell_timer/api.php` | AJAX API endpoint |
| `ispconfig-integration/shell_timer/timer.js` | Frontend JS (list/edit page enhancement) |
| `ispconfig-integration/shell_timer/dashboard.php` | Dashboard page with multi-select bulk actions |
| `ispconfig-integration/watchdog/ispconfig-redeploy.sh` | Idempotent restore script (deployed to `/usr/local/shell-access-manager/`) |
| `ispconfig-integration/watchdog/shell-timer-watchdog.path` | systemd path-unit reacting to ISPConfig updates |
| `ispconfig-integration/watchdog/shell-timer-watchdog.service` | systemd oneshot service running the redeploy script |
| `ispconfig-integration/watchdog/shell-timer-watchdog.timer` | systemd hourly safety-net timer |
| `ispconfig-integration/README-watchdog.md` | Watchdog architecture & manual test instructions |

Files created on the server by the integration installer:

| Path | Description |
| --- | --- |
| `/var/lib/shell-access-manager/panel-limits.conf` | World-readable copy of `IDLE_LIMIT` / `HARD_LIMIT` for the panel |
| `/var/backups/shell-timer/` | Backups of vhosts edited by the installer |

**Why the limits are copied:** `shell-access-manager.conf` is mode 0600 root, so the panel process
cannot read it and would silently display the built-in defaults (3h idle, 8h hard) instead of the
configured values.

**Why backups moved out of the vhost directory:** Apache parses every file in `sites-enabled`, so a
`.bak` copy left beside the vhost is read as a second vhost and takes the whole config down with
`Cannot define multiple Listeners on the same IP:port`. Backups now go to `/var/backups/shell-timer/`
and the installer sweeps away any stray copy an earlier version left behind.

## Security Notes

* Config file is chmod 600 (only root can read the API password)
* Remote API user has minimal permissions (Shell User Get + Update only)
* Disable gracefully terminates active sessions (HUP → TERM → KILL)
* Disable does not alter the user's chroot setting (preserves the original None / Jailkit configuration)
* ISPConfig integration: admin-only for enable/disable actions
* ISPConfig integration: sudoers with NOPASSWD only for the three specific scripts, granted to the
  panel's real runtime user (`ispconfig` under suexec) and `www-data`, never to a wildcard
* Lock file prevents concurrent monitor execution
* Logrotate configured (weekly, 12 weeks retention)

## License

MIT License – See [LICENSE](LICENSE)

## Contributing

Pull requests are welcome! Please test on ISPConfig 3.3.x before submitting.

---

# Magyar leírás

## Shell Access Manager ISPConfig-hoz

Automatikus időzített SSH shell user kezelés ISPConfig 3.3.x szerverekhez.

### Funkciók

* **Inaktivitási időtúllépés** – Automatikusan letiltja a shell usert ha nincs futó process (alapértelmezett: 3 óra)
* **Hard limit** – Maximális session élettartam aktivitástól függetlenül (alapértelmezett: 8 óra)
* **ISPConfig API integráció** – A hivatalos Remote JSON API-t használja
* **Jailkit kompatibilis** – `pgrep` alapú process detektálás (működik jailkit chroot-ban is)
* **ISPConfig Panel Integráció** – Opcionális webes UI visszaszámlálóval, dashboarddal, és enable/disable gombokkal
* **Frissítés-biztos watchdog** – systemd path-unit + óránkénti timer automatikusan visszaállítja a plugin fájlokat ~30 másodpercen belül, ha egy ISPConfig frissítés letörölné őket

### Telepítés

```
git clone https://github.com/kalmarr/shell-access-manager-ispconfig.git
cd shell-access-manager-ispconfig
sudo ./install.sh
```

A telepítő felajánlja az ISPConfig panel integráció telepítését is, ha ISPConfig-ot észlel.

### ISPConfig Panel Integráció

Az ISPConfig integráció **egyetlen ISPConfig fájlt sem módosít** – Apache `mod_substitute` és saját könyvtár segítségével működik. ISPConfig frissítés után **semmi teendő**.

Külön telepítés:
```
sudo bash ispconfig-integration/install.sh install
```

### Használat

```
shell-enable <felhasználó> [órák]    # Engedélyezés
shell-disable <felhasználó>          # Letiltás
shell-status                          # Állapot
```
