[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
$setupScript = Join-Path $repoRoot 'Set-VcpkgEnv.ps1'
# Refuse to execute the legacy writer, including through dot-sourcing.
$source = [IO.File]::ReadAllText($setupScript)
if ($source -notmatch 'function Invoke-VcpkgEnvironment' -or $source -notmatch '\$MyInvocation.InvocationName') {
    throw 'FAIL: safe dot-source entry point is missing; legacy writer was not executed.'
}
. $setupScript
$script:checks = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch {
        Assert-True ($_.Exception.Message -match $Pattern) "Expected error matching $Pattern; got $($_.Exception.Message)"
        return
    }
    throw "FAIL: Expected error matching $Pattern"
}
function New-Fixture {
    $state = @{
        Values = @{ MACHINE_CODE_ROOT = 'C:\fixture-code'; Path = 'unchanged;PATH'; SND_SQ_Shared = 'C:\ignored-share' }
        Writes = [Collections.Generic.List[object]]::new()
        IdentityCalls = 0
        Exists = $true
        Identity = [pscustomobject]@{ status = 'VERIFIED'; machineId = 'snd-desk'; instanceId = 'ca96d510-7d87-4cec-8e1a-bd8fc3866903' }
    }
    $adapter = @{
        Read = { param($Name) $state.Values[$Name] }.GetNewClosure()
        Write = { param($Name, $Value) $state.Writes.Add([pscustomobject]@{Name=$Name;Value=$Value}); $state.Values[$Name]=$Value }.GetNewClosure()
        Exists = { param($Path) $state.Exists }.GetNewClosure()
        Identity = { $state.IdentityCalls++; $state.Identity }.GetNewClosure()
    }
    [pscustomobject]@{State=$state;Adapter=$adapter}
}
$f = New-Fixture
$p = Invoke-VcpkgEnvironment -Adapter $f.Adapter
Assert-True ($p.Mode -eq 'Plan' -and $p.Scope -eq 'Process') 'default is Process Plan'
Assert-True ($p.Changes.Count -eq 3 -and -not $p.IsValid) 'plan reports three differences'
Assert-True ($p.Changes[0].After -eq 'C:\fixture-code\Development\vcpkg-SevIQ') 'canonical root ignores script/worktree location'
Assert-True ($f.State.Writes.Count -eq 0 -and $f.State.IdentityCalls -eq 0) 'Plan is read-only'
Assert-True (-not ($p.Changes.Name -contains 'VCPKG_BINARY_SOURCES')) 'legacy shared-root fallback ignored'
$v = Invoke-VcpkgEnvironment -Mode Validate -Adapter $f.Adapter
Assert-True (-not $v.IsValid -and $f.State.Writes.Count -eq 0) 'Validate reports drift without writes'
$a = Invoke-VcpkgEnvironment -Mode Apply -DisableMetrics -Adapter $f.Adapter
Assert-True ($a.Mode -eq 'Apply' -and $a.IsValid -and $a.Identity.machineId -eq 'snd-desk') 'Apply returns verified receipt'
Assert-True ($a.Changes.Count -eq 4 -and $f.State.Writes.Count -eq 4) 'Apply writes only selected variables'
Assert-True (($f.State.Writes.Name -join ',') -eq 'VCPKG_ROOT,VCPKG_DEFAULT_TRIPLET,CMAKE_TOOLCHAIN_FILE,VCPKG_DISABLE_METRICS') 'exact writer allowlist'
Assert-True ($a.Changes[0].Before -eq $null -and $a.Changes[0].Changed) 'receipt records previous missing value'
Assert-True ($a.Changes[0].After -eq $f.State.Values.VCPKG_ROOT) 'receipt records applied value'
Assert-True ($f.State.Values.Path -ceq 'unchanged;PATH') 'PATH remains untouched'
$a2 = Invoke-VcpkgEnvironment -Mode Apply -DisableMetrics -Adapter $f.Adapter
Assert-True (@($a2.Changes | Where-Object Changed).Count -eq 0 -and $f.State.Writes.Count -eq 4) 'Apply is idempotent'
$v2 = Invoke-VcpkgEnvironment -Mode Validate -DisableMetrics -Adapter $f.Adapter
Assert-True $v2.IsValid 'Validate passes converged values'
foreach ($scope in @('User','Machine')) {
    foreach ($mode in @('Plan','Validate','Apply')) {
        Assert-Throws { Invoke-VcpkgEnvironment -Mode $mode -Scope $scope -Adapter $f.Adapter } 'Process.*persistent'
    }
}
foreach ($identity in @(
    $null,
    [pscustomobject]@{status='REJECTED';machineId='snd-desk';instanceId='ca96d510-7d87-4cec-8e1a-bd8fc3866903'},
    [pscustomobject]@{status='VERIFIED';machineId='other';instanceId='ca96d510-7d87-4cec-8e1a-bd8fc3866903'},
    [pscustomobject]@{status='VERIFIED';machineId='snd-desk';instanceId='other'},
    @([pscustomobject]@{status='VERIFIED'}, [pscustomobject]@{status='VERIFIED'})
)) {
    $bad = New-Fixture
    $bad.State.Identity = $identity
    Assert-Throws { Invoke-VcpkgEnvironment -Mode Apply -Adapter $bad.Adapter } 'identity'
    Assert-True ($bad.State.Writes.Count -eq 0) 'identity rejection precedes all writes'
}
$f = New-Fixture
$f.State.Exists = $false
$p = Invoke-VcpkgEnvironment -Adapter $f.Adapter
Assert-True (-not $p.IsValid -and $p.Errors.Count -eq 1) 'missing toolchain reported in Plan'
Assert-Throws { Invoke-VcpkgEnvironment -Mode Apply -Adapter $f.Adapter } 'toolchain'
Assert-True ($f.State.Writes.Count -eq 0) 'missing toolchain fails closed'
foreach ($root in @('', 'relative', '\root-relative', 'C:drive-relative')) {
    $f = New-Fixture
    $f.State.Values.MACHINE_CODE_ROOT = $root
    Assert-Throws { Invoke-VcpkgEnvironment -Adapter $f.Adapter } 'MACHINE_CODE_ROOT'
}
$f = New-Fixture
foreach ($shared in @('relative', '\root-relative', 'C:\bad,root', 'C:\bad;root', 'C:\bad`root')) {
    Assert-Throws { Invoke-VcpkgEnvironment -SharedRoot $shared -Adapter $f.Adapter } 'SharedRoot'
}
$f.State.Values.VCPKG_BINARY_SOURCES = 'https://user:synthetic-password@example.invalid/cache?token=synthetic-token'
Assert-Throws { Invoke-VcpkgEnvironment -Mode Apply -SharedRoot 'C:\explicit-share' -Adapter $f.Adapter } 'ReplaceBinarySources'
Assert-True ($f.State.Writes.Count -eq 0) 'binary-source conflict fails before mutation'
$a = Invoke-VcpkgEnvironment -Mode Apply -SharedRoot 'C:\explicit-share' -ReplaceBinarySources -Adapter $f.Adapter
$binary = $a.Changes | Where-Object Name -eq VCPKG_BINARY_SOURCES
Assert-True ($binary.Before -eq '[redacted]' -and $binary.After -eq 'clear;files,C:\explicit-share\caches\vcpkg\binary,readwrite;default,readwrite') 'explicit cache receipt'
Assert-True (($a | ConvertTo-Json -Depth 6) -notmatch 'synthetic-password|synthetic-token') 'receipt excludes arbitrary previous values'
$a2 = Invoke-VcpkgEnvironment -Mode Apply -SharedRoot 'C:\explicit-share' -Adapter $f.Adapter
Assert-True (@($a2.Changes | Where-Object Changed).Count -eq 0) 'same cache configuration does not need replacement consent'
Assert-Throws { Invoke-VcpkgEnvironment -ReplaceBinarySources -Adapter $f.Adapter } 'SharedRoot'
$f = New-Fixture
$f.State.Values.VCPKG_DISABLE_METRICS = 'existing-metrics'
$f.State.Values.VCPKG_BINARY_SOURCES = 'existing-cache'
$null = Invoke-VcpkgEnvironment -Mode Apply -Adapter $f.Adapter
Assert-True ($f.State.Values.VCPKG_DISABLE_METRICS -eq 'existing-metrics' -and $f.State.Values.VCPKG_BINARY_SOURCES -eq 'existing-cache') 'omitted options preserve metrics and cache'
$f = New-Fixture
$f.Adapter.Identity = { throw 'synthetic identity failure' }
Assert-Throws { Invoke-VcpkgEnvironment -Mode Apply -Adapter $f.Adapter } 'identity failure'
Assert-True ($f.State.Writes.Count -eq 0) 'verifier exception fails before writes'
$f = New-Fixture
$f.Adapter.Write = { param($Name, $Value) }
Assert-Throws { Invoke-VcpkgEnvironment -Mode Apply -Adapter $f.Adapter } 'readback failed'
$f = New-Fixture
$f.Adapter.Write = { param($Name, $Value) throw 'synthetic write failure' }
Assert-Throws { Invoke-VcpkgEnvironment -Mode Apply -Adapter $f.Adapter } 'write failure'
$f = New-Fixture
$f.State.Values.VCPKG_ROOT = 'synthetic-secret-existing-root'
$p = Invoke-VcpkgEnvironment -Adapter $f.Adapter
Assert-True (($p | ConvertTo-Json -Depth 6) -notmatch 'synthetic-secret') 'Plan also excludes arbitrary prior values'
foreach ($credentialPath in @('C:\cache\token=review-synthetic-secret-8042', 'C:\cache\password=review-synthetic-secret-8042', 'C:\cache\api_key=review-synthetic-secret-8042', 'C:\cache\Bearer review-synthetic-8042', 'C:\cache\glpat-reviewSynthetic8042abcd', 'C:\cache\xoxb-reviewSynthetic8042abcd', 'C:\cache\hf_reviewSynthetic8042abcd', 'C:\cache\npm_reviewSynthetic8042abcd', 'C:\cache\AIzaReviewSynthetic8042abcdefghijklmnopq', 'C:\cache\eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.reviewSynthetic8042abcd', 'C:\cache\-----BEGIN PRIVATE KEY-----', 'C:\cache\https://user:review-synthetic-8042@example.invalid', 'C:\cache\ASIA1234567890ABCDEF', 'C:\cache\Basic cmV2aWV3OnN5bnRoZXRpYy1zZWNyZXQ=')) {
    foreach ($option in @('MACHINE_CODE_ROOT', 'SharedRoot')) {
        $f = New-Fixture
        $arguments = @{Adapter=$f.Adapter}
        if ($option -eq 'MACHINE_CODE_ROOT') { $f.State.Values.MACHINE_CODE_ROOT = $credentialPath }
        else { $arguments.SharedRoot = $credentialPath }
        $errorMessage = $null
        try { $null = Invoke-VcpkgEnvironment @arguments }
        catch { $errorMessage = $_.Exception.Message }
        Assert-True ($null -ne $errorMessage -and $errorMessage -match 'credential-shaped') 'credential-shaped path rejected'
        Assert-True ($errorMessage -notmatch [regex]::Escape($credentialPath)) 'rejection does not echo credential'
    }
}
# Exercise the public read-only entry point and compare the entire real Process environment.
$before = [Environment]::GetEnvironmentVariables('Process') | ConvertTo-Json -Compress
$publicPlan = & $setupScript
$publicValidate = & $setupScript -Mode Validate
$after = [Environment]::GetEnvironmentVariables('Process') | ConvertTo-Json -Compress
Assert-True ($before -ceq $after) 'public Plan and Validate preserve the whole Process environment'
Assert-True ($publicPlan.Mode -eq 'Plan' -and $publicValidate.Mode -eq 'Validate') 'public command mode dispatch'
foreach ($scope in @('User','Machine')) {
    Assert-Throws { & $setupScript -Scope $scope } 'Process.*persistent'
}
# Statically constrain public execution: no adapter/bypass parameter, one process-only writer.
$ast = [Management.Automation.Language.Parser]::ParseFile($setupScript, [ref]$null, [ref]$null)
Assert-True (-not ($ast.ParamBlock.Parameters.Name.VariablePath.UserPath -contains 'Adapter')) 'adapter is not a public execution switch'
Assert-True (([regex]::Matches($source, 'SetEnvironmentVariable\(')).Count -eq 1) 'only one environment mutation call'
Assert-True ($source -match "SetEnvironmentVariable\(\`$Name, \`$Value, 'Process'\)") 'environment writer hardcodes Process'
Assert-True ($source -notmatch 'New-Item|CreateDirectory|bootstrap-vcpkg|SendMessageTimeout|Get-ChildItem|SND_SQ_Shared') 'no cache, bootstrap, discovery, broadcast, or implicit share side effects'
Write-Output "PASS: $script:checks vcpkg environment contract checks; PowerShell $($PSVersionTable.PSVersion); synthetic Apply only."
