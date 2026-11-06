#ifndef PluginVersion
  #error PluginVersion must be supplied
#endif
#ifndef PackageArch
  #error PackageArch must be supplied (x64 or arm64)
#endif
#ifndef StageDir
  #error StageDir must be supplied
#endif
#ifndef OutputDir
  #define OutputDir "..\release"
#endif
[Setup]
AppId={{B3B9F4C4-5D0E-4C1D-9A55-6A0C8B3A2F71}
AppName=Optimized Previews for OBS Studio
AppVersion={#PluginVersion}
AppVerName=Optimized Previews for OBS Studio v{#PluginVersion}
UninstallDisplayName=Optimized Previews for OBS Studio v{#PluginVersion}
VersionInfoVersion={#PluginVersion}.0
VersionInfoProductVersion={#PluginVersion}
VersionInfoProductTextVersion=v{#PluginVersion}
AppPublisher=Alekstyle
DefaultDirName={commonappdata}\obs-studio\plugins
DisableProgramGroupPage=yes
DisableDirPage=no
LicenseFile=..\LICENSE
OutputDir={#OutputDir}
OutputBaseFilename=obs-optimized-previews_{#PluginVersion}_windows-{#PackageArch}
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=admin
UninstallFilesDir={app}\obs-optimized-previews\uninstall
CloseApplications=yes
CloseApplicationsFilter=obs64.exe,obs-arm64.exe
RestartApplications=no
#if PackageArch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
[Files]
Source: "{#StageDir}\obs-optimized-previews\*"; DestDir: "{app}\obs-optimized-previews"; Flags: ignoreversion recursesubdirs createallsubdirs
[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
