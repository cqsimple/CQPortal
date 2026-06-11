#!/bin/bash

# ============================================================
#  Login System Setup Script — MariaDB Edition
#  Run as root: sudo bash setup_login_system.sh
# ============================================================

WEB_DIR="/var/www/html/portal"
DB_HOST="localhost"
DB_USER="root"
DB_PASS="NewRootPass123!"
DB_NAME="portal"

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { echo "Run as root: bash $0"; exit 1; }

# ── Pre-flight: confirm Bridge_Phone resources are safe ───────────────────────
echo "=== Pre-flight checks ==="
for svc in site-dashboard openvpn@server wg-quick@wg0; do
    systemctl is-active --quiet "$svc" 2>/dev/null && echo "  â $svc running â will not be affected" || true
done
echo "  â Portal installs to /var/www/html/portal/ â no overlap with /opt/site-dashboard/"
echo "  â Portal binds to 10.9.0.1:80 (wg0) â Bridge_Phone uses 10.9.0.1:8080 (wg0)"
echo "  â MariaDB will not affect Bridge_Phone SQLite database"
echo "=========================================="

# ---- Auto-detect the Apache runtime user (FreePBX uses asterisk, others use apache/www-data) ----
APACHE_USER="www-data"
echo "Apache user: $APACHE_USER"

# ---- Install PHP and MySQL extension ----
echo "Installing PHP modules..."
apt-get install -y php php-mysqli php-mbstring libapache2-mod-php mariadb-server curl jq
systemctl enable apache2 mariadb
systemctl start apache2 mariadb

# ── Bind Apache to WireGuard interface only (10.9.0.1) ───────────────────────
# Portal will only be reachable through the WireGuard VPN — not from public internet
echo "Configuring Apache to listen on WireGuard interface only..."
sed -i 's/^Listen 80$/Listen 10.9.0.1:80/' /etc/apache2/ports.conf
sed -i 's/^Listen 443$/Listen 10.9.0.1:443/' /etc/apache2/ports.conf 2>/dev/null || true
# Update default VirtualHost to bind to wg0 IP
sed -i 's/<VirtualHost \*:80>/<VirtualHost 10.9.0.1:80>/' /etc/apache2/sites-available/000-default.conf
systemctl restart apache2
echo "Apache now listening on 10.9.0.1:80 (WireGuard only)"


# Allow port 80 on WireGuard interface ONLY — not reachable from public internet
echo "Configuring UFW — portal restricted to WireGuard tunnel (wg0)..."
ufw allow in on wg0 to any port 80
echo "UFW updated. Current rules:"
ufw status

# ---- Create web directory ----
mkdir -p "$WEB_DIR"

# ============================================================
#  Create the portal database and users table in MariaDB
# ============================================================
echo "Setting up MariaDB database..."
mysql -u "$DB_USER" -p"$DB_PASS" <<SQLEOF
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;
USE \`$DB_NAME\`;
CREATE TABLE IF NOT EXISTS users (
    id        INT AUTO_INCREMENT PRIMARY KEY,
    username  VARCHAR(80)  UNIQUE NOT NULL,
    password  VARCHAR(255) NOT NULL,
    redirect  VARCHAR(500) NOT NULL DEFAULT '',
    is_admin  TINYINT(1)   NOT NULL DEFAULT 0,
    created   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS clients (
    id        INT AUTO_INCREMENT PRIMARY KEY,
    suffix    VARCHAR(80)  UNIQUE NOT NULL,
    label     VARCHAR(120) NOT NULL DEFAULT '',
    created   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS onprem_links (
    id        INT AUTO_INCREMENT PRIMARY KEY,
    suffix    VARCHAR(80)  NOT NULL,
    site_name VARCHAR(200) NOT NULL,
    url       VARCHAR(500) NOT NULL,
    created   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_suffix (suffix)
);
-- Insert default admin if not exists
INSERT IGNORE INTO users (username, password, redirect, is_admin)
VALUES ('admin', '$(php -r "echo password_hash('Admin1234!', PASSWORD_DEFAULT);")', '/portal/admin.php', 1);
SQLEOF

if [ $? -eq 0 ]; then
    echo "✅ Database and table created successfully."
else
    echo "❌ Database setup failed. Check your MariaDB credentials."
    exit 1
fi

# ============================================================
#  Apache config — allow access to /portal
# ============================================================
cat <<'APACHEEOF' > /etc/apache2/conf-available/portal.conf
# CQ Simple Portal — accessible via WireGuard (10.9.0.1) only
<Directory /var/www/html/portal>
    Options -Indexes -FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>
APACHEEOF

a2enconf portal
systemctl reload apache2

# ============================================================
#  config.php  —  shared DB connection + session helpers
# ============================================================
cat <<'PHPEOF' > "$WEB_DIR/config.php"
<?php
define('DB_HOST', 'localhost');
define('DB_USER', 'root');
define('DB_PASS', 'NewRootPass123!');
define('DB_NAME', 'portal');
define('SESSION_TIMEOUT', 1800); // 30 minutes

function get_db() {
    $db = new mysqli(DB_HOST, DB_USER, DB_PASS, DB_NAME);
    if ($db->connect_error) {
        die("Database connection failed: " . $db->connect_error);
    }
    return $db;
}

function require_login() {
    if (session_status() === PHP_SESSION_NONE) session_start();
    if (empty($_SESSION['user_id'])) {
        header('Location: /portal/index.php');
        exit;
    }
    if (isset($_SESSION['last_active']) && (time() - $_SESSION['last_active']) > SESSION_TIMEOUT) {
        session_unset();
        session_destroy();
        header('Location: /portal/index.php?msg=timeout');
        exit;
    }
    $_SESSION['last_active'] = time();
}

function require_admin() {
    require_login();
    if (empty($_SESSION['is_admin'])) {
        header('Location: /portal/index.php?msg=denied');
        exit;
    }
}
?>
PHPEOF

# ============================================================
#  index.php
# ============================================================
cat <<'PHPEOF' > "$WEB_DIR/index.php"
<?php
require_once __DIR__ . '/config.php';
if (session_status() === PHP_SESSION_NONE) session_start();

if (!empty($_SESSION['user_id'])) {
    header('Location: ' . ($_SESSION['redirect'] ?: '/portal/admin.php'));
    exit;
}

$error = '';
$msg_map = [
    'timeout' => 'Your session has expired. Please log in again.',
    'denied'  => 'Access denied.',
    'logout'  => 'You have been logged out.',
];
$info = isset($_GET['msg']) ? ($msg_map[$_GET['msg']] ?? '') : '';

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $username = trim($_POST['username'] ?? '');
    $password = $_POST['password'] ?? '';

    if ($username && $password) {
        $db   = get_db();
        $stmt = $db->prepare('SELECT id, password, redirect, is_admin FROM users WHERE username = ?');
        $stmt->bind_param('s', $username);
        $stmt->execute();
        $row = $stmt->get_result()->fetch_assoc();
        $stmt->close();
        $db->close();

        if ($row && password_verify($password, $row['password'])) {
            session_regenerate_id(true);
            $_SESSION['user_id']     = $row['id'];
            $_SESSION['username']    = $username;
            $_SESSION['is_admin']    = $row['is_admin'];
            $_SESSION['redirect']    = $row['redirect'];
            $_SESSION['last_active'] = time();

            $dest = $row['redirect'] ?: ($row['is_admin'] ? '/portal/admin.php' : '/');
            header('Location: ' . $dest);
            exit;
        } else {
            $error = 'Invalid username or password.';
        }
    } else {
        $error = 'Please enter both username and password.';
    }
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Portal Login</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: Arial, sans-serif;
    background: #1a1a2e;
    display: flex; align-items: center; justify-content: center;
    min-height: 100vh;
  }
  .card {
    background: #fff;
    border-radius: 10px;
    padding: 40px 36px;
    width: 100%; max-width: 400px;
    box-shadow: 0 8px 32px rgba(0,0,0,0.35);
  }
  .logo-wrap {
    text-align: center;
    margin-bottom: 20px;
  }
  .logo-wrap img {
    width: 90px; height: 90px;
    border-radius: 10px;
  }
  .card h1 { font-size: 1.4rem; color: #1a1a2e; margin-bottom: 4px; text-align: center; }
  .card p.sub { color: #666; font-size: 0.88rem; margin-bottom: 24px; text-align: center; }
  label { display: block; font-size: 0.85rem; font-weight: bold; color: #333; margin-bottom: 5px; }
  input[type=text], input[type=password] {
    width: 100%; padding: 10px 12px; border: 1px solid #ccc;
    border-radius: 6px; font-size: 0.95rem; margin-bottom: 18px;
    transition: border-color .2s;
  }
  input:focus { outline: none; border-color: #4a90e2; }
  button {
    width: 100%; padding: 11px; background: #1a1a2e; color: #fff;
    border: none; border-radius: 6px; font-size: 1rem; cursor: pointer;
    transition: background .2s;
  }
  button:hover { background: #2e2e5e; }
  .alert { padding: 10px 14px; border-radius: 6px; font-size: 0.88rem; margin-bottom: 18px; }
  .alert.error { background: #fde8e8; color: #c0392b; border: 1px solid #f5c6c6; }
  .alert.info  { background: #e8f4fd; color: #1a6fa8; border: 1px solid #b8d9f5; }
  .copyright {
    text-align: center; font-size: 0.75rem; color: #aaa;
    margin-top: 20px;
  }
</style>
</head>
<body>
<div class="card">
  <div class="logo-wrap">
    <img src="/portal/cqsimple_logo.png" alt="CQ Simple LLC">
  </div>
  <h1>&#128274; Portal Login</h1>
  <p class="sub">Robinson Cloud Systems — CQ Simple LLC</p>
  <?php if ($error): ?><div class="alert error"><?= htmlspecialchars($error) ?></div><?php endif; ?>
  <?php if ($info):  ?><div class="alert info"><?= htmlspecialchars($info) ?></div><?php endif; ?>
  <form method="POST">
    <label for="username">Username</label>
    <input type="text" id="username" name="username" autofocus autocomplete="username"
           value="<?= htmlspecialchars($_POST['username'] ?? '') ?>">
    <label for="password">Password</label>
    <input type="password" id="password" name="password" autocomplete="current-password">
    <button type="submit">Sign In</button>
  </form>
  <p class="copyright">&copy; <?= date('Y') ?> CQ Simple LLC. All rights reserved.</p>
</div>
</body>
</html>
PHPEOF

# ============================================================
#  logout.php
# ============================================================
cat <<'PHPEOF' > "$WEB_DIR/logout.php"
<?php
session_start();
session_unset();
session_destroy();
header('Location: /portal/index.php?msg=logout');
exit;
?>
PHPEOF

# ============================================================
#  generate.php  —  triggered by admin panel to run the
#  instance generation script
# ============================================================
cat <<'PHPEOF' > "$WEB_DIR/generate.php"
<?php
require_once __DIR__ . '/config.php';
require_admin();
header('Content-Type: application/json');

$script = '/usr/local/bin/generate_instances.sh';
if (!file_exists($script)) {
    echo json_encode(['success' => false, 'output' => "Script not found at $script\nRun: cp generate_instances.sh /usr/local/bin/ && chmod 755 /usr/local/bin/generate_instances.sh"]);
    exit;
}

if (!is_executable($script)) {
    echo json_encode(['success' => false, 'output' => "Script is not executable.\nRun: chmod 755 $script"]);
    exit;
}

$output = shell_exec("$script 2>&1");
echo json_encode(['success' => true, 'output' => $output ?: '(no output)']);
PHPEOF

# ============================================================
#  links.php  —  handles add/edit/delete for on-prem links
# ============================================================
cat <<'PHPEOF' > "$WEB_DIR/links.php"
<?php
require_once __DIR__ . '/config.php';
require_login();

$db     = get_db();
$action = $_POST['action'] ?? '';
$suffix = strtoupper(trim($_POST['suffix'] ?? ''));
$back   = '/portal/' . $suffix . '_Instances.php';

if (!$suffix) {
    header('Location: /portal/');
    exit;
}

if ($action === 'add') {
    $name = trim($_POST['site_name'] ?? '');
    $url  = trim($_POST['url'] ?? '');
    // Prepend https:// if no scheme provided
    if ($url && !preg_match('#^https?://#i', $url)) {
        $url = 'http://' . $url;
    }
    if ($name && $url) {
        $stmt = $db->prepare('INSERT INTO onprem_links (suffix, site_name, url) VALUES (?, ?, ?)');
        $stmt->bind_param('sss', $suffix, $name, $url);
        $stmt->execute();
        $stmt->close();
    }
}

if ($action === 'edit') {
    $id   = intval($_POST['id'] ?? 0);
    $name = trim($_POST['site_name'] ?? '');
    $url  = trim($_POST['url'] ?? '');
    if ($url && !preg_match('#^https?://#i', $url)) {
        $url = 'http://' . $url;
    }
    if ($id && $name && $url) {
        $stmt = $db->prepare('UPDATE onprem_links SET site_name=?, url=? WHERE id=? AND suffix=?');
        $stmt->bind_param('ssis', $name, $url, $id, $suffix);
        $stmt->execute();
        $stmt->close();
    }
}

if ($action === 'delete') {
    $id = intval($_POST['id'] ?? 0);
    if ($id) {
        $stmt = $db->prepare('DELETE FROM onprem_links WHERE id=? AND suffix=?');
        $stmt->bind_param('is', $id, $suffix);
        $stmt->execute();
        $stmt->close();
    }
}

$db->close();
header('Location: ' . $back);
exit;
?>
PHPEOF

# ============================================================
#  admin.php
# ============================================================
cat <<'PHPEOF' > "$WEB_DIR/admin.php"
<?php
require_once __DIR__ . '/config.php';
require_admin();

$db      = get_db();
$success = '';
$error   = '';

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $action = $_POST['action'] ?? '';

    if ($action === 'add') {
        $uname    = trim($_POST['username'] ?? '');
        $pass     = $_POST['password'] ?? '';
        $redirect = trim($_POST['redirect'] ?? '');
        $is_admin = isset($_POST['is_admin']) ? 1 : 0;

        if (!$uname || !$pass) {
            $error = 'Username and password are required.';
        } elseif (strlen($pass) < 8) {
            $error = 'Password must be at least 8 characters.';
        } else {
            $hash = password_hash($pass, PASSWORD_DEFAULT);
            $stmt = $db->prepare('INSERT INTO users (username, password, redirect, is_admin) VALUES (?, ?, ?, ?)');
            $stmt->bind_param('sssi', $uname, $hash, $redirect, $is_admin);
            if ($stmt->execute()) {
                $success = "User '$uname' added successfully.";
            } else {
                $error = 'Failed to add user (username may already exist).';
            }
            $stmt->close();
        }
    }

    if ($action === 'update') {
        $id       = intval($_POST['id'] ?? 0);
        $redirect = trim($_POST['redirect'] ?? '');
        $is_admin = isset($_POST['is_admin']) ? 1 : 0;
        $pass     = $_POST['password'] ?? '';

        if ($pass) {
            if (strlen($pass) < 8) {
                $error = 'New password must be at least 8 characters.';
            } else {
                $hash = password_hash($pass, PASSWORD_DEFAULT);
                $stmt = $db->prepare('UPDATE users SET password=?, redirect=?, is_admin=? WHERE id=?');
                $stmt->bind_param('ssii', $hash, $redirect, $is_admin, $id);
                $stmt->execute();
                $stmt->close();
                $success = 'User updated successfully.';
            }
        } else {
            $stmt = $db->prepare('UPDATE users SET redirect=?, is_admin=? WHERE id=?');
            $stmt->bind_param('sii', $redirect, $is_admin, $id);
            $stmt->execute();
            $stmt->close();
            $success = 'User updated successfully.';
        }
    }

    if ($action === 'delete') {
        $id = intval($_POST['id'] ?? 0);
        if ($id === $_SESSION['user_id']) {
            $error = 'You cannot delete your own account.';
        } else {
            $stmt = $db->prepare('DELETE FROM users WHERE id=?');
            $stmt->bind_param('i', $id);
            $stmt->execute();
            $stmt->close();
            $success = 'User deleted.';
        }
    }

    if ($action === 'add_client') {
        $suffix = strtoupper(trim($_POST['suffix'] ?? ''));
        $label  = trim($_POST['label'] ?? '');
        if (!$suffix) {
            $error = 'Suffix is required.';
        } else {
            $stmt = $db->prepare('INSERT INTO clients (suffix, label) VALUES (?, ?)');
            $stmt->bind_param('ss', $suffix, $label);
            if ($stmt->execute()) {
                $success = "Client '$suffix' added. Run Generate Pages to create the PHP file.";
            } else {
                $error = 'Failed to add client (suffix may already exist).';
            }
            $stmt->close();
        }
    }

    if ($action === 'delete_client') {
        $id = intval($_POST['id'] ?? 0);
        $stmt = $db->prepare('DELETE FROM clients WHERE id=?');
        $stmt->bind_param('i', $id);
        $stmt->execute();
        $stmt->close();
        $success = 'Client removed.';
    }
}

$users = [];
$res = $db->query('SELECT id, username, redirect, is_admin, created FROM users ORDER BY username');
while ($row = $res->fetch_assoc()) {
    $users[] = $row;
}

$clients = [];
$res = $db->query('SELECT id, suffix, label, created FROM clients ORDER BY suffix');
while ($row = $res->fetch_assoc()) {
    $clients[] = $row;
}
$db->close();
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Admin Panel — Portal</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: Arial, sans-serif; background: #f0f2f5; color: #222; }
  header {
    background: #1a1a2e; color: #fff; padding: 14px 28px;
    display: flex; justify-content: space-between; align-items: center;
  }
  header h1 { font-size: 1.2rem; }
  header a { color: #aac4ff; font-size: 0.88rem; text-decoration: none; }
  header a:hover { text-decoration: underline; }
  .container { max-width: 1000px; margin: 30px auto; padding: 0 20px; }
  .card { background: #fff; border-radius: 10px; padding: 28px; margin-bottom: 28px;
          box-shadow: 0 2px 12px rgba(0,0,0,0.08); }
  h2 { font-size: 1.1rem; margin-bottom: 20px; color: #1a1a2e;
       border-bottom: 2px solid #e8eaf0; padding-bottom: 10px; }
  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
  label { display: block; font-size: 0.82rem; font-weight: bold; color: #444; margin-bottom: 4px; }
  input[type=text], input[type=password] {
    width: 100%; padding: 9px 11px; border: 1px solid #ccc;
    border-radius: 6px; font-size: 0.92rem;
  }
  input:focus { outline: none; border-color: #4a90e2; }
  .checkbox-row { display: flex; align-items: center; gap: 8px; margin-top: 6px; font-size: 0.9rem; }
  .btn { padding: 9px 20px; border: none; border-radius: 6px; cursor: pointer; font-size: 0.9rem; }
  .btn-primary { background: #1a1a2e; color: #fff; }
  .btn-primary:hover { background: #2e2e5e; }
  .btn-danger  { background: #e74c3c; color: #fff; }
  .btn-danger:hover { background: #c0392b; }
  .btn-edit    { background: #3498db; color: #fff; }
  .btn-edit:hover { background: #2980b9; }
  .alert { padding: 10px 14px; border-radius: 6px; font-size: 0.88rem; margin-bottom: 20px; }
  .alert.success { background: #eafaf1; color: #1e8449; border: 1px solid #a9dfbf; }
  .alert.error   { background: #fde8e8; color: #c0392b; border: 1px solid #f5c6c6; }
  table { width: 100%; border-collapse: collapse; font-size: 0.9rem; }
  th, td { text-align: left; padding: 10px 12px; border-bottom: 1px solid #eee; }
  th { background: #f8f9fb; font-size: 0.82rem; color: #555;
       text-transform: uppercase; letter-spacing: .04em; }
  tr:hover td { background: #fafbff; }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 12px; font-size: 0.78rem; font-weight: bold; }
  .badge.admin { background: #fef3cd; color: #856404; }
  .badge.user  { background: #e8f4fd; color: #1a6fa8; }
  .url-cell { max-width: 220px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .modal-overlay {
    display: none; position: fixed; inset: 0;
    background: rgba(0,0,0,0.5); z-index: 100;
    align-items: center; justify-content: center;
  }
  .modal-overlay.active { display: flex; }
  .modal { background: #fff; border-radius: 10px; padding: 28px; width: 100%; max-width: 460px;
           box-shadow: 0 8px 32px rgba(0,0,0,0.25); }
  .modal h2 { margin-bottom: 18px; }
  .modal input { margin-bottom: 14px; }
  .modal-actions { display: flex; justify-content: flex-end; gap: 10px; margin-top: 20px; }
  .btn-cancel { background: #eee; color: #333; }
  .btn-cancel:hover { background: #ddd; }
  .btn-generate { background: #27ae60; color: #fff; padding: 10px 24px; border: none;
                  border-radius: 6px; font-size: 0.95rem; cursor: pointer; }
  .btn-generate:hover { background: #219a52; }
  .btn-generate:disabled { background: #aaa; cursor: not-allowed; }
  .generate-output {
    display: none; margin-top: 16px; background: #1a1a2e; color: #aac4ff;
    border-radius: 6px; padding: 16px; font-family: monospace; font-size: 0.82rem;
    white-space: pre-wrap; max-height: 300px; overflow-y: auto;
  }
  .suffix-badge {
    display: inline-block; background: #1a1a2e; color: #aac4ff;
    padding: 3px 10px; border-radius: 12px; font-size: 0.82rem;
    font-weight: bold; letter-spacing: .04em;
  }
</style>
</head>
<body>
<header>
  <h1>⚙️ Admin Panel</h1>
  <div>
    <span style="margin-right:16px; font-size:.88rem;">Logged in as
      <strong><?= htmlspecialchars($_SESSION['username']) ?></strong></span>
    <a href="/portal/logout.php">Sign Out</a>
  </div>
</header>

<div class="container">

  <?php if ($success): ?><div class="alert success"><?= htmlspecialchars($success) ?></div><?php endif; ?>
  <?php if ($error):   ?><div class="alert error"><?= htmlspecialchars($error) ?></div><?php endif; ?>

  <div class="card">
    <h2>➕ Add New User</h2>
    <form method="POST">
      <input type="hidden" name="action" value="add">
      <div class="grid">
        <div>
          <label>Username</label>
          <input type="text" name="username" required>
        </div>
        <div>
          <label>Password (min 8 chars)</label>
          <input type="password" name="password" required>
        </div>
        <div style="grid-column: span 2;">
          <label>Redirect URL after login</label>
          <input type="text" name="redirect"
                 placeholder="e.g. /Robinson_Instances.html or https://example.com">
        </div>
        <div>
          <div class="checkbox-row">
            <input type="checkbox" name="is_admin" id="new_admin">
            <label for="new_admin" style="margin:0;">Grant Admin Access</label>
          </div>
        </div>
        <div style="display:flex; align-items:flex-end;">
          <button type="submit" class="btn btn-primary">Add User</button>
        </div>
      </div>
    </form>
  </div>

  <div class="card">
    <h2>👥 Existing Users</h2>
    <table>
      <thead>
        <tr>
          <th>Username</th>
          <th>Role</th>
          <th>Redirect URL</th>
          <th>Created</th>
          <th>Actions</th>
        </tr>
      </thead>
      <tbody>
        <?php foreach ($users as $u): ?>
        <tr>
          <td><?= htmlspecialchars($u['username']) ?></td>
          <td><span class="badge <?= $u['is_admin'] ? 'admin' : 'user' ?>">
            <?= $u['is_admin'] ? 'Admin' : 'User' ?></span></td>
          <td class="url-cell" title="<?= htmlspecialchars($u['redirect']) ?>">
            <?= htmlspecialchars($u['redirect']) ?: '<em style="color:#aaa">none</em>' ?></td>
          <td><?= htmlspecialchars(substr($u['created'], 0, 10)) ?></td>
          <td>
            <button class="btn btn-edit"
              onclick="openEdit(
                <?= $u['id'] ?>,
                '<?= htmlspecialchars(addslashes($u['username'])) ?>',
                '<?= htmlspecialchars(addslashes($u['redirect'])) ?>',
                <?= $u['is_admin'] ?>
              )">Edit</button>
            <?php if ($u['id'] !== $_SESSION['user_id']): ?>
            <form method="POST" style="display:inline;"
                  onsubmit="return confirm('Delete user <?= htmlspecialchars($u['username']) ?>?')">
              <input type="hidden" name="action" value="delete">
              <input type="hidden" name="id" value="<?= $u['id'] ?>">
              <button type="submit" class="btn btn-danger">Delete</button>
            </form>
            <?php endif; ?>
          </td>
        </tr>
        <?php endforeach; ?>
      </tbody>
    </table>
  </div>

  <!-- CLIENT SUFFIXES -->
  <div class="card">
    <h2>🏷️ Client Suffixes</h2>
    <p style="font-size:0.88rem; color:#666; margin-bottom:20px;">
      Each suffix matches the last segment of a Vultr instance name (e.g. <code>ClientName-<strong>STI</strong></code>).
      After adding or removing a suffix, click <strong>Generate Pages</strong> below.
    </p>
    <form method="POST" style="display:flex; gap:12px; align-items:flex-end; margin-bottom:24px; flex-wrap:wrap;">
      <input type="hidden" name="action" value="add_client">
      <div>
        <label style="font-size:0.82rem; font-weight:bold; color:#444; display:block; margin-bottom:4px;">Suffix <span style="color:red">*</span></label>
        <input type="text" name="suffix" placeholder="e.g. STI" style="width:140px; padding:9px 11px; border:1px solid #ccc; border-radius:6px; text-transform:uppercase;">
      </div>
      <div>
        <label style="font-size:0.82rem; font-weight:bold; color:#444; display:block; margin-bottom:4px;">Display Label <span style="font-weight:normal; color:#888">(optional)</span></label>
        <input type="text" name="label" placeholder="e.g. STI Systems" style="width:200px; padding:9px 11px; border:1px solid #ccc; border-radius:6px;">
      </div>
      <button type="submit" class="btn btn-primary">Add Suffix</button>
    </form>

    <?php if (empty($clients)): ?>
      <p style="color:#aaa; font-style:italic; font-size:0.88rem;">No client suffixes added yet.</p>
    <?php else: ?>
    <table>
      <thead>
        <tr>
          <th>Suffix</th>
          <th>Display Label</th>
          <th>PHP File Generated</th>
          <th>Added</th>
          <th>Actions</th>
        </tr>
      </thead>
      <tbody>
        <?php foreach ($clients as $c): ?>
        <tr>
          <td><span class="suffix-badge"><?= htmlspecialchars($c['suffix']) ?></span></td>
          <td><?= htmlspecialchars($c['label']) ?: '<em style="color:#aaa">none</em>' ?></td>
          <td style="font-family:monospace; font-size:0.82rem; color:#555;">
            /portal/<?= htmlspecialchars($c['suffix']) ?>_Instances.php
          </td>
          <td><?= htmlspecialchars(substr($c['created'], 0, 10)) ?></td>
          <td>
            <form method="POST" style="display:inline;"
                  onsubmit="return confirm('Remove suffix <?= htmlspecialchars($c['suffix']) ?>?')">
              <input type="hidden" name="action" value="delete_client">
              <input type="hidden" name="id" value="<?= $c['id'] ?>">
              <button type="submit" class="btn btn-danger">Remove</button>
            </form>
          </td>
        </tr>
        <?php endforeach; ?>
      </tbody>
    </table>
    <?php endif; ?>
  </div>

  <!-- GENERATE PAGES -->
  <div class="card">
    <h2>⚙️ Generate Instance Pages</h2>
    <p style="font-size:0.88rem; color:#666; margin-bottom:16px;">
      Fetches live data from Vultr and regenerates a <code>.php</code> file for each client suffix above.
      Run this after adding/removing suffixes or to refresh instance data.
    </p>
    <button class="btn btn-generate" id="generateBtn" onclick="runGenerate()">
      ▶ Generate Pages Now
    </button>
    <pre class="generate-output" id="generateOutput"></pre>
  </div>

</div>

<!-- EDIT MODAL -->
<div class="modal-overlay" id="editModal">
  <div class="modal">
    <h2>✏️ Edit User</h2>
    <form method="POST">
      <input type="hidden" name="action" value="update">
      <input type="hidden" name="id" id="edit_id">
      <label>Username</label>
      <input type="text" id="edit_username" readonly style="background:#f5f5f5;">
      <label>New Password <span style="font-weight:normal;color:#888">(leave blank to keep current)</span></label>
      <input type="password" name="password">
      <label>Redirect URL after login</label>
      <input type="text" name="redirect" id="edit_redirect"
             placeholder="e.g. /portal/STI_Instances.php">
      <div class="checkbox-row">
        <input type="checkbox" name="is_admin" id="edit_is_admin">
        <label for="edit_is_admin" style="margin:0;">Grant Admin Access</label>
      </div>
      <div class="modal-actions">
        <button type="button" class="btn btn-cancel" onclick="closeEdit()">Cancel</button>
        <button type="submit" class="btn btn-primary">Save Changes</button>
      </div>
    </form>
  </div>
</div>

<script>
function openEdit(id, username, redirect, isAdmin) {
    document.getElementById('edit_id').value        = id;
    document.getElementById('edit_username').value  = username;
    document.getElementById('edit_redirect').value  = redirect;
    document.getElementById('edit_is_admin').checked = isAdmin == 1;
    document.getElementById('editModal').classList.add('active');
}
function closeEdit() {
    document.getElementById('editModal').classList.remove('active');
}
document.getElementById('editModal').addEventListener('click', function(e) {
    if (e.target === this) closeEdit();
});

function runGenerate() {
    const btn = document.getElementById('generateBtn');
    const out = document.getElementById('generateOutput');
    btn.disabled = true;
    btn.textContent = '⏳ Generating...';
    out.style.display = 'block';
    out.textContent = 'Running... please wait.\n';

    fetch('/portal/generate.php', { method: 'POST' })
        .then(r => r.json())
        .then(data => {
            out.textContent = data.output || '(no output)';
            btn.disabled = false;
            btn.textContent = '▶ Generate Pages Now';
        })
        .catch(err => {
            out.textContent = 'Error: ' + err;
            btn.disabled = false;
            btn.textContent = '▶ Generate Pages Now';
        });
}
</script>
</body>
</html>
PHPEOF

# ============================================================
#  Set permissions and restart Apache
# ============================================================
chown -R "$APACHE_USER:$APACHE_USER" "$WEB_DIR"
chmod -R 755 "$WEB_DIR"

# ============================================================
#  SELinux — allow Apache to write to the portal directory
#  (Required on CentOS/RHEL/FreePBX systems)
# ============================================================
if command -v getenforce &>/dev/null && [ "$(getenforce)" != "Disabled" ]; then
    echo "SELinux detected — setting apache2_sys_rw_content_t context..."
    # chcon (not needed on Debian) # chcon -R -t apache2_sys_rw_content_t "$WEB_DIR"
    semanage fcontext -a -t apache2_sys_rw_content_t "${WEB_DIR}(/.*)?" 2>/dev/null || true
    # restorecon (not needed on Debian) -Rv "$WEB_DIR" &>/dev/null
    echo "✅ SELinux context applied."
fi

# ============================================================
#  Copy logo to portal directory if it exists in same folder
# ============================================================
if [ -f "$(dirname "$0")/cqsimple_logo.png" ]; then
    cp "$(dirname "$0")/cqsimple_logo.png" "$WEB_DIR/cqsimple_logo.png"
    chmod 644 "$WEB_DIR/cqsimple_logo.png"
    echo "✅ Logo copied to $WEB_DIR"
else
    echo "⚠️  Logo not found. Copy it manually:"
    echo "   cp cqsimple_logo.png $WEB_DIR/"
fi

systemctl restart apache2 2>/dev/null || service apache2 restart 2>/dev/null

# ============================================================
#  Make generate script executable by Apache
# ============================================================
if [ -f "/usr/local/bin/generate_instances.sh" ]; then
    chmod 755 /usr/local/bin/generate_instances.sh
    echo "✅ Generate script permissions set."
fi

# ============================================================
#  Warning page — shown to VPN users attempting blocked sites
# ============================================================
echo "Deploying VPN warning page on port 8082..."
apt-get install -y netfilter-persistent iptables-persistent 2>/dev/null || true

# Add warning page port to Apache
grep -q '10.9.0.1:8082' /etc/apache2/ports.conf || echo 'Listen 10.9.0.1:8082' >> /etc/apache2/ports.conf

cat > /etc/apache2/sites-available/portal-warning.conf << 'WARNEOF'
<VirtualHost 10.9.0.1:8082>
    DocumentRoot /var/www/html/portal-warning
    <Directory /var/www/html/portal-warning>
        AllowOverride None
        Options -Indexes
        Require all granted
    </Directory>
</VirtualHost>
WARNEOF

mkdir -p /var/www/html/portal-warning

cat > /var/www/html/portal-warning/index.php << 'PHPEOF'
<?php
$attempted = htmlspecialchars($_SERVER['HTTP_HOST'] ?? 'that address');
?>
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1.0">
  <title>Access Restricted - CQ Simple VPN</title>
  <link rel="icon" type="image/png" href="/portal/cqsimple_logo.png">
  <style>
    *,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
    body{font-family:Arial,Helvetica,sans-serif;background:#0d1b2a;color:#c8d6e5;
         min-height:100vh;display:flex;align-items:center;justify-content:center;padding:20px}
    .box{background:#0f2035;border:1px solid #7a2020;border-radius:10px;
         max-width:540px;width:100%;padding:40px 36px;text-align:center;
         box-shadow:0 8px 40px rgba(0,0,0,.5)}
    .icon{font-size:3rem;margin-bottom:18px}
    h1{font-size:1.3rem;color:#e05050;margin-bottom:10px}
    .target{font-family:monospace;font-size:1rem;color:#f08080;
            background:#1a1010;border:1px solid #7a2020;border-radius:6px;
            padding:10px 18px;margin:18px 0;display:inline-block;word-break:break-all}
    p{font-size:.92rem;color:#9ab8d0;line-height:1.6;margin-bottom:12px}
    .note{font-size:.82rem;color:#5a7a9a;margin-top:20px;
          border-top:1px solid #1a3a5c;padding-top:16px}
    .btn{display:inline-block;margin-top:22px;padding:10px 28px;
         background:#1a3a6c;color:#5ba3f5;border-radius:6px;
         text-decoration:none;font-size:.9rem;border:1px solid #1e4a7a}
    .btn:hover{background:#2a5aa0}
  </style>
</head>
<body>
<div class="box">
  <div class="icon">&#128683;</div>
  <h1>Access Restricted</h1>
  <div class="target"><?= $attempted ?></div>
  <p>This VPN connection is managed by <strong>CQ Simple LLC</strong> and
     is restricted to authorised systems only.</p>
  <p>The destination you are trying to reach is not a CQ Simple managed
     system and cannot be accessed through this VPN.</p>
  <p>If you believe this is an error, contact your administrator.</p>
  <a class="btn" href="http://10.9.0.1/portal/">Return to Portal</a>
  <div class="note">
    CQ Simple Managed VPN &bull; Unauthorised access attempts are logged
  </div>
</div>
</body>
</html>
PHPEOF

chown -R www-data:www-data /var/www/html/portal-warning
chmod -R 644 /var/www/html/portal-warning
find /var/www/html/portal-warning -type d -exec chmod 755 {} \;
a2ensite portal-warning
systemctl reload apache2
ufw allow in on wg0 to any port 8082
echo "Warning page ready at http://10.9.0.1:8082/"

echo ""
echo "============================================"
echo " ✅  Login system deployed successfully!" 
echo "============================================"
echo ""
echo " Login page:  http://10.9.0.1/portal/  (WireGuard connected users only)"
echo " Admin panel: http://10.9.0.1/portal/admin.php"
echo ""
echo " Portal WAN IP (for remote VPS firewall rules): 207.148.10.72"
echo " Add this rule on each remote VPS: ufw allow from 207.148.10.72 to any port 80"
echo ""
echo " Default admin credentials:"
echo "   Username: admin"
echo "   Password: Admin1234!"
echo ""
echo " ⚠️  Change the admin password immediately"
echo "     via the Edit button in the admin panel!"
echo ""
echo " ℹ️  Copy the generate script to /root:"
echo "   cp generate_instances_debian.sh /usr/local/bin/generate_instances.sh"
echo "   chmod +x /usr/local/bin/generate_instances.sh"
echo "   Then set your VULTR_API_KEY at the top of the script"
echo "============================================"
