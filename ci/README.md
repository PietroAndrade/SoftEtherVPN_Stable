# CI / Automation

Reference scripts and pipeline templates for building SoftEther VPN
binaries from this fork on Windows runners.

The build prerequisites and patch context are documented in
[`../BUILD_WINDOWS.md`](../BUILD_WINDOWS.md). This directory is only
about reproducible automation.

---

## Files

| File | Purpose |
|---|---|
| `build-binary.ps1` | Idempotent PowerShell script that builds **one** binary by name. Locates VS, SDK, sets env vars, cleans state, runs MSBuild, smoke-tests CLI binaries. Exit code 0 on success. |
| `build-desktop-client.ps1` | Orchestrator that builds the **three** desktop-client binaries (`vpncmd`, `vpnclient`, `vpncmgr`) by calling `build-binary.ps1` for each. Reports a final per-binary status table. |
| `install-local.ps1` | Deploys the built desktop-client trio to a local folder (default `%USERPROFILE%\SoftEtherVPN\`), copies `hamcore\`, writes convenience launchers, and optionally pre-stages the Neo6 virtual-NIC driver via `pnputil /add-driver` (self-elevates to admin if `-InstallDriver` is set). Non-destructive: no service registered, no Program Files write. Usage docs in [`../RUN_WINDOWS.md`](../RUN_WINDOWS.md). |
| `installer.ps1` | Full **per-user installer/uninstaller** (the app itself never needs admin). Installs to `%LOCALAPPDATA%\Programs\SoftEtherVPN\`, copies binaries + `hamcore\`, creates Start Menu + Desktop shortcuts, adds the folder to the user `PATH` (+ a `vpncmd` shim), registers an Add/Remove Programs entry, and copies itself in so `-Uninstall` is self-contained. `-InstallDriver` stages Neo6 in a single self-elevating step. Use this for a "real" install; use `install-local.ps1` for quick run-in-place dev iteration. |
| `build-inno.ps1` | Compiles `installer\SoftEtherVPN.iss` (Inno Setup) into a single self-contained `dist\SoftEtherVPN-Client-Setup.exe` that bundles the binaries + `hamcore\` and presents an install wizard. Auto-locates `ISCC.exe` (Program Files **or** winget's per-user `%LOCALAPPDATA%\Programs\Inno Setup 6\`, or the registry); `-InstallInno` installs Inno Setup via winget first. The Inno sources live in `installer\` (`SoftEtherVPN.iss`, `vpncmd.cmd`, `install-driver.cmd`). |
| `README.md` | This file. Pipeline templates and runner-setup notes. |

When new binaries (`vpnserver`, `vpnbridge`, …) are validated, just add
their name to the `-Target` whitelist at the top of `build-binary.ps1`
(it is already in the param `[ValidateSet]`) and a new orchestrator if
you want grouped builds (e.g. `build-server-host.ps1`).

---

## Local usage

From a regular PowerShell prompt at the repository root:

```powershell
# Build a single binary
.\ci\build-binary.ps1 -Target vpncmd
.\ci\build-binary.ps1 -Target vpnclient
.\ci\build-binary.ps1 -Target vpncmgr

# Or build the entire desktop client runtime in one shot
.\ci\build-desktop-client.ps1
```

You should not need to open Developer PowerShell — both scripts resolve
toolchain paths via `vswhere`. Useful flags:

```powershell
# More verbose MSBuild output
.\ci\build-binary.ps1 -Target vpnclient -Verbosity normal

# Build with PDB (slower; risk of mspdbsrv races on weaker runners)
.\ci\build-binary.ps1 -Target vpncmd -SkipPdb $false

# GUI binary — explicitly skip the /HELP smoke test
.\ci\build-binary.ps1 -Target vpncmgr -SmokeTest:$false
# (this is also the default for non-CLI binaries)

# Continue building remaining binaries even if one fails
.\ci\build-desktop-client.ps1 -ContinueOnError
```

---

## Installing the built client

There are three ways to get the binaries onto a workstation. All install
**per-user** (no admin for the app itself) and register no Windows service.

| | `install-local.ps1` | `installer.ps1` | Inno `setup.exe` |
|---|---|---|---|
| Kind | Run-in-place dev deploy | Per-user installer (script) | Per-user wizard installer |
| Hand-off | needs the repo | needs the repo | single self-contained `.exe` |
| Location | `%USERPROFILE%\SoftEtherVPN\` | `%LOCALAPPDATA%\Programs\SoftEtherVPN\` | `%LOCALAPPDATA%\Programs\SoftEtherVPN\` |
| Launchers | `run-*.cmd` files | Start Menu + Desktop shortcuts | Start Menu + Desktop shortcuts |
| PATH | not touched | adds folder + `vpncmd` shim | optional task (+ `vpncmd` shim) |
| Add/Remove Programs | no | yes (HKCU) | yes (native Inno) |
| Uninstall | delete the folder | `-Uninstall` / Settings → Apps | Settings → Apps / Start Menu |
| Neo6 driver | `-InstallDriver` (self-elevates) | `-InstallDriver` (self-elevates) | optional finish-page step (self-elevates) |
| Build tooling | none | none | Inno Setup (ISCC) |

In all three, only the Neo6 driver step touches admin (it self-elevates); the
file copy, shortcuts, PATH and registry writes stay in the user's context. On
uninstall the driver is intentionally left in the store (remove it manually
with `pnputil /delete-driver oem<n>.inf /uninstall`). The HVCI / Memory
Integrity caveat in [`../RUN_WINDOWS.md`](../RUN_WINDOWS.md) applies to NIC
creation regardless of which one you use.

### `installer.ps1` (PowerShell installer)

Run from a normal (non-admin) prompt. Pass `-ExecutionPolicy Bypass` because
the binaries are unsigned:

```powershell
# Full install incl. Neo6 driver staging (the only UAC prompt is the driver)
powershell -ExecutionPolicy Bypass -File .\ci\installer.ps1 -InstallDriver

# App only; stage the driver later via the "Install Neo6 Driver (Admin)" shortcut
powershell -ExecutionPolicy Bypass -File .\ci\installer.ps1

# Custom folder / skip shortcuts or PATH
powershell -ExecutionPolicy Bypass -File .\ci\installer.ps1 -DestinationPath C:\sevpn -NoShortcuts -NoPath

# Uninstall (also available from Settings -> Apps)
powershell -ExecutionPolicy Bypass -File .\ci\installer.ps1 -Uninstall
```

### Inno `setup.exe` (single redistributable installer)

`ci\build-inno.ps1` compiles `installer\SoftEtherVPN.iss` into
`dist\SoftEtherVPN-Client-Setup.exe` — one file that bundles the binaries +
`hamcore\` and shows a normal install wizard (EN + pt-BR). Use this to hand
the client to someone else.

```powershell
# Build the setup.exe (Inno Setup must already be installed)
powershell -ExecutionPolicy Bypass -File .\ci\build-inno.ps1

# Same, but install Inno Setup via winget first if ISCC.exe isn't found
powershell -ExecutionPolicy Bypass -File .\ci\build-inno.ps1 -InstallInno
```

The compiler (`ISCC.exe`) is auto-located in Program Files, in the per-user
`%LOCALAPPDATA%\Programs\Inno Setup 6\` (where winget installs it), or via the
registry. The produced `setup.exe` is **unsigned**, so SmartScreen warns on
first run ("More info" → "Run anyway") until it is Authenticode-signed.

---

## Runner requirements

Whichever CI provider you use, the runner must have:

- **Windows 11** (or Windows Server 2022+ with Desktop Experience, untested)
- **Visual Studio 2026 Build Tools** (or full VS) with components:
  - MSVC v143+ x86/x64 build tools
  - Windows 11 SDK 10.0.26100+
  - C++ ATL (only required for `vpnweb` — skip for desktop client)
  - .NET Framework 4.8 SDK
- **PowerShell 5.1+** (built into Windows)

Microsoft-hosted runners (`windows-latest` on GitHub Actions, `windows-2022`
on Azure DevOps) ship VS Enterprise with most components but not always
the v145 toolset. If the build fails with "PlatformToolset v145 not
found", install via the VS Installer in a setup step or use a
self-hosted runner with VS2026 pre-installed.

---

## GitHub Actions

`.github/workflows/build-desktop-client.yml`:

```yaml
name: Build SoftEther VPN desktop client

on:
  push:
    branches: [ main, master, 'feature/**' ]
  pull_request:
    branches: [ main, master ]
  workflow_dispatch:

jobs:
  build:
    runs-on: windows-latest   # or self-hosted with VS2026

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Show toolchain
        shell: pwsh
        run: |
          $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
          & $vswhere -latest -property installationPath
          & $vswhere -latest -property installationVersion

      - name: Build desktop client (vpncmd + vpnclient + vpncmgr)
        shell: pwsh
        run: .\ci\build-desktop-client.ps1

      - name: Upload binaries
        uses: actions/upload-artifact@v4
        with:
          name: softether-desktop-client-x64
          path: |
            src/bin/vpncmd_x64.exe
            src/bin/vpnclient_x64.exe
            src/bin/vpncmgr_x64.exe
          if-no-files-found: error
          retention-days: 30
```

If you prefer per-binary jobs (parallelism, faster failure):

```yaml
jobs:
  build:
    runs-on: windows-latest
    strategy:
      fail-fast: false
      matrix:
        target: [vpncmd, vpnclient, vpncmgr]
    steps:
      - uses: actions/checkout@v4
      - name: Build ${{ matrix.target }}
        shell: pwsh
        run: .\ci\build-binary.ps1 -Target ${{ matrix.target }}
      - uses: actions/upload-artifact@v4
        with:
          name: ${{ matrix.target }}-x64
          path: src/bin/${{ matrix.target }}_x64.exe
```

---

## Azure DevOps Pipelines

`azure-pipelines.yml`:

```yaml
trigger:
  branches:
    include:
      - main
      - master
      - feature/*

pool:
  vmImage: 'windows-latest'   # or self-hosted with VS2026

steps:
  - checkout: self
    fetchDepth: 1

  - task: PowerShell@2
    displayName: 'Show toolchain'
    inputs:
      targetType: inline
      pwsh: true
      script: |
        $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
        & $vswhere -latest -property installationPath
        & $vswhere -latest -property installationVersion

  - task: PowerShell@2
    displayName: 'Build desktop client'
    inputs:
      filePath: 'ci/build-desktop-client.ps1'
      pwsh: true
      failOnStderr: false   # MSBuild emits warnings on stderr legitimately

  - task: PublishPipelineArtifact@1
    displayName: 'Publish desktop client binaries'
    inputs:
      targetPath: 'src/bin'
      artifactName: 'softether-desktop-client-x64'
```

---

## Adding a new binary

When you finish porting another binary (e.g. `vpnserver`):

1. The `-Target` parameter of `build-binary.ps1` already has it in the
   validated whitelist — just call it: `.\ci\build-binary.ps1 -Target vpnserver`.
2. (Optional) Create a new orchestrator if you want grouped builds, e.g.
   `build-server-host.ps1` calling `vpnserver`, `vpnbridge`, `vpnsmgr`.
3. Add a CI YAML job/step or extend the matrix.
4. Update the status table in [`../BUILD_WINDOWS.md`](../BUILD_WINDOWS.md).

---

## Self-hosted runner setup (optional)

If hosted images are too slow or missing components, provision a
Windows 11 VM with:

```powershell
# As admin, after installing Windows 11
winget install --id Microsoft.VisualStudio.2026.Community --silent `
    --override "--add Microsoft.VisualStudio.Workload.NativeDesktop `
                --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
                --add Microsoft.VisualStudio.Component.Windows11SDK.26100 `
                --add Microsoft.VisualStudio.Component.VC.ATL `
                --add Microsoft.NetCore.Component.Runtime.8.0 `
                --add Microsoft.Net.Component.4.8.SDK `
                --quiet --norestart"

# Add Defender exclusion for build dir to avoid PDB locks
Add-MpPreference -ExclusionPath C:\actions-runner\_work
```

Then register the runner with your GitHub org / Azure DevOps project per
their documentation.
