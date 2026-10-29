; BahaiResearch Inno Setup Script
;
; The {app} payload is built on Linux by tools/package-windows-payload.sh and published as
; the release asset BahaiResearch-win-payload-<version>.zip.
;
; On Windows both steps are handled by one command:
;   tools\release-windows.bat 1.6.0
;
; To compile by hand:
;   ISCC.exe /DMyAppVersion=1.6.0 BahaiResearch.iss

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#ifndef MyAppSourceDir
  #define MyAppSourceDir "dist\installer\BahaiResearch"
#endif

#define MyAppName "BahaiResearch"
#define MyJavaExe "runtime\bin\javaw.exe"
#define MyIconFile "assets\BahaiResearch.ico"
#define MyAppIconName "BahaiResearch.ico"

; Launch arguments use absolute {app} paths so the app works regardless of the working
; directory. They are written inline instead of via a #define: a define is expanded before
; section parsing, so its quotes would terminate the value; inside a section "" is one quote.

[Setup]
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=BahaiResearch
AppComments=Baha'i scripture research tool
SetupIconFile={#MyIconFile}
DefaultDirName={localappdata}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=dist\installer-output
OutputBaseFilename=BahaiResearch-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppIconName}

[Files]
Source: "{#MyAppSourceDir}\*"; DestDir: "{app}"; Excludes: "VERSION"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#MyIconFile}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyJavaExe}"; Parameters: "-Dbahai.keyPath=""{app}\app\bahai-research.properties"" -Dbahai.corpusPath=""{app}\app\data\corpus"" -jar ""{app}\app\BahaiResearch-all.jar"""; WorkingDir: "{app}"; IconFilename: "{app}\{#MyAppIconName}"
Name: "{userdesktop}\{#MyAppName}"; Filename: "{app}\{#MyJavaExe}"; Parameters: "-Dbahai.keyPath=""{app}\app\bahai-research.properties"" -Dbahai.corpusPath=""{app}\app\data\corpus"" -jar ""{app}\app\BahaiResearch-all.jar"""; WorkingDir: "{app}"; IconFilename: "{app}\{#MyAppIconName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"

[InstallDelete]
; Clean up old JAR files so only the new one remains
Type: files; Name: "{app}\app\*.jar"
Type: files; Name: "{app}\app\BahaiResearch.cfg"
; Launcher produced by jpackage in 1.5.0 and earlier; the app now runs from runtime\bin\javaw.exe
Type: files; Name: "{app}\BahaiResearch.exe"
; Clean up the SQLite database so the new version regenerates it with new sources
Type: files; Name: "{app}\app\data\corpus\corpus.db"

[UninstallDelete]
Type: filesandordirs; Name: "{app}\app\data\corpus"

[Run]
Filename: "{app}\{#MyJavaExe}"; Parameters: "-Dbahai.keyPath=""{app}\app\bahai-research.properties"" -Dbahai.corpusPath=""{app}\app\data\corpus"" -jar ""{app}\app\BahaiResearch-all.jar"""; WorkingDir: "{app}"; Description: "Launch {#MyAppName} now"; Flags: nowait postinstall skipifsilent
