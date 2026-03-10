<?php
/**
 * Shell Timer - AJAX API Endpoint for ISPConfig
 * 
 * Location: /usr/local/ispconfig/interface/web/shell_timer/api.php
 * Reads from: /var/lib/shell-access-manager/ state files
 * 
 * This file lives in a CUSTOM directory that ISPConfig updates never touch.
 */

$conf_file_check = realpath(dirname(__FILE__) . '/../../lib/config.inc.php');
if (!$conf_file_check || !file_exists($conf_file_check)) {
    die(json_encode(['error' => 'ISPConfig not found']));
}

require_once $conf_file_check;
require_once realpath(dirname(__FILE__) . '/../../lib/app.inc.php');

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-cache, no-store, must-revalidate');

// Session check
if (!isset($_SESSION['s']['user']) || empty($_SESSION['s']['user']['userid'])) {
    http_response_code(403);
    echo json_encode(['error' => 'Not authenticated']);
    exit;
}

$is_admin = (isset($_SESSION['s']['user']['typ']) && $_SESSION['s']['user']['typ'] === 'admin');
$action = isset($_GET['action']) ? $_GET['action'] : 'status';

// Admin-only actions
if (in_array($action, ['enable', 'disable']) && !$is_admin) {
    http_response_code(403);
    echo json_encode(['error' => 'Admin access required']);
    exit;
}

// Config
$state_dir = '/var/lib/shell-access-manager';
$conf_file = '/usr/local/shell-access-manager/shell-access-manager.conf';
$idle_limit = 10800;
$hard_limit = 28800;

if (file_exists($conf_file)) {
    $lines = file($conf_file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    foreach ($lines as $line) {
        $line = trim($line);
        if ($line === '' || $line[0] === '#') continue;
        if (preg_match('/^IDLE_LIMIT=(\d+)/', $line, $m)) $idle_limit = (int)$m[1];
        if (preg_match('/^HARD_LIMIT=(\d+)/', $line, $m)) $hard_limit = (int)$m[1];
    }
}

$username = isset($_GET['username']) ? preg_replace('/[^a-zA-Z0-9_.-]/', '', $_GET['username']) : '';

// ============================================================
// Actions
// ============================================================

if ($action === 'list') {
    $sql = "SELECT su.shell_user_id, su.username, su.active, su.chroot, su.shell, su.dir,
                   w.domain AS website
            FROM shell_user su
            LEFT JOIN web_domain w ON su.parent_domain_id = w.domain_id
            ORDER BY su.active DESC, su.username";
    $records = $app->db->queryAllRecords($sql);
    
    $users = [];
    foreach ($records as $rec) {
        $users[] = [
            'shell_user_id' => (int)$rec['shell_user_id'],
            'username'      => $rec['username'],
            'active'        => $rec['active'],
            'chroot'        => $rec['chroot'],
            'shell'         => $rec['shell'],
            'dir'           => $rec['dir'],
            'website'       => $rec['website'] ?: '-',
            'timer'         => get_timer_status($rec['username'], $state_dir, $idle_limit, $hard_limit)
        ];
    }
    
    echo json_encode([
        'status' => 'ok',
        'users'  => $users,
        'config' => ['idle_limit' => $idle_limit, 'hard_limit' => $hard_limit],
        'server_time' => time()
    ]);

} elseif ($action === 'status' && $username) {
    $timer = get_timer_status($username, $state_dir, $idle_limit, $hard_limit);
    echo json_encode(['status' => 'ok', 'username' => $username, 'timer' => $timer]);

} elseif ($action === 'enable' && $username) {
    $hours = isset($_GET['hours']) ? max(1, min(24, (int)$_GET['hours'])) : 3;
    $output = [];
    $retval = 0;
    exec("sudo /usr/local/shell-access-manager/enable-shell-user.sh " .
         escapeshellarg($username) . " " . (int)$hours . " 2>&1", $output, $retval);
    echo json_encode([
        'status' => $retval === 0 ? 'ok' : 'error',
        'output' => implode("\n", $output)
    ]);

} elseif ($action === 'disable' && $username) {
    $output = [];
    $retval = 0;
    exec("sudo /usr/local/shell-access-manager/disable-shell-user.sh " .
         escapeshellarg($username) . " manual-ispconfig 2>&1", $output, $retval);
    echo json_encode([
        'status' => $retval === 0 ? 'ok' : 'error',
        'output' => implode("\n", $output)
    ]);

} else {
    echo json_encode(['error' => 'Invalid action or missing username']);
}

// ============================================================
// Timer status helper
// ============================================================

function get_timer_status($username, $state_dir, $idle_limit, $hard_limit) {
    $now = time();
    $result = [
        'enabled'        => false,
        'enabled_at'     => null,
        'hard_limit'     => 0,
        'hard_remaining' => 0,
        'idle_limit'     => $idle_limit,
        'idle_elapsed'   => 0,
        'idle_remaining' => 0,
        'has_processes'  => false,
        'process_count'  => 0,
        'process_list'   => [],
        'state'          => 'disabled'
    ];

    $enabled_file = $state_dir . '/' . $username . '.enabled';
    $hard_file    = $state_dir . '/' . $username . '.hard_limit';

    if (file_exists($enabled_file)) {
        $enabled_epoch = (int)trim(file_get_contents($enabled_file));
        $result['enabled']    = true;
        $result['enabled_at'] = $enabled_epoch;

        $effective_hard = $hard_limit;
        if (file_exists($hard_file)) {
            $effective_hard = (int)trim(file_get_contents($hard_file));
        }
        $result['hard_limit']     = $effective_hard;
        $result['hard_remaining'] = max(0, $effective_hard - ($now - $enabled_epoch));
    }

    // Running processes (pgrep - works with jailkit)
    $pgrep = [];
    exec("pgrep -u " . escapeshellarg($username) . " -la 2>/dev/null", $pgrep);
    $result['process_count']  = count($pgrep);
    $result['has_processes']  = $result['process_count'] > 0;
    $result['process_list']   = array_slice($pgrep, 0, 10);

    // State logic (mirrors lib-functions.sh)
    if (!$result['enabled']) {
        $result['state'] = 'disabled';
    } elseif ($result['has_processes']) {
        $result['state']          = 'active';
        $result['idle_remaining'] = $idle_limit;
    } else {
        $idle_seconds = $now - $result['enabled_at'];
        $result['idle_elapsed']   = $idle_seconds;
        $result['idle_remaining'] = max(0, $idle_limit - $idle_seconds);

        if ($result['idle_remaining'] <= 0)          $result['state'] = 'expired';
        elseif ($result['idle_remaining'] < 1800)    $result['state'] = 'warning';
        else                                          $result['state'] = 'idle';
    }

    return $result;
}
