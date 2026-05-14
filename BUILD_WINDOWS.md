# Building SoftEther VPN on Windows (Modern Toolchain)

This document supersedes the legacy `BUILD_WINDOWS.TXT` files. The original
upstream instructions assume **Visual Studio 2008 SP1** and the **Windows SDK
6.0A**. This fork has been modernized to build on **Visual Studio 2026** with
the **Windows 11 SDK** on **Windows 11**, without the legacy WDK 7.1.

| Project | Type | State |
|---|---|---|
| `BuildUtil` | C# exe | Builds, runtime works |
| `Mayaqua` | static lib | Builds |
| `Cedar` | static lib | Builds |
| `vpncmd` | CLI exe | **Builds and runs** |
| `vpnclient` | service exe | **Builds** (desktop client runtime ✓) |
| `vpncmgr` | GUI exe | **Builds** (desktop client runtime ✓) |
| `VGate` | user-mode DLL | **Builds** (transitive dep) |
| `vpnserver` | service exe | Pending |
| `vpnbridge` | service exe | Pending |
| `vpnsmgr` | GUI exe | Pending |
| `vpncmdsys` | service exe | Pending |
| `vpnsetup` | exe | Pending (only for installer packaging) |
| `vpndrvinst` | exe | Pending (only for installer packaging) |
| `vpninstall` | exe | Pending (only for installer packaging) |
| `vpnbrand` | exe | Pending (OEM rebranding tool) |
| `PenCore` | user-mode DLL | Pending (no required consumer for desktop client) |
| `Ham` | exe | Pending (internal cert/NIC utility) |
| `vpnweb` | ATL OCX | Pending (legacy IE ActiveX — IE retired 2022) |
| `Neo`, `Neo6`, `See`, `SeeDll`, `SeLow`, `Wfp` | kernel drivers | **Not built** — pre-signed `.sys`/`.cat` files in `src/bin/hamcore/DriverPackages/` are used at runtime; rebuilding requires WDK 7600 |

If you extend this work to other binaries, update this table.

---

## 0. What to build (by use case)

The `.sln` contains 24 projects but very few are needed for any given use
case. Pick the row that matches your goal and build only the listed
projects.

### 0.1 Desktop VPN client (most common)

End-user installs SoftEther on a Windows PC to connect to an existing VPN
server.

| Build | Project | Purpose |
|---|---|---|
| Required | `vpnclient` | Background service that maintains tunnels |
| Required | `vpncmgr` | Connection Manager GUI (the icon users click) |
| Required | `vpncmd` ✓ | CLI for scripts and advanced config |
| Auto | `VGate` | Library; pulled transitively by `vpnclient` |
| Already shipped | Neo / Neo6 / SeLow drivers | Pre-signed `.sys` in `src/bin/hamcore/DriverPackages/` |

For an internal deployment (GPO / Ansible / DSC), this set is sufficient.
Use `pnputil` to register the drivers and `New-Service` to register
`vpnclient` as a Windows service.

For a packaged installer (`.exe` / `.msi`), additionally build:

| Build | Project | Purpose |
|---|---|---|
| Optional | `vpndrvinst` | Driver-install helper invoked at first run |
| Optional | `vpninstall` | Generic installer helper |
| Optional | `vpnsetup` | Full setup wizard |

### 0.2 VPN server / bridge host

Operator hosts a SoftEther server or bridge.

| Build | Project | Purpose |
|---|---|---|
| Required | `vpnserver` *or* `vpnbridge` | The service itself |
| Required | `vpncmd` ✓ | CLI for management |
| Recommended | `vpnsmgr` | Server Manager GUI |
| Auto | `Cedar`, `Mayaqua`, `VGate` | Libraries pulled transitively |

### 0.3 Anything else

| Project | When to build |
|---|---|
| `vpnbrand` | Only if you need to apply a custom OEM brand to the binaries |
| `vpncmdsys` | Service-mode wrapper of `vpncmd` (rarely needed standalone) |
| `Ham` | SoftEther internal certificate / NIC utility (not user-facing) |
| `vpnweb` | Legacy ActiveX for VPN-over-Internet-Explorer; **skip** — IE was retired in 2022 |
| `PenCore` | Has no required consumer outside Cedar's optional build-order link; skip unless a future port requires it |
| Driver projects | Only if you have WDK 7.1 + an EV cert + intent to re-sign through Microsoft Hardware Dev Center |

### 0.4 Suggested porting order

If you are progressively modernizing this fork, attack the binaries in
this order — earlier ones unlock or de-risk later ones:

1. **`vpnclient`** — first user-mode service; reuses every Cedar/Mayaqua patch already in place
2. **`vpncmgr`** — first GUI; will surface any Win11 SDK breakage in Common Controls / shell APIs
3. **`vpnserver`** + **`vpnbridge`** — server-side, near-twins of `vpnclient`
4. **`vpnsmgr`** — second GUI, follows `vpncmgr`'s patches
5. **Installer chain** (`vpndrvinst`, `vpninstall`, `vpnsetup`) — only if shipping packages
6. The rest, on demand

Each binary added should follow the [§4 Per-binary porting
checklist](#4-per-binary-porting-checklist) and update the status table
above.

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
- **.NET Framework 4.8 SDK** (targeting pack)
- **C++ ATL** for the latest MSVC *(only needed for `vpnweb`, the legacy IE
  ActiveX control — skip otherwise)*

> **MFC is NOT required.** Despite the `#include "afxres.h"` boilerplate in
> some `.rc` files (vestigial Visual Studio template noise), no project sets
> `<UseOfMfc>` and the GUIs (`vpncmgr`, `vpnsmgr`) are built with raw Win32
> + SoftEther's own UI framework. The `afxres.h` include is replaced with
> `<winres.h>` per binary as those binaries are ported.

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

### 2.2 (Optional) Override SDK paths

`BuildUtil` auto-discovers the highest-versioned Windows 10/11 SDK under
`C:\Program Files (x86)\Windows Kits\10\bin\` and uses its `x64\rc.exe`
and `x64\makecat.exe`. **No environment variable setup is required on a
standard Win11 + VS2026 machine.**

You only need to set env vars to override the auto-discovered defaults
(e.g. to pin a specific SDK version):

```powershell
$env:RC_EXE      = "C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64\rc.exe"
$env:MAKECAT_EXE = "C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64\makecat.exe"
```

Precedence: `RC_EXE` env var → auto-discovered SDK → legacy `Microsoft SDK
v6.0A` (rarely present) → empty (build will fail with a clear error if
`rc.exe` is needed but not located).

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

### 3.6 Legacy CRT shim centralized in Mayaqua

**File:** `src/Mayaqua/legacy_crt_shim.c` (new), referenced from
`src/Mayaqua/Mayaqua.vcxproj`

A single compilation unit, baked into `Mayaqua.lib`, provides:

- A definition of `__iob_func()` that returns a `FILE iob[3]` array backed
  by the modern UCRT `__acrt_iob_func(0|1|2)` accessors. The pre-built
  OpenSSL static libs in `src/BuildFiles/Library/` reference `__iob_func`,
  which UCRT no longer exports.
- A `#pragma comment(lib, "legacy_stdio_definitions.lib")` directive that
  tells the linker to additionally include MSVC's compatibility lib. That
  lib restores the pre-UCRT names `_vsnprintf`, `_vsnwprintf`, `sscanf`,
  `_snprintf` etc. that the same OpenSSL libs reference.

Because this is inside `Mayaqua.lib`, **every binary that links Mayaqua
inherits the shim transparently** — no per-binary `.vcxproj` patches are
required to resolve the legacy CRT symbols.

### 3.7 vpncmd — replace `afxres.h`, sync TargetName

**Files:** `src/vpncmd/vpncmd.rc`, `src/vpncmd/vpncmd.vcxproj`

Two small changes specific to the `vpncmd` binary:

- `vpncmd.rc`: `#include "afxres.h"` → `#include <winres.h>`. `vpncmd` is CLI
  and has no MFC dependency; the original include was a leftover from the VS
  resource template.
- `vpncmd.vcxproj` (Release|x64): added `<TargetName>vpncmd_x64</TargetName>`
  so `$(TargetPath)` matches the `vpncmd_x64.exe` declared in `<OutputFile>`.
  Without this, `BuildUtil /CMD:SetManifest` (PostBuildEvent) fails to find
  the file.

These two changes will need to be repeated **per binary** for `vpnclient`,
`vpncmgr`, `vpnserver`, `vpnbridge`, `vpnsmgr`. See
[§4](#4-per-binary-porting-checklist).

---

## 4. Per-binary porting checklist

When porting another user-mode binary, expect to repeat the `vpncmd`
recipe. With the centralized CRT shim in Mayaqua (§3.6), there are now
only two mandatory steps per binary:

1. **`<binary>.rc`**: replace `#include "afxres.h"` with
   `#include <winres.h>` if the binary does not actually use MFC. (No
   SoftEther binary truly uses MFC — they all use raw Win32.)
2. **`<binary>.vcxproj`**: ensure `<TargetName>` matches `<OutputFile>`
   for each `$(Configuration)|$(Platform)` you intend to build. For
   example, if `<OutputFile>` is `vpnclient_x64.exe`, add
   `<TargetName>vpnclient_x64</TargetName>` to the matching
   `<PropertyGroup>`.

The legacy CRT symbols (`__iob_func`, `_vsnprintf`, etc.) are resolved
automatically because every binary links `Mayaqua.lib`.

Additionally, expect to surface during compile/link:

- A Windows SDK header that worked transitively no longer does (add
  the explicit `#include`)
- A deprecated CRT function (`strcpy`, `gets`, etc.) needing `_s`
  variant or `_CRT_SECURE_NO_WARNINGS`
- 32-bit pointer truncation warnings (C4311 / C4312) — typically
  harmless on x64, can be left as warnings
- `BuildUtil /CMD:...` pre/post-build event failures when
  `$(TargetPath)` does not resolve to the real output file

Keep updating the status table at the top of this file as binaries
are validated.

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

**Fix:** This is already handled centrally by
`src/Mayaqua/legacy_crt_shim.c` (compiled into `Mayaqua.lib`). If you see
this error, verify:

- The binary's `.vcxproj` actually has a `<ProjectReference>` to
  `Mayaqua.vcxproj`. Without it, the shim is not linked in.
- The Mayaqua build picked up `legacy_crt_shim.c` (`<ClCompile Include="legacy_crt_shim.c" />` in `Mayaqua.vcxproj`).
- The MSVC `legacy_stdio_definitions.lib` is discoverable via the
  current `LIB` env (set automatically by `vswhere`-resolved MSBuild).

The proper long-term fix is to **rebuild OpenSSL with VS2026** and replace
the binaries in `src/BuildFiles/Library/{Win32,x64}_{Debug,Release}/`. Once
that is done, remove `legacy_crt_shim.c` from `Mayaqua.vcxproj`.

### 5.3 `cannot open include file 'afxres.h'`

**Cause:** Resource script references the MFC `afxres.h` header. SoftEther
binaries do not actually use MFC; this include is template boilerplate left
over from old Visual Studio resource editors.

**Fix:** Replace with `#include <winres.h>` (the lightweight subset that
only pulls in the resource constants `.rc` scripts actually need). This is
the same patch that was applied to `vpncmd.rc`.

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
