<?php
/**
 * Shell Timer Dashboard for ISPConfig
 * Shows all shell users with real-time timer status
 *
 * Location: /usr/local/ispconfig/interface/web/shell_timer/dashboard.php
 *
 * IMPORTANT: this page is loaded via AJAX into #pageContent, which lives
 * INSIDE ISPConfig's <form id="pageForm">. Every <button> therefore MUST
 * carry type="button", otherwise clicking it submits pageForm and the panel
 * navigates away to the start page.
 */

$conf_file_check = realpath(dirname(__FILE__) . '/../../lib/config.inc.php');
if (!$conf_file_check || !file_exists($conf_file_check)) {
    die('ISPConfig not found');
}
require_once $conf_file_check;
require_once realpath(dirname(__FILE__) . '/../../lib/app.inc.php');

if (!isset($_SESSION['s']['user']) || empty($_SESSION['s']['user']['userid'])) {
    die('Not authenticated');
}

$is_admin = (isset($_SESSION['s']['user']['typ']) && $_SESSION['s']['user']['typ'] === 'admin');
?>

<div class="page-header">
    <h1><span class="fa fa-clock-o"></span> Shell Timer Dashboard</h1>
</div>
<p>Valós idejű SSH hozzáférés kezelés — automatikusan frissül 30 másodpercenként.</p>

<div id="shell-timer-dashboard">
    <div class="text-center" style="padding:40px">
        <span class="fa fa-spinner fa-spin fa-2x"></span>
        <p style="margin-top:10px">Betöltés...</p>
    </div>
</div>

<script>
(function() {
    'use strict';

    const API = '/shell_timer/api.php';
    const ROOT_ID = 'shell-timer-dashboard';
    const isAdmin = <?php echo $is_admin ? 'true' : 'false'; ?>;
    const REFRESH_MS = 30000;
    const CONFIRM_LIST_MAX = 15;

    // The dashboard can be (re)loaded many times into #pageContent without a
    // page reload. Kill the poller left behind by a previous load.
    if (window.__shellTimerDashTimer) {
        clearInterval(window.__shellTimerDashTimer);
        window.__shellTimerDashTimer = null;
    }

    const state = {
        selected: new Set(),   // usernames ticked by the operator
        busy: false,           // a bulk run is in progress
        notice: null           // { type, title, details } summary banner
    };

    function root() { return document.getElementById(ROOT_ID); }

    // ========================================
    // Formatting helpers
    // ========================================

    function fmt(sec) {
        if (!sec || sec <= 0) return '0p';
        const h = Math.floor(sec / 3600);
        const m = Math.floor((sec % 3600) / 60);
        return h > 0 ? h + 'ó ' + m + 'p' : m + 'p';
    }

    function fmtDate(epoch) {
        if (!epoch) return '-';
        return new Date(epoch * 1000).toLocaleString('hu-HU', {
            month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit'
        });
    }

    function esc(str) {
        const d = document.createElement('div');
        d.textContent = (str === null || str === undefined) ? '' : String(str);
        return d.innerHTML;
    }

    // esc() does not escape quotes, so attribute values need their own helper.
    function escAttr(str) {
        return String((str === null || str === undefined) ? '' : str)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    }

    function badge(state_) {
        const map = {
            active:   '<span class="label label-success" style="font-size:12px;padding:4px 8px">● AKTÍV</span>',
            idle:     '<span class="label label-info" style="font-size:12px;padding:4px 8px">◐ IDLE</span>',
            warning:  '<span class="label label-warning" style="font-size:12px;padding:4px 8px">⚠ LEJÁR</span>',
            expired:  '<span class="label label-danger" style="font-size:12px;padding:4px 8px">✕ LEJÁRT</span>',
            disabled: '<span class="label label-default" style="font-size:12px;padding:4px 8px">◻ TILTVA</span>'
        };
        return map[state_] || map.disabled;
    }

    function chrootBadge(chroot) {
        if (chroot === 'jailkit') return '<span class="label label-info" style="font-size:11px">Jailkit (korlátozott)</span>';
        if (chroot === 'no' || chroot === '') return '<span class="label label-danger" style="font-size:11px">Teljes shell ⚠️</span>';
        return '<span class="label label-default" style="font-size:11px">' + esc(chroot || '?') + '</span>';
    }

    // ========================================
    // API
    // ========================================

    async function apiCall(action, params) {
        const qs = new URLSearchParams(params || {});
        qs.set('action', action);
        try {
            const r = await fetch(API + '?' + qs.toString(), { credentials: 'same-origin' });
            if (!r.ok) return { status: 'error', error: 'HTTP ' + r.status };
            return await r.json();
        } catch (e) {
            return { status: 'error', error: e.message || 'hálózati hiba' };
        }
    }

    // ========================================
    // Rendering
    // ========================================

    async function loadDashboard() {
        const el = root();
        if (!el) return;
        const data = await apiCall('list');
        if (!data || !data.users) {
            el.innerHTML = noticeHtml() +
                '<div class="alert alert-danger"><strong>Hiba:</strong> ' +
                esc((data && (data.error || data.output)) || 'nem sikerült betölteni a listát') + '</div>';
            return;
        }
        render(data);
    }

    function render(data) {
        const el = root();
        if (!el) return;

        const users = data.users;

        // Drop selections for users that no longer exist.
        const names = new Set(users.map(u => u.username));
        state.selected.forEach(u => { if (!names.has(u)) state.selected.delete(u); });

        const activeUsers = users.filter(u => u.timer.state !== 'disabled');
        const disabledUsers = users.filter(u => u.timer.state === 'disabled');

        let html = noticeHtml();

        // Summary cards
        html += '<div class="row" style="margin-bottom:20px">';
        html += summaryCard('Összes', users.length, 'default', 'fa-users');
        html += summaryCard('Aktív', activeUsers.filter(u => u.timer.state === 'active').length, 'success', 'fa-check-circle');
        html += summaryCard('Idle', activeUsers.filter(u => u.timer.state === 'idle' || u.timer.state === 'warning').length, 'warning', 'fa-clock-o');
        html += summaryCard('Letiltva', disabledUsers.length, 'default', 'fa-lock');
        html += '</div>';

        // Bulk action bar (admin only, hidden until something is selected)
        if (isAdmin) html += bulkBarHtml();

        // Config info
        html += '<div class="well well-sm" style="font-size:12px;margin-bottom:15px">';
        html += '<strong>Beállítások:</strong> Idle limit: <strong>' + fmt(data.config.idle_limit) + '</strong> | ';
        html += 'Hard limit: <strong>' + fmt(data.config.hard_limit) + '</strong> | ';
        html += 'Szerver idő: ' + new Date(data.server_time * 1000).toLocaleTimeString('hu-HU');
        html += ' <button type="button" class="btn btn-xs btn-default pull-right" data-st-action="refresh">';
        html += '<span class="fa fa-refresh"></span> Frissítés</button>';
        html += '</div>';

        // Active users table
        html += '<h4 style="color:#5cb85c"><span class="fa fa-bolt"></span> Aktív hozzáférések</h4>';
        html += renderTable(activeUsers, true, 'active');

        // Disabled users table
        html += '<h4 style="margin-top:25px;color:#999"><span class="fa fa-lock"></span> Letiltott userek</h4>';
        html += renderTable(disabledUsers, false, 'disabled');

        el.innerHTML = html;
        restoreSelection();
    }

    function noticeHtml() {
        if (!state.notice) return '';
        const n = state.notice;
        let h = '<div class="alert alert-' + n.type + '" style="margin-bottom:15px">';
        h += '<button type="button" class="close" data-st-action="dismiss-notice" aria-label="Bezár">&times;</button>';
        h += '<strong>' + esc(n.title) + '</strong>';
        if (n.details) {
            h += '<pre style="margin:8px 0 0;font-size:11px;max-height:200px;overflow:auto;background:#fff">' +
                 esc(n.details) + '</pre>';
        }
        h += '</div>';
        return h;
    }

    function summaryCard(title, count, style, icon) {
        return '<div class="col-sm-3"><div class="panel panel-' + style + '">' +
            '<div class="panel-body text-center">' +
            '<span class="fa ' + icon + ' fa-2x" style="opacity:0.6"></span>' +
            '<div style="font-size:28px;font-weight:bold;margin:5px 0">' + count + '</div>' +
            '<div style="font-size:12px;color:#666">' + title + '</div>' +
            '</div></div></div>';
    }

    function bulkBarHtml() {
        return '<div id="st-bulk-bar" style="display:none;position:sticky;top:0;z-index:10;margin-bottom:15px;' +
            'padding:10px 12px;background:#f5f9ff;border:1px solid #b7d4f5;border-radius:4px;' +
            'box-shadow:0 2px 6px rgba(0,0,0,.12)">' +
            '<strong id="st-bulk-count" style="line-height:30px">0 elem kijelölve</strong>' +
            '<span class="pull-right">' +
            '<button type="button" class="btn btn-sm btn-success" data-st-action="bulk-enable" data-st-hours="3">' +
                '<span class="fa fa-play"></span> Indítás 3ó</button> ' +
            '<button type="button" class="btn btn-sm btn-primary" data-st-action="bulk-enable" data-st-hours="8" ' +
                'title="A timer újraindítása 8 órára, a mostani időponttól">' +
                '<span class="fa fa-clock-o"></span> 8ó újraindítás</button> ' +
            '<button type="button" class="btn btn-sm btn-danger" data-st-action="bulk-disable">' +
                '<span class="fa fa-stop"></span> Letiltás</button> ' +
            '<button type="button" class="btn btn-sm btn-default" data-st-action="clear-selection">' +
                'Kijelölés törlése</button>' +
            '</span><div style="clear:both"></div></div>';
    }

    function renderTable(users, showTimers, tableKey) {
        let cols = 4 + (showTimers ? 4 : 0) + (isAdmin ? 2 : 0);

        let html = '<div class="table-responsive"><table class="table table-striped table-hover" ' +
                   'data-st-table="' + tableKey + '" style="margin-bottom:0">';
        html += '<thead><tr>';
        if (isAdmin) {
            html += '<th style="width:34px"><input type="checkbox" class="st-all-check" ' +
                    'data-st-table="' + tableKey + '" title="Mind kijelöl"></th>';
        }
        html += '<th>Státusz</th>';
        html += '<th>Felhasználó</th>';
        html += '<th>Weboldal</th>';
        html += '<th>Szint</th>';
        if (showTimers) {
            html += '<th>Engedélyezve</th>';
            html += '<th>Processek</th>';
            html += '<th>Idle hátra</th>';
            html += '<th>Hard hátra</th>';
        }
        if (isAdmin) html += '<th>Műveletek</th>';
        html += '</tr></thead><tbody>';

        if (users.length === 0) {
            html += '<tr><td colspan="' + cols + '" class="text-muted" style="padding:14px">Nincs megjeleníthető felhasználó.</td></tr>';
        }

        users.forEach(u => {
            const t = u.timer;
            const rowClass = t.state === 'warning' ? 'warning' : (t.state === 'expired' ? 'danger' : '');
            html += '<tr class="' + rowClass + '" data-st-row="' + escAttr(u.username) + '">';

            if (isAdmin) {
                html += '<td><input type="checkbox" class="st-row-check" data-st-user="' +
                        escAttr(u.username) + '"></td>';
            }

            html += '<td>' + badge(t.state) + '</td>';
            html += '<td><strong>' + esc(u.username) + '</strong></td>';
            html += '<td>' + esc(u.website) + '</td>';
            html += '<td>' + chrootBadge(u.chroot) + '</td>';

            if (showTimers) {
                html += '<td>' + fmtDate(t.enabled_at);
                // The monitor counts idle time from here, so show it: otherwise a
                // long-running session looks expired when it is not.
                if (t.last_seen_active && t.last_seen_active > t.enabled_at) {
                    html += '<div style="font-size:11px;color:#999">utoljára aktív: ' +
                            fmtDate(t.last_seen_active) + '</div>';
                }
                html += '</td>';
                html += '<td>';
                if (t.process_count > 0) {
                    html += '<span class="badge" style="background:#5cb85c">' + t.process_count + '</span> ';
                    html += '<span class="text-muted" style="font-size:11px;cursor:help" ';
                    html += 'title="' + escAttr((t.process_list || []).join('\n')) + '">';
                    html += 'részletek</span>';
                } else {
                    html += '<span class="text-muted">0</span>';
                }
                html += '</td>';
                html += '<td style="font-family:monospace;font-weight:bold;' +
                    (t.idle_remaining < 1800 && t.state !== 'active' ? 'color:#d9534f' : '') + '">' +
                    (t.state === 'active' ? '<span style="color:#5cb85c">∞</span>' : fmt(t.idle_remaining)) + '</td>';
                html += '<td style="font-family:monospace">' + fmt(t.hard_remaining) + '</td>';
            }

            if (isAdmin) {
                const un = escAttr(u.username);
                html += '<td style="white-space:nowrap">';
                html += '<span class="st-row-status" style="margin-right:6px"></span>';
                if (t.state === 'disabled') {
                    html += '<button type="button" class="btn btn-xs btn-success" data-st-action="enable" ' +
                            'data-st-user="' + un + '" data-st-hours="3"><span class="fa fa-play"></span> 3ó</button> ';
                    html += '<button type="button" class="btn btn-xs btn-success" data-st-action="enable" ' +
                            'data-st-user="' + un + '" data-st-hours="8">8ó</button>';
                } else {
                    html += '<button type="button" class="btn btn-xs btn-warning" data-st-action="enable" ' +
                            'data-st-user="' + un + '" data-st-hours="3" title="Újraindít 3ó">' +
                            '<span class="fa fa-refresh"></span></button> ';
                    html += '<button type="button" class="btn btn-xs btn-primary" data-st-action="enable" ' +
                            'data-st-user="' + un + '" data-st-hours="8" ' +
                            'title="A timer újraindítása 8 órára, a mostani időponttól">8ó újra</button> ';
                    html += '<button type="button" class="btn btn-xs btn-danger" data-st-action="disable" ' +
                            'data-st-user="' + un + '" title="Letilt"><span class="fa fa-stop"></span></button>';
                }
                html += '</td>';
            }

            html += '</tr>';
        });

        html += '</tbody></table></div>';
        return html;
    }

    // ========================================
    // Selection handling
    // ========================================

    function restoreSelection() {
        const el = root();
        if (!el) return;
        el.querySelectorAll('.st-row-check').forEach(b => {
            b.checked = state.selected.has(b.dataset.stUser);
        });
        updateAllChecks();
        updateBulkBar();
    }

    function updateAllChecks() {
        const el = root();
        if (!el) return;
        el.querySelectorAll('.st-all-check').forEach(all => {
            const table = all.closest('table');
            if (!table) return;
            const boxes = table.querySelectorAll('.st-row-check');
            const checked = table.querySelectorAll('.st-row-check:checked').length;
            all.checked = boxes.length > 0 && checked === boxes.length;
            all.indeterminate = checked > 0 && checked < boxes.length;
        });
    }

    function updateBulkBar(progressText) {
        const bar = document.getElementById('st-bulk-bar');
        if (!bar) return;
        const n = state.selected.size;
        bar.style.display = (n > 0 || state.busy) ? '' : 'none';
        const label = document.getElementById('st-bulk-count');
        if (label) {
            label.textContent = progressText ? progressText : (n + ' elem kijelölve');
        }
    }

    function setControlsDisabled(disabled) {
        const el = root();
        if (!el) return;
        el.querySelectorAll('button[data-st-action]').forEach(b => {
            if (b.dataset.stAction !== 'dismiss-notice') b.disabled = disabled;
        });
        el.querySelectorAll('input.st-row-check, input.st-all-check').forEach(b => { b.disabled = disabled; });
    }

    function setRowStatus(username, kind) {
        const row = root() ? root().querySelector('[data-st-row="' + CSS.escape(username) + '"]') : null;
        if (!row) return;
        const cell = row.querySelector('.st-row-status');
        if (!cell) return;
        if (kind === 'spinner')   cell.innerHTML = '<span class="fa fa-spinner fa-spin" style="color:#337ab7"></span>';
        else if (kind === 'ok')   cell.innerHTML = '<span class="fa fa-check" style="color:#5cb85c"></span>';
        else if (kind === 'fail') cell.innerHTML = '<span class="fa fa-times" style="color:#d9534f"></span>';
        else                      cell.innerHTML = '';
    }

    // ========================================
    // Actions
    // ========================================

    function actionLabel(action, hours) {
        if (action === 'disable') return 'Letiltás';
        // enable-shell-user.sh does not add time, it rewrites the state files and
        // reschedules the at-job, so this is always a restart of the full window.
        return 'Indítás / timer újraindítás ' + hours + ' órára';
    }

    function confirmText(action, hours, users) {
        const shown = users.slice(0, CONFIRM_LIST_MAX);
        let txt = actionLabel(action, hours) + ' — ' + users.length + ' felhasználó:\n\n';
        txt += shown.map(u => '  • ' + u).join('\n');
        if (users.length > shown.length) txt += '\n  … és még ' + (users.length - shown.length) + ' db';
        if (action !== 'disable') {
            txt += '\n\nA timer nem hozzáad, hanem ÚJRAINDUL: az idle és a hard limit is\n' +
                   'a mostani időponttól számít ' + hours + ' órát.';
        }
        return txt + '\n\nFolytatod?';
    }

    async function runSingle(action, username, hours) {
        if (state.busy) return;
        const params = { username: username };
        if (action === 'enable') params.hours = hours;
        if (!confirm(confirmText(action, hours, [username]))) return;

        state.busy = true;
        setControlsDisabled(true);
        setRowStatus(username, 'spinner');
        const d = await apiCall(action, params);
        const ok = d && d.status === 'ok';
        setRowStatus(username, ok ? 'ok' : 'fail');

        if (ok) {
            state.notice = { type: 'success', title: actionLabel(action, hours) + ' kész: ' + username };
        } else {
            state.notice = {
                type: 'danger',
                title: actionLabel(action, hours) + ' SIKERTELEN: ' + username,
                details: (d && (d.output || d.error)) || 'ismeretlen hiba'
            };
        }
        await loadDashboard();
        state.busy = false;
    }

    async function runBulk(action, hours) {
        if (state.busy) return;
        const users = Array.from(state.selected);
        if (users.length === 0) return;
        if (!confirm(confirmText(action, hours, users))) return;

        state.busy = true;
        setControlsDisabled(true);

        const results = [];
        for (let i = 0; i < users.length; i++) {
            const u = users[i];
            updateBulkBar('Folyamatban: ' + (i + 1) + '/' + users.length + ' — ' + u);
            setRowStatus(u, 'spinner');

            const params = { username: u };
            if (action === 'enable') params.hours = hours;
            const d = await apiCall(action, params);

            const ok = d && d.status === 'ok';
            results.push({ user: u, ok: ok, msg: (d && (d.output || d.error)) || 'ismeretlen hiba' });
            setRowStatus(u, ok ? 'ok' : 'fail');
        }

        const failed = results.filter(r => !r.ok);

        if (failed.length === 0) {
            state.notice = {
                type: 'success',
                title: actionLabel(action, hours) + ': mind a ' + results.length + ' felhasználó kész.'
            };
        } else {
            state.notice = {
                type: 'warning',
                title: actionLabel(action, hours) + ': ' + (results.length - failed.length) + ' sikeres, ' +
                       failed.length + ' hibás.',
                details: failed.map(r => r.user + ': ' + r.msg).join('\n')
            };
        }

        state.selected.clear();
        await loadDashboard();
        state.busy = false;
    }

    // ========================================
    // Event wiring (delegated on the stable container)
    // ========================================

    const container = root();

    container.addEventListener('click', function(e) {
        const btn = e.target.closest('[data-st-action]');
        if (!btn || !container.contains(btn)) return;
        e.preventDefault();      // never let the click reach ISPConfig's pageForm
        e.stopPropagation();

        const action = btn.dataset.stAction;
        const user = btn.dataset.stUser;
        const hours = parseInt(btn.dataset.stHours || '3', 10);

        if (action === 'refresh')             { if (!state.busy) loadDashboard(); }
        else if (action === 'dismiss-notice') { state.notice = null; const a = btn.closest('.alert'); if (a) a.remove(); }
        else if (action === 'clear-selection'){ state.selected.clear(); restoreSelection(); }
        else if (action === 'enable')         { runSingle('enable', user, hours); }
        else if (action === 'disable')        { runSingle('disable', user, hours); }
        else if (action === 'bulk-enable')    { runBulk('enable', hours); }
        else if (action === 'bulk-disable')   { runBulk('disable', hours); }
    });

    container.addEventListener('change', function(e) {
        const el = e.target;
        if (el.classList && el.classList.contains('st-row-check')) {
            const u = el.dataset.stUser;
            if (el.checked) state.selected.add(u); else state.selected.delete(u);
            updateAllChecks();
            updateBulkBar();
        } else if (el.classList && el.classList.contains('st-all-check')) {
            const table = el.closest('table');
            if (!table) return;
            table.querySelectorAll('.st-row-check').forEach(b => {
                b.checked = el.checked;
                if (el.checked) state.selected.add(b.dataset.stUser); else state.selected.delete(b.dataset.stUser);
            });
            updateAllChecks();
            updateBulkBar();
        }
    });

    // Public API kept for backwards compatibility / console use.
    window.ShellTimerDash = {
        refresh: loadDashboard,
        enable: function(username, hours) { return runSingle('enable', username, hours || 3); },
        disable: function(username) { return runSingle('disable', username, 3); }
    };

    // ========================================
    // Init + self-terminating auto refresh
    // ========================================

    loadDashboard();

    window.__shellTimerDashTimer = setInterval(function() {
        if (!document.getElementById(ROOT_ID)) {
            clearInterval(window.__shellTimerDashTimer);
            window.__shellTimerDashTimer = null;
            return;
        }
        if (state.busy) return;
        loadDashboard();
    }, REFRESH_MS);
})();
</script>
