# VCPKG Environment

This note documents a machine-level Windows native build setup for CMake projects that use MSVC, Ninja, and `vcpkg`.

## Installed Location

On this machine, `vcpkg` lives at:

- `D:\Development\vcpkg-SevIQ`

The expected toolchain file is:

- `D:\Development\vcpkg-SevIQ\scripts\buildsystems\vcpkg.cmake`

## Setup Command

Use the repo script to bootstrap `vcpkg.exe` if needed and persist the expected environment.

Machine scope:

```powershell
pwsh -File .\Set-VcpkgEnv.ps1 -Scope Machine -DisableMetrics
```

User scope:

```powershell
pwsh -File .\Set-VcpkgEnv.ps1 -Scope User -DisableMetrics
```

The script also adds the Visual Studio Ninja directory to `PATH` when it can resolve it via `vswhere`.

## Environment Variables

| Variable | Value | Status | Purpose |
|---|---|---|---|
| `VCPKG_ROOT` | `D:\Development\vcpkg-SevIQ` | recommended | standard machine-level reference to the local `vcpkg` tree |
| `CMAKE_TOOLCHAIN_FILE` | `D:\Development\vcpkg-SevIQ\scripts\buildsystems\vcpkg.cmake` | required for manual CMake | integrates `vcpkg` with CMake |
| `PATH` | include `D:\Development\vcpkg-SevIQ` | recommended | makes `vcpkg.exe` available from any shell |
| `PATH` | include the Visual Studio Ninja directory resolved from `vswhere` | recommended | allows `cmake -G Ninja` to work outside a developer shell |
| `VCPKG_DEFAULT_TRIPLET` | `x64-windows` | optional | useful default for manual `vcpkg` commands |

`vcpkg.exe` being on `PATH` is recommended because many shells do not inherit the same startup environment, and ad-hoc troubleshooting is easier when `vcpkg` is directly callable.

## Required Tools

- Visual Studio with the C++ toolchain and Windows SDK
- CMake
- Ninja
- `vcpkg`

## Practical Rule

Do not assume a shell already has your expected environment loaded.

A reliable Windows-native build flow should explicitly do these steps:

- locate Visual Studio with `vswhere`
- import the MSVC environment through `VsDevCmd.bat`
- set `VCPKG_ROOT`
- set or pass `CMAKE_TOOLCHAIN_FILE`
- resolve `Ninja`
- run `cmake -S ... -B ...`
- run `cmake --build ...`

That approach is more reliable than depending on a pre-opened Developer PowerShell or user-specific shell startup configuration.

## Generic Manual Configure Example

```powershell
cmake -S <repo-root> `
      -B <repo-root>\out\build\x64-debug `
      -G Ninja `
      -DCMAKE_BUILD_TYPE=Debug `
      -DCMAKE_TOOLCHAIN_FILE=D:\Development\vcpkg-SevIQ\scripts\buildsystems\vcpkg.cmake
```

## Generic Manual Build Example

```powershell
cmake --build <repo-root>\out\build\x64-debug
```

## Suggested Build Script Behavior

If a repo has a build helper such as `build.ps1`, it should preferably:

- accept a configurable `VcpkgRoot`
- compute the toolchain file from that root
- import the Visual Studio environment itself
- locate `Ninja` instead of assuming it is already on `PATH`
- pass the toolchain file into CMake explicitly
- avoid depending on the caller to launch from a special shell first

## Common Failure Modes

- `VCPKG_ROOT` points at the wrong directory
- `CMAKE_TOOLCHAIN_FILE` is missing or wrong
- `Ninja` is not installed or not discoverable
- `CMAKE_C_COMPILER` or `CMAKE_CXX_COMPILER` is unset
- standard headers like `string.h` or `stddef.h` are missing

Missing standard headers usually means the Visual Studio developer environment was not imported correctly.
