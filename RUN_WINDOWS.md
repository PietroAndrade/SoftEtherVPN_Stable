# Running the built SoftEther VPN client on Windows

This document covers **how to deploy and use** the desktop-client binaries
produced by this fork on a Windows 10 / 11 machine. For *building* them,
see [`BUILD_WINDOWS.md`](BUILD_WINDOWS.md).

The three binaries needed for a working VPN client are:

| Binary | Role |
|---|---|
| `vpnclient_x64.exe` | The user-mode client engine. Talks to the Neo6 virtual NIC, brokers the VPN tunnel, holds the connection profile DB. Normally runs as a Windows service named **SEVPNCLIENT**; for testing we run it in foreground "test" mode instead. |
| `vpncmd_x64.exe` | Command-line management tool. Connects to a running `vpnclient_x64.exe` (or `vpnserver`/`vpnbridge`) on the local or a remote machine. |
| `vpncmgr_x64.exe` | GUI client manager. Same job as `vpncmd` but with a Windows UI. Auto-detects a local `vpnclient` on launch. |

Plus the **Neo6 virtual NIC driver**, which is what actually creates a
network adapter visible to Windows so traffic can be routed through it.
Pre-signed `.sys` / `.cat` / `.inf` ship in the repo under
`src/bin/hamcore/DriverPackages/Neo6_Win10/`.

---

## Quick install (run-in-place, user folder)

This is the *non-destructive* path: binaries land in your user profile,
no Windows service registered, only the driver gets system-wide (which is
unavoidable — driver staging always requires admin).

From a regular PowerShell prompt at the repo root:

```powershell
# Copy binaries to %USERPROFILE%\SoftEtherVPN\ and stage the Neo6 driver
.\ci\install-local.ps1 -InstallDriver
```

The script will prompt for UAC elevation because driver staging via
`pnputil /add-driver /install` requires administrator rights. The file
copy itself does not need admin and lands in your user profile.

Flags worth knowing:

- `-DestinationPath <path>` — install somewhere other than
  `%USERPROFILE%\SoftEtherVPN\` (e.g. `C:\sevpn\` for a shorter path).
- *(no `-InstallDriver`)* — just copy the binaries, skip driver staging.
  Useful for a UI smoke test where you don't actually need to create a
  virtual NIC.
- `-Force` — overwrite existing files in the destination even if a hash
  comparison says they differ.

After it finishes, you'll have:

```
%USERPROFILE%\SoftEtherVPN\
├── vpnclient_x64.exe
├── vpncmd_x64.exe
├── vpncmgr_x64.exe
├── hamcore\                   # runtime data: language tables, certs, infs
├── run-vpnclient-test.cmd     # launches vpnclient in foreground /test mode
├── run-vpncmgr.cmd            # launches the GUI manager
└── run-vpncmd.cmd             # opens vpncmd against localhost
```

---

## First-run walkthrough

### 1. Start the client engine

Double-click **`run-vpnclient-test.cmd`** (or run it from a terminal).
A console window will open and print the SoftEther banner; leave it
running. This is `vpnclient_x64.exe /test` — interactive, foreground,
no service registration. Close it with **Ctrl-C** when done.

> *Why not the service?* In service mode (the SoftEther default) you'd
> need to register `vpnclient_x64.exe /install` as Administrator, which
> writes to `HKLM\SYSTEM\CurrentControlSet\Services` and persists across
> reboots. Test mode keeps everything ephemeral.

### 2. Connect a management tool

Open a second window. To use the **GUI**:

```cmd
%USERPROFILE%\SoftEtherVPN\run-vpncmgr.cmd
```

To use the **CLI**:

```cmd
%USERPROFILE%\SoftEtherVPN\run-vpncmd.cmd
```

Both auto-target the running `vpnclient` on localhost.

### 3. Create a virtual NIC

In `vpncmd`:

```
VPN Client> NicCreate VPN
```

(or use the *Virtual Network Adapter* menu in `vpncmgr`). This is the
step that needs the Neo6 driver to already be in the driver store —
that's what `install-local.ps1 -InstallDriver` did. Without driver
staging, NicCreate will pop a UAC prompt and ask Windows to install
the driver on the fly, which often fails on Win11 24H2+ for reasons
explained below.

After NicCreate, a new adapter named **"VPN Client Adapter - VPN"** will
appear in `ncpa.cpl` (Network Connections).

### 4. Create a connection profile and connect

```
VPN Client> AccountCreate myvpn /SERVER:vpn.example.com:443 /HUB:DEFAULT /USERNAME:alice /NICNAME:VPN
VPN Client> AccountPasswordSet myvpn /PASSWORD:secret /TYPE:standard
VPN Client> AccountConnect myvpn
```

Then check status with `AccountList` or look at the GUI tray icon.

---

## Caveats and pitfalls

### `PenCore.dll not found. SoftEther VPN couldn't start.`

`PenCore.dll` is a resource-only DLL that holds the icons, bitmaps and
splash images the GUI / `vpnclient` reference at startup via
`MsLoadLibrary("|PenCore.dll")`. It is built from a **separate MSBuild
target** (`src\PenCore\PenCore.vcxproj`) and lands at
`src\bin\hamcore\PenCore.dll`. The `install-local.ps1` script then
copies the entire `hamcore\` tree (including PenCore.dll) into the
install destination.

If you skipped that build step, `vpnclient_x64.exe` and `vpncmgr_x64.exe`
will pop up a dialog like:

> `|PenCore.dll not found. SoftEther VPN couldn't start. Please reinstall all files with SoftEther VPN Installer.`

Fix it:

```powershell
.\ci\build-binary.ps1 -Target PenCore
.\ci\install-local.ps1 -Force          # re-copies hamcore\ including the new DLL
```

The installer also warns up-front if `src\bin\hamcore\PenCore.dll` is
missing in pre-flight, so you should see this coming. `PenCore` was
added to `build-binary.ps1`'s `-Target` whitelist alongside the desktop
trio.

### Windows 11 24H2+ Memory Integrity blocks the Neo6 driver

The Neo6 driver in this repo is signed with the upstream SoftEther
certificate chain, which uses an older signing posture that **HVCI**
(Hypervisor-protected Code Integrity, aka *Memory Integrity*) refuses
to load by default on Win11 24H2 and later. Symptoms:

- `pnputil /add-driver /install` returns success but
  `pnputil /enum-devices` shows the Neo6 device as **Code 39** or **52**.
- NicCreate fails with "Failed to install or load the driver."

**Workaround** (until a fresh WHQL signing is in place):

1. Open *Settings* → *Privacy & security* → *Windows Security* →
   *Device security* → *Core isolation details*.
2. Turn off **Memory integrity**.
3. Reboot.
4. Re-run `.\ci\install-local.ps1 -InstallDriver`.

This is the same mitigation noted in `CLAUDE.md`'s "Known pitfalls"
section. A long-term fix requires re-signing the kernel driver with an
EV cert and going through Microsoft's hardware attestation portal.

### Binaries are not Authenticode-signed

The three `.exe` files are unsigned. SmartScreen will warn on first
launch ("Windows protected your PC"). Click *More info* → *Run anyway*.
For real distribution you'd want an Authenticode certificate on the
binaries themselves (the kernel driver is a separate signing problem,
addressed above).

### `vpnclient /test` does not survive logout

Foreground test mode dies when its console host process exits. For a
persistent setup (auto-start at boot, runs without anyone being logged
in), you'd register the service:

```powershell
# Administrator required
Start-Process -Verb RunAs -FilePath "$env:USERPROFILE\SoftEtherVPN\vpnclient_x64.exe" -ArgumentList '/install'
```

To remove later:

```powershell
Start-Process -Verb RunAs -FilePath "$env:USERPROFILE\SoftEtherVPN\vpnclient_x64.exe" -ArgumentList '/uninstall'
```

This writes to `HKLM` and is a system change, so it's deliberately not
part of `install-local.ps1`.

### `hamcore.se2` is not generated by individual binary builds

Production SoftEther releases pack all the runtime data files
(`lang.config`, `root_certs.dat`, the .inf templates, etc.) into a
single archive called `hamcore.se2`. The desktop binaries fall back to
reading the *unpacked* `hamcore\` directory when no `.se2` is present,
which is exactly what `install-local.ps1` ships. Functionally
equivalent, just a few thousand small files instead of one ~4 MB blob.

---

## Uninstall

Most of the install is contained:

```powershell
Remove-Item -Recurse -Force "$env:USERPROFILE\SoftEtherVPN"
```

Removes the binaries, hamcore data, profile DB (`vpn_client.config`),
and launchers.

The Neo6 driver, if you staged it, stays in the Windows driver store.
To remove that:

```powershell
# Find the oemNN.inf alias Windows assigned to Neo6
pnputil /enum-drivers | Select-String -Pattern 'Neo6_x64_VPN' -Context 2,2

# Delete by alias (replace oem42.inf with whatever you found above)
pnputil /delete-driver oem42.inf /uninstall /force
```

If you ran NicCreate, also delete the virtual adapter:

```
VPN Client> NicDelete VPN
```

before deleting the driver.

---

## When in doubt

- The build side is documented in [`BUILD_WINDOWS.md`](BUILD_WINDOWS.md).
- The installer script is `ci\install-local.ps1` — its `.SYNOPSIS` /
  `.DESCRIPTION` block (run `Get-Help .\ci\install-local.ps1 -Detailed`)
  is a reasonable second source of truth if this file gets stale.
- For `vpncmd` / `vpncmgr` usage beyond first-connection, the upstream
  SoftEther docs at <https://www.softether.org/4-docs/1-manual> still
  apply — none of the modernization patches change the CLI surface.
