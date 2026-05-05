# helpers/wmi-cache.ps1
# Session-scoped WMI query cache. Eliminates redundant slow WMI calls.
# PowerShell 5.1 compatible.

$script:WmiCache = @{}

function Get-CachedWmi {
    param([string]$Class, [switch]$Force)
    if ($Force -or -not $script:WmiCache.ContainsKey($Class)) {
        $script:WmiCache[$Class] = @(Get-WmiObject -Class $Class -ErrorAction SilentlyContinue)
    }
    return $script:WmiCache[$Class]
}

function Get-CachedPnPEntity {
    param([switch]$Force)
    return Get-CachedWmi -Class 'Win32_PnPEntity' -Force:$Force
}

function Get-CachedVideoController {
    param([switch]$Force)
    return Get-CachedWmi -Class 'Win32_VideoController' -Force:$Force
}

function Get-CachedPnPSignedDriver {
    param([switch]$Force)
    return Get-CachedWmi -Class 'Win32_PnPSignedDriver' -Force:$Force
}

function Get-CachedProcessor {
    param([switch]$Force)
    return Get-CachedWmi -Class 'Win32_Processor' -Force:$Force
}

function Get-CachedOperatingSystem {
    param([switch]$Force)
    return Get-CachedWmi -Class 'Win32_OperatingSystem' -Force:$Force
}

function Clear-WmiCache {
    $script:WmiCache = @{}
}
