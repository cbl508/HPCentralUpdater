#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppName=SecurePaq Central Manager
AppVersion={#AppVersion}
DefaultDirName={pf}\SecurePaqCentralManager
DefaultGroupName=SecurePaq Central Manager
OutputBaseFilename=SecurePaqCentralManagerInstaller
Compression=lzma
SolidCompression=yes
OutputDir=Output

[Files]
Source: "securepaq-web-server.exe"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "public\*"; DestDir: "{app}\scripts\public"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\Modules\*"; DestDir: "{app}\Modules"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\SecurePaq Central Manager"; Filename: "{app}\scripts\securepaq-web-server.exe"; IconFilename: "{app}\scripts\securepaq-web-server.exe"
Name: "{commondesktop}\SecurePaq Central Manager"; Filename: "{app}\scripts\securepaq-web-server.exe"; IconFilename: "{app}\scripts\securepaq-web-server.exe"

[Run]
Filename: "{app}\scripts\securepaq-web-server.exe"; Description: "Launch SecurePaq Central Manager"; Flags: postinstall nowait
