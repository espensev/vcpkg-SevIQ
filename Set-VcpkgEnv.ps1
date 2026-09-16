[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Validate', 'Apply')]
    [string]$Mode = 'Plan',
    [ValidateSet('Process', 'User', 'Machine')]
    [string]$Scope = 'Process',
    [string]$SharedRoot,
    [switch]$ReplaceBinarySources,
    [switch]$DisableMetrics
)

function Invoke-VcpkgEnvironment {
    [CmdletBinding()]
    param(
        [ValidateSet('Plan', 'Validate', 'Apply')][string]$Mode = 'Plan',
        [ValidateSet('Process', 'User', 'Machine')][string]$Scope = 'Process',
        [string]$SharedRoot,
        [switch]$ReplaceBinarySources,
        [switch]$DisableMetrics,
        [Parameter(Mandatory)][hashtable]$Adapter
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    if ($Scope -ne 'Process') {
        throw 'Use -Scope Process. User/Machine persistent changes require a separately reviewed environment owner.'
    }
    $codeRoot = & $Adapter.Read 'MACHINE_CODE_ROOT'
    # Reject credential-shaped paths before probing or returning intended values.
    $credentialPattern = '(?i)\[REDACTED\]|\bsk-(?:proj-|ant-)?[a-z0-9_-]{16,}|\bgh[pousr]_[a-z0-9]{20,}|\bgithub_pat_[a-z0-9_]{20,}|\bxox[baprs]-[a-z0-9-]{10,}|\b(?:glpat-|hf_|npm_)[a-z0-9_-]{16,}|\b(?:AKIA|ASIA)[A-Z0-9]{16}\b|\bAIza[a-z0-9_-]{30,}|\beyJ[a-z0-9_-]+\.[a-z0-9_-]+\.[a-z0-9_-]+|-----BEGIN [A-Z ]+-----|\b(?:bearer|basic)\s+\S+|[a-z][a-z0-9+.-]*://[^\s/@:]+:[^\s/@]+@|(?:password|passwd|pwd|sshpass|token|secret|api[ _-]?key|authorization|credential|connection[ _-]?string)\s*[=:]\s*\S+'
    if ($codeRoot -match $credentialPattern -or $SharedRoot -match $credentialPattern) {
        throw 'MACHINE_CODE_ROOT and SharedRoot must not contain credential-shaped content.'
    }
    # Reject drive-relative and current-drive paths; permit absolute drive and UNC roots.
    if ([string]::IsNullOrWhiteSpace($codeRoot) -or $codeRoot -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)') {
        throw 'MACHINE_CODE_ROOT must contain an absolute code-volume root in the caller Process environment.'
    }
    $root = [IO.Path]::GetFullPath((Join-Path $codeRoot 'Development\vcpkg-SevIQ'))
    $toolchain = Join-Path $root 'scripts\buildsystems\vcpkg.cmake'
    $desired = [ordered]@{
        VCPKG_ROOT = $root
        VCPKG_DEFAULT_TRIPLET = 'x64-windows'
        CMAKE_TOOLCHAIN_FILE = $toolchain
    }
    if ($DisableMetrics) { $desired.VCPKG_DISABLE_METRICS = '1' }
    if ($ReplaceBinarySources -and [string]::IsNullOrWhiteSpace($SharedRoot)) {
        throw '-ReplaceBinarySources requires an explicit -SharedRoot.'
    }
    if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
        if ($SharedRoot -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)' -or
            $SharedRoot.IndexOfAny([char[]]@(',', ';', '`')) -ge 0) {
            throw 'SharedRoot must be an absolute path without comma, semicolon, or backtick binary-source delimiters.'
        }
        $cache = Join-Path ([IO.Path]::GetFullPath($SharedRoot)) 'caches\vcpkg\binary'
        $binarySources = "clear;files,$cache,readwrite;default,readwrite"
        $existing = & $Adapter.Read 'VCPKG_BINARY_SOURCES'
        if (-not [string]::IsNullOrEmpty($existing) -and $existing -cne $binarySources -and -not $ReplaceBinarySources) {
            throw 'VCPKG_BINARY_SOURCES already differs. Use -ReplaceBinarySources with -SharedRoot to opt in to replacement.'
        }
        $desired.VCPKG_BINARY_SOURCES = $binarySources
    }
    $errors = @()
    if (-not (& $Adapter.Exists $toolchain)) {
        $errors += "Canonical toolchain file is missing: $toolchain"
    }
    $changes = @(
        foreach ($name in $desired.Keys) {
            $before = & $Adapter.Read $name
            [pscustomobject]@{
                Name = $name
                Scope = 'Process'
                # Existing values may carry credentials, even for conventional path variables.
                Before = $(if ($null -eq $before) { $null } else { '[redacted]' })
                After = $desired[$name]
                Changed = ($before -cne $desired[$name])
            }
        }
    )
    $identity = $null
    if ($Mode -eq 'Apply') {
        if ($errors.Count -gt 0) { throw ($errors -join '; ') }
        $results = @(& $Adapter.Identity)
        if ($results.Count -ne 1 -or $null -eq $results[0] -or
            $null -eq $results[0].PSObject.Properties['status'] -or
            $null -eq $results[0].PSObject.Properties['machineId'] -or
            $null -eq $results[0].PSObject.Properties['instanceId'] -or
            $results[0].status -cne 'VERIFIED' -or
            $results[0].machineId -cne 'snd-desk' -or
            $results[0].instanceId -cne 'ca96d510-7d87-4cec-8e1a-bd8fc3866903') {
            throw 'Local identity verification must return exactly one VERIFIED snd-desk result with the enrolled instance ID.'
        }
        $identity = [pscustomobject]@{
            Status = $results[0].status
            MachineId = $results[0].machineId
            InstanceId = $results[0].instanceId
        }
        foreach ($change in $changes) {
            if ($change.Changed) {
                & $Adapter.Write $change.Name $change.After
            }
            if ((& $Adapter.Read $change.Name) -cne $change.After) {
                throw "Process readback failed for $($change.Name); earlier Process changes may have applied."
            }
        }
    }
    [pscustomobject]@{
        Mode = $Mode
        Scope = 'Process'
        IsValid = ($errors.Count -eq 0 -and ($Mode -eq 'Apply' -or @($changes | Where-Object Changed).Count -eq 0))
        Identity = $identity
        Changes = $changes
        Errors = $errors
    }
}

# Dot-sourcing loads the function without applying or planning anything.
if ($MyInvocation.InvocationName -ne '.') {
    $adapter = @{
        Read = { param($Name) [Environment]::GetEnvironmentVariable($Name, 'Process') }
        Write = { param($Name, $Value) [Environment]::SetEnvironmentVariable($Name, $Value, 'Process') }
        Exists = { param($Path) Test-Path -LiteralPath $Path -PathType Leaf }
        Identity = {
            $verifier = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'common_dev\v2\Test-LocalMachineIdentity.ps1'
            if (-not (Test-Path -LiteralPath $verifier -PathType Leaf)) {
                throw 'Installed local identity verifier is missing.'
            }
            & $verifier
        }
    }
    Invoke-VcpkgEnvironment -Mode $Mode -Scope $Scope -SharedRoot $SharedRoot `
        -ReplaceBinarySources:$ReplaceBinarySources -DisableMetrics:$DisableMetrics -Adapter $adapter
}
