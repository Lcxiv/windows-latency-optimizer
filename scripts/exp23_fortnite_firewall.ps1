#Requires -RunAsAdministrator
<#
.SYNOPSIS
    EXP23: Fortnite & Epic Games Firewall Optimization

.DESCRIPTION
    Creates Windows Firewall inbound/outbound allow rules for Fortnite and
    Epic Games services. Ensures game traffic is never blocked or delayed by
    Windows Filtering Platform (WFP) inspection.

    Port list compiled from:
    - Epic Games official support: "How to unblock ports" (epicgames.com/help)
    - Epic Online Services developer docs: "Firewall Considerations"
    - Palo Alto Networks App-ID case study (Wireshark-based analysis)
    - Community Wireshark captures: UDP 9011 game traffic stream
    - Netduma/portforward.com port forwarding guides

    ## Port Map (what each port does)

    | Port(s)       | Protocol | Service                                    |
    |---------------|----------|--------------------------------------------|
    | 80            | TCP      | HTTP — launcher updates, CDN fallback       |
    | 443           | TCP      | HTTPS — auth, matchmaking, API, CDN         |
    | 3478-3479     | TCP+UDP  | STUN/TURN — NAT traversal for P2P/voice    |
    | 5060          | TCP+UDP  | SIP — voice chat signaling                  |
    | 5062          | TCP+UDP  | SIP-TLS — encrypted voice chat signaling    |
    | 5222          | TCP      | XMPP — party chat, friend presence          |
    | 5795-5847     | UDP      | EOS P2P relay range (Epic Online Services)  |
    | 6250          | TCP+UDP  | Epic matchmaking / lobby coordination       |
    | 9011          | UDP      | Fortnite game server (Wireshark confirmed)  |
    | 12000-65000   | TCP+UDP  | Game server dynamic range (Epic official)   |

    ## What this script does

    1. Detects Epic/Fortnite executable paths on disk
    2. Creates port-based allow rules (inbound + outbound) for all protocols
    3. Creates program-based allow rules for each executable found
    4. Adds EasyAntiCheat executables
    5. Removes duplicate/stale Epic rules created by Windows auto-prompt
    6. Verifies all rules active

.PARAMETER Remove
    Remove all rules created by this script.

.PARAMETER Audit
    Show what would be created without making changes.

.PARAMETER FortniteDir
    Override Fortnite install directory (for non-default installs).

.EXAMPLE
    .\exp23_fortnite_firewall.ps1           # Create all rules
    .\exp23_fortnite_firewall.ps1 -Audit    # Preview only
    .\exp23_fortnite_firewall.ps1 -Remove   # Remove all rules

.NOTES
    Related: [[burst-pattern-analysis]], EXP22 network optimization
    Sources:
      - https://www.epicgames.com/help/c-202300000001639/c-202300000001735/how-to-unblock-ports-to-connect-to-the-epic-games-launcher-and-fortnite-a202300000017735
      - https://dev.epicgames.com/docs/epic-online-services/eos-get-started/firewall-considerations
      - https://knowledgebase.paloaltonetworks.com/KCSArticleDetail?id=kA10g000000ClVKCA0
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [switch]$Audit,
    [string]$FortniteDir = ''
)

$ErrorActionPreference = 'Stop'
$rulePrefix = 'LatencyGuard_'
$groupName = 'LatencyGuard Fortnite'

Write-Host ''
Write-Host '======================================================' -ForegroundColor Cyan
Write-Host '  EXP23: Fortnite & Epic Games Firewall Rules'         -ForegroundColor Cyan
Write-Host '======================================================' -ForegroundColor Cyan
if ($Audit) { Write-Host '  MODE: AUDIT (no changes)' -ForegroundColor Yellow }
Write-Host ''

# ════════════════════════════════════════════════════════════════════════════
# REMOVE MODE
# ════════════════════════════════════════════════════════════════════════════
if ($Remove) {
    Write-Host 'Removing all LatencyGuard firewall rules...' -ForegroundColor Yellow
    $existing = @(Get-NetFirewallRule -DisplayName ($rulePrefix + '*') -ErrorAction SilentlyContinue)
    if ($existing.Count -eq 0) {
        Write-Host '  No LatencyGuard rules found.' -ForegroundColor Gray
    } else {
        foreach ($r in $existing) {
            Remove-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue
        }
        Write-Host ('  Removed ' + $existing.Count + ' rules.') -ForegroundColor Green
    }
    Write-Host 'Done.' -ForegroundColor Cyan
    exit 0
}

# ════════════════════════════════════════════════════════════════════════════
# PORT DEFINITIONS
# ════════════════════════════════════════════════════════════════════════════

# TCP-only ports
$tcpPorts = @(
    @{ Port = '80';    Desc = 'HTTP launcher/CDN' },
    @{ Port = '443';   Desc = 'HTTPS auth/matchmaking/API' },
    @{ Port = '5222';  Desc = 'XMPP party chat/presence' }
)

# UDP-only ports
$udpPorts = @(
    @{ Port = '9011';      Desc = 'Fortnite game server (Wireshark confirmed)' },
    @{ Port = '5795-5847'; Desc = 'EOS P2P relay range' }
)

# Both TCP+UDP ports
$dualPorts = @(
    @{ Port = '3478-3479'; Desc = 'STUN/TURN NAT traversal' },
    @{ Port = '5060';      Desc = 'SIP voice signaling' },
    @{ Port = '5062';      Desc = 'SIP-TLS voice signaling' },
    @{ Port = '6250';      Desc = 'Epic matchmaking/lobby' },
    @{ Port = '12000-65000'; Desc = 'Game server dynamic range' }
)

# ════════════════════════════════════════════════════════════════════════════
# DISCOVER EXECUTABLES
# ════════════════════════════════════════════════════════════════════════════
Write-Host '--- Discovering executables ---' -ForegroundColor Yellow

$exePaths = @()

# Epic Games Launcher
$launcherPaths = @(
    'C:\Program Files\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe',
    'C:\Program Files\Epic Games\Launcher\Engine\Binaries\Win64\EpicGamesLauncher.exe',
    'C:\Program Files (x86)\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe'
)
foreach ($lp in $launcherPaths) {
    if (Test-Path $lp) { $exePaths += $lp }
}

# Fortnite executables — auto-discover from Epic manifests + common paths
$fnSearchDirs = @(
    'C:\Program Files\Epic Games\Fortnite',
    'D:\Epic Games\Fortnite',
    'E:\Epic Games\Fortnite',
    'D:\Fortnite',
    'E:\Fortnite',
    'F:\Fortnite'
)

# Read Epic manifests for actual install locations
$manifestPath = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
if (Test-Path $manifestPath) {
    Get-ChildItem $manifestPath -Filter '*.item' -ErrorAction SilentlyContinue | ForEach-Object {
        $json = Get-Content $_.FullName -Raw | ConvertFrom-Json
        if ($json.InstallLocation -and (Test-Path $json.InstallLocation)) {
            $fnSearchDirs += $json.InstallLocation
        }
    }
}

if ($FortniteDir -ne '') { $fnSearchDirs = @($FortniteDir) }
$fnSearchDirs = @($fnSearchDirs | Select-Object -Unique)

$fnExeNames = @(
    'FortniteClient-Win64-Shipping.exe',
    'FortniteClient-Win64-Shipping_BE.exe',
    'FortniteClient-Win64-Shipping_EAC.exe',
    'FortniteLauncher.exe',
    'FortniteClient-Win64-Shipping_EAC_EOS.exe'
)

foreach ($dir in $fnSearchDirs) {
    if (Test-Path $dir) {
        foreach ($name in $fnExeNames) {
            $found = Get-ChildItem $dir -Recurse -Filter $name -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $exePaths += $found.FullName }
        }
    }
}

# EasyAntiCheat
$eacPaths = @(
    'C:\Program Files (x86)\EasyAntiCheat\EasyAntiCheat.exe',
    'C:\Program Files\Epic Games\Fortnite\FortniteGame\Binaries\Win64\EasyAntiCheat\EasyAntiCheat.exe'
)
foreach ($ep in $eacPaths) {
    if (Test-Path $ep) { $exePaths += $ep }
}
# EAC service executable
$eacSvc = Get-CimInstance Win32_Service -Filter 'Name like "EasyAntiCheat%"' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($eacSvc -and $eacSvc.PathName) {
    $eacExe = $eacSvc.PathName -replace '"', ''
    if (Test-Path $eacExe) { $exePaths += $eacExe }
}

# EOS Overlay
$eosOverlayPaths = @(
    'C:\Program Files\Epic Games\Launcher\Portal\Extras\Overlay\EOSOverlayRenderer-Win64-Shipping.exe',
    'C:\Program Files (x86)\Epic Games\Epic Online Services\managedArtifacts\*\EOSOverlayRenderer-Win64-Shipping.exe'
)
foreach ($eosp in $eosOverlayPaths) {
    $found = Get-Item $eosp -ErrorAction SilentlyContinue
    if ($found) {
        foreach ($f in $found) { $exePaths += $f.FullName }
    }
}

# Deduplicate
$exePaths = @($exePaths | Select-Object -Unique)

Write-Host ('  Found ' + $exePaths.Count + ' executables:') -ForegroundColor White
foreach ($e in $exePaths) {
    $exists = if (Test-Path $e) { 'OK' } else { 'MISSING' }
    $color = if ($exists -eq 'OK') { 'Green' } else { 'Yellow' }
    Write-Host ('    [' + $exists + '] ' + $e) -ForegroundColor $color
}
if ($exePaths.Count -eq 0) {
    Write-Host '    (none found — Fortnite may not be installed yet)' -ForegroundColor Yellow
    Write-Host '    Port rules will still be created.' -ForegroundColor Gray
}
Write-Host ''

# ════════════════════════════════════════════════════════════════════════════
# CLEAN OLD AUTO-GENERATED RULES
# ════════════════════════════════════════════════════════════════════════════
Write-Host '--- Cleaning stale auto-generated rules ---' -ForegroundColor Yellow

$staleRules = @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object {
    $_.DisplayName -match 'EpicGamesLauncher' -and $_.DisplayName -notmatch $rulePrefix
})
if ($staleRules.Count -gt 0) {
    if ($Audit) {
        Write-Host ('  Would remove ' + $staleRules.Count + ' auto-generated EpicGamesLauncher rules') -ForegroundColor Yellow
    } else {
        foreach ($sr in $staleRules) {
            Remove-NetFirewallRule -Name $sr.Name -ErrorAction SilentlyContinue
        }
        Write-Host ('  Removed ' + $staleRules.Count + ' auto-generated EpicGamesLauncher rules') -ForegroundColor Cyan
    }
} else {
    Write-Host '  No stale rules found.' -ForegroundColor Gray
}
Write-Host ''

# ════════════════════════════════════════════════════════════════════════════
# CREATE RULES
# ════════════════════════════════════════════════════════════════════════════

$created = 0
$skipped = 0

function New-FwRule {
    param(
        [string]$Name,
        [string]$DisplayName,
        [string]$Direction,
        [string]$Protocol,
        [string]$LocalPort,
        [string]$Program,
        [string]$Description
    )

    $fullName = $rulePrefix + $Name

    # Check if already exists
    $existing = Get-NetFirewallRule -Name $fullName -ErrorAction SilentlyContinue
    if ($existing) {
        $script:skipped++
        return
    }

    if ($Audit) {
        Write-Host ('  [TODO] ' + $DisplayName + ' (' + $Direction + ' ' + $Protocol + ' ' + $LocalPort + ')') -ForegroundColor Yellow
        $script:created++
        return
    }

    $params = @{
        Name        = $fullName
        DisplayName = $rulePrefix + $DisplayName
        Direction   = $Direction
        Action      = 'Allow'
        Enabled     = 'True'
        Profile     = 'Any'
        Group       = $groupName
        Description = $Description
    }

    if ($Protocol -ne '') { $params['Protocol'] = $Protocol }
    if ($LocalPort -ne '') { $params['LocalPort'] = $LocalPort }
    if ($Program -ne '') { $params['Program'] = $Program }

    try {
        New-NetFirewallRule @params | Out-Null
        $script:created++
    } catch {
        Write-Host ('  [FAIL] ' + $DisplayName + ': ' + $_.Exception.Message) -ForegroundColor Red
    }
}

Write-Host '--- Creating port-based rules ---' -ForegroundColor Yellow

# TCP-only ports
foreach ($p in $tcpPorts) {
    foreach ($dir in @('Inbound', 'Outbound')) {
        $dirShort = if ($dir -eq 'Inbound') { 'In' } else { 'Out' }
        New-FwRule `
            -Name ('Fortnite_TCP_' + ($p.Port -replace '-', '_') + '_' + $dirShort) `
            -DisplayName ('Fortnite TCP ' + $p.Port + ' ' + $dirShort) `
            -Direction $dir `
            -Protocol 'TCP' `
            -LocalPort $p.Port `
            -Program '' `
            -Description ($p.Desc + ' - Epic Games official port list')
    }
}

# UDP-only ports
foreach ($p in $udpPorts) {
    foreach ($dir in @('Inbound', 'Outbound')) {
        $dirShort = if ($dir -eq 'Inbound') { 'In' } else { 'Out' }
        New-FwRule `
            -Name ('Fortnite_UDP_' + ($p.Port -replace '-', '_') + '_' + $dirShort) `
            -DisplayName ('Fortnite UDP ' + $p.Port + ' ' + $dirShort) `
            -Direction $dir `
            -Protocol 'UDP' `
            -LocalPort $p.Port `
            -Program '' `
            -Description ($p.Desc + ' - Epic Games official port list')
    }
}

# Dual TCP+UDP ports
foreach ($p in $dualPorts) {
    foreach ($proto in @('TCP', 'UDP')) {
        foreach ($dir in @('Inbound', 'Outbound')) {
            $dirShort = if ($dir -eq 'Inbound') { 'In' } else { 'Out' }
            New-FwRule `
                -Name ('Fortnite_' + $proto + '_' + ($p.Port -replace '-', '_') + '_' + $dirShort) `
                -DisplayName ('Fortnite ' + $proto + ' ' + $p.Port + ' ' + $dirShort) `
                -Direction $dir `
                -Protocol $proto `
                -LocalPort $p.Port `
                -Program '' `
                -Description ($p.Desc + ' - Epic Games official port list')
        }
    }
}

Write-Host ''
Write-Host '--- Creating program-based rules ---' -ForegroundColor Yellow

foreach ($exe in $exePaths) {
    if (-not (Test-Path $exe)) { continue }
    $exeName = [System.IO.Path]::GetFileNameWithoutExtension($exe)
    foreach ($dir in @('Inbound', 'Outbound')) {
        $dirShort = if ($dir -eq 'Inbound') { 'In' } else { 'Out' }
        New-FwRule `
            -Name ('Program_' + ($exeName -replace '[^a-zA-Z0-9]', '_') + '_' + $dirShort) `
            -DisplayName ($exeName + ' ' + $dirShort) `
            -Direction $dir `
            -Protocol '' `
            -LocalPort '' `
            -Program $exe `
            -Description ('Allow all traffic for ' + $exeName)
    }
}

Write-Host ''

# ════════════════════════════════════════════════════════════════════════════
# VERIFY
# ════════════════════════════════════════════════════════════════════════════
Write-Host '--- Verification ---' -ForegroundColor Yellow

$allRules = @(Get-NetFirewallRule -DisplayName ($rulePrefix + '*') -ErrorAction SilentlyContinue)
$enabledCount = @($allRules | Where-Object { $_.Enabled -eq 'True' }).Count

Write-Host ('  Total LatencyGuard rules: ' + $allRules.Count) -ForegroundColor White
Write-Host ('  Enabled: ' + $enabledCount) -ForegroundColor Green
Write-Host ('  Created this run: ' + $created) -ForegroundColor Cyan
Write-Host ('  Skipped (existed): ' + $skipped) -ForegroundColor Gray
Write-Host ''

# Show summary table
if ($allRules.Count -gt 0 -and -not $Audit) {
    Write-Host '  Rule Summary:' -ForegroundColor White
    $portRules = @($allRules | Where-Object { $_.DisplayName -match 'TCP|UDP' })
    $progRules = @($allRules | Where-Object { $_.DisplayName -notmatch 'TCP|UDP' })
    Write-Host ('    Port rules:    ' + $portRules.Count + ' (TCP+UDP inbound/outbound)') -ForegroundColor Gray
    Write-Host ('    Program rules: ' + $progRules.Count + ' (executable allow-all)') -ForegroundColor Gray
}

# ════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ════════════════════════════════════════════════════════════════════════════
Write-Host ''
Write-Host '======================================================' -ForegroundColor Cyan
Write-Host '  SUMMARY'                                              -ForegroundColor Cyan
Write-Host '======================================================' -ForegroundColor Cyan
Write-Host ''

if ($Audit) {
    Write-Host '  AUDIT MODE — no changes made.' -ForegroundColor Yellow
} else {
    Write-Host '  Firewall rules created for Fortnite + Epic Games.' -ForegroundColor Green
}

Write-Host ''
Write-Host '  Port coverage:' -ForegroundColor White
Write-Host '    TCP 80         HTTP (launcher updates, CDN)' -ForegroundColor Gray
Write-Host '    TCP 443        HTTPS (auth, matchmaking, API)' -ForegroundColor Gray
Write-Host '    TCP+UDP 3478-9 STUN/TURN (NAT traversal, voice)' -ForegroundColor Gray
Write-Host '    TCP+UDP 5060   SIP (voice chat signaling)' -ForegroundColor Gray
Write-Host '    TCP+UDP 5062   SIP-TLS (encrypted voice)' -ForegroundColor Gray
Write-Host '    TCP 5222       XMPP (party chat, friend status)' -ForegroundColor Gray
Write-Host '    UDP 5795-5847  EOS P2P relay' -ForegroundColor Gray
Write-Host '    TCP+UDP 6250   Epic matchmaking/lobby' -ForegroundColor Gray
Write-Host '    UDP 9011       Fortnite game server (Wireshark)' -ForegroundColor Gray
Write-Host '    TCP+UDP 12K-65K Game server dynamic range' -ForegroundColor Gray
Write-Host ''
Write-Host '  Executables covered:' -ForegroundColor White
foreach ($e in $exePaths) {
    Write-Host ('    ' + [System.IO.Path]::GetFileName($e)) -ForegroundColor Gray
}
if ($exePaths.Count -eq 0) {
    Write-Host '    (none yet — install Fortnite, then re-run)' -ForegroundColor Yellow
}
Write-Host ''
Write-Host '  Remove all rules: .\exp23_fortnite_firewall.ps1 -Remove' -ForegroundColor DarkGray
Write-Host ''
