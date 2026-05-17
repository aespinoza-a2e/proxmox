# =============================================================================
# Proxmox <-> hosts.txt Interactive Editor (Phase 3)
# Two-source sync tool: cluster VM inventory + Flask CT's hosts.txt.
# Reads both, lets the operator queue add/remove ops, commits via pct push.
# Backup retention: last 3 versions kept inside the CT.
# Requires: Install-Module Posh-SSH -Scope CurrentUser
# =============================================================================

Import-Module Posh-SSH -ErrorAction Stop

# --- Enable VT100 / ANSI processing on Windows console ----------------------
# Required so cursor positioning + color escape codes render instead of printing
# as literal "[31m" gibberish on PS 5.1. Win10 1607+ conhost supports it once
# ENABLE_VIRTUAL_TERMINAL_PROCESSING (0x0004) is set on stdout.
if (-not ('Win32.VT' -as [type])) {
    Add-Type -Namespace Win32 -Name VT -MemberDefinition @'
        [System.Runtime.InteropServices.DllImport("kernel32.dll")]
        public static extern bool GetConsoleMode(System.IntPtr h, out uint m);
        [System.Runtime.InteropServices.DllImport("kernel32.dll")]
        public static extern bool SetConsoleMode(System.IntPtr h, uint m);
        [System.Runtime.InteropServices.DllImport("kernel32.dll")]
        public static extern System.IntPtr GetStdHandle(int n);
'@
}
try {
    $hOut = [Win32.VT]::GetStdHandle(-11)
    $cMode = 0
    [void][Win32.VT]::GetConsoleMode($hOut, [ref]$cMode)
    [void][Win32.VT]::SetConsoleMode($hOut, $cMode -bor 0x0004)
} catch {}

# ANSI escape primitives
$ESC = [char]27
$ANSI = @{
    Home    = "$ESC[H"
    AltOn   = "$ESC[?1049h"
    AltOff  = "$ESC[?1049l"
    HideCur = "$ESC[?25l"
    ShowCur = "$ESC[?25h"
    Reset   = "$ESC[0m"
    ClrScr  = "$ESC[2J"
}
# Map ConsoleColor-style name -> ANSI SGR foreground code
$FG = @{
    White    = "$ESC[97m"
    Gray     = "$ESC[37m"
    DarkGray = "$ESC[90m"
    Red      = "$ESC[91m"
    Green    = "$ESC[92m"
    Yellow   = "$ESC[93m"
    Blue     = "$ESC[94m"
    Magenta  = "$ESC[95m"
    Cyan     = "$ESC[96m"
}

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
$FlaskCtHost       = $Config.FlaskCtHost
$FlaskCtId         = $Config.FlaskCtId
$FlaskHostsPath    = $Config.FlaskHostsPath

# --- Whitelist validation ----------------------------------------------------
function Assert-Config {
    param([string]$Name, $Value, [string]$Pattern)
    if ($null -eq $Value -or "$Value" -eq '') {
        Write-Host "  Config error: '$Name' missing." -ForegroundColor Red; exit 1
    }
    if ("$Value" -notmatch $Pattern) {
        Write-Host ("  Config error: '{0}' value '{1}' fails safety check ({2})." -f $Name, $Value, $Pattern) -ForegroundColor Red
        exit 1
    }
}
Assert-Config -Name 'FlaskCtId'      -Value $FlaskCtId      -Pattern '^[1-9][0-9]{0,8}$'
Assert-Config -Name 'FlaskCtHost'    -Value $FlaskCtHost    -Pattern '^[A-Za-z0-9.\-]{1,253}$'
Assert-Config -Name 'FlaskHostsPath' -Value $FlaskHostsPath -Pattern '^/[A-Za-z0-9_./\-]+$'
Assert-Config -Name 'SshUser'        -Value $SshUser        -Pattern '^[A-Za-z_][A-Za-z0-9_.\-]*$'
$FlaskCtId = [int]$FlaskCtId

$SecurePass = ConvertTo-SecureString $SshPass -AsPlainText -Force
$Cred = New-Object System.Management.Automation.PSCredential ($SshUser, $SecurePass)

# Input validation for user-entered fields
$GroupPattern = '^[A-Za-z0-9 _.\-]{1,40}$'
$NotesPattern = '^[A-Za-z0-9 _./\-]{0,80}$'
# VM name -> FQDN: must be safe to interpolate into hosts.txt
$VmNamePattern = '^[A-Za-z0-9][A-Za-z0-9.\-]{0,62}$'

# --- SSH helpers -------------------------------------------------------------
function Open-Session {
    param([string]$Ip)
    try {
        return New-SSHSession -ComputerName $Ip -Credential $Cred `
                              -AcceptKey -ConnectionTimeout $ConnectTimeoutSec `
                              -ErrorAction Stop -WarningAction SilentlyContinue
    } catch { return $null }
}
function Invoke-Remote {
    param($Session, [string]$Cmd, [int]$Timeout = 30)
    $r = Invoke-SSHCommand -SessionId $Session.SessionId -Command $Cmd -TimeOut $Timeout
    return [pscustomobject]@{
        Output   = ($r.Output -join "`n").Trim()
        Error    = ($r.Error  -join "`n").Trim()
        ExitCode = $r.ExitStatus
    }
}
function Close-Session { param($Session) if ($Session) { Remove-SSHSession -SessionId $Session.SessionId | Out-Null } }

# --- Data fetch --------------------------------------------------------------
function Fetch-ClusterVms {
    foreach ($n in $Nodes) {
        $s = Open-Session -Ip $n.IP
        if (-not $s) { continue }
        try {
            $r = Invoke-Remote -Session $s -Cmd "pvesh get /cluster/resources --type vm --output-format json"
            if ($r.ExitCode -ne 0) { continue }
            $all = $r.Output | ConvertFrom-Json
            # Keep only real qemu VMs: drop LXC containers and templates.
            $vms = @($all | Where-Object { $_.type -eq 'qemu' -and $_.template -ne 1 })
            return [pscustomobject]@{ Vms = $vms; SourceNode = $n }
        } catch {} finally { Close-Session $s }
    }
    return $null
}
function Fetch-HostsTxt {
    $s = Open-Session -Ip $FlaskCtHost
    if (-not $s) { return $null }
    try {
        $r = Invoke-Remote -Session $s -Cmd "pct exec $FlaskCtId -- cat '$FlaskHostsPath'" -Timeout 20
        if ($r.ExitCode -ne 0) { return $null }
        return $r.Output
    } finally { Close-Session $s }
}

# --- Parsers / model ---------------------------------------------------------
function Parse-HostsTxt {
    param([string]$Raw)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in $Raw -split "`n") {
        $t = $line.TrimEnd("`r")
        $trim = $t.Trim()
        if (-not $trim) { continue }
        if ($trim.StartsWith('#')) { continue }
        $parts = $trim -split ',', 3
        $fqdn = $parts[0].Trim()
        $grp  = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
        $note = if ($parts.Count -ge 3) { $parts[2].Trim() } else { '' }
        $bare = $fqdn
        if ($bare.ToLower().EndsWith('.local')) { $bare = $bare.Substring(0, $bare.Length - 6) }
        $rows.Add([pscustomobject]@{
            Fqdn  = $fqdn
            Bare  = $bare.ToLower()
            Group = $grp
            Notes = $note
        })
    }
    return $rows
}

# Build unified row list. Status: '=', '+', '-'
function Build-Rows {
    param($Vms, $HostsRows)

    $vmByName = @{}
    foreach ($v in $Vms) { if ($v.name) { $vmByName[$v.name.ToLower()] = $v } }
    $hostByBare = @{}
    foreach ($h in $HostsRows) { $hostByBare[$h.Bare] = $h }

    $out = New-Object System.Collections.Generic.List[object]

    # synced + orphan (start from hosts.txt)
    foreach ($h in $HostsRows) {
        $stat = if ($vmByName.ContainsKey($h.Bare)) { '=' } else { '-' }
        $out.Add([pscustomobject]@{
            Stat      = $stat
            Bare      = $h.Bare
            Fqdn      = $h.Fqdn
            Group     = $h.Group
            Notes     = $h.Notes
            VmNode    = if ($vmByName.ContainsKey($h.Bare)) { $vmByName[$h.Bare].node } else { '' }
            VmStatus  = if ($vmByName.ContainsKey($h.Bare)) { $vmByName[$h.Bare].status } else { '' }
            Queued    = $false
        })
    }
    # missing-in-hosts (cluster VMs not in hosts.txt)
    foreach ($v in $Vms) {
        if (-not $v.name) { continue }
        $bare = $v.name.ToLower()
        if (-not $hostByBare.ContainsKey($bare)) {
            $out.Add([pscustomobject]@{
                Stat     = '+'
                Bare     = $bare
                Fqdn     = "$($v.name).local"
                Group    = ''
                Notes    = ''
                VmNode   = $v.node
                VmStatus = $v.status
                Queued   = $false
            })
        }
    }

    # Sort: group asc, fqdn asc. Empty group sorts first.
    return $out | Sort-Object @{Expression='Group'}, @{Expression='Fqdn'}
}

# --- Render ------------------------------------------------------------------
function Get-VisibleRows {
    param($Rows, [bool]$MismatchOnly)
    if ($MismatchOnly) { return @($Rows | Where-Object { $_.Stat -ne '=' }) }
    return @($Rows)
}

$script:InAltBuffer = $false
$script:LastW = 0
$script:LastH = 0

function Enter-AltBuffer {
    if ($script:InAltBuffer) { return }
    [Console]::Write($ANSI.AltOn + $ANSI.HideCur + $ANSI.ClrScr + $ANSI.Home)
    $script:InAltBuffer = $true
    $script:LastW = 0; $script:LastH = 0  # force resize-clear path on first frame
}
function Exit-AltBuffer {
    if (-not $script:InAltBuffer) { return }
    [Console]::Write($ANSI.Reset + $ANSI.ShowCur + $ANSI.AltOff)
    $script:InAltBuffer = $false
}

# Append one line into the frame builder, padded to width, colored, terminated
# with CRLF. Single pass, no per-line console flush.
function Add-Line {
    param([System.Text.StringBuilder]$Sb, [string]$Text, [string]$Color, [int]$Width)
    if ($null -eq $Text) { $Text = '' }
    if ($Text.Length -gt $Width) { $Text = $Text.Substring(0, $Width) }
    elseif ($Text.Length -lt $Width) { $Text = $Text + (' ' * ($Width - $Text.Length)) }
    [void]$Sb.Append($FG[$Color])
    [void]$Sb.Append($Text)
    [void]$Sb.Append($ANSI.Reset)
    [void]$Sb.Append("`r`n")
}

function Render-Screen {
    param(
        $Rows, [int]$Cursor, [int]$ScrollTop,
        [bool]$MismatchOnly, [int]$VmCount, [int]$HostsCount,
        $SourceNode, [int]$PendingAdd, [int]$PendingRemove, [int]$PendingEdit, [string]$Status
    )

    $w = [Console]::WindowWidth
    $h = [Console]::WindowHeight
    if ($w -lt 80) { $w = 80 }
    if ($h -lt 20) { $h = 20 }
    $width = $w - 1

    $sb = [System.Text.StringBuilder]::new(8192)
    if ($w -ne $script:LastW -or $h -ne $script:LastH) {
        [void]$sb.Append($ANSI.ClrScr)
        $script:LastW = $w; $script:LastH = $h
    }
    [void]$sb.Append($ANSI.Home)

    Add-Line $sb ('=' * $width) 'White' $width

    $title = "  PROXMOX <-> hosts.txt SYNC"
    $right = "pending: +$PendingAdd / -$PendingRemove / ~$PendingEdit"
    $pad = $width - $title.Length - $right.Length
    if ($pad -lt 1) { $pad = 1 }
    Add-Line $sb ($title + (' ' * $pad) + $right) 'White' $width

    Add-Line $sb ('=' * $width) 'White' $width

    $filterLabel = if ($MismatchOnly) { 'mismatches' } else { 'all' }
    $srcLabel = if ($SourceNode) { "$($SourceNode.IP) ($($SourceNode.Label))" } else { '-' }
    Add-Line $sb ("  Filter: {0,-11}  Cluster: {1} VMs   hosts.txt: {2} rows   src: {3}" -f $filterLabel, $VmCount, $HostsCount, $srcLabel) 'DarkGray' $width
    Add-Line $sb ('-' * $width) 'DarkGray' $width

    $fmt = "  {0,1} {1,-4}  {2,-38} {3,-14} {4}"
    Add-Line $sb ($fmt -f ' ', 'STAT', 'FQDN', 'GROUP', 'NOTES') 'White' $width
    Add-Line $sb ('-' * $width) 'DarkGray' $width

    $reserved = 11
    $rowsAvail = $h - $reserved
    if ($rowsAvail -lt 5) { $rowsAvail = 5 }

    $total = $Rows.Count
    $end = [Math]::Min($ScrollTop + $rowsAvail, $total)

    if ($total -eq 0) {
        Add-Line $sb "  (no rows match filter)" 'DarkGray' $width
        for ($i = 1; $i -lt $rowsAvail; $i++) { Add-Line $sb '' 'Gray' $width }
    } else {
        for ($i = $ScrollTop; $i -lt $end; $i++) {
            $r = $Rows[$i]
            $marker = if ($i -eq $Cursor) { '>' } else { ' ' }
            $stat = "[$($r.Stat)]"
            if ($r.Queued) { $stat = "[$($r.Stat)*]" }
            $grp = if ($r.Group) { $r.Group } else { '-' }
            $note = if ($r.Notes) { $r.Notes } else { '-' }
            $color = switch ($r.Stat) {
                '=' { if ($r.Queued) { 'Cyan' } else { 'Green' } }
                '+' { if ($r.Queued) { 'Cyan' } else { 'Yellow' } }
                '-' { if ($r.Queued) { 'Cyan' } else { 'Magenta' } }
                default { 'Gray' }
            }
            Add-Line $sb ($fmt -f $marker, $stat, $r.Fqdn, $grp, $note) $color $width
        }
        for ($i = $end - $ScrollTop; $i -lt $rowsAvail; $i++) { Add-Line $sb '' 'Gray' $width }
    }

    Add-Line $sb ('-' * $width) 'DarkGray' $width
    $scrollNote = if ($total -gt $rowsAvail) {
        "  showing $($ScrollTop + 1)-$end of $total"
    } else { "  showing $total of $total" }
    Add-Line $sb $scrollNote 'DarkGray' $width
    Add-Line $sb "  up/down move   a add   d remove   u undo   f filter   r refresh   w write   q quit   ? help" 'DarkGray' $width
    $statusLine = if ($Status) { "  $Status" } else { '' }
    $statusColor = if ($Status) { 'Cyan' } else { 'Gray' }
    Add-Line $sb $statusLine $statusColor $width

    # Strip trailing CRLF — last line must not push cursor past last row,
    # otherwise terminal scrolls and top border slips off.
    if ($sb.Length -ge 2) { [void]$sb.Remove($sb.Length - 2, 2) }

    # Single atomic flush — eliminates scanline-by-scanline jitter
    [Console]::Write($sb.ToString())
}

# --- Prompts (drop out of curses mode) --------------------------------------
function Read-Field {
    param([string]$Label, [string]$Pattern, [bool]$AllowEmpty = $false)
    Exit-AltBuffer
    try {
        while ($true) {
            Write-Host ''
            $val = Read-Host $Label
            if ($AllowEmpty -and -not $val) { return '' }
            if ($val -match $Pattern) { return $val.Trim() }
            Write-Host "  invalid (regex: $Pattern). retry or blank to cancel." -ForegroundColor Yellow
            $retry = Read-Host '  retry? [y/N]'
            if ($retry -ne 'y') { return $null }
        }
    } finally {
        Enter-AltBuffer
    }
}
function Confirm-Yes {
    param([string]$Prompt)
    Exit-AltBuffer
    try {
        $a = Read-Host $Prompt
        return ($a -eq 'y' -or $a -eq 'Y' -or $a -eq 'yes')
    } finally {
        Enter-AltBuffer
    }
}

# --- Help overlay ------------------------------------------------------------
function Show-Help {
    Exit-AltBuffer
    Write-Host ""
    Write-Host "  KEYS" -ForegroundColor White
    Write-Host "    up / down       move cursor"
    Write-Host "    pgup / pgdn     scroll page"
    Write-Host "    home / end      jump top / bottom"
    Write-Host "    a   or Enter    add ([+] rows only) -- prompts for group + notes"
    Write-Host "    d   or Del      remove ([-] rows only) -- confirms"
    Write-Host "    e               edit  ([=] rows only) -- prompts new group/notes (blank = keep)"
    Write-Host "    u               undo last queued op"
    Write-Host "    f               toggle filter: mismatches / all"
    Write-Host "    r               refresh from cluster + CT (aborts queue with warn)"
    Write-Host "    w               write queued ops to hosts.txt"
    Write-Host "    q               quit (warns if pending)"
    Write-Host "    ?               this help"
    Write-Host ""
    Write-Host "  LEGEND" -ForegroundColor White
    Write-Host "    [=]   synced    (green)"
    Write-Host "    [+]   in cluster, missing from hosts.txt   (yellow)"
    Write-Host "    [-]   in hosts.txt, no VM                  (magenta)"
    Write-Host "    *     queued op pending commit             (cyan)"
    Write-Host ""
    Write-Host "  WRITE FLOW" -ForegroundColor White
    Write-Host "    1. Re-reads hosts.txt fresh"
    Write-Host "    2. Shows preview diff"
    Write-Host "    3. Asks you to type WRITE exactly"
    Write-Host "    4. Backs up hosts.txt inside CT (timestamped)"
    Write-Host "    5. SCPs new file, pct push, prunes backups to last 3"
    Write-Host ""
    Read-Host "  press Enter to return" | Out-Null
    Enter-AltBuffer
}

# --- Commit ------------------------------------------------------------------
function Build-NewContent {
    param([string]$OriginalRaw, $Queue)

    # Apply ops by FQDN match. Preserve original line order, comments, blanks.
    $removeSet = @{}
    $editMap   = @{}
    $addList   = New-Object System.Collections.Generic.List[string]
    foreach ($op in $Queue) {
        if ($op.Type -eq 'remove') { $removeSet[$op.Fqdn.ToLower()] = $true }
        elseif ($op.Type -eq 'edit') {
            $editMap[$op.Fqdn.ToLower()] = $op
        }
        elseif ($op.Type -eq 'add') {
            $addList.Add(("{0}, {1}, {2}" -f $op.Fqdn, $op.Group, $op.Notes))
        }
    }

    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($line in $OriginalRaw -split "`n") {
        $t = $line.TrimEnd("`r")
        $trim = $t.Trim()
        if (-not $trim -or $trim.StartsWith('#')) {
            $kept.Add($t); continue
        }
        $fqdn = ($trim -split ',', 2)[0].Trim().ToLower()
        if ($removeSet.ContainsKey($fqdn)) { continue }
        if ($editMap.ContainsKey($fqdn)) {
            $op = $editMap[$fqdn]
            $kept.Add(("{0}, {1}, {2}" -f $op.Fqdn, $op.NewGroup, $op.NewNotes))
            continue
        }
        $kept.Add($t)
    }
    foreach ($a in $addList) { $kept.Add($a) }

    return ($kept -join "`n") + "`n"
}

function Commit-Queue {
    param($Queue)
    Exit-AltBuffer
    try {
        return Commit-QueueImpl -Queue $Queue
    } finally {
        Enter-AltBuffer
    }
}
function Commit-QueueImpl {
    param($Queue)
    if ($Queue.Count -eq 0) {
        Write-Host "  Nothing to commit." -ForegroundColor Yellow
        return $false
    }

    Write-Host ""
    Write-Host "  Re-reading hosts.txt..." -ForegroundColor Cyan
    $fresh = Fetch-HostsTxt
    if (-not $fresh) {
        Write-Host "  Could not read current hosts.txt -- aborting." -ForegroundColor Red
        return $false
    }

    $newContent = Build-NewContent -OriginalRaw $fresh -Queue $Queue
    $newLineCount = ($newContent -split "`n" | Where-Object { $_ -ne '' }).Count

    Write-Host ""
    Write-Host "  Pending operations:" -ForegroundColor White
    foreach ($op in $Queue) {
        if ($op.Type -eq 'add') {
            Write-Host ("    + {0}, {1}, {2}" -f $op.Fqdn, $op.Group, $op.Notes) -ForegroundColor Yellow
        } elseif ($op.Type -eq 'edit') {
            Write-Host ("    ~ {0}: ({1}, {2}) -> ({3}, {4})" -f $op.Fqdn, $op.OldGroup, $op.OldNotes, $op.NewGroup, $op.NewNotes) -ForegroundColor Cyan
        } else {
            Write-Host ("    - {0}" -f $op.Fqdn) -ForegroundColor Magenta
        }
    }
    Write-Host ""
    Write-Host ("  New file will have {0} non-empty lines." -f $newLineCount) -ForegroundColor DarkGray
    Write-Host ""
    $confirm = Read-Host "  Type WRITE to commit (anything else aborts)"
    if ($confirm -ne 'WRITE') {
        Write-Host "  Aborted." -ForegroundColor Yellow
        return $false
    }

    # SSH to FRL3248B for backup + push
    $s = Open-Session -Ip $FlaskCtHost
    if (-not $s) {
        Write-Host "  Cannot reach $FlaskCtHost -- aborting." -ForegroundColor Red
        return $false
    }

    try {
        $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backupPath = "$FlaskHostsPath.bak.$ts"

        Write-Host "  Backing up hosts.txt -> $backupPath ..." -ForegroundColor Cyan
        $rcp = Invoke-Remote -Session $s -Cmd "pct exec $FlaskCtId -- cp '$FlaskHostsPath' '$backupPath'"
        if ($rcp.ExitCode -ne 0) {
            Write-Host "  Backup failed: $($rcp.Error)" -ForegroundColor Red
            return $false
        }
        $rcheck = Invoke-Remote -Session $s -Cmd "pct exec $FlaskCtId -- test -s '$backupPath'"
        if ($rcheck.ExitCode -ne 0) {
            Write-Host "  Backup verify failed (empty file)." -ForegroundColor Red
            return $false
        }

        # Write to local temp, SCP up, pct push, cleanup.
        # Set-SCPItem treats -Destination as a REMOTE DIRECTORY and uses the
        # local file's basename. So we point -Destination at /tmp and compute
        # the remote path ourselves from the local filename.
        $tmpName  = "hosts.txt.new.$ts." + [guid]::NewGuid().ToString('N').Substring(0,8)
        $localTmp = Join-Path $env:TEMP $tmpName
        $remoteTmp = "/tmp/$tmpName"
        Set-Content -Path $localTmp -Value $newContent -NoNewline -Encoding UTF8

        Write-Host "  Uploading new file to host..." -ForegroundColor Cyan
        try {
            Set-SCPItem -ComputerName $FlaskCtHost -Credential $Cred `
                        -Path $localTmp -Destination '/tmp' `
                        -AcceptKey -ErrorAction Stop -WarningAction SilentlyContinue
        } catch {
            Write-Host "  SCP failed: $($_.Exception.Message)" -ForegroundColor Red
            Remove-Item $localTmp -Force -ErrorAction SilentlyContinue
            return $false
        }
        Remove-Item $localTmp -Force -ErrorAction SilentlyContinue

        # Validate path of SCPed file matches our pattern
        if ($remoteTmp -notmatch '^/tmp/hosts\.txt\.new\.[A-Za-z0-9.\-]+$') {
            Write-Host "  remote temp path failed safety check -- aborting." -ForegroundColor Red
            return $false
        }

        Write-Host "  pct push -> $FlaskHostsPath ..." -ForegroundColor Cyan
        $rpush = Invoke-Remote -Session $s -Cmd "pct push $FlaskCtId '$remoteTmp' '$FlaskHostsPath'"
        # Always try to clean up the staged file
        Invoke-Remote -Session $s -Cmd "rm -f '$remoteTmp'" | Out-Null

        if ($rpush.ExitCode -ne 0) {
            Write-Host "  pct push failed: $($rpush.Error)" -ForegroundColor Red
            Write-Host "  Backup at $backupPath inside CT $FlaskCtId is intact." -ForegroundColor Yellow
            return $false
        }

        # Prune: keep newest 3 .bak.* files
        Write-Host "  Pruning old backups (keep last 3)..." -ForegroundColor Cyan
        $pruneCmd = "pct exec $FlaskCtId -- sh -c `"ls -1t '$FlaskHostsPath'.bak.* 2>/dev/null | tail -n +4 | xargs -r rm -f`""
        $rprune = Invoke-Remote -Session $s -Cmd $pruneCmd
        if ($rprune.ExitCode -ne 0) {
            Write-Host "  Backup prune warning: $($rprune.Error)" -ForegroundColor Yellow
        }

        Write-Host ""
        Write-Host "  Commit OK. Backup: $backupPath" -ForegroundColor Green
        Read-Host "  press Enter" | Out-Null
        return $true
    } finally {
        Close-Session $s
    }
}

# --- Main loop ---------------------------------------------------------------
function Run-Editor {
    Write-Host ""
    Write-Host "  Loading cluster + hosts.txt..." -ForegroundColor Cyan
    $clusterInfo = Fetch-ClusterVms
    if (-not $clusterInfo) {
        Write-Host "  No cluster node reachable. Aborting." -ForegroundColor Red
        return
    }
    $hostsRaw = Fetch-HostsTxt
    if (-not $hostsRaw) {
        Write-Host "  Could not read hosts.txt. Aborting." -ForegroundColor Red
        return
    }
    $hostsRows = Parse-HostsTxt -Raw $hostsRaw
    $rows = @(Build-Rows -Vms $clusterInfo.Vms -HostsRows $hostsRows)

    $mismatchOnly = $true
    $queue = New-Object System.Collections.Generic.List[object]
    $cursor = 0
    $scrollTop = 0
    $status = ''

    Enter-AltBuffer

    while ($true) {
        $visible = Get-VisibleRows -Rows $rows -MismatchOnly $mismatchOnly
        if ($cursor -ge $visible.Count) { $cursor = [Math]::Max(0, $visible.Count - 1) }
        if ($cursor -lt 0) { $cursor = 0 }

        $h = [Console]::WindowHeight
        if ($h -lt 20) { $h = 20 }
        $rowsAvail = $h - 11
        if ($rowsAvail -lt 5) { $rowsAvail = 5 }
        if ($cursor -lt $scrollTop) { $scrollTop = $cursor }
        if ($cursor -ge $scrollTop + $rowsAvail) { $scrollTop = $cursor - $rowsAvail + 1 }
        if ($scrollTop -lt 0) { $scrollTop = 0 }

        $pendAdd  = @($queue | Where-Object { $_.Type -eq 'add' }).Count
        $pendRem  = @($queue | Where-Object { $_.Type -eq 'remove' }).Count
        $pendEdit = @($queue | Where-Object { $_.Type -eq 'edit' }).Count

        Render-Screen -Rows $visible -Cursor $cursor -ScrollTop $scrollTop `
                      -MismatchOnly $mismatchOnly -VmCount $clusterInfo.Vms.Count `
                      -HostsCount $hostsRows.Count -SourceNode $clusterInfo.SourceNode `
                      -PendingAdd $pendAdd -PendingRemove $pendRem -PendingEdit $pendEdit -Status $status
        $status = ''

        $key = [Console]::ReadKey($true)
        $row = if ($visible.Count -gt 0) { $visible[$cursor] } else { $null }

        switch ($key.Key) {
            'UpArrow'    { if ($cursor -gt 0) { $cursor-- } }
            'DownArrow'  { if ($cursor -lt $visible.Count - 1) { $cursor++ } }
            'PageUp'     { $cursor = [Math]::Max(0, $cursor - $rowsAvail) }
            'PageDown'   { $cursor = [Math]::Min($visible.Count - 1, $cursor + $rowsAvail) }
            'Home'       { $cursor = 0 }
            'End'        { $cursor = [Math]::Max(0, $visible.Count - 1) }

            'F' { $mismatchOnly = -not $mismatchOnly; $cursor = 0; $scrollTop = 0 }

            'R' {
                if ($queue.Count -gt 0) {
                    $status = "Refresh aborted -- $($queue.Count) queued ops pending. Press u to undo or w to commit first."
                } else {
                    $status = 'Reloading...'
                    $clusterInfo = Fetch-ClusterVms
                    $hostsRaw = Fetch-HostsTxt
                    if ($clusterInfo -and $hostsRaw) {
                        $hostsRows = Parse-HostsTxt -Raw $hostsRaw
                        $rows = @(Build-Rows -Vms $clusterInfo.Vms -HostsRows $hostsRows)
                        $status = 'Refreshed.'
                    } else {
                        $status = 'Refresh failed -- keeping old data.'
                    }
                }
            }

            'U' {
                if ($queue.Count -eq 0) { $status = 'Queue empty.'; break }
                $last = $queue[$queue.Count - 1]
                $queue.RemoveAt($queue.Count - 1)
                # Clear Queued flag on the affected row + restore prior display
                foreach ($r in $rows) {
                    if ($r.Fqdn.ToLower() -eq $last.Fqdn.ToLower()) {
                        $r.Queued = $false
                        if ($last.Type -eq 'add')  { $r.Group = ''; $r.Notes = '' }
                        if ($last.Type -eq 'edit') { $r.Group = $last.OldGroup; $r.Notes = $last.OldNotes }
                    }
                }
                $status = "Undone: $($last.Type) $($last.Fqdn)"
            }

            'A' {
                if (-not $row) { $status = 'No row selected.'; break }
                if ($row.Stat -ne '+') { $status = "Add only valid on [+] rows."; break }
                if ($row.Queued)       { $status = "Already queued."; break }

                if ($row.Bare -notmatch $VmNamePattern) { $status = "VM name failed safety check."; break }

                $grp = Read-Field -Label "  Group for $($row.Fqdn)" -Pattern $GroupPattern -AllowEmpty $false
                if (-not $grp) { $status = 'Add cancelled.'; break }
                $note = Read-Field -Label "  Notes for $($row.Fqdn) (blank = empty)" -Pattern $NotesPattern -AllowEmpty $true
                if ($null -eq $note) { $status = 'Add cancelled.'; break }

                $queue.Add([pscustomobject]@{ Type='add'; Fqdn=$row.Fqdn; Group=$grp; Notes=$note })
                $row.Queued = $true
                $row.Group  = $grp
                $row.Notes  = $note
                $status = "Queued add: $($row.Fqdn)"
            }

            'D' {
                if (-not $row) { $status = 'No row selected.'; break }
                if ($row.Stat -ne '-') { $status = "Remove only valid on [-] rows."; break }
                if ($row.Queued)       { $status = "Already queued."; break }
                Write-Host ""
                if (Confirm-Yes "  Remove $($row.Fqdn) from hosts.txt? [y/N]") {
                    $queue.Add([pscustomobject]@{ Type='remove'; Fqdn=$row.Fqdn })
                    $row.Queued = $true
                    $status = "Queued remove: $($row.Fqdn)"
                } else {
                    $status = 'Remove cancelled.'
                }
            }
            'Delete' {
                if (-not $row) { $status = 'No row selected.'; break }
                if ($row.Stat -ne '-') { $status = "Remove only valid on [-] rows."; break }
                if ($row.Queued)       { $status = "Already queued."; break }
                Write-Host ""
                if (Confirm-Yes "  Remove $($row.Fqdn) from hosts.txt? [y/N]") {
                    $queue.Add([pscustomobject]@{ Type='remove'; Fqdn=$row.Fqdn })
                    $row.Queued = $true
                    $status = "Queued remove: $($row.Fqdn)"
                } else {
                    $status = 'Remove cancelled.'
                }
            }

            'E' {
                if (-not $row) { $status = 'No row selected.'; break }
                if ($row.Stat -ne '=') { $status = "Edit only valid on [=] rows."; break }
                if ($row.Queued)       { $status = "Already queued."; break }

                $oldGroup = $row.Group
                $oldNotes = $row.Notes

                $newGrp = Read-Field -Label "  Group for $($row.Fqdn) (current: $oldGroup, blank = keep)" -Pattern $GroupPattern -AllowEmpty $true
                if ($null -eq $newGrp) { $status = 'Edit cancelled.'; break }
                $newNote = Read-Field -Label "  Notes for $($row.Fqdn) (current: $oldNotes, blank = keep)" -Pattern $NotesPattern -AllowEmpty $true
                if ($null -eq $newNote) { $status = 'Edit cancelled.'; break }

                $finalGrp  = if ($newGrp)  { $newGrp }  else { $oldGroup }
                $finalNote = if ($newNote) { $newNote } else { $oldNotes }

                if ($finalGrp -eq $oldGroup -and $finalNote -eq $oldNotes) {
                    $status = 'No change.'; break
                }

                $queue.Add([pscustomobject]@{
                    Type='edit'; Fqdn=$row.Fqdn;
                    OldGroup=$oldGroup; OldNotes=$oldNotes;
                    NewGroup=$finalGrp; NewNotes=$finalNote
                })
                $row.Queued = $true
                $row.Group  = $finalGrp
                $row.Notes  = $finalNote
                $status = "Queued edit: $($row.Fqdn)"
            }

            'Enter' {
                if ($row -and $row.Stat -eq '+' -and -not $row.Queued) {
                    if ($row.Bare -notmatch $VmNamePattern) { $status = "VM name failed safety check."; break }
                    $grp = Read-Field -Label "  Group for $($row.Fqdn)" -Pattern $GroupPattern -AllowEmpty $false
                    if (-not $grp) { $status = 'Add cancelled.'; break }
                    $note = Read-Field -Label "  Notes for $($row.Fqdn) (blank = empty)" -Pattern $NotesPattern -AllowEmpty $true
                    if ($null -eq $note) { $status = 'Add cancelled.'; break }
                    $queue.Add([pscustomobject]@{ Type='add'; Fqdn=$row.Fqdn; Group=$grp; Notes=$note })
                    $row.Queued = $true
                    $row.Group  = $grp
                    $row.Notes  = $note
                    $status = "Queued add: $($row.Fqdn)"
                }
            }

            'W' {
                if (Commit-Queue -Queue $queue) {
                    # Reload after successful commit
                    $clusterInfo = Fetch-ClusterVms
                    $hostsRaw = Fetch-HostsTxt
                    if ($clusterInfo -and $hostsRaw) {
                        $hostsRows = Parse-HostsTxt -Raw $hostsRaw
                        $rows = @(Build-Rows -Vms $clusterInfo.Vms -HostsRows $hostsRows)
                    }
                    $queue.Clear()
                    $status = 'Committed.'
                }
            }

            'Q' {
                if ($queue.Count -gt 0) {
                    Write-Host ""
                    if (-not (Confirm-Yes "  $($queue.Count) queued ops will be discarded. Quit anyway? [y/N]")) {
                        $status = 'Quit cancelled.'
                        continue
                    }
                }
                return
            }

            default {
                if ($key.KeyChar -eq '?') { Show-Help }
            }
        }
    }
}

try {
    Run-Editor
} finally {
    Exit-AltBuffer
    try { [Console]::ResetColor() } catch {}
}
Write-Host ""
Write-Host "  Bye." -ForegroundColor DarkGray
