; Inno Setup script for NormalSwitcher (Windows).
; Packages the self-contained single-file exe into a per-user installer with a Start-Menu
; shortcut and an uninstaller. Autostart is handled by the app itself (Settings → "Launch at
; startup"), so the installer does not add a Run key. Compiled by the windows-release CI (ISCC).
;
; Expected defines (passed by CI with /D...):
;   MyAppVersion  — e.g. 0.1.0
;   SourceExe     — path to the published NormalSwitcher.exe
; Falls back to sensible defaults for a local compile.

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#ifndef SourceExe
  #define SourceExe "..\src\RuSwitcher.Win\bin\Release\net8.0-windows\win-x64\publish\NormalSwitcher.exe"
#endif

#define MyAppName "NormalSwitcher"
#define MyAppPublisher "NormalSwitcher"
#define MyAppURL "https://github.com/antonjas/NormalSwitcher"
#define MyAppExeName "NormalSwitcher.exe"

[Setup]
; A stable AppId ties upgrades/uninstalls together across versions — never change it.
AppId={{D729A5A6-DE1C-5068-A3B9-97BED831D11B}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\{#MyAppName}
DisableProgramGroupPage=yes
; Per-user install → no UAC elevation needed (matches a menu-bar utility's footprint).
PrivilegesRequired=lowest
OutputDir=dist
OutputBaseFilename=NormalSwitcher-Setup-{#MyAppVersion}
SetupIconFile=..\src\RuSwitcher.Win\NormalSwitcher.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Files]
Source: "{#SourceExe}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
Filename: "{app}\{#MyAppExeName}"; Flags: nowait skipifnotsilent; Check: IsAppUpdate

[Code]
function IsAppUpdate: Boolean;
begin
  Result := ExpandConstant('{param:NORMALSWITCHERUPDATE|0}') = '1';
end;
