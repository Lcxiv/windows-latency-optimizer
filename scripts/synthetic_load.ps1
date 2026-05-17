<#
.SYNOPSIS
    Synthetic CPU+disk load driver for baseline capture under stress.
.DESCRIPTION
    Start/Stop modes. Primary path: Prime95 SmallFFT torture test for CPU+cache
    pressure. Fallback: PowerShell jobs with cache-pressure-aware allocation
    pattern if Prime95 fails to spawn or isn't available.

    Disk burn: bounded 512 MB working set with random 4K seek/read/write loop.
    No fragmentation spiral — fixed file size, in-place I/O.

    Writes synthetic_load_config.json describing what ran (mode, PID, thread
    count, disk burn path) so the baseline capture can include it in the
    manifest.
.EXAMPLE
    .\synthetic_load.ps1 -Start -OutputConfigPath 30_loaded\synthetic_load_config.json
.EXAMPLE
    .\synthetic_load.ps1 -Start -UseFallback -OutputConfigPath config.json
.EXAMPLE
    .\synthetic_load.ps1 -Stop
#>
param(
    [Parameter(ParameterSetName='Start', Mandatory=$true)]
    [switch]$Start,

    [Parameter(ParameterSetName='Stop', Mandatory=$true)]
    [switch]$Stop,

    [Parameter(ParameterSetName='Start')]
    [string]$OutputConfigPath = '',

    [Parameter(ParameterSetName='Start')]
    [switch]$UseFallback,

    [Parameter(ParameterSetName='Start')]
    [string]$Prime95Exe = '',

    [Parameter(ParameterSetName='Start')]
    [string]$DiskBurnPath = 'C:\temp\burn',

    [Parameter(ParameterSetName='Start')]
    [ValidateRange(64, 8192)]
    [int]$DiskBurnSizeMB = 512
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$stateFile = Join-Path $projectRoot 'captures\.synthetic_load_state.json'

function Find-Prime95Exe {
    param([string]$Hint)

    if ($Hint -ne '' -and (Test-Path $Hint)) { return $Hint }

    $tryPaths = @(
        (Join-Path $projectRoot 'p95v3019b20.win64\prime95.exe'),
        'C:\Program Files\prime95\prime95.exe',
        'C:\prime95\prime95.exe'
    )
    foreach ($p in $tryPaths) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Write-Prime95Config {
    param([string]$Prime95Dir)

    # Config for unattended SmallFFT torture test.
    # V24OptionsConverted=1 + StressTester=1 + UsePrimenet=0 = bypass GUI prompts.
    # MinTortureFFT=4, MaxTortureFFT=32 = SmallFFT range (L1/L2/L3/V-Cache pressure).
    # TortureTime=1 = 1 minute per FFT (rotates through range).
    $primeTxt = Join-Path $Prime95Dir 'prime.txt'
    $localTxt = Join-Path $Prime95Dir 'local.txt'

    $primeContent = @(
        'V24OptionsConverted=1',
        'StressTester=1',
        'UsePrimenet=0',
        'MinTortureFFT=4',
        'MaxTortureFFT=32',
        'TortureMem=0',
        'TortureTime=1'
    ) -join "`r`n"

    # local.txt needs OutputIterations to avoid chatty stdout.
    $localContent = @(
        'OutputIterations=99999999',
        'ResultsFileTimestamp=1'
    ) -join "`r`n"

    Set-Content -Path $primeTxt -Value $primeContent -Encoding ASCII
    Set-Content -Path $localTxt -Value $localContent -Encoding ASCII
}

function Start-Prime95Burn {
    param([string]$ExePath)

    $exeDir = Split-Path $ExePath -Parent
    Write-Prime95Config -Prime95Dir $exeDir

    # -t = torture test mode. Hidden window so it doesn't steal focus.
    $proc = Start-Process -FilePath $ExePath -ArgumentList '-t' -WorkingDirectory $exeDir `
        -WindowStyle Hidden -PassThru

    # Give it 2s to confirm it stays alive.
    Start-Sleep -Seconds 2
    $alive = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
    if (-not $alive) {
        return $null
    }

    return @{
        mode = 'prime95'
        pid = $proc.Id
        exe = $ExePath
        threads = (Get-WmiObject Win32_ComputerSystem).NumberOfLogicalProcessors
        fft_range = '4-32 (SmallFFT)'
    }
}

function Start-FallbackBurn {
    # PS cache-pressure-aware CPU burn. 16 jobs (one per logical CPU on 9800X3D).
    # Each allocates 96 MB array and does cache-line-walk multiplication.
    $cores = (Get-WmiObject Win32_ComputerSystem).NumberOfLogicalProcessors
    $jobs = @()
    for ($i = 0; $i -lt $cores; $i++) {
        $job = Start-Job -ScriptBlock {
            # 96 MB double array = 12M elements. Exceeds L3 (typically 32-96 MB on 9800X3D),
            # forcing evictions. Multiply-in-place touches every cache line.
            $n = 12000000
            $arr = New-Object 'System.Double[]' $n
            for ($k = 0; $k -lt $n; $k++) { $arr[$k] = [Math]::PI * ($k + 1) }
            while ($true) {
                for ($k = 0; $k -lt $n; $k++) { $arr[$k] = $arr[$k] * 1.0000001 }
            }
        }
        $jobs += $job
    }
    return @{
        mode = 'ps-fallback'
        pid = $null
        exe = $null
        threads = $cores
        job_ids = @($jobs | ForEach-Object { $_.Id })
    }
}

function Start-DiskBurn {
    param(
        [string]$Path,
        [int]$SizeMB
    )

    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    $burnFile = Join-Path $Path 'burn_fixed.bin'

    # Create fixed-size file once. 512 MB default. No fragmentation spiral.
    if (-not (Test-Path $burnFile) -or (Get-Item $burnFile).Length -ne ($SizeMB * 1MB)) {
        $bytes = New-Object 'byte[]' ($SizeMB * 1MB)
        [IO.File]::WriteAllBytes($burnFile, $bytes)
    }

    # Background job: seek/read/write random 4K blocks inside the file.
    $job = Start-Job -ScriptBlock {
        param($FilePath)
        $fs = [IO.File]::Open($FilePath, 'Open', 'ReadWrite')
        try {
            $buf = New-Object 'byte[]' 4096
            $rng = New-Object System.Random
            while ($true) {
                $pos = [int64]($rng.Next(0, [int]($fs.Length / 4096)) * 4096)
                $fs.Seek($pos, 'Begin') | Out-Null
                [void]$fs.Read($buf, 0, 4096)
                $fs.Seek($pos, 'Begin') | Out-Null
                $fs.Write($buf, 0, 4096)
            }
        }
        finally {
            $fs.Close()
        }
    } -ArgumentList $burnFile

    return @{
        job_id = $job.Id
        path = $burnFile
        size_mb = $SizeMB
    }
}

function Stop-AllBurn {
    if (-not (Test-Path $stateFile)) {
        Write-Output 'No synthetic load state file found. Nothing to stop.'
        return
    }

    $state = Get-Content $stateFile -Raw | ConvertFrom-Json

    # Stop CPU burn
    if ($state.cpu.mode -eq 'prime95' -and $state.cpu.pid) {
        $proc = Get-Process -Id $state.cpu.pid -ErrorAction SilentlyContinue
        if ($proc) { Stop-Process -Id $state.cpu.pid -Force -ErrorAction SilentlyContinue }
        # Also sweep any stray prime95 processes
        Get-Process -Name 'prime95' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    elseif ($state.cpu.mode -eq 'ps-fallback' -and $state.cpu.job_ids) {
        foreach ($jid in $state.cpu.job_ids) {
            Stop-Job -Id $jid -ErrorAction SilentlyContinue
            Remove-Job -Id $jid -Force -ErrorAction SilentlyContinue
        }
    }

    # Stop disk burn
    if ($state.disk.job_id) {
        Stop-Job -Id $state.disk.job_id -ErrorAction SilentlyContinue
        Remove-Job -Id $state.disk.job_id -Force -ErrorAction SilentlyContinue
    }
    if ($state.disk.path -and (Test-Path $state.disk.path)) {
        Remove-Item -Path $state.disk.path -Force -ErrorAction SilentlyContinue
        $parentDir = Split-Path $state.disk.path -Parent
        if ((Test-Path $parentDir) -and (Get-ChildItem $parentDir -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item -Path $parentDir -Force -ErrorAction SilentlyContinue
        }
    }

    Remove-Item -Path $stateFile -Force -ErrorAction SilentlyContinue
    Write-Output 'Synthetic load stopped. All jobs killed + burn file cleaned.'
}

# ── Main dispatch ────────────────────────────────────────────────────────────

if ($Stop) {
    Stop-AllBurn
    exit 0
}

if ($Start) {
    # Ensure state dir exists
    $stateDir = Split-Path $stateFile -Parent
    if (-not (Test-Path $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }

    $cpuConfig = $null
    if (-not $UseFallback) {
        $exe = Find-Prime95Exe -Hint $Prime95Exe
        if ($exe) {
            $cpuConfig = Start-Prime95Burn -ExePath $exe
        }
    }
    if (-not $cpuConfig) {
        Write-Output 'Prime95 unavailable or failed to spawn. Using PS fallback burn.'
        $cpuConfig = Start-FallbackBurn
    }

    $diskConfig = Start-DiskBurn -Path $DiskBurnPath -SizeMB $DiskBurnSizeMB

    $fullConfig = @{
        cpu = $cpuConfig
        disk = $diskConfig
        started_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    }

    # Write state file for Stop to consume
    $fullConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $stateFile -Encoding UTF8

    # Write caller-specified config path if provided
    if ($OutputConfigPath -ne '') {
        $outDir = Split-Path $OutputConfigPath -Parent
        if ($outDir -and -not (Test-Path $outDir)) {
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        }
        $fullConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputConfigPath -Encoding UTF8
    }

    Write-Output ('Synthetic load started. CPU mode: ' + $cpuConfig.mode + ' | Disk: ' + $diskConfig.path + ' (' + $diskConfig.size_mb + ' MB)')
    exit 0
}
