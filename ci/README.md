# CI / Automation

Reference scripts and pipeline templates for building SoftEther VPN
binaries from this fork on Windows runners.

The build prerequisites and patch context are documented in
[`../BUILD_WINDOWS.md`](../BUILD_WINDOWS.md). This directory is only about
reproducible automation.

---

## Files

| File | Purpose |
|---|---|
| `build-vpncmd.ps1` | Idempotent PowerShell script that builds `vpncmd_x64.exe` end-to-end. Locates VS, SDK, sets env vars, cleans state, runs MSBuild, smoke-tests the output. Exit code 0 on success. |
| `README.md` | This file. Pipeline templates and runner-setup notes. |

When new binaries (`vpnserver`, `vpnclient`, …) are validated, add a
matching `build-<binary>.ps1` next to `build-vpncmd.ps1` and reference it
from the templates below.

---

## Local usage

From a regular PowerShell prompt at the repository root:

```powershell
.\ci\build-vpncmd.ps1
```

You should not need to open Developer PowerShell — the script resolves
toolchain paths via `vswhere`. Useful flags:

```powershell
# More verbose MSBuild output
.\ci\build-vpncmd.ps1 -Verbosity normal

# Build with PDB (slower; risk of mspdbsrv races on weaker runners)
.\ci\build-vpncmd.ps1 -SkipPdb $false
```

---

## Runner requirements

Whichever CI provider you use, the runner must have:

- **Windows 11** (or Windows Server 2022+ with Desktop Experience, untested)
- **Visual Studio 2026 Build Tools** (or full VS) with components:
  - MSVC v143+ x86/x64 build tools
  - Windows 11 SDK 10.0.26100+
  - C++ ATL (and C++ MFC if you intend to build GUI binaries)
  - .NET Framework 4.8 SDK
- **PowerShell 5.1+** (built into Windows)

Microsoft-hosted runners (`windows-latest` on GitHub Actions, `windows-2022`
on Azure DevOps) ship VS Enterprise with most of these components but not
necessarily the v145 toolset. If a hosted runner is missing the right MSVC
version, install via the VS Installer in a setup step, or use a
self-hosted runner with VS2026 pre-installed.

---

## GitHub Actions

`.github/workflows/build-vpncmd.yml`:

```yaml
name: Build vpncmd

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

      - name: Build vpncmd
        shell: pwsh
        run: .\ci\build-vpncmd.ps1 -Verbosity minimal

      - name: Upload binary
        uses: actions/upload-artifact@v4
        with:
          name: vpncmd-x64
          path: src/bin/vpncmd_x64.exe
          if-no-files-found: error
          retention-days: 30
```

Notes:

- `windows-latest` may need a setup step to install MSVC v145; if the build
  fails with "PlatformToolset v145 not found", add a step using
  [`microsoft/setup-msbuild`](https://github.com/microsoft/setup-msbuild)
  or invoke the Visual Studio Installer to add the right component.
- For private forks, prefer a **self-hosted runner** with VS2026 pre-baked
  to keep build times under 2 minutes.

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
      script: |
        $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
        & $vswhere -latest -property installationPath
        & $vswhere -latest -property installationVersion

  - task: PowerShell@2
    displayName: 'Build vpncmd'
    inputs:
      filePath: 'ci/build-vpncmd.ps1'
      arguments: '-Verbosity minimal'
      pwsh: true
      failOnStderr: false   # MSBuild emits warnings on stderr legitimately

  - task: PublishPipelineArtifact@1
    displayName: 'Publish vpncmd binary'
    inputs:
      targetPath: 'src/bin/vpncmd_x64.exe'
      artifactName: 'vpncmd-x64'
```

---

## Adding pipelines for new binaries

When you finish porting `vpnserver` (or any other binary):

1. Copy `build-vpncmd.ps1` to `build-vpnserver.ps1`.
2. Replace the project target name (`/t:vpncmd` → `/t:vpnserver`) and the
   expected output path (`vpncmd_x64.exe` → `vpnserver_x64.exe`).
3. Tweak the smoke-test invocation if needed (services typically don't
   support a `/HELP` flag the same way).
4. Add a new step or job in the YAML that calls the new script and uploads
   its artifact.
5. Update the status table in [`../BUILD_WINDOWS.md`](../BUILD_WINDOWS.md).

---

## Self-hosted runner setup (optional)

If hosted images are too slow or missing components, provision a Windows 11
VM with:

```powershell
# As admin, after installing Windows 11
winget install --id Microsoft.VisualStudio.2026.Community --silent `
    --override "--add Microsoft.VisualStudio.Workload.NativeDesktop `
                --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
                --add Microsoft.VisualStudio.Component.Windows11SDK.26100 `
                --add Microsoft.VisualStudio.Component.VC.ATL `
                --add Microsoft.VisualStudio.Component.VC.ATLMFC `
                --add Microsoft.NetCore.Component.Runtime.8.0 `
                --add Microsoft.Net.Component.4.8.SDK `
                --quiet --norestart"

# Add Defender exclusion for build dir to avoid PDB locks
Add-MpPreference -ExclusionPath C:\actions-runner\_work
```

Then register the runner with your GitHub org / Azure DevOps project per
their documentation.
