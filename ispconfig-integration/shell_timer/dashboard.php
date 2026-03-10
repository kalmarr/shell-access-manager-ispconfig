<?php
/**
 * Shell Timer Dashboard for ISPConfig
 * Shows all shell users with real-time timer status
 * 
 * Location: /usr/local/ispconfig/interface/web/shell_timer/dashboard.php
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
    const API = '/shell_timer/api.php';
    const isAdmin = <?php echo $is_admin ? 'true' : 'false'; ?>;
    let autoRefresh = null;

    function fmt(sec) {
        if (sec <= 0) return '0p';
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

    function badge(state) {
        const map = {
            active:   '<span class="label label-success" style="font-size:12px;padding:4px 8px">● AKTÍV</span>',
            idle:     '<span class="label label-info" style="font-size:12px;padding:4px 8px">◐ IDLE</span>',
            warning:  '<span class="label label-warning" style="font-size:12px;padding:4px 8px">⚠ LEJÁR</span>',
            expired:  '<span class="label label-danger" style="font-size:12px;padding:4px 8px">✕ LEJÁRT</span>',
            disabled: '<span class="label label-default" style="font-size:12px;padding:4px 8px">◻ TILTVA</span>'
        };
        return map[state] || map.disabled;
    }

    function chrootBadge(chroot) {
        if (chroot === 'jailkit') return '<span class="label label-info" style="font-size:11px">jailkit</span>';
        if (chroot === 'no' || chroot === '') return '<span class="label label-danger" style="font-size:11px">FULL ⚠</span>';
        return '<span class="label label-default" style="font-size:11px">' + (chroot || '?') + '</span>';
    }

    async function loadDashboard() {
        try {
            const resp = await fetch(API + '?action=list');
            const data = await resp.json();
            if (!data.users) throw new Error('No data');
            render(data);
        } catch(e) {
            document.getElementById('shell-timer-dashboard').innerHTML =
                '<div class="alert alert-danger"><strong>Hiba:</strong> ' + e.message + '</div>';
        }
    }

    function render(data) {
        const users = data.users;
        const activeUsers = users.filter(u => u.timer.state !== 'disabled');
        const disabledUsers = users.filter(u => u.timer.state === 'disabled');

        // Summary cards
        let html = '<div class="row" style="margin-bottom:20px">';
        html += summaryCard('Összes', users.length, 'default', 'fa-users');
        html += summaryCard('Aktív', activeUsers.filter(u => u.timer.state === 'active').length, 'success', 'fa-check-circle');
        html += summaryCard('Idle', activeUsers.filter(u => u.timer.state === 'idle' || u.timer.state === 'warning').length, 'warning', 'fa-clock-o');
        html += summaryCard('Letiltva', disabledUsers.length, 'default', 'fa-lock');
        html += '</div>';

        // Config info
        html += '<div class="well well-sm" style="font-size:12px;margin-bottom:15px">';
        html += '<strong>Beállítások:</strong> Idle limit: <strong>' + fmt(data.config.idle_limit) + '</strong> | ';
        html += 'Hard limit: <strong>' + fmt(data.config.hard_limit) + '</strong> | ';
        html += 'Szerver idő: ' + new Date(data.server_time * 1000).toLocaleTimeString('hu-HU');
        html += ' <button class="btn btn-xs btn-default pull-right" onclick="ShellTimerDash.refresh()"><span class="fa fa-refresh"></span> Frissítés</button>';
        html += '</div>';

        // Active users table
        if (activeUsers.length > 0) {
            html += '<h4 style="color:#5cb85c"><span class="fa fa-bolt"></span> Aktív hozzáférések</h4>';
            html += renderTable(activeUsers, true);
        }

        // Disabled users table
        html += '<h4 style="margin-top:25px;color:#999"><span class="fa fa-lock"></span> Letiltott userek</h4>';
        html += renderTable(disabledUsers, false);

        document.getElementById('shell-timer-dashboard').innerHTML = html;
    }

    function summaryCard(title, count, style, icon) {
        return '<div class="col-sm-3"><div class="panel panel-' + style + '">' +
            '<div class="panel-body text-center">' +
            '<span class="fa ' + icon + ' fa-2x" style="opacity:0.6"></span>' +
            '<div style="font-size:28px;font-weight:bold;margin:5px 0">' + count + '</div>' +
            '<div style="font-size:12px;color:#666">' + title + '</div>' +
            '</div></div></div>';
    }

    function renderTable(users, showTimers) {
        let html = '<div class="table-responsive"><table class="table table-striped table-hover" style="margin-bottom:0">';
        html += '<thead><tr>';
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

        users.forEach(u => {
            const t = u.timer;
            const rowClass = t.state === 'warning' ? 'warning' : (t.state === 'expired' ? 'danger' : '');
            html += '<tr class="' + rowClass + '">';
            html += '<td>' + badge(t.state) + '</td>';
            html += '<td><strong>' + esc(u.username) + '</strong></td>';
            html += '<td>' + esc(u.website) + '</td>';
            html += '<td>' + chrootBadge(u.chroot) + '</td>';

            if (showTimers) {
                html += '<td>' + fmtDate(t.enabled_at) + '</td>';
                html += '<td>';
                if (t.process_count > 0) {
                    html += '<span class="badge" style="background:#5cb85c">' + t.process_count + '</span> ';
                    html += '<span class="text-muted" style="font-size:11px;cursor:pointer" ';
                    html += 'title="' + esc(t.process_list.join('\n')) + '">';
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
                html += '<td style="white-space:nowrap">';
                if (t.state === 'disabled') {
                    html += '<button class="btn btn-xs btn-success" onclick="ShellTimerDash.enable(\'' +
                        esc(u.username) + '\',3)"><span class="fa fa-play"></span> 3ó</button> ';
                    html += '<button class="btn btn-xs btn-success" onclick="ShellTimerDash.enable(\'' +
                        esc(u.username) + '\',8)">8ó</button>';
                } else {
                    html += '<button class="btn btn-xs btn-warning" onclick="ShellTimerDash.enable(\'' +
                        esc(u.username) + '\',3)"><span class="fa fa-refresh"></span></button> ';
                    html += '<button class="btn btn-xs btn-danger" onclick="ShellTimerDash.disable(\'' +
                        esc(u.username) + '\')"><span class="fa fa-stop"></span></button>';
                }
                html += '</td>';
            }

            html += '</tr>';
        });

        html += '</tbody></table></div>';
        return html;
    }

    function esc(str) {
        const d = document.createElement('div');
        d.textContent = str || '';
        return d.innerHTML;
    }

    // Public API
    window.ShellTimerDash = {
        refresh: loadDashboard,
        enable: async function(username, hours) {
            if (!confirm('Engedélyezed: ' + username + ' (' + hours + 'ó)?')) return;
            const r = await fetch(API + '?action=enable&username=' + encodeURIComponent(username) + '&hours=' + hours);
            const d = await r.json();
            if (d.status === 'ok') loadDashboard();
            else alert('Hiba: ' + (d.output || d.error || 'ismeretlen'));
        },
        disable: async function(username) {
            if (!confirm('Letiltod: ' + username + '?')) return;
            const r = await fetch(API + '?action=disable&username=' + encodeURIComponent(username));
            const d = await r.json();
            if (d.status === 'ok') loadDashboard();
            else alert('Hiba: ' + (d.output || d.error || 'ismeretlen'));
        }
    };

    // Init
    loadDashboard();
    autoRefresh = setInterval(loadDashboard, 30000);
})();
</script>
