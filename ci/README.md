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
