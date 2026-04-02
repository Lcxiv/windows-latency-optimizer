#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Audit check functions for audit.ps1.
.DESCRIPTION
    Dot-sourced by audit.ps1. Contains all check functions and New-CheckResult helper.
    Each check function returns a hashtable matching the check result schema.
    Read-only — no system modifications.
#>

# ---------------------------------------------------------------------------
# Helper: Build a check result hashtable
# ---------------------------------------------------------------------------
function New-CheckResult {
    param(
        [string]$Name,
        [string]$Category,
        [string]$Tier,
        [string]$Severity,
        [string]$Status,
        [string]$Current  = '',
        [string]$Expected = '',
        [string]$Message  = '',
        [string]$Source   = '',
        [string]$Fix      = '',
        [string]$FixNote  = ''
    )
    return [ordered]@{
        name     = $Name
        category = $Category
        tier     = $Tier
        severity = $Severity
        status   = $Status
        current  = $Current
        expected = $Expected
        message  = $Message
        source   = $Source
        fix      = $Fix
        fixNote  = $FixNote
    }
}

# ---------------------------------------------------------------------------
# System information (called once by audit.ps1 before running checks)
# ---------------------------------------------------------------------------
function Get-SystemInfo {
    $info = [ordered]@{
        os        = ''
        build     = ''
        cpu       = ''
        gpu       = ''
        gpuDriver = ''
        ram       = ''
        nic       = ''
        nicDriver = ''
    }

    # OS
    $os = Get-WmiObject Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) {
        $info.os    = $os.Caption + ' Build ' + $os.BuildNumber
        $info.build = $os.BuildNumber
    }

    # CPU
    $cpu = Get-WmiObject Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cpu) { $info.cpu = $cpu.Name.Trim() }

    # GPU
    $gpu = Get-WmiObject Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gpu) {
        $info.gpu       = $gpu.Name
        $info.gpuDriver = $gpu.DriverVersion
    }

    # RAM — total + configured speed
    $dimms = Get-WmiObject Win32_PhysicalMemory -ErrorAction SilentlyContinue
    if ($dimms) {
        $totalMB = ($dimms | Measure-Object -Property Capacity -Sum).Sum / 1MB
        $speed   = ($dimms | Select-Object -First 1).ConfiguredClockSpeed
        $info.ram = [string][math]::Round($totalMB / 1024) + ' GB @ ' + $speed + ' MT/s'
    }

    # NIC
    $nic = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    if ($nic) {
        $info.nic       = $nic.InterfaceDescription
        $info.nicDriver = $nic.DriverVersion
    }

    return $info
}
