#!/bin/bash

# ============================================================
#  CQ Simple LLC — Cloud Instances Page Generator
#
#  TO ADD A NEW CLIENT:
#    1. Log into the Admin Panel
#    2. Go to Client Suffixes → Add the new suffix
#    3. Click "Generate Pages Now"
#    4. Set the user's redirect URL to /portal/SUFFIX_Instances.php
# ============================================================

VULTR_API_KEY="NUDNRUE3KFXYESOJP47UA2HBRTQPL5TGFH5A"
API_URL="https://api.vultr.com/v2/instances"
OUTPUT_DIR="/var/www/html/portal"
DB_USER="root"
DB_PASS="NewRootPass123!"
DB_NAME="portal"

# ============================================================
#  Read client suffixes from MariaDB
#  (Manage these in the Admin Panel → Client Suffixes)
# ============================================================
mapfile -t CLIENT_SUFFIXES < <(mysql -u "$DB_USER" -p"$DB_PASS" -N -e "SELECT suffix FROM clients ORDER BY suffix;" "$DB_NAME" 2>/dev/null)

if [ ${#CLIENT_SUFFIXES[@]} -eq 0 ]; then
    echo "⚠️  No client suffixes found in the database."
    echo "    Add suffixes via the Admin Panel → Client Suffixes section."
    exit 1
fi

echo "Found ${#CLIENT_SUFFIXES[@]} client(s): ${CLIENT_SUFFIXES[*]}"

# ============================================================
#  Region code to full name
# ============================================================
get_region_name() {
    case "$1" in
        "ewr") echo "Newark, NJ, USA" ;;
        "sjc") echo "San Jose, CA, USA" ;;
        "ord") echo "Chicago, IL, USA" ;;
        "lax") echo "Los Angeles, CA, USA" ;;
        "mia") echo "Miami, FL, USA" ;;
        "dfw") echo "Dallas, TX, USA" ;;
        "sea") echo "Seattle, WA, USA" ;;
        "atl") echo "Atlanta, GA, USA" ;;
        "ams") echo "Amsterdam, Netherlands" ;;
        "fra") echo "Frankfurt, Germany" ;;
        "lhr") echo "London, UK" ;;
        "par") echo "Paris, France" ;;
        "yto") echo "Toronto, Canada" ;;
        "syd") echo "Sydney, Australia" ;;
        "sin") echo "Singapore" ;;
        "nrt") echo "Tokyo, Japan" ;;
        "bom") echo "Mumbai, India" ;;
        *) echo "Unknown ($1)" ;;
    esac
}

# ============================================================
#  Fetch ALL instances from Vultr once
# ============================================================

# Use mktemp so temp files are always owned by the current user
ALL_INSTANCES=$(mktemp /tmp/all_instances.XXXXXX)
CLIENT_INSTANCES=$(mktemp /tmp/client_instances.XXXXXX)
trap "rm -f $ALL_INSTANCES $CLIENT_INSTANCES" EXIT

echo "Fetching all instances from Vultr..."

cursor=""
while : ; do
    response=$(curl -s -X GET "$API_URL?per_page=100&cursor=$cursor" \
        -H "Authorization: Bearer $VULTR_API_KEY" \
        -H "Content-Type: application/json")

    echo "$response" | jq -r '
        .instances[] |
        "\(.label),\(.main_ip),\(.date_created | split("T")[0]),\(.region)"
    ' >> "$ALL_INSTANCES"

    cursor=$(echo "$response" | jq -r '.meta.links.next // empty')
    [[ -z "$cursor" ]] && break
done

total=$(wc -l < "$ALL_INSTANCES")
echo "Fetched $total total instances. Generating pages..."
echo ""

# ============================================================
#  Loop — generate one PHP file per client suffix
# ============================================================
for suffix in "${CLIENT_SUFFIXES[@]}"; do

    PHP_FILE="${OUTPUT_DIR}/${suffix}_Instances.php"

    # Filter instances where last segment after '-' matches suffix
    awk -F',' -v s="${suffix}" '
        {
            n = split($1, parts, "-")
            if (tolower(parts[n]) == tolower(s)) print $0
        }
    ' "$ALL_INSTANCES" | sort -t',' -k1,1 > "$CLIENT_INSTANCES"

    count=$(wc -l < "$CLIENT_INSTANCES")
    echo "  [$suffix] → ${count} instance(s) → ${PHP_FILE}"

    # ---- Write PHP file ----
    cat <<EOF > "$PHP_FILE"
<?php
require_once __DIR__ . '/config.php';
require_login();
header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
header('Pragma: no-cache');
header('Expires: Sat, 01 Jan 2000 00:00:00 GMT');
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>${suffix} Cloud Instances</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="Cache-Control" content="no-store, no-cache, must-revalidate">
    <meta http-equiv="Pragma" content="no-cache">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.2/css/all.min.css">
    <style>
        *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: Arial, sans-serif; background: #f0f2f5; color: #222; }
        header {
            background: #1a1a2e; color: #fff; padding: 14px 28px;
            display: flex; justify-content: space-between; align-items: center;
        }
        header h1 { font-size: 1.2rem; }
        header .meta { font-size: 0.82rem; color: #aac4ff; }
        .header-logo { height: 42px; width: 42px; border-radius: 6px; margin-right: 12px; vertical-align: middle; }
        .logout-btn {
            background: transparent; border: 1px solid #aac4ff; color: #aac4ff;
            padding: 6px 14px; border-radius: 6px; font-size: 0.82rem;
            cursor: pointer; text-decoration: none;
            transition: background .2s, color .2s; margin-left: 16px;
        }
        .logout-btn:hover { background: #aac4ff; color: #1a1a2e; text-decoration: none; }
        .container { max-width: 1100px; margin: 30px auto; padding: 0 20px; }
        .info-bar {
            background: #e8f4fd; border: 1px solid #b8d9f5; color: #1a6fa8;
            border-radius: 6px; padding: 10px 16px; font-size: 0.88rem; margin-bottom: 20px;
        }
        .card {
            background: #fff; border-radius: 10px; padding: 28px;
            box-shadow: 0 2px 12px rgba(0,0,0,0.08); margin-bottom: 24px;
        }
        .card h2 {
            font-size: 1.1rem; margin-bottom: 20px; color: #1a1a2e;
            border-bottom: 2px solid #e8eaf0; padding-bottom: 10px;
        }
        table { width: 100%; border-collapse: collapse; font-size: 0.9rem; }
        th, td { text-align: left; padding: 10px 12px; border-bottom: 1px solid #eee; }
        th {
            background: #f8f9fb; font-size: 0.82rem; color: #555;
            text-transform: uppercase; letter-spacing: .04em;
            cursor: pointer; user-select: none;
        }
        th:hover { background: #eef0f5; }
        tr:hover td { background: #fafbff; }
        .sort-icon { margin-left: 5px; color: #aaa; }
        a { color: #3498db; text-decoration: none; }
        a:hover { text-decoration: underline; }
        footer.copyright {
            text-align: center; padding: 20px; font-size: 0.78rem; color: #aaa;
        }
    </style>
    <script>
    function sortTable(columnIndex, isDate = false) {
        const table = document.getElementById("instancesTable");
        const tbody = table.tBodies[0];
        const rows = Array.from(tbody.rows);
        let asc = table.getAttribute("data-sort-dir") !== "asc";
        rows.sort((a, b) => {
            let valA = a.cells[columnIndex].innerText.trim().toLowerCase();
            let valB = b.cells[columnIndex].innerText.trim().toLowerCase();
            if (isDate) { valA = valA.replace(/-/g,''); valB = valB.replace(/-/g,''); }
            if (valA < valB) return asc ? -1 : 1;
            if (valA > valB) return asc ? 1 : -1;
            return 0;
        });
        rows.forEach(row => tbody.appendChild(row));
        table.setAttribute("data-sort-dir", asc ? "asc" : "desc");
    }
    </script>
</head>
<body>
<header>
    <div style="display:flex; align-items:center;">
        <img src="/portal/cqsimple_logo.png" alt="CQ Simple LLC" class="header-logo">
        <span style="font-size:1.1rem; font-weight:bold;">${suffix} Cloud Instances</span>
    </div>
    <div style="display:flex; align-items:center;">
        <span class="meta">CQ Simple LLC &nbsp;|&nbsp; Updated: $(date)</span>
        <a href="/portal/logout.php" class="logout-btn">&#128274; Sign Out</a>
    </div>
</header>
<div class="container">
    <div class="info-bar">
        &#8505;&#65039; If you can't connect on port 80, try <strong>port 85</strong>.
    </div>
    <div class="card" style="margin-bottom: 24px;">
        <a href="https://simplyhostedplus.com/signin?locale=en-US" target="_blank"
           style="display:flex; align-items:center; gap:12px; text-decoration:none; color:#1a1a2e;">
            <span style="font-size:1.5rem;">&#127760;</span>
            <div>
                <div style="font-weight:bold; font-size:1rem;">Simply Hosted + Clients</div>
                <div style="font-size:0.82rem; color:#3498db;">simplyhostedplus.com</div>
            </div>
            <span style="margin-left:auto; color:#aaa; font-size:0.85rem;">Sign In &#8594;</span>
        </a>
    </div>
    <div class="card">
        <h2>&#128101; CQ Simply Hosted Systems — ${suffix}</h2>
        <table id="instancesTable" data-sort-dir="asc">
            <thead>
                <tr>
                    <th onclick="sortTable(0)">Instance Name <i class="fa fa-sort sort-icon"></i></th>
                    <th>IP Address</th>
                    <th onclick="sortTable(2, true)">Date Created <i class="fa fa-sort sort-icon"></i></th>
                    <th onclick="sortTable(3)">Region <i class="fa fa-sort sort-icon"></i></th>
                </tr>
            </thead>
            <tbody>
EOF

    while IFS=',' read -r label ip date_created region; do
        ip_link="<a href='http://$ip' target='_blank'>$ip</a>"
        region_name=$(get_region_name "$region")
        echo "                <tr><td>$label</td><td>$ip_link</td><td>$date_created</td><td>$region_name</td></tr>" >> "$PHP_FILE"
    done < "$CLIENT_INSTANCES"

    cat <<EOF >> "$PHP_FILE"
            </tbody>
        </table>
    </div>

    <!-- ON-PREMISE SYSTEMS -->
    <div class="card">
        <h2>&#127968; On-Premise Systems</h2>
        <p style="font-size:0.85rem; color:#666; margin-bottom:18px;">
            Add bookmarks to your internal or on-premise systems. These are stored privately for <strong>${suffix}</strong>.
        </p>

        <?php
        \$db2 = get_db();
        \$sfx = '${suffix}';
        \$st  = \$db2->prepare('SELECT id, site_name, url, lan_ip, user, password, note, created FROM onprem_links WHERE suffix=? ORDER BY site_name ASC');
        \$st->bind_param('s', \$sfx);
        \$st->execute();
        \$links = \$st->get_result()->fetch_all(MYSQLI_ASSOC);
        \$st->close();
        \$db2->close();
        ?>

        <form method="POST" action="/portal/links.php"
              style="display:flex; gap:10px; align-items:flex-end; margin-bottom:20px; flex-wrap:wrap;">
            <input type="hidden" name="action" value="add">
            <input type="hidden" name="suffix" value="${suffix}">
            <div>
                <label style="display:block; font-size:0.78rem; font-weight:bold; color:#555; margin-bottom:4px; text-transform:uppercase; letter-spacing:.04em;">Site Name</label>
                <input type="text" name="site_name" placeholder="e.g. Accounting Server" required
                       style="padding:8px 12px; border:1px solid #ddd; border-radius:6px; font-size:0.88rem; width:220px;">
            </div>
            <div>
                <label style="display:block; font-size:0.78rem; font-weight:bold; color:#555; margin-bottom:4px; text-transform:uppercase; letter-spacing:.04em;">URL</label>
                <input type="text" name="url" placeholder="e.g. 192.168.1.50 or http://server" required
                       style="padding:8px 12px; border:1px solid #ddd; border-radius:6px; font-size:0.88rem; width:280px;">
            </div>
            <button type="submit"
                    style="padding:8px 20px; background:#1a1a2e; color:#fff; border:none; border-radius:6px; font-size:0.88rem; cursor:pointer; white-space:nowrap;">
                + Add System
            </button>
        </form>

        <?php if (empty(\$links)): ?>
            <p style="color:#aaa; font-style:italic; font-size:0.88rem;">No on-premise systems added yet.</p>
        <?php else: ?>
        <table>
            <thead>
                <tr>
                    <th>Site Name</th>
                    <th>URL</th>
                    <th>Added</th>
                    <th style="width:160px;">Actions</th>
                </tr>
            </thead>
            <tbody>
                <?php foreach (\$links as \$lnk): ?>
                <tr>
                    <td><strong><?= htmlspecialchars(\$lnk['site_name']) ?></strong></td>
                    <td><a href="<?= htmlspecialchars(\$lnk['url']) ?>" target="_blank"><?= htmlspecialchars(\$lnk['url']) ?></a></td>
                    <td style="color:#999; font-size:0.82rem;"><?= substr(\$lnk['created'], 0, 10) ?></td>
                    <td>
                        <button onclick="openEdit(<?= \$lnk['id'] ?>, '<?= htmlspecialchars(addslashes(\$lnk['site_name'])) ?>', '<?= htmlspecialchars(addslashes(\$lnk['url'])) ?>')"
                                style="padding:4px 12px; background:#3498db; color:#fff; border:none; border-radius:5px; font-size:0.8rem; cursor:pointer; margin-right:4px;">
                            Edit
                        </button>
                        <form method="POST" action="/portal/links.php" style="display:inline;"
                              onsubmit="return confirm('Remove this system?')">
                            <input type="hidden" name="action" value="delete">
                            <input type="hidden" name="suffix" value="${suffix}">
                            <input type="hidden" name="id" value="<?= \$lnk['id'] ?>">
                            <button type="submit"
                                    style="padding:4px 12px; background:#e74c3c; color:#fff; border:none; border-radius:5px; font-size:0.8rem; cursor:pointer;">
                                Remove
                            </button>
                        </form>
                    </td>
                </tr>
                <?php endforeach; ?>
            </tbody>
        </table>
        <?php endif; ?>
    </div>

</div>

<!-- EDIT MODAL -->
<div id="editModal" style="display:none; position:fixed; inset:0; background:rgba(0,0,0,0.5); z-index:100; align-items:center; justify-content:center;">
    <div style="background:#fff; border-radius:10px; padding:28px; width:100%; max-width:460px; box-shadow:0 8px 32px rgba(0,0,0,0.25);">
        <h2 style="font-size:1.1rem; margin-bottom:18px; color:#1a1a2e;">&#9998; Edit On-Premise System</h2>
        <form method="POST" action="/portal/links.php">
            <input type="hidden" name="action" value="edit">
            <input type="hidden" name="suffix" value="${suffix}">
            <input type="hidden" name="id" id="edit_id">
            <label style="display:block; font-size:0.82rem; font-weight:bold; color:#333; margin-bottom:4px;">Site Name</label>
            <input type="text" name="site_name" id="edit_name" required
                   style="width:100%; padding:9px 12px; border:1px solid #ccc; border-radius:6px; font-size:0.9rem; margin-bottom:14px;">
            <label style="display:block; font-size:0.82rem; font-weight:bold; color:#333; margin-bottom:4px;">URL</label>
            <input type="text" name="url" id="edit_url" required
                   style="width:100%; padding:9px 12px; border:1px solid #ccc; border-radius:6px; font-size:0.9rem; margin-bottom:20px;">
            <div style="display:flex; justify-content:flex-end; gap:10px;">
                <button type="button" onclick="closeEdit()"
                        style="padding:8px 18px; background:#eee; color:#333; border:none; border-radius:6px; cursor:pointer;">Cancel</button>
                <button type="submit"
                        style="padding:8px 18px; background:#1a1a2e; color:#fff; border:none; border-radius:6px; cursor:pointer;">Save Changes</button>
            </div>
        </form>
    </div>
</div>

<script>
function openEdit(id, name, url) {
    document.getElementById('edit_id').value   = id;
    document.getElementById('edit_name').value = name;
    document.getElementById('edit_url').value  = url;
    document.getElementById('editModal').style.display = 'flex';
}
function closeEdit() {
    document.getElementById('editModal').style.display = 'none';
}
document.getElementById('editModal').addEventListener('click', function(e) {
    if (e.target === this) closeEdit();
});
</script>

<footer class="copyright">&copy; $(date +%Y) CQ Simple LLC. All rights reserved.</footer>
</body>
</html>
EOF

    chown www-data:www-data "$PHP_FILE" 2>/dev/null || true
    chmod 644 "$PHP_FILE"

done

# ============================================================
#  Generate MASTER page — all instances, no filtering
# ============================================================
MASTER_FILE="${OUTPUT_DIR}/Master_Instances.php"
sort -t',' -k1,1 "$ALL_INSTANCES" > "$CLIENT_INSTANCES"
master_count=$(wc -l < "$CLIENT_INSTANCES")
echo "  [MASTER] → ${master_count} instance(s) → ${MASTER_FILE}"

cat <<EOF > "$MASTER_FILE"
<?php
require_once __DIR__ . '/config.php';
require_login();
header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
header('Pragma: no-cache');
header('Expires: Sat, 01 Jan 2000 00:00:00 GMT');
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Master CQ Vultr Systems</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="Cache-Control" content="no-store, no-cache, must-revalidate">
    <meta http-equiv="Pragma" content="no-cache">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.2/css/all.min.css">
    <style>
        *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: Arial, sans-serif; background: #f0f2f5; color: #222; }
        header {
            background: #1a1a2e; color: #fff; padding: 14px 28px;
            display: flex; justify-content: space-between; align-items: center;
        }
        .header-logo { height: 42px; width: 42px; border-radius: 6px; margin-right: 12px; vertical-align: middle; }
        .header-meta { font-size: 0.82rem; color: #aac4ff; }
        .logout-btn {
            background: transparent; border: 1px solid #aac4ff; color: #aac4ff;
            padding: 6px 14px; border-radius: 6px; font-size: 0.82rem;
            cursor: pointer; text-decoration: none;
            transition: background .2s, color .2s; margin-left: 16px;
        }
        .logout-btn:hover { background: #aac4ff; color: #1a1a2e; text-decoration: none; }
        .container { max-width: 1200px; margin: 30px auto; padding: 0 20px; }
        .stats-bar {
            display: flex; gap: 16px; margin-bottom: 20px; flex-wrap: wrap;
        }
        .stat-card {
            background: #fff; border-radius: 10px; padding: 16px 24px;
            box-shadow: 0 2px 12px rgba(0,0,0,0.08); flex: 1; min-width: 140px;
            text-align: center;
        }
        .stat-card .num { font-size: 2rem; font-weight: bold; color: #1a1a2e; }
        .stat-card .lbl { font-size: 0.78rem; color: #888; text-transform: uppercase; letter-spacing: .06em; margin-top: 4px; }
        .search-bar {
            background: #fff; border-radius: 10px; padding: 16px 20px;
            box-shadow: 0 2px 12px rgba(0,0,0,0.08); margin-bottom: 20px;
            display: flex; gap: 12px; align-items: center; flex-wrap: wrap;
        }
        .search-bar input {
            flex: 1; min-width: 200px; padding: 9px 14px;
            border: 1px solid #ddd; border-radius: 6px; font-size: 0.9rem;
        }
        .search-bar input:focus { outline: none; border-color: #3498db; }
        .search-bar label { font-size: 0.85rem; color: #555; font-weight: bold; white-space: nowrap; }
        .card {
            background: #fff; border-radius: 10px; padding: 28px;
            box-shadow: 0 2px 12px rgba(0,0,0,0.08); margin-bottom: 24px;
        }
        .card h2 {
            font-size: 1.1rem; margin-bottom: 20px; color: #1a1a2e;
            border-bottom: 2px solid #e8eaf0; padding-bottom: 10px;
            display: flex; justify-content: space-between; align-items: center;
        }
        .row-count { font-size: 0.8rem; color: #888; font-weight: normal; }
        table { width: 100%; border-collapse: collapse; font-size: 0.88rem; }
        th, td { text-align: left; padding: 9px 12px; border-bottom: 1px solid #eee; }
        th {
            background: #f8f9fb; font-size: 0.78rem; color: #555;
            text-transform: uppercase; letter-spacing: .04em;
            cursor: pointer; user-select: none; white-space: nowrap;
        }
        th:hover { background: #eef0f5; }
        tr:hover td { background: #fafbff; }
        tr.hidden { display: none; }
        .sort-icon { margin-left: 4px; color: #aaa; }
        .suffix-tag {
            display: inline-block; background: #1a1a2e; color: #aac4ff;
            padding: 2px 8px; border-radius: 10px; font-size: 0.75rem;
            font-weight: bold; letter-spacing: .04em;
        }
        a { color: #3498db; text-decoration: none; }
        a:hover { text-decoration: underline; }
        footer.copyright { text-align: center; padding: 20px; font-size: 0.78rem; color: #aaa; }
    </style>
    <script>
    function sortTable(colIdx, isDate = false) {
        const table = document.getElementById("masterTable");
        const tbody = table.tBodies[0];
        const rows = Array.from(tbody.querySelectorAll("tr:not(.hidden), tr.hidden"));
        let asc = table.getAttribute("data-sort-dir") !== "asc";
        rows.sort((a, b) => {
            let A = a.cells[colIdx].innerText.trim().toLowerCase();
            let B = b.cells[colIdx].innerText.trim().toLowerCase();
            if (isDate) { A = A.replace(/-/g,''); B = B.replace(/-/g,''); }
            return asc ? A.localeCompare(B) : B.localeCompare(A);
        });
        rows.forEach(r => tbody.appendChild(r));
        table.setAttribute("data-sort-dir", asc ? "asc" : "desc");
        updateCount();
    }
    function filterTable() {
        const q = document.getElementById("searchInput").value.toLowerCase();
        const rows = document.querySelectorAll("#masterTable tbody tr");
        let visible = 0;
        rows.forEach(r => {
            const match = r.innerText.toLowerCase().includes(q);
            r.classList.toggle("hidden", !match);
            if (match) visible++;
        });
        document.getElementById("rowCount").textContent = visible + " instances";
    }
    function updateCount() {
        const total = document.querySelectorAll("#masterTable tbody tr:not(.hidden)").length;
        document.getElementById("rowCount").textContent = total + " instances";
    }
    </script>
</head>
<body>
<header>
    <div style="display:flex; align-items:center;">
        <img src="/portal/cqsimple_logo.png" alt="CQ Simple LLC" class="header-logo">
        <span style="font-size:1.15rem; font-weight:bold;">Master CQ Vultr Systems</span>
    </div>
    <div style="display:flex; align-items:center;">
        <span class="header-meta">CQ Simple LLC &nbsp;|&nbsp; Updated: $(date)</span>
        <a href="/portal/logout.php" class="logout-btn">&#128274; Sign Out</a>
    </div>
</header>

<div class="container">

    <div class="stats-bar">
        <div class="stat-card">
            <div class="num">${master_count}</div>
            <div class="lbl">Total Instances</div>
        </div>
        <div class="stat-card">
            <div class="num">${#CLIENT_SUFFIXES[@]}</div>
            <div class="lbl">Client Groups</div>
        </div>
        <div class="stat-card">
            <div class="num">$(date +%Y-%m-%d)</div>
            <div class="lbl">Last Generated</div>
        </div>
    </div>

    <div class="search-bar">
        <label for="searchInput">&#128269; Filter:</label>
        <input type="text" id="searchInput" placeholder="Search by name, IP, region, or client..." oninput="filterTable()">
    </div>

    <div class="card">
        <h2>
            All Vultr Instances
            <span class="row-count" id="rowCount">${master_count} instances</span>
        </h2>
        <table id="masterTable" data-sort-dir="asc">
            <thead>
                <tr>
                    <th onclick="sortTable(0)">Instance Name <i class="fa fa-sort sort-icon"></i></th>
                    <th>IP Address</th>
                    <th onclick="sortTable(2, true)">Date Created <i class="fa fa-sort sort-icon"></i></th>
                    <th onclick="sortTable(3)">Region <i class="fa fa-sort sort-icon"></i></th>
                    <th onclick="sortTable(4)">Client <i class="fa fa-sort sort-icon"></i></th>
                    <th style="width:80px;">SSH</th>
                </tr>
            </thead>
            <tbody>
EOF

while IFS=',' read -r label ip date_created region; do
    ip_link="<a href='http://$ip' target='_blank'>$ip</a>"
    region_name=$(get_region_name "$region")
    # Extract suffix (last segment after final dash)
    suffix_tag=$(echo "$label" | awk -F'-' '{print $NF}' | tr '[:lower:]' '[:upper:]')
    ssh_btn="<a href='kitty://root@$ip' title='Open SSH session via KiTTY' style='display:inline-flex;align-items:center;gap:4px;padding:4px 10px;background:#1a1a2e;color:#aac4ff;border-radius:5px;text-decoration:none;font-size:0.78rem;font-weight:bold;'>&#128421; SSH</a>"
    echo "                <tr><td>$label</td><td>$ip_link</td><td>$date_created</td><td>$region_name</td><td><span class='suffix-tag'>$suffix_tag</span></td><td>$ssh_btn</td></tr>" >> "$MASTER_FILE"
done < "$CLIENT_INSTANCES"

cat <<EOF >> "$MASTER_FILE"
            </tbody>
        </table>
    </div>
</div>
    <!-- ON-PREMISE SYSTEMS - ALL DEALERS -->
    <div class="card" style="margin-top:30px;">
        <h2>&#127968; On-Premise Systems &mdash; All Dealers</h2>
        <?php
        \$db_op = get_db();
        \$res   = \$db_op->query('SELECT suffix FROM clients ORDER BY suffix ASC');
        \$suffixes = [];
        while (\$r = \$res->fetch_assoc()) { \$suffixes[] = \$r['suffix']; }
        \$res->close();
        \$any = false;
        foreach (\$suffixes as \$sfx):
            \$st = \$db_op->prepare('SELECT id, site_name, url, lan_ip, user, password, note FROM onprem_links WHERE suffix=? ORDER BY site_name ASC');
            \$st->bind_param('s', \$sfx);
            \$st->execute();
            \$links = \$st->get_result()->fetch_all(MYSQLI_ASSOC);
            \$st->close();
            if (empty(\$links)) continue;
            \$any = true;
        ?>
        <div style="margin-bottom:32px;">
            <div style="display:flex;align-items:center;gap:12px;margin-bottom:14px;">
                <span style="background:#1a1a2e;color:#aac4ff;padding:4px 14px;border-radius:12px;font-size:0.82rem;font-weight:bold;letter-spacing:.04em;"><?= htmlspecialchars(\$sfx) ?></span>
                <span style="color:#888;font-size:0.85rem;"><?= count(\$links) ?> system<?= count(\$links) !== 1 ? 's' : '' ?></span>
            </div>
            <table style="width:100%;border-collapse:collapse;font-size:0.88rem;">
                <thead>
                    <tr>
                        <th style="background:#f8f9fb;padding:8px 12px;text-align:left;font-size:0.78rem;color:#555;text-transform:uppercase;letter-spacing:.04em;border-bottom:2px solid #eee;">Site Name</th>
                        <th style="background:#f8f9fb;padding:8px 12px;text-align:left;font-size:0.78rem;color:#555;text-transform:uppercase;letter-spacing:.04em;border-bottom:2px solid #eee;">URL</th>
                        <th style="background:#f8f9fb;padding:8px 12px;text-align:left;font-size:0.78rem;color:#555;text-transform:uppercase;letter-spacing:.04em;border-bottom:2px solid #eee;">LAN IP</th>
                        <th style="background:#f8f9fb;padding:8px 12px;text-align:left;font-size:0.78rem;color:#555;text-transform:uppercase;letter-spacing:.04em;border-bottom:2px solid #eee;">User</th>
                        <th style="background:#f8f9fb;padding:8px 12px;text-align:left;font-size:0.78rem;color:#555;text-transform:uppercase;letter-spacing:.04em;border-bottom:2px solid #eee;">Password</th>
                        <th style="background:#f8f9fb;padding:8px 12px;text-align:left;font-size:0.78rem;color:#555;text-transform:uppercase;letter-spacing:.04em;border-bottom:2px solid #eee;">Note</th>
                        <th style="background:#f8f9fb;padding:8px 12px;text-align:left;font-size:0.78rem;color:#555;text-transform:uppercase;letter-spacing:.04em;border-bottom:2px solid #eee;width:80px;">SSH</th>
                    </tr>
                </thead>
                <tbody>
                <?php foreach (\$links as \$lnk): ?>
                    <tr>
                        <td style="padding:8px 12px;border-bottom:1px solid #eee;"><strong><?= htmlspecialchars(\$lnk['site_name']) ?></strong></td>
                        <td style="padding:8px 12px;border-bottom:1px solid #eee;"><?php if(!empty(\$lnk['url'])): ?><a href="<?= htmlspecialchars(\$lnk['url']) ?>" target="_blank"><?= htmlspecialchars(\$lnk['url']) ?></a><?php else: ?>&mdash;<?php endif; ?></td>
                        <td style="padding:8px 12px;border-bottom:1px solid #eee;font-family:monospace;font-size:0.88rem;"><?= htmlspecialchars(\$lnk['lan_ip'] ?? '') ?></td>
                        <td style="padding:8px 12px;border-bottom:1px solid #eee;"><?= htmlspecialchars(\$lnk['user'] ?? '') ?></td>
                        <td style="padding:8px 12px;border-bottom:1px solid #eee;">
                            <?php if(!empty(\$lnk['password'])): ?>
                            <span style="display:flex;align-items:center;gap:6px;">
                                <span id="mpw<?= (int)\$lnk['id'] ?>" data-v="<?= htmlspecialchars(\$lnk['password']) ?>" style="font-family:monospace;">&#8226;&#8226;&#8226;&#8226;&#8226;&#8226;&#8226;&#8226;</span>
                                <button type="button" onclick="toggleMpw(<?= (int)\$lnk['id'] ?>)"
                                        style="padding:2px 8px;font-size:0.75rem;border:1px solid #ddd;border-radius:4px;cursor:pointer;background:#f8f9fb;">Show</button>
                            </span>
                            <?php else: ?>&mdash;<?php endif; ?>
                        </td>
                        <td style="padding:8px 12px;border-bottom:1px solid #eee;color:#666;font-size:0.85rem;"><?= htmlspecialchars(\$lnk['note'] ?? '') ?></td>
                        <td style="padding:8px 12px;border-bottom:1px solid #eee;">
                            <?php if(!empty(\$lnk['lan_ip'])):
                                \$ssh_user = !empty(\$lnk['user']) ? \$lnk['user'] : 'root';
                            ?>
                            <a href="kitty://<?= htmlspecialchars(\$ssh_user) ?>@<?= htmlspecialchars(\$lnk['lan_ip']) ?>"
                               title="Open SSH session via KiTTY"
                               style="display:inline-flex;align-items:center;gap:4px;padding:4px 10px;background:#1a1a2e;color:#aac4ff;border-radius:5px;text-decoration:none;font-size:0.78rem;font-weight:bold;">
                                &#128421; SSH
                            </a>
                            <?php else: ?>&mdash;<?php endif; ?>
                        </td>
                    </tr>
                <?php endforeach; ?>
                </tbody>
            </table>
        </div>
        <?php endforeach; ?>
        <?php \$db_op->close(); ?>
        <?php if (!\$any): ?>
            <p style="color:#aaa;font-style:italic;font-size:0.88rem;">No on-premise systems have been added yet.</p>
        <?php endif; ?>
    </div>
</div>
<script>
function toggleMpw(id) {
    var el = document.getElementById('mpw' + id);
    var btn = el.nextElementSibling;
    if (btn.textContent.trim() === 'Show') {
        el.textContent = el.dataset.v;
        btn.textContent = 'Hide';
    } else {
        el.innerHTML = '&#8226;&#8226;&#8226;&#8226;&#8226;&#8226;&#8226;&#8226;';
        btn.textContent = 'Show';
    }
}
</script>
<footer class="copyright">&copy; $(date +%Y) CQ Simple LLC. All rights reserved.</footer>
</body>
</html>
EOF

echo ""
echo "✅ Done! Generated ${#CLIENT_SUFFIXES[@]} client pages + 1 master page:"
for suffix in "${CLIENT_SUFFIXES[@]}"; do
    echo "   /portal/${suffix}_Instances.php"
done
chown -R www-data:www-data "$OUTPUT_DIR" 2>/dev/null || true
echo "   /portal/Master_Instances.php  →  set redirect to: /portal/Master_Instances.php"

# ── Rebuild firewall whitelist to match current Vultr instance IPs ───────────────────
if [[ -x /usr/local/bin/portal_firewall.sh ]]; then
    echo ""
    echo "Updating firewall whitelist..."
    bash /usr/local/bin/portal_firewall.sh
else
    echo ""
    echo "⚠️  portal_firewall.sh not found in /usr/local/bin/ — firewall whitelist not updated."
    echo "   Copy portal_firewall.sh to /usr/local/bin/ and chmod +x to enable auto-updating."
fi

# ── Rebuild IP whitelist from fresh Vultr data ────────────────────────────────
FIREWALL_SCRIPT="/usr/local/bin/portal_firewall.sh"
if [[ -f "$FIREWALL_SCRIPT" ]]; then
    echo ""
    echo "Rebuilding IP whitelist..."
    bash "$FIREWALL_SCRIPT" --update-whitelist-only
    # Persist the updated ipset
    ipset save > /etc/ipset.conf 2>/dev/null || true
    echo "Whitelist updated and saved."
else
    echo ""
    echo "ℹ️  portal_firewall.sh not found — skipping whitelist update."
    echo "   Run portal_firewall.sh once to enable IP restriction."
fi