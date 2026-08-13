[CmdletBinding()]
param(
    [ValidateSet('Machine', 'User')]
    [string]$Scope = 'Machine',

    [switch]$DisableMetrics = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Bootstraps and registers vcpkg-related environment variables.
.DESCRIPTION
    Ensures vcpkg.exe exists, then sets VCPKG_ROOT, VCPKG_DEFAULT_TRIPLET,
    CMAKE_TOOLCHAIN_FILE and convenient PATH entries at Machine or User scope.
    Machine scope requires an elevated PowerShell session.
.NOTES
    Re-running is safe. Existing values are overwritten; PATH entries are not duplicated.
#>

$RepoRoot        = Split-Path -Parent $PSCommandPath
$VcpkgRoot       = $RepoRoot
$DefaultTriplet  = 'x64-windows'
$ToolchainFile   = Join-Path $VcpkgRoot 'scripts\buildsystems\vcpkg.cmake'
$BootstrapScript = Join-Path $VcpkgRoot 'bootstrap-vcpkg.bat'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TargetScope([string]$RequestedScope) {
    switch ($RequestedScope) {
        'Machine' { return [System.EnvironmentVariableTarget]::Machine }
        'User' { return [System.EnvironmentVariableTarget]::User }
        default { throw "Unsupported scope: $RequestedScope" }
    }
}

function Get-VisualStudioNinjaDir {
    $programFilesX86 = ${env:ProgramFiles(x86)}
    if ([string]::IsNullOrWhiteSpace($programFilesX86)) {
        return $null
    }

    $vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) {
        return $null
    }

    $installationPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($installationPath)) {
        return $null
    }

    $installationPath = $installationPath.Trim()
    $ninjaDir = Join-Path $installationPath 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja'
    if (Test-Path (Join-Path $ninjaDir 'ninja.exe')) {
        return $ninjaDir
    }

    return $null
}

function Get-VcpkgAcquiredToolDir {
    param(
        [string]$ExecutableName,
        [string]$ToolName
    )

    $toolsRoot = Join-Path $RepoRoot 'downloads\tools'
    if (-not (Test-Path $toolsRoot)) {
        return $null
    }

    $toolPath = Get-ChildItem -LiteralPath $toolsRoot -Directory -Filter "$ToolName-*" -ErrorAction SilentlyContinue |
        ForEach-Object {
            Get-ChildItem -LiteralPath $_.FullName -Recurse -Filter $ExecutableName -File -ErrorAction SilentlyContinue
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -ne $toolPath) {
        return $toolPath.DirectoryName
    }

    return $null
}

function Get-ProgramFilesCMakeDir {
    $cmakeDir = Join-Path $env:ProgramFiles 'CMake\bin'
    if (Test-Path (Join-Path $cmakeDir 'cmake.exe')) {
        return $cmakeDir
    }

    return $null
}

function Get-CMakeDir {
    $cmakeDir = Get-ProgramFilesCMakeDir
    if ($null -ne $cmakeDir) {
        return $cmakeDir
    }

    return Get-VcpkgAcquiredToolDir -ExecutableName 'cmake.exe' -ToolName 'cmake'
}

function Get-NinjaDir {
    $ninjaDir = Get-VisualStudioNinjaDir
    if ($null -ne $ninjaDir) {
        return $ninjaDir
    }

    return Get-VcpkgAcquiredToolDir -ExecutableName 'ninja.exe' -ToolName 'ninja'
}

function Set-ScopedVariable {
    param(
        [string]$Name,
        [string]$Value,
        [System.EnvironmentVariableTarget]$TargetScope
    )

    $current = [Environment]::GetEnvironmentVariable($Name, $TargetScope)
    if ($current -eq $Value) {
        Write-Host "  [skip] $Name already set correctly for $TargetScope" -ForegroundColor DarkGray
    } else {
        [Environment]::SetEnvironmentVariable($Name, $Value, $TargetScope)
        Write-Host "  [set]  $Name = $Value ($TargetScope)" -ForegroundColor Green
    }

    [Environment]::SetEnvironmentVariable($Name, $Value, [System.EnvironmentVariableTarget]::Process)
}

function Add-PathEntry {
    param(
        [string]$Entry,
        [System.EnvironmentVariableTarget]$TargetScope
    )

    if ([string]::IsNullOrWhiteSpace($Entry)) {
        return
    }

    $rawPath = [Environment]::GetEnvironmentVariable('Path', $TargetScope)
    $entries = @()
    if (-not [string]::IsNullOrWhiteSpace($rawPath)) {
        $entries = $rawPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }

    $remainingEntries = $entries | Where-Object { $_ -ne $Entry }
    $newEntries = @($Entry) + @($remainingEntries)
    $newPath = $newEntries -join ';'

    if ($rawPath -eq $newPath) {
        Write-Host "  [skip] PATH already prioritizes $Entry for $TargetScope" -ForegroundColor DarkGray
    } else {
        [Environment]::SetEnvironmentVariable('Path', $newPath, $TargetScope)
        Write-Host "  [set]  Prioritized $Entry in PATH ($TargetScope)" -ForegroundColor Green
    }

    $processEntries = @()
    if (-not [string]::IsNullOrWhiteSpace($env:Path)) {
        $processEntries = $env:Path -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }

    $processEntries = $processEntries | Where-Object { $_ -ne $Entry }
    $env:Path = ((@($Entry) + @($processEntries)) -join ';')
}

function Send-EnvironmentChangeNotification {
    if (-not ('Win32.NativeMethods' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;

namespace Win32
{
    public static class NativeMethods
    {
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd,
            int Msg,
            IntPtr wParam,
            string lParam,
            int fuFlags,
            int uTimeout,
            out IntPtr lpdwResult);
    }
}
'@
    }

    $hwndBroadcast = [IntPtr]0xffff
    $wmSettingChange = 0x001A
    $abortIfHung = 0x0002
    $result = [IntPtr]::Zero
    [void][Win32.NativeMethods]::SendMessageTimeout(
        $hwndBroadcast,
        $wmSettingChange,
        [IntPtr]::Zero,
        'Environment',
        $abortIfHung,
        5000,
        [ref]$result
    )
}

if ($Scope -eq 'Machine' -and -not (Test-IsAdministrator)) {
    throw "Machine scope requires an elevated PowerShell session. Re-run with -Scope User or launch PowerShell as Administrator."
}

if (-not (Test-Path $ToolchainFile)) {
    throw "Toolchain file not found at $ToolchainFile - aborting."
}

if (-not (Test-Path "$VcpkgRoot\vcpkg.exe")) {
    if (-not (Test-Path $BootstrapScript)) {
        throw "bootstrap-vcpkg.bat not found at $BootstrapScript - aborting."
    }

    Write-Host "Bootstrapping vcpkg.exe..." -ForegroundColor Cyan
    $bootstrapArgs = @()
    if ($DisableMetrics) {
        $bootstrapArgs += '-disableMetrics'
    }

    & $BootstrapScript @bootstrapArgs
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$VcpkgRoot\vcpkg.exe")) {
        throw "Bootstrapping vcpkg.exe failed."
    }
}

$targetScope = Get-TargetScope -RequestedScope $Scope
$vars = @{
    VCPKG_ROOT            = $VcpkgRoot
    VCPKG_DEFAULT_TRIPLET = $DefaultTriplet
    CMAKE_TOOLCHAIN_FILE  = $ToolchainFile
}

foreach ($kv in $vars.GetEnumerator()) {
    Set-ScopedVariable -Name $kv.Key -Value $kv.Value -TargetScope $targetScope
}

Add-PathEntry -Entry $VcpkgRoot -TargetScope $targetScope

$cmakeDir = Get-CMakeDir
if ($null -ne $cmakeDir) {
    Add-PathEntry -Entry $cmakeDir -TargetScope $targetScope
} else {
    Write-Warning 'CMake was not found in Program Files or vcpkg-acquired tools. Install CMake or ensure a compatible cmake.exe is on PATH.'
}

$ninjaDir = Get-NinjaDir
if ($null -ne $ninjaDir) {
    Add-PathEntry -Entry $ninjaDir -TargetScope $targetScope
} else {
    Write-Warning 'Ninja was not found in Visual Studio or vcpkg-acquired tools. CMake configure steps that use -G Ninja may need to locate Ninja explicitly.'
}

Send-EnvironmentChangeNotification
Write-Host "`nDone. Open a new shell to pick up the persisted changes." -ForegroundColor Cyan
