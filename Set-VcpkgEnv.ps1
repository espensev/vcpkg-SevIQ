#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Sets vcpkg-related system environment variables.
.DESCRIPTION
    Registers VCPKG_ROOT, VCPKG_DEFAULT_TRIPLET, CMAKE_TOOLCHAIN_FILE as
    Machine-level environment variables and ensures VCPKG_ROOT is on the
    system PATH.  Requires an elevated (Admin) PowerShell session.
.NOTES
    Re-running is safe — existing values are overwritten, PATH is not duplicated.
#>

$VcpkgRoot       = 'D:\Development\vcpkg-SevIQ'
$DefaultTriplet  = 'x64-windows'
$ToolchainFile   = "$VcpkgRoot\scripts\buildsystems\vcpkg.cmake"

# --- Validate ---
if (-not (Test-Path "$VcpkgRoot\vcpkg.exe")) {
    Write-Error "vcpkg.exe not found at $VcpkgRoot — aborting."
    exit 1
}
if (-not (Test-Path $ToolchainFile)) {
    Write-Error "Toolchain file not found at $ToolchainFile — aborting."
    exit 1
}

# --- Set system env vars ---
$vars = @{
    VCPKG_ROOT            = $VcpkgRoot
    VCPKG_DEFAULT_TRIPLET = $DefaultTriplet
    CMAKE_TOOLCHAIN_FILE  = $ToolchainFile
}

foreach ($kv in $vars.GetEnumerator()) {
    $current = [Environment]::GetEnvironmentVariable($kv.Key, 'Machine')
    if ($current -eq $kv.Value) {
        Write-Host "  [skip] $($kv.Key) already set correctly" -ForegroundColor DarkGray
    } else {
        [Environment]::SetEnvironmentVariable($kv.Key, $kv.Value, 'Machine')
        Write-Host "  [set]  $($kv.Key) = $($kv.Value)" -ForegroundColor Green
    }
}

# --- Ensure VCPKG_ROOT is on system PATH ---
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$entries = $machinePath -split ';' | Where-Object { $_ -ne '' }

if ($entries -contains $VcpkgRoot) {
    Write-Host "  [skip] PATH already contains $VcpkgRoot" -ForegroundColor DarkGray
} else {
    $newPath = ($entries + $VcpkgRoot) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')
    Write-Host "  [set]  Added $VcpkgRoot to system PATH" -ForegroundColor Green
}

Write-Host "`nDone. Open a new shell to pick up the changes." -ForegroundColor Cyan
