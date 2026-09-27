[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$setupScript = Join-Path $PSScriptRoot 'Set-VcpkgClientEnv.ps1'
$script:checks = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch {
        Assert-True ($_.Exception.Message -match $Pattern) "Expected error matching $Pattern"
        Assert-True ($_.Exception.Message -notmatch 'synthetic-sensitive') 'rejection does not echo sensitive input'
        return
    }
    throw "FAIL: Expected error matching $Pattern"
}
function Get-ProcessSnapshot {
    $values = [Environment]::GetEnvironmentVariables('Process')
    @($values.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ Name = $_; Value = $values[$_] } }) | ConvertTo-Json -Compress
}
function New-Checkout([string]$Path, [string]$Target, [string]$HostTripletName) {
    $null = New-Item -ItemType Directory -Path (Join-Path $Path 'scripts\buildsystems') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $Path 'triplets\community') -Force
    [IO.File]::WriteAllText((Join-Path $Path 'scripts\buildsystems\vcpkg.cmake'), '# synthetic checkout')
    [IO.File]::WriteAllText((Join-Path $Path ('triplets\' + $Target + '.cmake')), '# synthetic target')
    [IO.File]::WriteAllText((Join-Path $Path ('triplets\community\' + $HostTripletName + '.cmake')), '# synthetic host')
}

$initialProcess = Get-ProcessSnapshot
$saved = @{}
$variableNames = @('VCPKG_ROOT', 'CMAKE_TOOLCHAIN_FILE', 'VCPKG_DEFAULT_TRIPLET', 'VCPKG_DEFAULT_HOST_TRIPLET',
    'VCPKG_OVERLAY_TRIPLETS', 'VCPKG_BINARY_SOURCES', 'VCPKG_DISABLE_METRICS', 'VCPKG_DEFAULT_BINARY_CACHE')
foreach ($name in $variableNames) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$persistent = @{}
foreach ($scope in @('User', 'Machine')) {
    foreach ($name in $variableNames) { $persistent["$scope/$name"] = [Environment]::GetEnvironmentVariable($name, $scope) }
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('vcpkg-client-' + [Guid]::NewGuid().ToString('N'))
try {
    $rootA = Join-Path $testRoot 'client one'
    $rootB = Join-Path $testRoot 'second-client'
    $overlay = Join-Path $testRoot 'custom-triplets'
    New-Checkout $rootA 'x64-windows' 'x64-windows-host'
    New-Checkout $rootB 'arm64-custom' 'x86-custom-host'
    $null = New-Item -ItemType Directory -Path $overlay
    [IO.File]::WriteAllText((Join-Path $overlay 'custom-toolset.cmake'), '# client selects its own compiler')
    $arguments = @{ VcpkgRoot = $rootA; TargetTriplet = 'x64-windows'; HostTriplet = 'x64-windows-host' }
    foreach ($name in $variableNames) { [Environment]::SetEnvironmentVariable($name, 'synthetic-sensitive-previous', 'Process') }
    [Environment]::SetEnvironmentVariable('VCPKG_DEFAULT_BINARY_CACHE', [NullString]::Value, 'Process')
    [Environment]::SetEnvironmentVariable('VCPKG_OVERLAY_TRIPLETS', [NullString]::Value, 'Process')
    $before = Get-ProcessSnapshot
    $plan = & $setupScript @arguments
    $validate = & $setupScript @arguments -Mode Validate
    Assert-True ($before -ceq (Get-ProcessSnapshot)) 'Plan and Validate preserve the complete Process environment'
    Assert-True ($plan.Mode -eq 'Plan' -and $plan.Scope -eq 'Process' -and -not $plan.IsValid) 'default is Process Plan reporting drift'
    Assert-True ($validate.Mode -eq 'Validate' -and -not $validate.IsValid) 'Validate reports drift'
    Assert-True ($plan.Changes.Count -eq 4 -and $plan.Errors.Count -eq 0) 'four required variables and available target/host triplets'
    Assert-True (($plan | ConvertTo-Json -Depth 6) -notmatch 'synthetic-sensitive') 'plan excludes arbitrary previous values'
    $applied = & $setupScript @arguments -Mode Apply
    Assert-True ($applied.IsValid -and $env:VCPKG_ROOT -eq $rootA) 'first client applies selected checkout'
    Assert-True ($env:CMAKE_TOOLCHAIN_FILE -eq (Join-Path $rootA 'scripts\buildsystems\vcpkg.cmake')) 'selected toolchain applied'
    Assert-True ($env:VCPKG_DEFAULT_TRIPLET -eq 'x64-windows' -and $env:VCPKG_DEFAULT_HOST_TRIPLET -eq 'x64-windows-host') 'target and host are independently explicit'
    Assert-True ($env:VCPKG_BINARY_SOURCES -eq 'synthetic-sensitive-previous' -and $env:VCPKG_DISABLE_METRICS -eq 'synthetic-sensitive-previous' -and $null -eq $env:VCPKG_OVERLAY_TRIPLETS) 'omitted optional settings are preserved'
    Assert-True (($applied | ConvertTo-Json -Depth 6) -notmatch 'synthetic-sensitive') 'Apply receipt excludes arbitrary previous values'
    $again = & $setupScript @arguments -Mode Apply
    Assert-True ($again.IsValid -and @($again.Changes | Where-Object Changed).Count -eq 0) 'repeated Apply is idempotent'
    Assert-True ((& $setupScript @arguments -Mode Validate).IsValid) 'Validate accepts converged settings'

    $arguments = @{ VcpkgRoot = $rootB; TargetTriplet = 'arm64-custom'; HostTriplet = 'x86-custom-host' }
    $applied = & $setupScript @arguments -Mode Apply -UseLocalBinaryCache -DisableMetrics
    Assert-True ($applied.IsValid -and $env:VCPKG_ROOT -eq $rootB -and $env:VCPKG_DEFAULT_TRIPLET -eq 'arm64-custom' -and $env:VCPKG_DEFAULT_HOST_TRIPLET -eq 'x86-custom-host') 'second client uses a different root and distinct triplets'
    Assert-True ($env:VCPKG_BINARY_SOURCES -eq 'clear;default,readwrite' -and $env:VCPKG_DISABLE_METRICS -eq '1') 'explicit cache replacement and metrics opt-out'
    $arguments.TargetTriplet = 'custom-toolset'
    $before = Get-ProcessSnapshot
    $missing = & $setupScript @arguments
    Assert-True (-not $missing.IsValid -and $missing.Errors.Count -eq 1) 'missing custom triplet is reported'
    Assert-Throws { & $setupScript @arguments -Mode Apply } 'Target triplet'
    Assert-True ($before -ceq (Get-ProcessSnapshot)) 'missing triplet fails before any writes'
    $applied = & $setupScript @arguments -OverlayTriplets $overlay -Mode Apply
    Assert-True ($applied.IsValid -and $env:VCPKG_OVERLAY_TRIPLETS -eq $overlay -and $env:VCPKG_DEFAULT_TRIPLET -eq 'custom-toolset') 'explicit overlay supports client-selected toolsets'
    $inherited = & $setupScript @arguments -Mode Validate
    Assert-True ($inherited.IsValid -and @($inherited.Changes | Where-Object Name -eq 'VCPKG_OVERLAY_TRIPLETS').Count -eq 0) 'omitted overlays preserve and validate inherited triplet lookup'
    Assert-True (($inherited | ConvertTo-Json -Depth 6) -notmatch [regex]::Escape($overlay)) 'inherited overlay paths are not returned'
    $secondOverlay = Join-Path $testRoot 'preferred-triplets'
    $null = New-Item -ItemType Directory -Path $secondOverlay
    [IO.File]::WriteAllText((Join-Path $secondOverlay 'custom-toolset.cmake'), '# first overlay wins in vcpkg')
    $orderedOverlays = @($secondOverlay, $overlay)
    $applied = & $setupScript @arguments -OverlayTriplets $orderedOverlays -Mode Apply
    Assert-True ($applied.IsValid -and $env:VCPKG_OVERLAY_TRIPLETS -ceq ($orderedOverlays -join ';')) 'explicit overlay array preserves client precedence order'
    Assert-True ((& $setupScript @arguments -Mode Validate).IsValid) 'inherited overlay array validates with the same ordered configuration'
    [Environment]::SetEnvironmentVariable('VCPKG_OVERLAY_TRIPLETS', 'C:\token=synthetic-sensitive', 'Process')
    Assert-Throws { & $setupScript @arguments } 'credential-shaped'
    [Environment]::SetEnvironmentVariable('VCPKG_OVERLAY_TRIPLETS', $overlay, 'Process')
    Assert-Throws { & $setupScript @arguments -OverlayTriplets @() } 'at least one'
    Assert-Throws { & $setupScript @arguments -OverlayTriplets '\\server\share' } 'absolute local'
    Assert-Throws { & $setupScript @arguments -OverlayTriplets 'C:\token=synthetic-sensitive' } 'credential-shaped'

    foreach ($badRoot in @('relative', '\root-relative', 'C:drive-relative', '\\server\share', '//server/share', 'https://example.invalid/repo', 'C:\bad;path')) {
        $bad = @{ VcpkgRoot = $badRoot; TargetTriplet = 'x64-windows'; HostTriplet = 'x64-windows' }
        Assert-Throws { & $setupScript @bad -Mode Apply } 'absolute local|semicolons'
    }
    foreach ($secretRoot in @('C:\token=synthetic-sensitive', 'C:\Bearer synthetic-sensitive', 'C:\ghp_12345678901234567890synthetic')) {
        $bad = @{ VcpkgRoot = $secretRoot; TargetTriplet = 'x64-windows'; HostTriplet = 'x64-windows' }
        Assert-Throws { & $setupScript @bad } 'credential-shaped'
    }
    Assert-Throws { & $setupScript -VcpkgRoot (Join-Path $testRoot 'absent') -TargetTriplet 'x64-windows' -HostTriplet 'x64-windows' } 'existing local'
    Assert-Throws { & $setupScript -VcpkgRoot $rootA -TargetTriplet '..\outside' -HostTriplet 'x64-windows' } 'explicit triplet names'
    $arguments.TargetTriplet = 'arm64-custom'
    $before = Get-ProcessSnapshot
    [IO.File]::Delete((Join-Path $rootB 'scripts\buildsystems\vcpkg.cmake'))
    $missing = & $setupScript @arguments
    Assert-True (-not $missing.IsValid -and $missing.Errors.Count -eq 1) 'missing toolchain is reported'
    Assert-Throws { & $setupScript @arguments -Mode Apply } 'missing scripts/buildsystems'
    Assert-True ($before -ceq (Get-ProcessSnapshot)) 'missing toolchain fails before writes'
    $arguments.VcpkgRoot = $rootA
    $arguments.TargetTriplet = 'x64-windows'
    $arguments.HostTriplet = 'x64-windows-host'
    [Environment]::SetEnvironmentVariable('VCPKG_DEFAULT_BINARY_CACHE', '\\server\cache', 'Process')
    Assert-Throws { & $setupScript @arguments -UseLocalBinaryCache -Mode Apply } 'absolute local'
    [Environment]::SetEnvironmentVariable('VCPKG_DEFAULT_BINARY_CACHE', 'C:\token=synthetic-sensitive', 'Process')
    Assert-Throws { & $setupScript @arguments -UseLocalBinaryCache } 'credential-shaped'
    [Environment]::SetEnvironmentVariable('VCPKG_DEFAULT_BINARY_CACHE', $testRoot, 'Process')
    $cachePlan = & $setupScript @arguments -UseLocalBinaryCache
    Assert-True ($cachePlan.Errors.Count -eq 0) 'an existing local default-cache override is allowed'
    Assert-True (@($cachePlan.Changes | Where-Object Name -eq 'VCPKG_DEFAULT_BINARY_CACHE').Count -eq 0) 'default-cache override is never returned or changed'

    foreach ($scope in @('User', 'Machine')) {
        foreach ($name in $variableNames) {
            Assert-True ($persistent["$scope/$name"] -ceq [Environment]::GetEnvironmentVariable($name, $scope)) 'persistent environments remain unchanged'
        }
    }
    $source = [IO.File]::ReadAllText($setupScript)
    Assert-True (([regex]::Matches($source, 'SetEnvironmentVariable\(')).Count -eq 1) 'single process-only environment writer'
    Assert-True ($source -match "SetEnvironmentVariable\(\`$change.Name, \`$change.After, 'Process'\)") 'writer hardcodes Process scope'
    Assert-True ($source -notmatch 'MACHINE_CODE_ROOT|snd-desk|Set-Item.*Env:Path|Start-Process|CreateDirectory|New-Item') 'no machine assumption, child process, or directory creation'
    $parserErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($setupScript, [ref]$null, [ref]$parserErrors)
    Assert-True ($parserErrors.Count -eq 0) 'helper parses without errors'
    $parameterNames = $ast.ParamBlock.Parameters.Name.VariablePath.UserPath
    Assert-True (-not ($parameterNames -contains 'Scope') -and -not ($parameterNames -contains 'Adapter')) 'public entry point has no persistence or bypass option'
}
finally {
    foreach ($name in $variableNames) {
        $restore = $(if ($null -eq $saved[$name]) { [NullString]::Value } else { $saved[$name] })
        [Environment]::SetEnvironmentVariable($name, $restore, 'Process')
    }
    # This directory was created by this test. Verify its resolved parent and
    # generated basename before deleting only the synthetic fixtures.
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if (([IO.Path]::GetDirectoryName($resolvedTestRoot) -cne $tempParent) -or
        ([IO.Path]::GetFileName($resolvedTestRoot) -notmatch '^vcpkg-client-[a-f0-9]{32}$')) {
        throw 'Refusing cleanup outside the generated temporary fixture directory.'
    }
    if (Test-Path -LiteralPath $resolvedTestRoot) { Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force }
}
Assert-True ($initialProcess -ceq (Get-ProcessSnapshot)) 'entire Process environment restored, including PATH'
Write-Output "PASS: $script:checks portable vcpkg client checks; PowerShell $($PSVersionTable.PSVersion); synthetic checkouts only, Process environment restored."
