# config.ps1
# Central configuration for the windows-latency-optimizer toolkit.
# Dot-source this in any script that needs tool paths, defaults, or project paths:
#   . "$PSScriptRoot\config.ps1"
#
# PowerShell 5.1 compatible — no ternary, no null-coalescing.

# ─── Project Paths ────────────────────────────────────────────────────────────
$script:ProjectRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:CaptureRoot   = Join-Path $script:ProjectRoot 'captures'
$script:ExperimentsDir = Join-Path $script:CaptureRoot 'experiments'
$script:ArchiveDir     = Join-Path $script:CaptureRoot 'archive'
$script:DashboardDir   = Join-Path $script:ProjectRoot 'dashboard'
$script:DashboardData  = Join-Path $script:DashboardDir 'data'
$script:ScriptsDir     = $PSScriptRoot

# ─── Tool Discovery ──────────────────────────────────────────────────────────

function Find-Tool {
    <#
    .SYNOPSIS
        Locate an executable by checking PATH, then common install directories.
    .PARAMETER Name
        Executable name (e.g., 'Procmon64.exe').
    .PARAMETER SearchPaths
        Additional directories to check beyond PATH.
    .OUTPUTS
        [string] Full path to the executable, or $null if not found.
    #>
    param(
        [string]$Name,
        [string[]]$SearchPaths = @()
    )

    # 1. Check PATH
    $found = Get-Command $Name -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }

    # 2. Check provided search paths
    foreach ($dir in $SearchPaths) {
        $candidate = Join-Path $dir $Name
        if (Test-Path $candidate) { return $candidate }
    }

    return $null
}

$script:ToolPaths = @{
    ProcMon = Find-Tool 'Procmon64.exe' @(
        (Join-Path $env:USERPROFILE 'Desktop\ProcessMonitor'),
        'C:\Tools',
        'C:\SysinternalsSuite',
        (Join-Path $env:USERPROFILE 'Downloads\ProcessMonitor')
    )
    WPR = Find-Tool 'wpr.exe'
    Xperf = Find-Tool 'xperf.exe' @(
        'C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit',
        'C:\Program Files\Windows Kits\10\Windows Performance Toolkit'
    )
    PresentMon = Find-Tool 'PresentMon.exe' @(
        (Join-Path $env:USERPROFILE 'Desktop'),
        'C:\Tools',
        (Join-Path $env:USERPROFILE 'Downloads')
    )
}

# ─── Performance Counter List ────────────────────────────────────────────────
$script:PerfCounters = @(
    '\Processor(*)\% Interrupt Time',
    '\Processor(*)\% DPC Time',
    '\Processor(*)\Interrupts/sec',
    '\Processor(_Total)\% Processor Time',
    '\Processor(_Total)\% DPC Time',
    '\Processor(_Total)\% Interrupt Time',
    '\Memory\Available MBytes',
    '\Memory\Pages/sec',
    '\Memory\Page Faults/sec',
    '\PhysicalDisk(_Total)\Avg. Disk sec/Read',
    '\PhysicalDisk(_Total)\Avg. Disk sec/Write',
    '\PhysicalDisk(_Total)\Current Disk Queue Length',
    '\System\Context Switches/sec',
    '\System\Processor Queue Length'
)

# ─── Counter Name Normalization Map ──────────────────────────────────────────
# Maps lowercased raw counter key substrings to dashboard field names.
# Used by generate_dashboard_data.ps1 to normalize run_experiment.ps1 output.
$script:CounterNameMap = [ordered]@{
    '% processor time[_total]'  = 'ProcessorTimePct'
    '% dpc time[_total]'        = 'DPCTimePct'
    '% interrupt time[_total]'  = 'InterruptTimePct'
    'available mbytes'          = 'AvailableMemoryMB'
    'pages/sec'                 = 'PagesSec'
    'page faults/sec'           = 'PageFaultsSec'
    'avg. disk sec/read'        = 'DiskSecRead'
    'avg. disk sec/write'       = 'DiskSecWrite'
    'current disk queue length' = 'DiskQueueLength'
    'context switches/sec'      = 'ContextSwitchesSec'
    'processor queue length'    = 'ProcessorQueueLength'
}

# ─── Known Game Processes ────────────────────────────────────────────────────
$script:KnownGameProcesses = @(
    'FortniteClient-Win64-Shipping',
    'cs2',
    'VALORANT-Win64-Shipping',
    'VALORANT',
    'r5apex',
    'OverwatchOW',
    'Overwatch',
    'PUBG-Win64-Shipping',
    'RocketLeague',
    'KovaaK',
    'FPSAimTrainer',
    'destiny2',
    'cod',
    'Warzone',
    'GTA5',
    'eldenring'
)

# ─── Network Ping Targets ───────────────────────────────────────────────────
$script:PingTargets = @(
    'google.com',
    '1.1.1.1',
    '8.8.8.8',
    'cloudflare.com',
    'nae1-prod-livefn.ol.epicgames.com',
    'nae1-gs-livefn.ol.epicgames.com',
    'ping-nae.ds.on.epicgames.com',
    'dynamodb.us-east-1.amazonaws.com'
)

# ─── CPU Topology (auto-discovered) ──────────────────────────────────────────
. "$PSScriptRoot\topology.ps1"

# ─── GPU Vendor Detection ────────────────────────────────────────────────────
. "$PSScriptRoot\gpu-vendor.ps1"

# ─── Interrupt Affinity Device Checks (DEPRECATED - use Get-CpuTopology) ─────
# Kept for backwards compatibility; will be removed in a future version.
$script:AffinityDeviceChecks = @(
    @{ Name = 'GPU';      Pattern = 'VEN_10DE' },
    @{ Name = 'NIC';      Pattern = 'VEN_8086&DEV_125C' },
    @{ Name = 'USB_15B6'; Pattern = 'VEN_1022&DEV_15B6' },
    @{ Name = 'USB_15B7'; Pattern = 'VEN_1022&DEV_15B7' },
    @{ Name = 'USB_43F7'; Pattern = 'VEN_1022&DEV_43F7' },
    @{ Name = 'USB_15B8'; Pattern = 'VEN_1022&DEV_15B8' }
)
