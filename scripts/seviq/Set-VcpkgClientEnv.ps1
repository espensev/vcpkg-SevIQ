<#
.SYNOPSIS
Plans, validates, or applies vcpkg settings in the caller's Process environment.
.DESCRIPTION
Supports Windows clients running Windows PowerShell 5.1 or PowerShell 7.
Run with & in the PowerShell session that will build. Choose the local checkout,
target triplet, and host triplet explicitly for this client. No compiler, SDK,
generator, machine identity, or installation path is inferred. This helper does
not bootstrap vcpkg, create directories, change PATH, or persist settings.

Optional overlay directories replace VCPKG_OVERLAY_TRIPLETS when supplied;
otherwise its existing value is preserved and its directories are validated.
Triplet availability is checked in effective overlays before the checkout.
This is not a compiler or
package compatibility check. Use a new project build directory after relocation.

UseLocalBinaryCache explicitly replaces VCPKG_BINARY_SOURCES with
clear;default,readwrite. vcpkg owns the default cache location, including any
existing VCPKG_DEFAULT_BINARY_CACHE override; that override is checked for a
local directory but never returned. Omitted cache and metrics options preserve
their existing values. Read-only Plan and Validate report drift as IsValid=false.
#>
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Validate', 'Apply')]
    [string]$Mode = 'Plan',
    [Parameter(Mandatory = $true)]
    [string]$VcpkgRoot,
    [Parameter(Mandatory = $true)]
    [string]$TargetTriplet,
    [Parameter(Mandatory = $true)]
    [string]$HostTriplet,
    [string[]]$OverlayTriplets,
    [switch]$UseLocalBinaryCache,
    [switch]$DisableMetrics
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Reject recognizable secrets before any filesystem probe or intended-value output.
$credentialPattern = '(?i)\[REDACTED\]|\bsk-(?:proj-|ant-)?[a-z0-9_-]{16,}|\bgh[pousr]_[a-z0-9]{20,}|\bgithub_pat_[a-z0-9_]{20,}|\bxox[baprs]-[a-z0-9-]{10,}|\b(?:glpat-|hf_|npm_)[a-z0-9_-]{16,}|\b(?:AKIA|ASIA)[A-Z0-9]{16}\b|\bAIza[a-z0-9_-]{30,}|\beyJ[a-z0-9_-]+\.[a-z0-9_-]+\.[a-z0-9_-]+|-----BEGIN [A-Z ]+-----|\b(?:bearer|basic)\s+\S+|[a-z][a-z0-9+.-]*://[^\s/@:]+:[^\s/@]+@|(?:password|passwd|pwd|sshpass|token|secret|api[ _-]?key|authorization|credential|connection[ _-]?string)\s*[=:]\s*\S+'

function Get-LocalClientDirectory {
    param([string]$Value, [string]$ArgumentName)
    if ($Value -match $credentialPattern) {
        throw "$ArgumentName must not contain credential-shaped content."
    }
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[A-Za-z]:[\\/]') {
        throw "$ArgumentName must be an absolute local Windows directory, not a network or drive-relative path."
    }
    # Delimiters are unsafe in overlay search lists and CMake path lists.
    if ($Value.IndexOfAny([char[]]@(';', "`r", "`n")) -ge 0) {
        throw "$ArgumentName must not contain semicolons or newlines."
    }
    try {
        $fullPath = [IO.Path]::GetFullPath($Value)
        $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($fullPath))
        if (-not $drive.IsReady -or $drive.DriveType -notin @('Fixed', 'Removable', 'Ram') -or
            $drive.VolumeLabel -match '(?i)pcloud') {
            throw 'Nonlocal drive.'
        }
        $directory = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
        if (-not ($directory -is [IO.DirectoryInfo])) { throw 'Not a directory.' }
        # A local-looking junction can lead to a network/cloud root. Require an
        # ordinary path so this check works identically on PowerShell 5.1 and 7.
        for ($ancestor = $directory; $null -ne $ancestor; $ancestor = $ancestor.Parent) {
            if (($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Reparse path.'
            }
        }
        $directory.FullName
    }
    catch {
        # Do not echo arbitrary user paths or filesystem exception messages.
        throw "$ArgumentName must be an existing local directory on a ready local drive; network, pCloud, and reparse paths are not supported."
    }
}

$root = Get-LocalClientDirectory -Value $VcpkgRoot -ArgumentName 'VcpkgRoot'
foreach ($triplet in @($TargetTriplet, $HostTriplet)) {
    if ($triplet -match $credentialPattern) { throw 'Triplets must not contain credential-shaped content.' }
    if ($triplet -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') {
        throw 'TargetTriplet and HostTriplet must be explicit triplet names without path separators.'
    }
}
$overlays = @(
    foreach ($overlay in $OverlayTriplets) {
        Get-LocalClientDirectory -Value $overlay -ArgumentName 'OverlayTriplets'
    }
)
if ($PSBoundParameters.ContainsKey('OverlayTriplets') -and $overlays.Count -eq 0) {
    throw 'OverlayTriplets requires at least one existing local directory when supplied.'
}
$effectiveOverlays = $overlays
if (-not $PSBoundParameters.ContainsKey('OverlayTriplets')) {
    $inheritedOverlays = [Environment]::GetEnvironmentVariable('VCPKG_OVERLAY_TRIPLETS', 'Process')
    $effectiveOverlays = @(
        if (-not [string]::IsNullOrEmpty($inheritedOverlays)) {
            foreach ($inheritedOverlay in ($inheritedOverlays -split ';')) {
                Get-LocalClientDirectory -Value $inheritedOverlay -ArgumentName 'VCPKG_OVERLAY_TRIPLETS'
            }
        }
    )
}
if ($UseLocalBinaryCache) {
    $cacheOverride = [Environment]::GetEnvironmentVariable('VCPKG_DEFAULT_BINARY_CACHE', 'Process')
    if (-not [string]::IsNullOrEmpty($cacheOverride)) {
        $null = Get-LocalClientDirectory -Value $cacheOverride -ArgumentName 'VCPKG_DEFAULT_BINARY_CACHE'
    }
}
$toolchain = Join-Path $root 'scripts\buildsystems\vcpkg.cmake'
$errors = @()
if (-not (Test-Path -LiteralPath $toolchain -PathType Leaf)) {
    $errors += 'The selected VcpkgRoot is missing scripts/buildsystems/vcpkg.cmake.'
}
$searchDirectories = @($effectiveOverlays) + @((Join-Path $root 'triplets'), (Join-Path $root 'triplets\community'))
foreach ($choice in @(@{ Role = 'Target'; Name = $TargetTriplet }, @{ Role = 'Host'; Name = $HostTriplet })) {
    $found = $false
    foreach ($searchDirectory in $searchDirectories) {
        if (Test-Path -LiteralPath (Join-Path $searchDirectory ($choice.Name + '.cmake')) -PathType Leaf) {
            $found = $true
            break
        }
    }
    if (-not $found) { $errors += ($choice.Role + ' triplet is missing from the checkout and effective overlays.') }
}
$desired = [ordered]@{
    VCPKG_ROOT = $root
    CMAKE_TOOLCHAIN_FILE = $toolchain
    VCPKG_DEFAULT_TRIPLET = $TargetTriplet
    VCPKG_DEFAULT_HOST_TRIPLET = $HostTriplet
}
if ($overlays.Count -gt 0) { $desired.VCPKG_OVERLAY_TRIPLETS = $overlays -join ';' }
if ($UseLocalBinaryCache) { $desired.VCPKG_BINARY_SOURCES = 'clear;default,readwrite' }
if ($DisableMetrics) { $desired.VCPKG_DISABLE_METRICS = '1' }
$changes = @(
    foreach ($name in $desired.Keys) {
        $before = [Environment]::GetEnvironmentVariable($name, 'Process')
        [pscustomobject]@{
            Name = $name
            Scope = 'Process'
            Before = $(if ($null -eq $before) { $null } else { '[redacted]' })
            After = $desired[$name]
            Changed = ($before -cne $desired[$name])
        }
    }
)
if ($Mode -eq 'Apply') {
    if ($errors.Count -gt 0) { throw ($errors -join '; ') }
    foreach ($change in $changes) {
        if ($change.Changed) {
            [Environment]::SetEnvironmentVariable($change.Name, $change.After, 'Process')
        }
        if ([Environment]::GetEnvironmentVariable($change.Name, 'Process') -cne $change.After) {
            throw "Process readback failed for $($change.Name); earlier Process changes may have applied."
        }
    }
}
[pscustomobject]@{
    Mode = $Mode
    Scope = 'Process'
    IsValid = ($errors.Count -eq 0 -and ($Mode -eq 'Apply' -or @($changes | Where-Object Changed).Count -eq 0))
    Changes = $changes
    Errors = $errors
}
