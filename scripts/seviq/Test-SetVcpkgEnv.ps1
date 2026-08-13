[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
$setupScript = Join-Path $repoRoot 'Set-VcpkgEnv.ps1'
$testSharedRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vcpkg-shared-cache-test-{0}" -f [guid]::NewGuid().ToString('N'))
$cacheRoot = Join-Path $testSharedRoot 'caches\vcpkg\binary'
$expectedBinarySources = "clear;files,$cacheRoot,readwrite;default,readwrite"
$variableNames = @(
    'SND_SQ_Shared'
    'VCPKG_ROOT'
    'VCPKG_DEFAULT_TRIPLET'
    'CMAKE_TOOLCHAIN_FILE'
    'VCPKG_BINARY_SOURCES'
)
$originalValues = @{}

foreach ($name in $variableNames) {
    $originalValues[$name] = [Environment]::GetEnvironmentVariable(
        $name,
        [System.EnvironmentVariableTarget]::Process
    )
}
$originalPath = $env:Path

try {
    [Environment]::SetEnvironmentVariable(
        'SND_SQ_Shared',
        $null,
        [System.EnvironmentVariableTarget]::Process
    )

    & $setupScript -Scope Process -SharedRoot $testSharedRoot -DisableMetrics

    if (-not (Test-Path -LiteralPath $cacheRoot -PathType Container)) {
        throw "Expected shared binary-cache directory was not created: $cacheRoot"
    }

    if ($env:VCPKG_BINARY_SOURCES -ne $expectedBinarySources) {
        throw "Unexpected VCPKG_BINARY_SOURCES. Expected '$expectedBinarySources'; got '$env:VCPKG_BINARY_SOURCES'."
    }

    if ($env:VCPKG_ROOT -ne $repoRoot) {
        throw "VCPKG_ROOT changed away from the local checkout. Expected '$repoRoot'; got '$env:VCPKG_ROOT'."
    }

    Write-Output 'PASS: local vcpkg root uses the namespaced shared binary cache with a local fallback.'
} finally {
    foreach ($name in $variableNames) {
        [Environment]::SetEnvironmentVariable(
            $name,
            $originalValues[$name],
            [System.EnvironmentVariableTarget]::Process
        )
    }
    $env:Path = $originalPath

    if (Test-Path -LiteralPath $testSharedRoot) {
        $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
        $resolvedTestRoot = [System.IO.Path]::GetFullPath($testSharedRoot).TrimEnd('\')
        $expectedPrefix = "$tempRoot\vcpkg-shared-cache-test-"
        if (-not $resolvedTestRoot.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove unexpected test directory: $resolvedTestRoot"
        }
        Remove-Item -LiteralPath $testSharedRoot -Recurse -Force
    }
}
