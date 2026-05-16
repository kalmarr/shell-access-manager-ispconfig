/**
 * Shell Timer - ISPConfig UI Integration
 * 
 * Loaded on EVERY ISPConfig page via Apache mod_substitute.
 * Only activates when relevant (shell_user pages or nav injection).
 * 
 * Location: /usr/local/ispconfig/interface/web/shell_timer/timer.js
 * This file is in a CUSTOM directory that ISPConfig updates never touch.
 */
(function() {
    'use strict';

    const API = '/shell_timer/timer.js'.replace('timer.js', 'api.php');
    let countdownInterval = null;

    // ========================================
    // Utility functions
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

    function badge(state) {
        const map = {
            active:   '<span class="label label-success" style="font-size:12px">● AKTÍV</span>',
            idle:     '<span class="label label-info" style="font-size:12px">◐ IDLE</span>',
            warning:  '<span class="label label-warning" style="font-size:12px">⚠ LEJÁR</span>',
            expired:  '<span class="label label-danger" style="font-size:12px">✕ LEJÁRT</span>',
            disabled: '<span class="label label-default" style="font-size:12px">◻ TILTVA</span>'
        };
        return map[state] || map.disabled;
    }

    function esc(str) {
        const d = document.createElement('div');
        d.textContent = str || '';
        return d.innerHTML;
    }

    async function apiCall(action, params) {
        const qs = new URLSearchParams(params || {});
        qs.set('action', action);
        try {
            const r = await fetch(API + '?' + qs.toString());
            if (!r.ok) return null;
            return await r.json();
        } catch(e) {
            return null;
        }
    }

    // ISPConfig content container
    function getContent() {
        return document.querySelector('#pageContent');
    }

    // ========================================
    // 1. NAV MENU INJECTION
    //    Adds "Shell Timer" item to Sites menu
    // ========================================

    function injectNavItem() {
        if (document.getElementById('shell-timer-nav')) return;

        const navLinks = document.querySelectorAll('#sidebar a, .nav-sidebar a, .pushy a, #side-nav a, .sidenav a');
        let shellUserLink = null;

        navLinks.forEach(a => {
            const href = a.getAttribute('data-load-content') || a.getAttribute('href') || '';
            if (href.indexOf('shell_user_list') > -1) {
                shellUserLink = a;
            }
        });

        if (shellUserLink) {
            const li = document.createElement('li');
            li.id = 'shell-timer-nav';
            const a = document.createElement('a');
            a.href = '#';
            a.setAttribute('data-load-content', 'shell_timer/dashboard.php');
            a.innerHTML = '<span class="fa fa-clock-o"></span> Shell Timer';
            a.style.cssText = 'color:#5cb85c !important';
            li.appendChild(a);

            const parentLi = shellUserLink.closest('li');
            if (parentLi && parentLi.parentNode) {
                parentLi.parentNode.insertBefore(li, parentLi.nextSibling);
            }
        }
    }

    // ========================================
    // 2. SHELL_USER LIST PAGE ENHANCEMENT
    //    Adds timer columns to the user list
    // ========================================

    async function enhanceListPage() {
        const data = await apiCall('list');
        if (!data || !data.users) return;

        const pc = getContent();
        const table = pc
            ? pc.querySelector('.table-wrapper table.table')
            : document.querySelector('.table-wrapper table.table');
        if (!table || table.dataset.shellTimerDone) return;
        table.dataset.shellTimerDone = '1';

        const timerMap = {};
        data.users.forEach(u => { timerMap[u.username] = u; });

        // Add headers
        const headerRow = table.querySelector('thead tr:first-child');
        if (headerRow) {
            const lastTh = headerRow.lastElementChild;
            ['Státusz', 'Hátra', 'Szint'].forEach(label => {
                const th = document.createElement('th');
                th.className = 'shell-timer-col';
                th.textContent = label;
                headerRow.insertBefore(th, lastTh);
            });
        }

        // Add filter row placeholders
        const filterRow = table.querySelector('thead tr:nth-child(2)');
        if (filterRow) {
            const lastTd = filterRow.lastElementChild;
            for (let i = 0; i < 3; i++) {
                const td = document.createElement('td');
                td.className = 'shell-timer-col';
                filterRow.insertBefore(td, lastTd);
            }
        }

        // Add data cells
        table.querySelectorAll('tbody tr').forEach(row => {
            if (row.classList.contains('tbl_row_noresults')) return;
            const lastTd = row.lastElementChild;

            let username = '';
            row.querySelectorAll('a').forEach(a => {
                const t = a.textContent.trim();
                if (timerMap[t]) username = t;
            });

            const u = timerMap[username];
            const t = u ? u.timer : null;

            // Status
            const td1 = document.createElement('td');
            td1.className = 'shell-timer-col';
            td1.innerHTML = t ? badge(t.state) : '-';
            row.insertBefore(td1, lastTd);

            // Time remaining
            const td2 = document.createElement('td');
            td2.className = 'shell-timer-col';
            td2.style.fontFamily = 'monospace';
            if (!t || t.state === 'disabled') {
                td2.innerHTML = '<span style="color:#ccc">-</span>';
            } else if (t.state === 'active') {
                td2.innerHTML = '<strong style="color:#5cb85c">H:' + fmt(t.hard_remaining) + '</strong>';
            } else {
                td2.innerHTML = 'I:' + fmt(t.idle_remaining) + ' <small style="color:#999">H:' + fmt(t.hard_remaining) + '</small>';
            }
            row.insertBefore(td2, lastTd);

            // Access level
            const td3 = document.createElement('td');
            td3.className = 'shell-timer-col';
            if (u) {
                td3.innerHTML = u.chroot === 'jailkit'
                    ? '<span class="label label-info" style="font-size:11px">Jailkit (korlátozott)</span>'
                    : '<span class="label label-danger" style="font-size:11px">Teljes shell ⚠️</span>';
            } else {
                td3.textContent = '-';
            }
            row.insertBefore(td3, lastTd);
        });
    }

    // ========================================
    // 3. SHELL_USER EDIT PAGE ENHANCEMENT
    //    Adds timer panel above the form
    // ========================================

    async function enhanceEditPage() {
        const prefixEl = document.querySelector('#username-desc');
        const inputEl = document.querySelector('#username');
        if (!inputEl) return;

        const username = (prefixEl ? prefixEl.textContent : '') + inputEl.value;
        if (!username) return;

        // Don't double-inject
        const existing = document.getElementById('shell-timer-panel');
        if (existing) {
            if (existing.dataset.username === username && Date.now() - (parseInt(existing.dataset.ts) || 0) < 5000) return;
            existing.remove();
        }

        const data = await apiCall('status', { username: username });
        if (!data || !data.timer) return;
        const t = data.timer;

        // Panel style
        let panelStyle = 'panel-default';
        if (t.state === 'active') panelStyle = 'panel-success';
        else if (t.state === 'warning') panelStyle = 'panel-warning';
        else if (t.state === 'idle') panelStyle = 'panel-info';
        else if (t.state === 'expired') panelStyle = 'panel-danger';

        // Chroot info
        const chrootSelect = document.querySelector('select[name="chroot"]');
        let accessLevel = chrootSelect ? chrootSelect.value : '?';
        if (accessLevel === 'jailkit') accessLevel = 'Jailkit (korlátozott)';
        else if (accessLevel === 'no' || accessLevel === '') accessLevel = 'Teljes shell ⚠️';

        // Processes
        let procHtml = '';
        if (t.process_list && t.process_list.length > 0) {
            procHtml = '<div style="margin-top:12px;padding:8px;background:#f5f5f5;border-radius:4px">' +
                '<strong>Futó processzek (' + t.process_count + '):</strong><br>' +
                '<code style="font-size:11px;white-space:pre-wrap">' +
                t.process_list.map(p => esc(p)).join('\n') + '</code></div>';
        }

        // Buttons
        let btns = '';
        if (t.state === 'disabled') {
            btns = '<button class="btn btn-success btn-sm" onclick="ShellTimer.enable(\'' + esc(username) + '\',3)">▶ Engedélyez (3ó)</button> ' +
                   '<button class="btn btn-success btn-sm" onclick="ShellTimer.enable(\'' + esc(username) + '\',8)">▶ Engedélyez (8ó)</button>';
        } else {
            btns = '<button class="btn btn-warning btn-sm" onclick="ShellTimer.enable(\'' + esc(username) + '\',3)">↻ Újraindít (3ó)</button> ' +
                   '<button class="btn btn-danger btn-sm" onclick="ShellTimer.disable(\'' + esc(username) + '\')">■ Letilt</button>';
        }

        // Build panel
        const panel = document.createElement('div');
        panel.id = 'shell-timer-panel';
        panel.dataset.username = username;
        panel.dataset.ts = Date.now().toString();
        panel.innerHTML =
            '<div class="panel ' + panelStyle + '">' +
            '<div class="panel-heading"><h3 class="panel-title">' +
            '<span class="fa fa-clock-o"></span> Shell Timer' +
            '<a href="#" data-load-content="shell_timer/dashboard.php" class="btn btn-xs btn-default pull-right">' +
            '<span class="fa fa-tachometer"></span> Dashboard</a></h3></div>' +
            '<div class="panel-body">' +
                '<div class="row">' +
                    '<div class="col-sm-2 text-center">' +
                        '<div style="font-size:22px;margin-bottom:5px">' + badge(t.state) + '</div>' +
                        '<div style="font-size:11px;color:#666">Szint: <strong>' + esc(accessLevel) + '</strong></div>' +
                    '</div>' +
                    '<div class="col-sm-3">' +
                        '<div style="font-size:11px;color:#999">Engedélyezve</div>' +
                        '<div><strong>' + (t.enabled ? fmtDate(t.enabled_at) : '-') + '</strong></div>' +
                        '<div style="font-size:11px;color:#999;margin-top:6px">Processek</div>' +
                        '<div><strong>' + t.process_count + ' db</strong></div>' +
                    '</div>' +
                    '<div class="col-sm-3">' +
                        '<div style="font-size:11px;color:#999">Idle limit</div>' +
                        '<div><strong>' + fmt(t.idle_limit) + '</strong>' +
                            (t.state !== 'disabled' && t.state !== 'active' ? ' <small>(' + fmt(t.idle_remaining) + ' hátra)</small>' : '') +
                        '</div>' +
                        '<div style="font-size:11px;color:#999;margin-top:6px">Hard limit</div>' +
                        '<div><strong>' + fmt(t.hard_limit) + '</strong>' +
                            (t.state !== 'disabled' ? ' <small>(' + fmt(t.hard_remaining) + ' hátra)</small>' : '') +
                        '</div>' +
                    '</div>' +
                    '<div class="col-sm-4">' +
                        '<div style="margin-top:5px">' + btns + '</div>' +
                    '</div>' +
                '</div>' +
                procHtml +
                (t.state !== 'disabled' ? '<div id="shell-timer-live" style="margin-top:10px;text-align:center;font-size:16px;font-family:monospace"></div>' : '') +
            '</div></div>';

        const form = document.querySelector('form[name="pageForm"]') || document.querySelector('.form-horizontal');
        if (form) form.parentNode.insertBefore(panel, form);

        if (t.state !== 'disabled') startCountdown(t);
    }

    function startCountdown(t) {
        if (countdownInterval) clearInterval(countdownInterval);
        let hard = t.hard_remaining;
        let idle = t.idle_remaining;

        countdownInterval = setInterval(() => {
            const el = document.getElementById('shell-timer-live');
            if (!el) { clearInterval(countdownInterval); return; }

            hard--;
            if (t.state !== 'active') idle--;

            if (hard <= 0 || (t.state !== 'active' && idle <= 0)) {
                el.innerHTML = '<span class="label label-danger" style="font-size:14px">⏱ LEJÁRT</span>';
                clearInterval(countdownInterval);
                return;
            }

            let style = 'color:#333';
            let prefix = '';
            if (t.state === 'active') { style = 'color:#5cb85c'; prefix = '● Aktív | '; }
            else if (idle < 1800) { style = 'color:#d9534f'; prefix = '⚠ '; }

            el.innerHTML = '<span style="' + style + '">' + prefix +
                'Hard: <strong>' + fmt(hard) + '</strong>' +
                (t.state !== 'active' ? ' | Idle: <strong>' + fmt(idle) + '</strong>' : '') +
                '</span>';
        }, 1000);
    }

    // ========================================
    // Public API (for buttons)
    // ========================================

    window.ShellTimer = {
        enable: async function(username, hours) {
            if (!confirm('Engedélyezed: ' + username + ' (' + hours + 'ó)?')) return;
            const d = await apiCall('enable', { username: username, hours: hours });
            if (d && d.status === 'ok') {
                location.reload ? location.reload() : enhanceEditPage();
            } else {
                alert('Hiba: ' + (d ? d.output || d.error : 'API hiba'));
            }
        },
        disable: async function(username) {
            if (!confirm('Letiltod: ' + username + '?')) return;
            const d = await apiCall('disable', { username: username });
            if (d && d.status === 'ok') {
                location.reload ? location.reload() : enhanceEditPage();
            } else {
                alert('Hiba: ' + (d ? d.output || d.error : 'API hiba'));
            }
        }
    };

    // ========================================
    // Page detection & auto-init
    // ========================================

    function detect() {
        const pc = getContent();
        const html = pc ? pc.innerHTML : '';
        if (html.indexOf('shell_user_edit.php') > -1 && document.querySelector('#username')) return 'edit';
        if (html.indexOf('shell_user_list.php') > -1 && html.indexOf('search_username') > -1) return 'list';
        return null;
    }

    function init() {
        injectNavItem();
        const page = detect();
        if (page === 'list') enhanceListPage();
        else if (page === 'edit') enhanceEditPage();
    }

    // ISPConfig loads pages via AJAX - observe #pageContent for changes
    const observer = new MutationObserver(() => {
        clearTimeout(window._stDebounce);
        window._stDebounce = setTimeout(init, 400);
    });

    function startObserver() {
        const target = document.querySelector('#pageContent') || document.querySelector('#container') || document.body;
        observer.observe(target, { childList: true, subtree: true });
        init();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', startObserver);
    } else {
        startObserver();
    }

    // Periodic refresh for shell_user pages
    setInterval(() => { if (detect()) init(); }, 60000);
})();
