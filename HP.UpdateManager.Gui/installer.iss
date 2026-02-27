#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppName=CentralHPUpdater
AppVersion={#AppVersion}
DefaultDirName={pf}\CentralHPUpdater
DefaultGroupName=CentralHPUpdater
OutputBaseFilename=CentralHPUpdaterInstaller
Compression=lzma
SolidCompression=yes
OutputDir=Output

[Files]
Source: "..\scripts\securepaq-web-server.exe"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\scripts\public\*"; DestDir: "{app}\scripts\public"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\Modules\*"; DestDir: "{app}\Modules"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\CentralHPUpdater"; Filename: "{app}\scripts\securepaq-web-server.exe"
Name: "{commondesktop}\CentralHPUpdater"; Filename: "{app}\scripts\securepaq-web-server.exe"

[Run]
Filename: "{app}\scripts\securepaq-web-server.exe"; Description: "Launch CentralHPUpdater (Web Server)"; Flags: postinstall nowait
