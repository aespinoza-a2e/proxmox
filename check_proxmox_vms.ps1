# =============================================================================
# Proxmox Cluster VM Inventory + Memory Over-Provisioning Audit
# Connects to any reachable cluster node via SSH, queries `pvesh
# /cluster/resources`, lists every VM with its configured memory, and prints a
# per-node summary showing allocated vs total RAM with status flags.
# Read-only. No writes anywhere.
# Requires: Install-Module Posh-SSH -Scope CurrentUser
# =============================================================================

Import-Module Posh-SSH -ErrorAction Stop

# --- Configuration -----------------------------------------------------------
$ConfigPath = Join-Path $PSScriptRoot 'config.json'
if (-not (Test-Path $ConfigPath)) {
    Write-Host "Missing $ConfigPath. Copy config.example.json to config.json and edit." -ForegroundColor Red
    exit 1
}
$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$Nodes             = $Config.Nodes
$SshUser           = $Config.SshUser
$SshPass           = $Config.SshPass
$ConnectTimeoutSec = $Config.ConnectTimeoutSec

$SecurePass = ConvertTo-SecureString $SshPass -AsPlainText -Force
$Cred = New-Object System.Management.Automation.PSCredential ($SshUser, $SecurePass)

# Cluster-wide query — runs on any one node, returns VMs + nodes in one call.
# No --type filter so we get node capacity entries alongside VM entries.
$RemoteCmd = "pvesh get /cluster/resources --output-format json"

# Over-provisioning thresholds (in bytes)
$WarnFreeBytes = 30GB   # yellow if free < 30 GB
$CritFreeBytes = 15GB   # red    if free <= 15 GB (or alloc > total)

# --- Header ------------------------------------------------------------------
Write-Host ""
Write-Host "==============================================================" -ForegroundColor White
Write-Host "  PROXMOX CLUSTER - VM Inventory (read-only)" -ForegroundColor White
Write-Host "==============================================================" -ForegroundColor White
Write-Host ""

# --- Connect to first reachable node ----------------------------------------
$session = $null
$connectedNode = $null

foreach ($n in $Nodes) {
    $ip = $n.IP
    Write-Host ("  Trying {0,-16} ..." -f $ip) -NoNewline -ForegroundColor Cyan
    try {
        $session = New-SSHSession -ComputerName $ip -Credential $Cred `
                                  -AcceptKey -ConnectionTimeout $ConnectTimeoutSec `
                                  -ErrorAction Stop -WarningAction SilentlyContinue
        Write-Host " connected" -ForegroundColor Green
        $connectedNode = $n
        break
    } catch {
        Write-Host " unreachable" -ForegroundColor Red
    }
}

if (-not $session) {
    Write-Host ""
    Write-Host "  No cluster node reachable. Aborting." -ForegroundColor Red
    exit 1
}

# --- Query cluster ----------------------------------------------------------
try {
    $result = Invoke-SSHCommand -SessionId $session.SessionId -Command $RemoteCmd -TimeOut 30
    $raw = ($result.Output -join "`n").Trim()
} catch {
    Write-Host ("  pvesh failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Remove-SSHSession -SessionId $session.SessionId | Out-Null
    exit 1
}

Remove-SSHSession -SessionId $session.SessionId | Out-Null

# --- Parse JSON --------------------------------------------------------------
try {
    $all = $raw | ConvertFrom-Json
} catch {
    Write-Host "  Could not parse pvesh JSON output." -ForegroundColor Red
    Write-Host $raw -ForegroundColor DarkGray
    exit 1
}
# Split resources: VMs (qemu non-template), CTs (lxc non-template), nodes (online)
$vms       = @($all | Where-Object { $_.type -eq 'qemu' -and $_.template -ne 1 })
$cts       = @($all | Where-Object { $_.type -eq 'lxc'  -and $_.template -ne 1 })
$nodeList  = @($all | Where-Object { $_.type -eq 'node' -and $_.status -eq 'online' })

if ((-not $vms -or $vms.Count -eq 0) -and (-not $cts -or $cts.Count -eq 0)) {
    Write-Host "  No VMs or CTs returned by cluster." -ForegroundColor Yellow
    exit 0
}

# --- VM table ----------------------------------------------------------------
$sortedVms = $vms | Sort-Object name

Write-Host ""
Write-Host ("  Source node: {0} ({1})" -f $connectedNode.IP, $connectedNode.Label) -ForegroundColor DarkGray
Write-Host ("  Total VMs: {0}    Total CTs: {1}" -f $sortedVms.Count, $cts.Count) -ForegroundColor DarkGray
Write-Host ""
Write-Host "==============================================================" -ForegroundColor White
Write-Host "  VMs (qemu)" -ForegroundColor White
Write-Host "==============================================================" -ForegroundColor White

$fmt = "  {0,-6} {1,-32} {2,-14} {3,-9} {4,8}"
Write-Host ($fmt -f 'VMID', 'NAME', 'NODE', 'STATUS', 'MEM_GB') -ForegroundColor White
Write-Host ("  " + ('-' * 74)) -ForegroundColor DarkGray

foreach ($vm in $sortedVms) {
    $color = switch ($vm.status) {
        'running' { 'Green' }
        'stopped' { 'DarkGray' }
        default   { 'Yellow' }
    }
    $memGB = if ($vm.maxmem) { [Math]::Round([double]$vm.maxmem / 1GB, 1) } else { 0 }
    Write-Host ($fmt -f $vm.vmid, $vm.name, $vm.node, $vm.status, $memGB) -ForegroundColor $color
}

# --- CT table ----------------------------------------------------------------
Write-Host ""
Write-Host "==============================================================" -ForegroundColor White
Write-Host "  CTs (lxc)" -ForegroundColor White
Write-Host "==============================================================" -ForegroundColor White

if (-not $cts -or $cts.Count -eq 0) {
    Write-Host "  (no containers)" -ForegroundColor DarkGray
} else {
    $sortedCts = $cts | Sort-Object name
    Write-Host ($fmt -f 'CTID', 'NAME', 'NODE', 'STATUS', 'MEM_GB') -ForegroundColor White
    Write-Host ("  " + ('-' * 74)) -ForegroundColor DarkGray
    foreach ($ct in $sortedCts) {
        $color = switch ($ct.status) {
            'running' { 'Green' }
            'stopped' { 'DarkGray' }
            default   { 'Yellow' }
        }
        $memGB = if ($ct.maxmem) { [Math]::Round([double]$ct.maxmem / 1GB, 1) } else { 0 }
        Write-Host ($fmt -f $ct.vmid, $ct.name, $ct.node, $ct.status, $memGB) -ForegroundColor $color
    }
}

# --- Per-node memory over-provisioning audit --------------------------------
# Sum maxmem of RUNNING VMs + CTs per node. Stopped guests reserve no live
# RAM, but a separate "ALL_GB" column shows worst-case if everything ran.
$runAlloc = @{}
$allAlloc = @{}
$guests = @($vms) + @($cts)
foreach ($v in $guests) {
    $nm = $v.node
    if (-not $nm) { continue }
    $m = if ($v.maxmem) { [int64]$v.maxmem } else { [int64]0 }
    if (-not $allAlloc.ContainsKey($nm)) { $allAlloc[$nm] = [int64]0 }
    $allAlloc[$nm] += $m
    if ($v.status -eq 'running') {
        if (-not $runAlloc.ContainsKey($nm)) { $runAlloc[$nm] = [int64]0 }
        $runAlloc[$nm] += $m
    }
}

Write-Host ""
Write-Host "==============================================================" -ForegroundColor White
Write-Host "  NODE MEMORY OVER-PROVISIONING (running VMs + CTs)" -ForegroundColor White
Write-Host "==============================================================" -ForegroundColor White
Write-Host ("  Thresholds: red if free <= {0} GB or alloc > total, yellow if free < {1} GB" -f ($CritFreeBytes/1GB), ($WarnFreeBytes/1GB)) -ForegroundColor DarkGray
Write-Host ""

# Header row (plain, only status will be colored per-row)
$headerFmt = "  {0,-12} {1,8} {2,16} {3,8} {4,-26} {5,5}  {6}"
Write-Host ($headerFmt -f 'NODE', 'TOTAL', 'ALLOC_ON/ALL', 'FREE', 'BAR', 'PCT', 'STATUS')
Write-Host ("  " + ('-' * 92)) -ForegroundColor DarkGray

$barW = 24
foreach ($n in $nodeList | Sort-Object node) {
    $name  = $n.node
    $total = if ($n.maxmem) { [int64]$n.maxmem } else { [int64]0 }
    $alloc = if ($runAlloc.ContainsKey($name)) { $runAlloc[$name] } else { [int64]0 }
    $allA  = if ($allAlloc.ContainsKey($name)) { $allAlloc[$name] } else { [int64]0 }
    $free  = $total - $alloc
    $pct   = if ($total -gt 0) { [int](($alloc * 100) / $total) } else { 0 }

    # Bar split: green for running, gray for stopped, dots for the rest.
    # Combined fill capped at barW (100%).
    $runFilled = if ($total -gt 0) { [int](($alloc * $barW) / $total) } else { 0 }
    $allFilled = if ($total -gt 0) { [int](($allA  * $barW) / $total) } else { 0 }
    if ($runFilled -gt $barW) { $runFilled = $barW }
    if ($runFilled -lt 0)     { $runFilled = 0 }
    if ($allFilled -gt $barW) { $allFilled = $barW }
    if ($allFilled -lt $runFilled) { $allFilled = $runFilled }
    $stopFilled = $allFilled - $runFilled
    $dotFilled  = $barW - $allFilled

    if ($alloc -gt $total) {
        $statusText = 'OVER'; $color = 'Red'
    } elseif ($free -le $CritFreeBytes) {
        $statusText = 'CRITICAL'; $color = 'Red'
    } elseif ($free -lt $WarnFreeBytes) {
        $statusText = 'WARN'; $color = 'Yellow'
    } else {
        $statusText = 'OK'; $color = 'Green'
    }

    $totalGB = [Math]::Round([double]$total / 1GB, 0)
    $allocGB = [Math]::Round([double]$alloc / 1GB, 0)
    $freeGB  = [Math]::Round([double]$free  / 1GB, 0)
    $allGB   = [Math]::Round([double]$allA  / 1GB, 0)
    $combo   = "$allocGB/$allGB GB"

    # Row split into segments so only STATUS is colored. Bar uses colored hashes.
    $left = "  {0,-12} {1,8} {2,16} {3,8} " -f $name, "$totalGB GB", $combo, "$freeGB GB"
    Write-Host $left -NoNewline
    Write-Host '[' -NoNewline
    if ($runFilled  -gt 0) { Write-Host ('#' * $runFilled)  -NoNewline -ForegroundColor Green }
    if ($stopFilled -gt 0) { Write-Host ('#' * $stopFilled) -NoNewline -ForegroundColor DarkGray }
    if ($dotFilled  -gt 0) { Write-Host ('.' * $dotFilled)  -NoNewline }
    Write-Host ']' -NoNewline
    Write-Host (" {0,5}  " -f "$pct%") -NoNewline
    Write-Host $statusText -ForegroundColor $color
}

Write-Host ""
Write-Host "  TOTAL = node physical RAM    ALLOC_ON/ALL = running / all (incl. stopped) guest maxmem    FREE = TOTAL - ALLOC_ON" -ForegroundColor DarkGray
Write-Host "  BAR: green = running, gray = stopped (capped 100%)    PCT = ALLOC_ON / TOTAL" -ForegroundColor DarkGray
Write-Host ""
Write-Host ("  Scan complete. {0}" -f (Get-Date)) -ForegroundColor DarkGray
Write-Host ""
