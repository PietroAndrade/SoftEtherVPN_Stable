# CLAUDE.md

Context for Claude / AI assistants working in this repository. Read this
first before answering questions about the build, troubleshooting issues,
or making changes.

## What this repo is

A **fork of SoftEther VPN Stable** (https://github.com/SoftEtherVPN/SoftEtherVPN_Stable),
**modernized to build with Visual Studio 2026 on Windows 11** instead of
the original Visual Studio 2008 SP1 + Windows SDK 6.0A + WDK 7.1 toolchain.

The upstream `BUILD_WINDOWS.TXT` instructions (still present, marked
deprecated) assume the VS2008-era toolchain. The current working build
process is documented in [`BUILD_WINDOWS.md`](BUILD_WINDOWS.md) — that
file is the source of truth for the Windows build.

## Quick orientation

- **Source root:** `src/` (this is where the .sln and project dirs live)
- **Solution file:** `src/SEVPN.sln` (already migrated to VS Format 12.00, "Visual Studio Version 18")
- **Projects:** all `.vcxproj` files target `<PlatformToolset>v145</PlatformToolset>` (VS2026)
- **Build tooling:** `src/BuildUtil/` is a small C# .NET Framework 4.8 program that orchestrates the official build pipeline and generates per-binary version resources via PreLinkEvent
- **CI scripts:** `ci/build-binary.ps1` (generic), `ci/build-desktop-client.ps1` (orchestrator), `ci/README.md` (yaml templates)
- **Pre-built artifacts shipped in repo:**
  - `src/BuildFiles/Library/{Win32,x64}_{Debug,Release}/{libeay32,ssleay32,zlib,libintelaes}.lib` — OpenSSL, zlib, Intel AES-NI built against legacy CRT
  - `src/bin/hamcore/DriverPackages/` — pre-signed `.sys`/`.cat` for Neo, Neo6, SeLow (no WDK required to redistribute)

## Build status (last verified May 2026)

| Binary | Type | Status |
|---|---|---|
| `BuildUtil` | C# exe | Builds (.NET 4.8) |
| `Mayaqua` | static lib | Builds |
| `Cedar` | static lib | Builds |
| `vpncmd` | CLI exe | **Builds + runs** (`vpncmd_x64.exe`) |
| `vpnclient` | service exe | **Builds + runs** (`vpnclient_x64.exe`) |
| `vpncmgr` | GUI exe | **Builds + runs** (`vpncmgr_x64.exe`) |
| `VGate` | user-mode DLL | Builds (transitive dep) |
| `vpnserver` / `vpnbridge` / `vpnsmgr` | exe | **Pending** — same 2-step recipe applies |
| `vpncmdsys` / `vpnbrand` / `vpndrvinst` / `vpninstall` / `vpnsetup` | exe | Pending |
| `Ham` | exe | Pending (internal cert/NIC utility) |
| `vpnweb` | ATL OCX | Pending (legacy IE ActiveX — usually skip) |
| `PenCore` | user-mode DLL | **Builds + required at runtime**. Resource-only DLL (icons/bitmaps), lands at `src/bin/hamcore/PenCore.dll`. `vpnclient` and `vpncmgr` LoadLibrary it on start via `"\|PenCore.dll"`; if absent they pop `"PenCore.dll not found"` and exit. Build with `ci\build-binary.ps1 -Target PenCore`. |
| `Neo` / `Neo6` / `See` / `SeeDll` / `SeLow` / `Wfp` | kernel drivers | **Not built** (require WDK 7600). Pre-signed binaries ship under `src/bin/hamcore/DriverPackages/`. |

The three desktop-client binaries (`vpncmd`, `vpnclient`, `vpncmgr`) are
together sufficient to install a SoftEther VPN client on Windows.

## How to build (TL;DR)

From a regular PowerShell prompt at the repo root:

```powershell
# One binary
.\ci\build-binary.ps1 -Target vpncmd
.\ci\build-binary.ps1 -Target vpnclient
.\ci\build-binary.ps1 -Target vpncmgr

# Or the full desktop client in one shot
.\ci\build-desktop-client.ps1
```

The scripts auto-discover Visual Studio 2026 via `vswhere` and the latest
Windows 11 SDK under `C:\Program Files (x86)\Windows Kits\10\bin\`. No
manual env-var setup is required.

If you need to bypass the helpers for a one-off invocation:

```powershell
msbuild src\SEVPN.sln /t:<target> `
  /p:Configuration=Release /p:Platform=x64 `
  /p:DebugInformationFormat=None `
  /v:minimal /nologo
```

`DebugInformationFormat=None` works around a recurring `mspdbsrv.exe`
race when multiple cl.exe processes write the same PDB. Drop it once
the build directory is excluded from Windows Defender real-time scan.

## Modernization patches applied (do not revert without thinking)

These are all small, surgical, and live as normal commits on
`feature/vs2026-build-modernization`. Each has a section in
[`BUILD_WINDOWS.md`](BUILD_WINDOWS.md) explaining the rationale.

1. **`src/BuildUtil/BuildUtil.csproj`** — retargeted from `.NET Framework v2.0`
   / `ToolsVersion="3.5"` to `.NET 4.8` / `ToolsVersion="Current"`.
2. **`src/BuildUtil/VpnBuilder.cs`** — `Paths` static ctor wrapped in
   `try/catch`, falls back to env vars (`RC_EXE`, `MAKECAT_EXE`,
   `VS_VC_DIR`, `WINDOWS_SDK_DIR`, `MSBUILD_EXE`), and auto-discovers
   the latest Win10/11 SDK under `Windows Kits\10\bin\*`.
3. **`src/Cedar/Cedar.vcxproj`** — `<ProjectReference>` to `Neo6`, `PenCore`,
   `SeeDll`, `Wfp` commented out. Those projects need WDK 7600. Pre-signed
   `.sys`/`.cat` ship in `src/bin/hamcore/DriverPackages/`.
4. **`src/Mayaqua/Internat.c`** — `UniParseToken` now uses the 3-arg
   `wcstok(str, delim, &state)`. VS2026 removed the legacy 2-arg form.
5. **`src/Mayaqua/Microsoft.h`** — explicit `#include <security.h>` inside
   the `MICROSOFT_C` block. The Win11 SDK no longer pulls
   `EXTENDED_NAME_FORMAT` transitively.
6. **`src/Mayaqua/legacy_crt_shim.c`** (new) — defines `__iob_func()` over
   UCRT's `__acrt_iob_func(0|1|2)` and emits
   `#pragma comment(lib, "legacy_stdio_definitions.lib")`. Resolves the
   `_vsnprintf`/`_vsnwprintf`/`sscanf`/`__iob_func` LNK2019 errors coming
   from the pre-built OpenSSL static libs. **Compiled into `Mayaqua.lib`,
   so every binary that links Mayaqua inherits the bridge for free.**
7. **Per-binary `.rc` files** — `#include "afxres.h"` replaced with
   `#include <winres.h>` for binaries that don't actually use MFC
   (none of them do; the include was VS template boilerplate).
8. **Per-binary `.vcxproj` `<TargetName>`** — Release|x64 PropertyGroup
   carries `<TargetName>{name}_x64</TargetName>` so `$(TargetPath)`
   matches `Link.OutputFile` and `BuildUtil`'s PostBuildEvent finds
   the file.

## Repository conventions

- **Branch:** active work happens on `feature/vs2026-build-modernization`.
- **EOL:** `.gitattributes` enforces LF for Unix scripts (.sh, .mak,
  .service) and CRLF for Windows tooling (.sln, .vcxproj, .csproj, .rc,
  .manifest, .cmd, .ps1). A one-off `chore(eol): renormalize` commit
  applied this.
- **gitignore:** build artifacts under `**/x64_Release/`, `**/Win32_Release/`,
  `src/tmp/`, `src/DebugFiles/`, `src/BuildUtil/{obj,bin}/`, plus
  `src/bin/*.exe`/`*.dll`/`*.pdb` (with hamcore/, lang.config, install_src.dat,
  vpnweb.cab/ocx whitelisted as pre-existing artifacts).
- **Commits:** atomic, conventional-commit-ish prefixes (`build(...)`,
  `chore(...)`, `docs(...)`, `fix(...)`, `ci`, `refactor(...)`). Each
  patch class lives in its own commit with rationale in the body.

## Adding another binary

Most user-mode binaries follow the same 2-step recipe documented in
§4 of [BUILD_WINDOWS.md](BUILD_WINDOWS.md):

1. `src/<binary>/<binary>.rc`: replace `#include "afxres.h"` with `#include <winres.h>`.
2. `src/<binary>/<binary>.vcxproj` Release|x64 `<PropertyGroup>`: add
   `<TargetName><binary>_x64</TargetName>`.

Then `.\ci\build-binary.ps1 -Target <binary>`. The `-Target` parameter's
`[ValidateSet]` already includes the standard SoftEther binary names.

If you hit a new error, it's almost always one of:

- **`fatal error RC1015: cannot open afxres.h`** — apply step 1 above.
- **`error MSB3073: BuildUtil /CMD:SetManifest ... exited with code 1`** —
  apply step 2 above.
- **`error C2122: 'TYPE': invalid prototype parameter name list`** — a
  type used by the binary is no longer pulled in transitively by the
  Win11 SDK. Add the explicit `#include <appropriate_header.h>`. Common
  cases: `<security.h>` (SSPI), `<wininet.h>`, `<wincrypt.h>`.
- **`error C2198: 'wcstok'`** — same C11 3-arg fix as Mayaqua/Internat.c.
- **`error C1090: PDB API call failed`** — `mspdbsrv` race. Use
  `/p:DebugInformationFormat=None` for the build or add a Defender
  exclusion for the repo path.

## Known pitfalls

- **Don't manipulate the git index from WSL/Linux mounts** — the file
  permission mode `-rwx------` that Windows files inherit confuses
  `git add --renormalize` and corrupts `.git/index`. Run git commands
  from native PowerShell on Windows.
- **`hamcore.se2` is not generated** by individual `msbuild /t:<binary>`
  calls — the runtime executables fall back to reading the unpacked
  `src/bin/hamcore/` directory. For a packaged distribution you'd need
  `BuildUtil.exe /CMD:BuildHamcore` (not yet validated under VS2026).
- **Driver signing on Win11 24H2+**: HVCI / Memory Integrity may block
  the pre-signed `Neo6` driver when end-users install it. Mitigation
  is documented in [`RUN_WINDOWS.md`](RUN_WINDOWS.md) — usually means
  temporarily disabling Memory Integrity.
- **Binaries are unsigned**. SmartScreen warns on first run for any
  end-user deployment. Code-signing for production would require an
  Authenticode certificate.

## Tasks the user is working through

This is a living section — update it when major work changes.

- [x] Build environment modernization for VS2026 on Win11
- [x] `vpncmd` + `vpnclient` + `vpncmgr` desktop-client trio building
- [x] `BUILD_WINDOWS.md`, `ci/build-*.ps1` scripts, CI README
- [ ] Validate desktop client on a clean Windows VM (in progress —
  deployment / install / first-VPN-connection scenarios)
- [x] `RUN_WINDOWS.md` + `ci/install-local.ps1`: one-shot deployment to
  `%USERPROFILE%\SoftEtherVPN\`, Neo6 driver staging via pnputil,
  Memory-Integrity workaround documented, foreground-test launchers.
- [ ] `vpnserver` / `vpnbridge` / `vpnsmgr` ports if server-side use
  case becomes needed
- [ ] Rebuild OpenSSL with VS2026 to remove the legacy CRT shim
  (longer-term cleanup)

## When in doubt

- Read [`BUILD_WINDOWS.md`](BUILD_WINDOWS.md) — it has prerequisites,
  applied patches, per-binary porting checklist, troubleshooting, and
  a status table.
- Read [`ci/README.md`](ci/README.md) — it has the script usage,
  GitHub Actions YAML, Azure Pipelines YAML, and self-hosted runner
  setup notes.
- For UX/runtime questions (how to install and use the built binaries
  on a target machine), read [`RUN_WINDOWS.md`](RUN_WINDOWS.md). It
  covers the `ci/install-local.ps1` flow, the Neo6 driver / Memory
  Integrity caveat, `vpnclient /test` vs. service mode, and uninstall.
