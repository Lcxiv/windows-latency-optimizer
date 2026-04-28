# helpers/chrome.ps1
# Chrome-specific diagnostic functions: process tree, cache stats, launch timing, Defender audit.
# PowerShell 5.1 compatible.

$script:ChromePath = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$script:ChromeUserData = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'

function Get-ChromeProcessTree {
    <#
    .SYNOPSIS
        Enumerate Chrome processes with type classification.
    .OUTPUTS
        Array of hashtables: pid, type, wsMb, cpuSec, threads, handles, commandLine
    #>
    $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return @() }

    $results = @()
    foreach ($p in $procs) {
        $type = 'unknown'
        $cmd = $p.CommandLine
        if ($null -eq $cmd) { $cmd = '' }

        if ($cmd -match '--type=gpu-process') { $type = 'gpu' }
        elseif ($cmd -match '--type=renderer') { $type = 'renderer' }
        elseif ($cmd -match '--type=utility.*network') { $type = 'network-service' }
        elseif ($cmd -match '--type=utility') { $type = 'utility' }
        elseif ($cmd -match '--type=crashpad') { $type = 'crashpad' }
        elseif ($cmd -notmatch '--type=') { $type = 'browser' }

        $ws = 0
        if ($null -ne $p.WorkingSetSize) { $ws = [math]::Round($p.WorkingSetSize / 1MB, 1) }

        $results += @{
            pid         = $p.ProcessId
            type        = $type
            wsMb        = $ws
            threads     = $p.ThreadCount
            handles     = $p.HandleCount
            createTime  = $p.CreationDate
            commandLine = $cmd.Substring(0, [math]::Min(200, $cmd.Length))
        }
    }
    return @($results | Sort-Object { $_.createTime })
}

function Get-ChromeCacheStats {
    <#
    .SYNOPSIS
        Measure Chrome cache directory sizes and file counts.
    .OUTPUTS
        Hashtable with per-cache: sizeMb, fileCount, oldestWrite, newestWrite
    #>
    $caches = @{
        ShaderCache       = Join-Path $script:ChromeUserData 'ShaderCache'
        GPUCache          = Join-Path $script:ChromeUserData 'Default\GPUCache'
        DawnGraphiteCache = Join-Path $script:ChromeUserData 'Default\DawnGraphiteCache'
        DawnWebGPUCache   = Join-Path $script:ChromeUserData 'Default\DawnWebGPUCache'
        CodeCache         = Join-Path $script:ChromeUserData 'Default\Code Cache'
        HttpCache         = Join-Path $script:ChromeUserData 'Default\Cache'
    }

    $result = @{}
    foreach ($name in $caches.Keys) {
        $path = $caches[$name]
        if (Test-Path $path) {
            $files = @(Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue)
            $measure = $files | Measure-Object -Property Length -Sum
            $sorted = @($files | Sort-Object LastWriteTime)
            $oldest = $null
            $newest = $null
            if ($sorted.Count -gt 0) {
                $oldest = $sorted[0].LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                $newest = $sorted[$sorted.Count - 1].LastWriteTime.ToString('yyyy-MM-dd HH:mm')
            }
            $result[$name] = @{
                sizeMb      = [math]::Round($measure.Sum / 1MB, 2)
                fileCount   = $measure.Count
                oldestWrite = $oldest
                newestWrite = $newest
            }
        } else {
            $result[$name] = @{ sizeMb = 0; fileCount = 0; oldestWrite = $null; newestWrite = $null }
        }
    }
    return $result
}

function Test-DefenderChromeExclusions {
    <#
    .SYNOPSIS
        Check if Chrome paths and process are in Defender exclusion list.
    .OUTPUTS
        Hashtable with excluded/notExcluded arrays and chromeExeExcluded bool.
    #>
    $mp = Get-MpPreference -ErrorAction SilentlyContinue
    if ($null -eq $mp) {
        return @{ error = 'Get-MpPreference failed'; excluded = @(); notExcluded = @(); chromeExeExcluded = $false }
    }

    $chromePaths = @(
        $script:ChromeUserData,
        (Join-Path $script:ChromeUserData 'Default\GPUCache'),
        (Join-Path $script:ChromeUserData 'ShaderCache'),
        (Join-Path $script:ChromeUserData 'Default\Code Cache'),
        (Join-Path $script:ChromeUserData 'Default\Cache'),
        'C:\Program Files\Google\Chrome\Application'
    )

    $excluded = @()
    $notExcluded = @()
    $exPaths = @()
    if ($null -ne $mp.ExclusionPath) { $exPaths = @($mp.ExclusionPath) }

    foreach ($p in $chromePaths) {
        $found = $false
        foreach ($ex in $exPaths) {
            if ($p -eq $ex -or $p.StartsWith($ex + '\')) { $found = $true; break }
        }
        if ($found) { $excluded += $p } else { $notExcluded += $p }
    }

    $exProcs = @()
    if ($null -ne $mp.ExclusionProcess) { $exProcs = @($mp.ExclusionProcess) }
    $chromeExeExcluded = $exProcs -contains 'chrome.exe'

    return @{
        excluded          = $excluded
        notExcluded       = $notExcluded
        chromeExeExcluded = $chromeExeExcluded
        totalExclPaths    = $exPaths.Count
        totalExclProcs    = $exProcs.Count
    }
}

function Measure-ChromeLaunch {
    <#
    .SYNOPSIS
        Launch Chrome and measure time to GPU process creation.
    .PARAMETER Url
        URL to open (default: about:blank).
    .PARAMETER ExtraArgs
        Additional Chrome arguments.
    .OUTPUTS
        Hashtable: launchTimeMs, gpuReadyMs, processCount, totalWsMb, processTree
    #>
    param(
        [string]$Url = 'about:blank',
        [string[]]$ExtraArgs = @()
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $args = @($Url) + $ExtraArgs
    Start-Process $script:ChromePath -ArgumentList $args

    $gpuReadyMs = $null
    $maxWaitMs = 20000
    while ($sw.ElapsedMilliseconds -lt $maxWaitMs) {
        $gpuProc = Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match '--type=gpu-process' }
        if ($null -ne $gpuProc) {
            $gpuReadyMs = $sw.ElapsedMilliseconds
            break
        }
        Start-Sleep -Milliseconds 200
    }
    $sw.Stop()

    Start-Sleep -Seconds 2
    $tree = Get-ChromeProcessTree
    $totalWs = 0
    foreach ($p in $tree) { $totalWs += $p.wsMb }

    return @{
        launchTimeMs = $sw.ElapsedMilliseconds
        gpuReadyMs   = $gpuReadyMs
        processCount = $tree.Count
        totalWsMb    = [math]::Round($totalWs, 1)
        processTree  = $tree
    }
}

function Invoke-DnsTimingCapture {
    <#
    .SYNOPSIS
        Measure DNS resolution time for Chrome-relevant domains.
    .OUTPUTS
        Hashtable with per-domain stats.
    #>
    param(
        [string[]]$Domains = @(
            'www.twitch.tv',
            'static.twitchcdn.net',
            'www.youtube.com',
            'i.ytimg.com',
            'fonts.googleapis.com'
        ),
        [int]$Samples = 5
    )

    $result = @{}
    foreach ($domain in $Domains) {
        ipconfig /flushdns 2>&1 | Out-Null
        $times = @()
        for ($i = 0; $i -lt $Samples; $i++) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try { [System.Net.Dns]::GetHostAddresses($domain) | Out-Null } catch {}
            $sw.Stop()
            $times += $sw.ElapsedMilliseconds
        }
        $result[$domain] = Get-Stats $times
    }
    return $result
}

function Invoke-TlsTimingCapture {
    <#
    .SYNOPSIS
        Measure TCP + TLS handshake times for Chrome-relevant hosts.
    .OUTPUTS
        Hashtable with per-host: tcpMs, tlsTotalMs, tlsHandshakeMs, protocol
    #>
    param(
        [string[]]$Hosts = @('www.twitch.tv', 'www.youtube.com')
    )

    $result = @{}
    foreach ($host_ in $Hosts) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect($host_, 443)
            $tcpMs = $sw.ElapsedMilliseconds

            $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream())
            $ssl.AuthenticateAsClient($host_)
            $sw.Stop()

            $result[$host_] = @{
                tcpMs          = $tcpMs
                tlsTotalMs     = $sw.ElapsedMilliseconds
                tlsHandshakeMs = $sw.ElapsedMilliseconds - $tcpMs
                protocol       = $ssl.SslProtocol.ToString()
            }
            $ssl.Dispose()
            $tcp.Dispose()
        } catch {
            $sw.Stop()
            $result[$host_] = @{
                tcpMs          = $null
                tlsTotalMs     = $null
                tlsHandshakeMs = $null
                protocol       = $null
                error          = $_.Exception.Message
            }
        }
    }
    return $result
}

function Get-DwmCompositorState {
    <#
    .SYNOPSIS
        Check DWM, MPO, and HAGS registry state.
    .OUTPUTS
        Hashtable with mpoEnabled, hagsMode, dwmSettings
    #>
    $mpo = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' -Name 'OverlayTestMode' -ErrorAction SilentlyContinue
    $mpoEnabled = $true
    if ($null -ne $mpo -and $mpo.OverlayTestMode -eq 5) { $mpoEnabled = $false }

    $hags = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -ErrorAction SilentlyContinue
    $hagsMode = $null
    if ($null -ne $hags) { $hagsMode = $hags.HwSchMode }

    $dwm = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' -ErrorAction SilentlyContinue
    $dwmSettings = @{}
    if ($null -ne $dwm) {
        foreach ($prop in @('ForceEffectMode', 'EnableAeroPeek', 'AlwaysHibernateThumbnails', 'Composition')) {
            $val = $dwm.$prop
            if ($null -ne $val) { $dwmSettings[$prop] = $val }
        }
    }

    return @{
        mpoEnabled  = $mpoEnabled
        hagsMode    = $hagsMode
        dwmSettings = $dwmSettings
    }
}
