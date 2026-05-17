# =============================================================================
# Proxmox Node Memory Leak Scanner (PowerShell + Posh-SSH)
# Checks corosync and pvestatd RSS memory across all cluster nodes via SSH.
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
$CorosyncWarnMB    = $Config.CorosyncWarnMB
$PvestatdWarnMB    = $Config.PvestatdWarnMB

# Build PSCredential once
$SecurePass = ConvertTo-SecureString $SshPass -AsPlainText -Force
$Cred = New-Object System.Management.Automation.PSCredential ($SshUser, $SecurePass)

# Remote command — single line so it ships safely as one SSH exec
$RemoteCmd = @'
CORO_KB=$(ps -C corosync -o rss= 2>/dev/null | awk '{s+=$1} END{print s+0}'); PVES_KB=$(ps -C pvestatd -o rss= 2>/dev/null | awk '{s+=$1} END{print s+0}'); TOTAL_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo); FREE_KB=$(awk '/MemAvailable/{print $2}' /proc/meminfo); HN=$(hostname); UP=$(uptime -p 2>/dev/null || uptime); echo "$HN|$CORO_KB|$PVES_KB|$TOTAL_KB|$FREE_KB|$UP"
'@

# --- Header ------------------------------------------------------------------
Write-Host ""
Write-Host "==============================================================" -ForegroundColor White
Write-Host "  PROXMOX CLUSTER - corosync / pvestatd Memory Scanner" -ForegroundColor White
Write-Host "==============================================================" -ForegroundColor White
Write-Host ("  Warn threshold: corosync > {0} MB | pvestatd > {1} MB" -f $CorosyncWarnMB, $PvestatdWarnMB) -ForegroundColor DarkGray
Write-Host ("  SSH user: {0}" -f $SshUser) -ForegroundColor DarkGray
Write-Host ""

$NeedsRestart = New-Object System.Collections.Generic.List[string]

foreach ($n in $Nodes) {
    $ip = $n.IP
    Write-Host ("  Scanning {0,-16} ..." -f $ip) -NoNewline -ForegroundColor Cyan

    $session = $null
    try {
        # AcceptKey auto-trusts the host key on first connect
        $session = New-SSHSession -ComputerName $ip -Credential $Cred `
                                  -AcceptKey -ConnectionTimeout $ConnectTimeoutSec `
                                  -ErrorAction Stop -WarningAction SilentlyContinue
    } catch {
        Write-Host " UNREACHABLE" -ForegroundColor Red
        Write-Host ("    {0}" -f $_.Exception.Message) -ForegroundColor DarkGray
        continue
    }

    try {
        $result = Invoke-SSHCommand -SessionId $session.SessionId -Command $RemoteCmd -TimeOut 15
        $raw = ($result.Output -join "`n").Trim()
    } catch {
        Write-Host " EXEC FAILED" -ForegroundColor Red
        Write-Host ("    {0}" -f $_.Exception.Message) -ForegroundColor DarkGray
        Remove-SSHSession -SessionId $session.SessionId | Out-Null
        continue
    }

    Remove-SSHSession -SessionId $session.SessionId | Out-Null

    $parts = $raw -split '\|'
    if ($parts.Count -lt 6) {
        Write-Host " BAD RESPONSE" -ForegroundColor Red
        Write-Host ("    raw: {0}" -f $raw) -ForegroundColor DarkGray
        continue
    }

    $hname    = $parts[0]
    $coroMB   = [int]([int64]$parts[1] / 1024)
    $pvesMB   = [int]([int64]$parts[2] / 1024)
    $totalMB  = [int]([int64]$parts[3] / 1024)
    $freeMB   = [int]([int64]$parts[4] / 1024)
    $uptime   = $parts[5]
    $usedMB   = $totalMB - $freeMB
    $memPct   = if ($totalMB -gt 0) { [int]($usedMB * 100 / $totalMB) } else { 0 }

    Write-Host (" {0}" -f $hname) -ForegroundColor White

    # Memory bar
    $barWidth = 24
    $filled = [int]($usedMB * $barWidth / [Math]::Max($totalMB,1))
    if ($filled -gt $barWidth) { $filled = $barWidth }
    $bar = '[' + ('#' * $filled) + ('.' * ($barWidth - $filled)) + ']'
    Write-Host ("    {0,-12} {1} {2}% used ({3} / {4} MB)" -f 'Total RAM:', $bar, $memPct, $usedMB, $totalMB)

    # corosync
    $coroStatus = if ($coroMB -gt $CorosyncWarnMB) { @{ Text = 'RESTART NEEDED'; Color = 'Red' } } else { @{ Text = 'OK'; Color = 'Green' } }
    Write-Host ("    {0,-12} {1,6} MB  " -f 'corosync:', $coroMB) -NoNewline
    Write-Host $coroStatus.Text -ForegroundColor $coroStatus.Color

    # pvestatd
    $pvesStatus = if ($pvesMB -gt $PvestatdWarnMB) { @{ Text = 'RESTART NEEDED'; Color = 'Red' } } else { @{ Text = 'OK'; Color = 'Green' } }
    Write-Host ("    {0,-12} {1,6} MB  " -f 'pvestatd:', $pvesMB) -NoNewline
    Write-Host $pvesStatus.Text -ForegroundColor $pvesStatus.Color

    Write-Host ("    Uptime: {0}" -f $uptime) -ForegroundColor DarkGray
    Write-Host ""

    $needs = @()
    if ($coroMB -gt $CorosyncWarnMB) { $needs += 'corosync' }
    if ($pvesMB -gt $PvestatdWarnMB) { $needs += 'pvestatd' }
    if ($needs.Count -gt 0) {
        $NeedsRestart.Add(("{0} ({1}): {2}" -f $ip, $hname, ($needs -join ' ')))
    }
}

# --- Summary -----------------------------------------------------------------
Write-Host "------------------------------------------------------------------" -ForegroundColor White
Write-Host "  SUMMARY" -ForegroundColor White
Write-Host "------------------------------------------------------------------" -ForegroundColor White

if ($NeedsRestart.Count -eq 0) {
    Write-Host "  All nodes are within normal memory limits." -ForegroundColor Green
} else {
    Write-Host "  The following nodes need service restarts:" -ForegroundColor Red
    Write-Host ""
    foreach ($entry in $NeedsRestart) {
        Write-Host ("    -> {0}" -f $entry) -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host ("  Scan complete. {0}" -f (Get-Date)) -ForegroundColor DarkGray
Write-Host ""
