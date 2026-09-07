# Shell Timer — Update-safe Watchdog

A Shell Timer plugin az **eredeti, GitHub-on lévő architektúrát** használja:
- Fájlok: `/usr/local/ispconfig/interface/web/shell_timer/{api.php,timer.js,dashboard.php}`
- Apache `mod_substitute` injekció az `ispconfig.vhost`-ban (port 8080)
- Sudoers: `/etc/sudoers.d/shell-timer`

Mivel **az ISPConfig frissítő bizonyos kiadásokban törli az `interface/web/` alatti ismeretlen alkönyvtárakat**, ez a watchdog réteg gondoskodik arról, hogy a plugin frissítés után **percen belül** automatikusan visszakerüljön — kézi beavatkozás nélkül.

## Hogyan működik

```
ISPConfig update
      │
      ├─ rsync --delete az interface/web alatt → shell_timer/ eltűnik
      └─ version.inc.php új tartalommal íródik
                                                       │
                                                       ▼
                                        systemd path-unit triggerel
                                        (shell-timer-watchdog.path)
                                                       │
                                                       ▼
                              shell-timer-watchdog.service
                              ExecStartPre: sleep 30s
                              ExecStart: ispconfig-redeploy.sh
                                                       │
                                                       ▼
                              /usr/local/shell-access-manager/
                              ispconfig-templates/  → visszamásol
                                                       │
                                                       ▼
                              systemctl reload apache2
                              (csak ha tényleg változott)
```

## Komponensek

| Fájl | Cél |
|------|-----|
| `ispconfig-redeploy.sh` | Idempotens visszamásoló script. Telepítve: `/usr/local/shell-access-manager/ispconfig-redeploy.sh` |
| `shell-timer-watchdog.path` | Reaktív trigger a `version.inc.php` változására |
| `shell-timer-watchdog.service` | A redeploy-t végrehajtó oneshot service (30s preprocessing delay) |
| `shell-timer-watchdog.timer` | Tartalék-háló: óránként újraellenőriz |

A "stabil forrás" (`/usr/local/shell-access-manager/ispconfig-templates/`) az ISPConfig fán **kívül** él, ezért az updater soha nem érinti.

**A sablonokat az `ispconfig-integration/install.sh` frissíti**, minden telepítéskor, a most kitelepített
fájlokból. Korábban ezt csak a repó gyökerében lévő `install.sh` tette meg, így aki az integrációs
telepítőt futtatta önmagában, annál a sablonok régiek maradtak, és a watchdog egy órán belül
visszaírta a régi fájlokat a frissen telepítettek helyére: minden deploy legfeljebb egy óráig élt.

**A jelöltek szűrve vannak.** Nem elég a fájlnév: a `sites-available/ispconfig.conf` egyes gépeken az
ISPConfig *globális* Apache-konfigja (`ServerTokens`, vlogger, `NameVirtualHost` sorok), amiben
nincs `<VirtualHost>` blokk, és a `sites-enabled/000-ispconfig.conf` symlink miatt mégis élőnek
látszik. Jelölt csak az a fájl lehet, amiben van `</VirtualHost>` **és** hivatkozik a panel
docrootjára (`/usr/local/ispconfig/interface/web` vagy `/var/www/ispconfig`).

**A vhost-kezelés közös**, az `ispconfig-integration/lib-apache.sh` fájlban. A watchdog és a telepítő
ugyanazt a `readlink -f`-fel feloldott, ténylegesen élő vhost-listát írja, ugyanoda ment
(`/var/backups/shell-timer/`), és a végén mindkettő megnézi, hogy a panel HTML-jében pontosan egyszer
szerepel-e a `timer.js`. Korábban a két szkriptben külön másolat élt ebből a logikából, és elcsúsztak.

## Naplózás

Minden visszaállítás syslog-ba kerül `shell-timer-watchdog` taggel:

```bash
journalctl -t shell-timer-watchdog -n 20
# vagy:
journalctl -u shell-timer-watchdog.service -n 20
```

## Manuális teszt

```bash
# Szimulált update: töröljük a plugint
sudo rm -rf /usr/local/ispconfig/interface/web/shell_timer

# Kézzel triggereljük a watchdog-ot (a 30s delay miatt ~35s múlva)
sudo systemctl start shell-timer-watchdog.service

# Ellenőrizzük
ls /usr/local/ispconfig/interface/web/shell_timer/
journalctl -t shell-timer-watchdog -n 5
```

## Eltávolítás

A teljes uninstall (`./install.sh uninstall`) a watchdog-ot is leszedi.
