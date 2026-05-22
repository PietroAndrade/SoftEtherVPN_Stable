; ---------------------------------------------------------------------------
;  Inno Setup script for the SoftEther VPN desktop client (VS2026 fork).
;
;  Produces a single, self-contained setup.exe that bundles the three
;  desktop-client binaries plus the entire hamcore\ runtime tree.
;
;  Per-user install: PrivilegesRequired=lowest, so the wizard does NOT prompt
;  for admin. The ONLY step that elevates is the optional Neo6 driver staging
;  (install-driver.cmd self-elevates via UAC when chosen).
;
;  Build it with ci\build-inno.ps1 (locates ISCC and passes the /D defines),
;  or directly:
;      ISCC.exe installer\SoftEtherVPN.iss
; ---------------------------------------------------------------------------

#define MyAppName "SoftEther VPN Client"
#ifndef MyAppVersion
  #define MyAppVersion "4.44.9807"
#endif
#define MyAppPublisher "SoftEther VPN Project (VS2026 fork)"
#define MyAppURL "https://github.com/SoftEtherVPN/SoftEtherVPN_Stable"

; Paths. ci\build-inno.ps1 passes absolute values via /D; the fallbacks below
; assume this .iss lives in <repo>\installer\ and is compiled from there.
#ifndef SourceBin
  #define SourceBin "..\src\bin"
#endif
#ifndef InstallerSrc
  #define InstallerSrc "."
#endif
#ifndef OutDir
  #define OutDir "..\dist"
#endif

[Setup]
AppId={{763A1592-40E6-4CBF-9AA4-110C812FE03D}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
DefaultDirName={localappdata}\Programs\SoftEtherVPN
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
OutputDir={#OutDir}
OutputBaseFilename=SoftEtherVPN-Client-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ChangesEnvironment=yes
UninstallDisplayIcon={app}\vpncmgr_x64.exe
UninstallDisplayName={#MyAppName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "addtopath"; Description: "Add the install folder to my PATH (so 'vpncmd' works in any terminal)"

[Files]
Source: "{#SourceBin}\vpncmd_x64.exe";          DestDir: "{app}";          Flags: ignoreversion
Source: "{#SourceBin}\vpnclient_x64.exe";       DestDir: "{app}";          Flags: ignoreversion
Source: "{#SourceBin}\vpncmgr_x64.exe";         DestDir: "{app}";          Flags: ignoreversion
Source: "{#SourceBin}\hamcore\*";               DestDir: "{app}\hamcore";  Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#InstallerSrc}\vpncmd.cmd";           DestDir: "{app}";          Flags: ignoreversion
Source: "{#InstallerSrc}\install-driver.cmd";   DestDir: "{app}";          Flags: ignoreversion

[Icons]
Name: "{group}\Start VPN Client (Usermode)"; Filename: "{app}\vpnclient_x64.exe"; Parameters: "/usermode"; WorkingDir: "{app}"; Comment: "Start the SoftEther VPN client engine (tray icon, no admin)"
Name: "{group}\VPN Client Manager"; Filename: "{app}\vpncmgr_x64.exe"; WorkingDir: "{app}"; Comment: "Create connections and connect (start the client engine first)"
Name: "{group}\Install Neo6 Driver (Admin)"; Filename: "{app}\install-driver.cmd"; WorkingDir: "{app}"; IconFilename: "{app}\vpncmgr_x64.exe"; Comment: "Stage the Neo6 virtual-NIC driver (prompts for administrator)"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{userdesktop}\VPN Client Manager"; Filename: "{app}\vpncmgr_x64.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Registry]
; Append {app} to the *user* PATH (HKCU) only if it isn't already there.
Root: HKCU; Subkey: "Environment"; ValueType: expandsz; ValueName: "Path"; ValueData: "{olddata};{app}"; Flags: preservestringtype; Tasks: addtopath; Check: NeedsAddPath(ExpandConstant('{app}'))

[Run]
Filename: "{app}\vpnclient_x64.exe"; Parameters: "/usermode"; Description: "Start the VPN client now (tray icon)"; Flags: postinstall nowait skipifsilent
Filename: "{app}\install-driver.cmd"; Description: "Stage the Neo6 virtual-NIC driver now (requires administrator)"; Flags: postinstall shellexec skipifsilent unchecked

[Code]
function NeedsAddPath(Param: string): boolean;
var
  OrigPath: string;
begin
  if not RegQueryStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', OrigPath) then
  begin
    Result := True;
    exit;
  end;
  { True only when ;Param; is not already inside ;Path; }
  Result := Pos(';' + Uppercase(Param) + ';', ';' + Uppercase(OrigPath) + ';') = 0;
end;

procedure RemovePath(Param: string);
var
  OrigPath: string;
  NewPath: string;
  P: Integer;
begin
  if not RegQueryStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', OrigPath) then
    exit;
  NewPath := ';' + OrigPath + ';';
  P := Pos(';' + Uppercase(Param) + ';', Uppercase(NewPath));
  if P = 0 then
    exit;
  { remove ';Param', leaving the trailing ';' that joined the next entry }
  Delete(NewPath, P, Length(Param) + 1);
  { strip the leading + trailing sentinel ';' we wrapped the value with }
  NewPath := Copy(NewPath, 2, Length(NewPath) - 2);
  RegWriteExpandStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', NewPath);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RemovePath(ExpandConstant('{app}'));
end;
