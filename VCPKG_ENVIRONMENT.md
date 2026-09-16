# VCPKG environment

`Set-VcpkgEnv.ps1` plans or validates the caller's Process environment by default.
Explicit `-Mode Apply` sets a small set of process variables after verifying the
installed local machine identity. It does not persist environment values.

## Plan, validate, apply

Run these commands in the PowerShell session that will run the build:

```powershell
# Read-only: inspect intended values and differences.
$plan = & .\Set-VcpkgEnv.ps1
$plan.Changes | Format-Table

# Read-only: IsValid is false for drift or a missing canonical toolchain.
$validation = & .\Set-VcpkgEnv.ps1 -Mode Validate
$validation.IsValid

# Explicit mutation: caller Process only, including optional metrics opt-out.
$receipt = & .\Set-VcpkgEnv.ps1 -Mode Apply -DisableMetrics
```

`-Scope Process` is the only supported scope and is the default. `-Scope User`
and `-Scope Machine` fail closed in every mode; persistent configuration belongs
to a separately reviewed environment owner. There is no administrator mode.

Use `&` in the current shell for Apply. Starting `pwsh -File` or
`powershell -File` changes only that child process; its parent cannot inherit
those changes. Dot-sourcing loads the implementation function for testing and
performs no setup.

## Values and prerequisites

The caller must have an absolute `MACHINE_CODE_ROOT`. The canonical vcpkg root
is its `Development\vcpkg-SevIQ` child, independent of the script's location or
a temporary worktree. Apply requires that root's
`scripts\buildsystems\vcpkg.cmake` file to exist.

| Variable | Intended Process value |
|---|---|
| `VCPKG_ROOT` | `<MACHINE_CODE_ROOT>\Development\vcpkg-SevIQ` |
| `CMAKE_TOOLCHAIN_FILE` | `<VCPKG_ROOT>\scripts\buildsystems\vcpkg.cmake` |
| `VCPKG_DEFAULT_TRIPLET` | `x64-windows` |
| `VCPKG_DISABLE_METRICS` | `1`, only with `-DisableMetrics`; otherwise preserved |
| `VCPKG_BINARY_SOURCES` | Configured only with explicit `-SharedRoot`; otherwise preserved |

Apply resolves `common_dev\v2\Test-LocalMachineIdentity.ps1` from the Windows
LocalApplicationData known folder. It requires exactly one `VERIFIED` result
for machine `snd-desk`, instance `ca96d510-7d87-4cec-8e1a-bd8fc3866903`.
Missing, failed, or mismatched verification stops before environment writes.
Plan and Validate do not invoke the verifier or perform writes.

## Optional shared binary cache

An explicit absolute shared root opts in to this configuration:

```text
clear;files,<SharedRoot>\caches\vcpkg\binary,readwrite;default,readwrite
```

```powershell
$plan = & .\Set-VcpkgEnv.ps1 -SharedRoot $chosenSharedRoot
$receipt = & .\Set-VcpkgEnv.ps1 -Mode Apply -SharedRoot $chosenSharedRoot
```

There is no automatic `SND_SQ_Shared` lookup. The script never creates the cache
directory or checks share access. Provision and authorize storage separately;
a subsequent vcpkg invocation can write to the configured cache. Commas,
semicolons, and backticks are rejected because they delimit or escape vcpkg
binary-source fields. Root paths containing credential-shaped assignments, bearer/basic authentication, URI userinfo,
known provider-key prefixes, JWTs, or PEM markers are rejected before probing or
reporting intended values. This bounded detection does not classify arbitrary secrets.

A different nonempty `VCPKG_BINARY_SOURCES` fails before mutation unless
`-ReplaceBinarySources` is also supplied with `-SharedRoot`. An already matching
value requires no replacement option. Review the Plan with the same options
before Apply.

## Results and boundaries

Plan and Validate return `Mode`, `Scope`, `IsValid`, `Identity`, `Changes`, and
`Errors`. `IsValid` checks the selected variables and canonical toolchain only;
it is not a build-tool installation check. Drift is returned as data, not a
nonzero shell exit code. Invalid arguments and Apply failures throw.

A successful Apply returns an in-memory receipt with verified identity and one
change row per selected variable. Each row records `Scope`, `Name`, `Before`,
`After`, and `Changed`. `Before` is null when absent and `[redacted]` otherwise;
arbitrary previous environment values are never returned. `After` is the
intended value, confirmed by readback. No receipt file is written. Repeating
Apply still verifies identity but skips values that already match. A write or
readback failure throws; earlier Process changes may remain, so no successful
receipt is returned for a partial application.

The script does not bootstrap vcpkg, discover downloaded tools, edit any PATH,
broadcast environment changes, or create directories. Install vcpkg and build
tools through their owners. Configure CMake and Ninja explicitly and import the
Visual Studio developer environment as required by the consuming build.

Existing User/Machine values, stale PATH entries, and previously created cache
directories are outside this writer's cleanup scope. This change does not
migrate or remove them. Persistent relocation and cleanup require separate
reviewed work.

## Verification

```powershell
pwsh -NoProfile -File .\scripts\seviq\Test-SetVcpkgEnv.ps1
powershell -NoProfile -File .\scripts\seviq\Test-SetVcpkgEnv.ps1
```

The harness runs Apply against in-memory environment and identity adapters,
then exercises public Plan and Validate read-only. It does not run live Apply,
bootstrap tools, or create a cache.
