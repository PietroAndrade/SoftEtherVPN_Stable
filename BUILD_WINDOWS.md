# Building SoftEther VPN on Windows (Modern Toolchain)

This document supersedes the legacy `BUILD_WINDOWS.TXT` files. The original
upstream instructions assume **Visual Studio 2008 SP1** and the **Windows SDK
6.0A**. This fork has been modernized to build on **Visual Studio 2026** with
the **Windows 11 SDK** on **Windows 11**, without the legacy WDK 7.1.

| Status (binary) | State |
|---|---|
| `BuildUtil` (.NET / C#) | Builds — runtime works |
| `Mayaqua` (static lib) | Builds |
| `Cedar` (static lib) | Builds |
| `vpncmd` (CLI) | **Builds and runs** |
| `vpnserver` | Not yet validated on this fork |
| `vpnclient` | Not yet validated on this fork |
| `vpnbridge` | Not yet validated on this fork |
| `vpncmgr`, `vpnsmgr` (GUI, MFC) | Not yet validated; requires MFC component |
| Driver projects (`Neo`, `Neo6`, `SeLow`, `Wfp`) | **Not built** — pre-signed binaries used from `src/bin/hamcore/DriverPackages/` |

If you extend this work to other binaries, please update this table.

---

## 1. Prerequisites

### 1.1 Operating system

- Windows 11 (tested on 24H2)

### 1.2 Visual Studio 2026

Install **Visual Studio 2026 Community / Professional / Enterprise** with at
least the following components (Visual Studio Installer → Modify → Individual
Components):

- **MSVC v143** or newer x64/x86 build tools (the projects target `v145`)
- **Windows 11 SDK 10.0.26100** or newer
- **C++ ATL** for the latest MSVC
- **C++ MFC** for the latest MSVC *(only needed for `vpncmgr`, `vpnsmgr`)*
- **.NET Framework 4.8 SDK** (targeting pack)

To validate the install:

```powershell
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
& $vswhere -latest -products * -property installationPath
& $vswhere -latest -products * -requires Microsoft.Component.MSBuild `
  -find "MSBuild\**\Bin\MSBuild.exe"
```

### 1.3 Windows 11 SDK tools

The build needs `rc.exe` (resource compiler) and optionally `makecat.exe`
(catalog signing). Both ship with the Windows 11 SDK at:

```
C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\rc.exe
C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\makecat.exe
```

Adjust the version (`10.0.26100.0`) if a newer SDK is installed.

### 1.4 What you do NOT need

- ❌ **Visual Studio 2008** — patches removed the hardcoded VC9 registry lookup
- ❌ **Windows SDK 6.0A** — patches added a fallback to the Win11 SDK via env vars
- ❌ **WDK 7.1 (`C:\WinDDK\7600.16385.0`)** — driver projects are excluded; pre-signed `.sys` files ship in the repo
- ❌ **.NET Framework 3.5** — `BuildUtil` was retargeted to .NET Framework 4.8

---

## 2. Building from a clean checkout

### 2.1 Open a Developer PowerShell

Start menu → **"Developer PowerShell for VS 2026"** (preferably the **x64
Native Tools** variant, so `LIB`/`INCLUDE` point at x64 libraries).

### 2.2 Set environment variables

```powershell
$env:RC_EXE      = "C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\rc.exe"
$env:MAKECAT_EXE = "C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\makecat.exe"
```

These are read by the patched `BuildUtil` to substitute the legacy SDK 6.0A
paths. They do not need to be persistent — only set in the build shell.

### 2.3 Build vpncmd (validated end-to-end)

```powershell
cd <repo-root>

msbuild src\SEVPN.sln /t:vpncmd `
  /p:Configuration=Release /p:Platform=x64 `
  /p:DebugInformationFormat=None `
  /v:minimal /nologo
```

The artifact lands at `src\bin\vpncmd_x64.exe`.

The `/p:DebugInformationFormat=None` flag is a workaround for a recurring PDB
race condition; see [§5 Troubleshooting](#5-troubleshooting). Drop it once you
have configured Defender exclusions or `mspdbsrv` serialization.

### 2.4 Build everything (experimental)

A full `msbuild src\SEVPN.sln /p:Configuration=Release /p:Platform=x64` is
**not yet validated** — driver projects will fail without WDK, MFC projects
will fail without the MFC component, and other user-mode binaries will need
the same kind of patches `vpncmd` received. See [§4 Per-binary porting
checklist](#4-per-binary-porting-checklist).

---

## 3. Modernization patches

These patches were applied to make the codebase build with the modern
toolchain. They live in normal commits on the working branch — there are no
out-of-tree patch files to apply.

### 3.1 BuildUtil retargeted to .NET Framework 4.8

**Files:** `src/BuildUtil/BuildUtil.csproj`

- `ToolsVersion` `"3.5"` → `"Current"`
- `<TargetFrameworkVersion>` `v2.0` → `v4.8`

Allows `BuildUtil` to compile under MSBuild that ships with VS2026 instead of
the deprecated .NET Framework 3.5 MSBuild.

### 3.2 Tolerant Paths static constructor

**File:** `src/BuildUtil/VpnBuilder.cs`

The `Paths` static constructor used to throw if the **Visual Studio 9.0
(VS2008)** registry key or the **Windows SDK 6.0A** were missing — neither
exists on a clean Windows 11 / VS2026 install.

The patched code:

- Wraps the legacy registry lookups in `try/catch`
- Falls back to environment variables when the registry returns empty:
  - `VS_VC_DIR` — Visual C++ install dir (mostly unused now)
  - `WINDOWS_SDK_DIR` — Windows SDK install dir
  - `RC_EXE` — full path to `rc.exe` (used by `GenerateVersionResource`)
  - `MAKECAT_EXE` — full path to `makecat.exe`
  - `MSBUILD_EXE` — full path to MSBuild (used by the legacy `/CMD:All` pipeline)
- Never throws from the static ctor when only `rc.exe` (the only thing
  `vpncmd`-style PreLink events actually need) is available.

### 3.3 Drop driver project references from Cedar

**File:** `src/Cedar/Cedar.vcxproj`

Cedar used to reference `Neo6`, `PenCore`, `SeeDll`, `Wfp` via
`<ProjectReference>` (build-order only, not link). Those projects need
**WDK 7600** (`C:\WinDDK\7600.16385.0`) hardcoded into their compile/link
lines, which we do not have.

The references are **commented out** with a note explaining how to re-enable
them if WDK is installed. The pre-signed `.sys` and `.cat` files in
`src/bin/hamcore/DriverPackages/` are used at runtime instead.

### 3.4 wcstok 3-argument form for MSVC v145

**File:** `src/Mayaqua/Internat.c` (function `UniParseToken`)

VS2026's MSVC removed the legacy 2-arg `wcstok`. The C11 standard mandates
the 3-arg form `wcstok(str, delim, &context)`. The original code only passed
the context pointer on Unix; it now does so unconditionally.

### 3.5 Explicit `<security.h>` include for SSPI types

**File:** `src/Mayaqua/Microsoft.h`

The `EXTENDED_NAME_FORMAT` enum (used by `GetUserNameExA/W` function pointer
typedefs) is no longer pulled in transitively by the Win11 SDK. Patch adds:

```c
#ifndef SECURITY_WIN32
#define SECURITY_WIN32
#endif
#include <security.h>
```

Inside the `MICROSOFT_C` block, ensuring all consumers of that block see the
type.

### 3.6 vpncmd — replace `afxres.h`, sync TargetName, bridge legacy CRT

**Files:** `src/vpncmd/vpncmd.rc`, `src/vpncmd/vpncmd.vcxproj`,
`src/vpncmd/legacy_iob_stub.c` (new)

Three small changes specific to the `vpncmd` binary:

- `vpncmd.rc`: `#include "afxres.h"` → `#include <winres.h>`. `vpncmd` is CLI
  and has no MFC dependency; the original include was a leftover from the VS
  resource template.
- `vpncmd.vcxproj` (Release|x64): added `<TargetName>vpncmd_x64</TargetName>`
  so `$(TargetPath)` matches the `vpncmd_x64.exe` declared in `<OutputFile>`.
  Without this, `BuildUtil /CMD:SetManifest` (PostBuildEvent) fails to find
  the file.
- `vpncmd.vcxproj` (Release|x64): added `legacy_stdio_definitions.lib` to
  `<AdditionalDependencies>` to resolve `_vsnprintf`, `_vsnwprintf`, `sscanf`
  symbols referenced by the **pre-built OpenSSL static libraries** (compiled
  against the legacy CRT, before VS2015's UCRT split).
- `legacy_iob_stub.c` (new): one-function shim that defines `__iob_func`
  using the modern UCRT `__acrt_iob_func(0|1|2)` accessors. The legacy
  OpenSSL libs reference `__iob_func` which the UCRT no longer provides.

These three changes will need to be repeated **per binary** for `vpnserver`,
`vpnclient`, `vpnbridge`. See [§4](#4-per-binary-porting-checklist).

---

## 4. Per-binary porting checklist

When porting another user-mode binary (e.g., `vpnserver`), expect to repeat
the `vpncmd` recipe:

1. **`<binary>.rc`**: if it uses `afxres.h` and the binary is not a GUI/MFC
   app, replace with `<winres.h>`. If it IS an MFC app, install the **C++
   MFC** component instead.
2. **`<binary>.vcxproj`**: ensure `<TargetName>` matches `<OutputFile>` for
   each `$(Configuration)|$(Platform)` you intend to build.
3. **`<binary>.vcxproj`**: add `legacy_stdio_definitions.lib` to
   `<AdditionalDependencies>` and include `legacy_iob_stub.c` in
   `<ClCompile>` items. (Or move both to `Mayaqua` so they're inherited
   transparently — recommended once more than one binary needs them.)
4. **Source code**: expect to find more places where:
   - A Windows SDK header that worked transitively no longer does
   - A deprecated CRT function (`strcpy`, `gets`, etc.) needs `_s` variant or `_CRT_SECURE_NO_WARNINGS`
   - A 32-bit pointer truncation warning becomes an error under `/W4 /WX`
5. **Pre-build/post-build events**: verify `BuildUtil /CMD:...` invocations
   resolve `$(TargetPath)` correctly.

Keep updating the status table at the top of this file as binaries are
validated.

---

## 5. Troubleshooting

### 5.1 `error C1090: PDB API call failed, error code '3'`

**Cause:** `mspdbsrv.exe` race condition or anti-virus locking the PDB.

**Mitigations (in order):**

```powershell
# Kill orphan mspdbsrv
Get-Process mspdbsrv -ErrorAction SilentlyContinue | Stop-Process -Force

# Pre-create output dirs so cl.exe doesn't race
New-Item -ItemType Directory -Force -Path src\tmp\lib\x64_Release | Out-Null
New-Item -ItemType Directory -Force -Path src\tmp\VersionResources | Out-Null

# Add Defender exclusion (admin shell)
Add-MpPreference -ExclusionPath "<path-to-repo>"

# Or skip PDB entirely for smoke tests
msbuild ... /p:DebugInformationFormat=None
```

### 5.2 `LNK2019: _vsnprintf / _vsnwprintf / sscanf / __iob_func`

**Cause:** Pre-built OpenSSL libs (`src/BuildFiles/Library/`) were compiled
against the legacy CRT (msvcrt). Modern UCRT does not export these symbols.

**Fix:** Ensure the binary's `.vcxproj` includes:

```xml
<Link>
  <AdditionalDependencies>legacy_stdio_definitions.lib;...</AdditionalDependencies>
</Link>
<ItemGroup>
  <ClCompile Include="legacy_iob_stub.c" />
</ItemGroup>
```

The proper long-term fix is to **rebuild OpenSSL with VS2026** and replace
the binaries in `src/BuildFiles/Library/{Win32,x64}_{Debug,Release}/`.

### 5.3 `cannot open include file 'afxres.h'`

**Cause:** Resource script references MFC header without the MFC component
installed.

**Fix (CLI/service binary):** Replace with `#include <winres.h>`.
**Fix (real GUI/MFC binary):** Install **C++ MFC** in VS Installer.

### 5.4 `error C2122: 'TYPE': invalid prototype parameter name list`

**Cause:** A type referenced in a function-pointer typedef is not declared.
Old SDKs pulled it transitively; new SDK does not.

**Fix:** Add the explicit `#include <whatever.h>` ahead of the typedef. Most
common culprits: `<security.h>` (SSPI), `<wincrypt.h>` (CryptoAPI),
`<wininet.h>` (WinINet).

### 5.5 `error MSB3073: BuildUtil.exe ... vpncmd.exe ... exited with code 1`

**Cause:** `BuildUtil`'s PostBuildEvent looks for `$(TargetPath)` (which uses
`<TargetName>`), but `<OutputFile>` was overridden to a different name
(`vpncmd_x64.exe`).

**Fix:** Add `<TargetName>vpncmd_x64</TargetName>` to the matching
`<PropertyGroup Condition="...Release|x64...">`.

### 5.6 `Visual C++ directory not found` from BuildUtil

**Cause:** The patched `Paths` ctor still expects either VS2008 in the
registry, the `VS_VC_DIR` env var, or one of the env-var fallbacks.

**Fix:** This message means you are exercising a code path that needs the VC
toolchain location (e.g., the legacy `/CMD:All` build pipeline). For the
`vpncmd`/`vpnserver`/etc. PreLink events, only `RC_EXE` is needed and the
ctor will not throw. If you really need the legacy pipeline, set
`VS_VC_DIR` to your VS2026 VC root.

---

## 6. CI / automation

A reference PowerShell build script is provided at
[`ci/build-vpncmd.ps1`](ci/build-vpncmd.ps1). It is idempotent, locates
toolchain paths automatically via `vswhere`, and exits non-zero on failure.

YAML examples for **GitHub Actions** and **Azure DevOps Pipelines** are in
[`ci/README.md`](ci/README.md).

---

## 7. Reference: legacy build pipeline

The original VS2008 build pipeline (`src/BuildAll.cmd` →
`BuildUtil.exe /CMD:All` → produces full installer packages) is **not yet
modernized**. It still references `Microsoft Visual Studio 9.0\VC\vcvarsall.bat`
and the .NET Framework 3.5 MSBuild. Modernizing this pipeline is tracked
separately and is not required for producing individual binaries via direct
`msbuild` invocation.

---

## 8. Contributing modernization fixes

When you fix the next binary or hit a new compatibility issue:

1. Add the patch in a small, focused commit on a feature branch.
2. Update [§3 Modernization patches](#3-modernization-patches) and the status
   table at the top of this file.
3. If the fix is reusable across binaries (e.g., the CRT shim), consider
   moving it into `Mayaqua` so it propagates automatically.
4. Add a troubleshooting entry in [§5](#5-troubleshooting) if the symptom is
   not obvious from the error message.
