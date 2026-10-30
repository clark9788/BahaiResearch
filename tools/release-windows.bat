@echo off
setlocal

REM Compile the Windows installer from a payload built on Linux.
REM
REM The payload (app\, runtime\, VERSION) is built on Linux by
REM tools/package-windows-payload.sh. Nothing is compiled here.
REM
REM The payload is located in this order:
REM   1) second argument, a path to the zip
REM   2) PAYLOAD_ZIP environment variable
REM   3) dist\BahaiResearch-win-payload-<version>.zip
REM   4) download from the matching GitHub release asset
REM
REM Usage: tools\release-windows.bat <version> [payload-zip]
REM   tools\release-windows.bat 1.5.0
REM   tools\release-windows.bat 1.5.0 X:\BahaiResearch-win-payload-1.5.0.zip

set "VERSION=%~1"
if "%VERSION%"=="" (
  echo Usage: tools\release-windows.bat ^<version^> [payload-zip]
  echo   e.g. tools\release-windows.bat 1.5.0
  echo        tools\release-windows.bat 1.5.0 X:\BahaiResearch-win-payload-1.5.0.zip
  exit /b 1
)

set "REPO=clark9788/BahaiResearch"
REM Resolve to a canonical absolute path: Inno resolves relative Source/SetupIconFile paths
REM against the script's directory, so no ".." may remain in the path handed to ISCC.
pushd "%~dp0.." >nul
set "ROOT=%CD%"
popd
set "ZIP=%ROOT%\dist\BahaiResearch-win-payload-%VERSION%.zip"
set "STAGE=%ROOT%\dist\installer"
set "URL=https://github.com/%REPO%/releases/download/v%VERSION%/BahaiResearch-win-payload-%VERSION%.zip"

REM An explicit path wins over the dist copy and over the release asset
if not "%~2"=="" set "PAYLOAD_SRC=%~2"
if not defined PAYLOAD_SRC if defined PAYLOAD_ZIP set "PAYLOAD_SRC=%PAYLOAD_ZIP%"
if defined PAYLOAD_SRC (
  if not exist "%PAYLOAD_SRC%" (
    echo ERROR: payload not found: %PAYLOAD_SRC%
    exit /b 1
  )
  set "ZIP=%PAYLOAD_SRC%"
)

if not exist "%ZIP%" (
  echo [1/4] Downloading payload %VERSION% ...
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Invoke-WebRequest -UseBasicParsing -Uri '%URL%' -OutFile '%ZIP%'"
  if errorlevel 1 (
    echo ERROR: no payload found and the release asset could not be downloaded.
    echo        Either copy the zip onto this machine and pass its path:
    echo          tools\release-windows.bat %VERSION% X:\BahaiResearch-win-payload-%VERSION%.zip
    echo        or place it here and re-run:
    echo          %ROOT%\dist\BahaiResearch-win-payload-%VERSION%.zip
    echo        Build it on Linux with tools/package-windows-payload.sh.
    exit /b 1
  )
) else (
  echo [1/4] Using payload: %ZIP%
  for %%F in ("%ZIP%") do echo        %%~zF bytes, modified %%~tF
  if not defined PAYLOAD_SRC echo        ^(delete it to download fresh from the release asset^)
)

echo [2/4] Extracting to %STAGE% ...
if exist "%STAGE%\BahaiResearch" rmdir /s /q "%STAGE%\BahaiResearch"
if not exist "%STAGE%" mkdir "%STAGE%"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Expand-Archive -Force -LiteralPath '%ZIP%' -DestinationPath '%STAGE%'"
if errorlevel 1 (
  echo ERROR: extraction failed.
  exit /b 1
)
if not exist "%STAGE%\BahaiResearch\VERSION" (
  echo ERROR: payload is incomplete: %STAGE%\BahaiResearch\VERSION is missing.
  exit /b 1
)
set /p PAYLOAD_VERSION=<"%STAGE%\BahaiResearch\VERSION"
if not "%PAYLOAD_VERSION%"=="%VERSION%" (
  echo ERROR: payload VERSION is %PAYLOAD_VERSION% but %VERSION% was requested.
  exit /b 1
)

echo [3/4] Locating Inno Setup compiler ...
REM Inno Setup is not put on PATH. Its install drive is not assumed to be C:, so probe the
REM explicit override, then the uninstall registry entry, then the usual folders on C:-F:.
set "ISCC="
if defined INNO_ISCC if exist "%INNO_ISCC%" set "ISCC=%INNO_ISCC%"
if not defined ISCC call :probe_registry
if not defined ISCC call :probe_common_dirs
if not defined ISCC call :probe_drives
if not defined ISCC call :probe_path
if not defined ISCC (
  echo ERROR: ISCC.exe not found. Inno Setup 6 is required.
  echo        Searched INNO_ISCC, the Inno Setup uninstall registry entry,
  echo        Program Files on drives C: to F:, and PATH.
  echo        Set the full path and re-run, for example:
  echo          set "INNO_ISCC=D:\Program Files ^(x86^)\Inno Setup 6\ISCC.exe"
  exit /b 1
)
echo        Using %ISCC%

echo [4/4] Compiling installer %VERSION% ...
"%ISCC%" /DMyAppVersion=%VERSION% "%ROOT%\BahaiResearch.iss"
if errorlevel 1 (
  echo ERROR: Inno Setup compile failed.
  exit /b 1
)

echo.
echo Done. Installer written to %ROOT%\dist\installer-output
echo Upload BahaiResearch-Setup.exe to the v%VERSION% release.
exit /b 0

:probe_registry
for %%K in (
  "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1"
  "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1"
  "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1"
) do if not defined ISCC call :try_registry_key %%K
exit /b 0

:try_registry_key
set "_dir="
for /f "tokens=2,*" %%A in ('reg query %1 /v InstallLocation 2^>nul ^| find "InstallLocation"') do set "_dir=%%B"
if not defined _dir exit /b 0
if "%_dir:~-1%"=="\" set "_dir=%_dir:~0,-1%"
if exist "%_dir%\ISCC.exe" set "ISCC=%_dir%\ISCC.exe"
exit /b 0

:probe_common_dirs
set "_pf86=%ProgramFiles(x86)%"
set "_pf=%ProgramFiles%"
for %%D in ("%_pf86%" "%_pf%") do (
  if not defined ISCC if exist "%%~D\Inno Setup 6\ISCC.exe" set "ISCC=%%~D\Inno Setup 6\ISCC.exe"
)
exit /b 0

:probe_drives
for %%L in (C D E F) do (
  if not defined ISCC if exist "%%L:\Program Files (x86)\Inno Setup 6\ISCC.exe" set "ISCC=%%L:\Program Files (x86)\Inno Setup 6\ISCC.exe"
  if not defined ISCC if exist "%%L:\Program Files\Inno Setup 6\ISCC.exe" set "ISCC=%%L:\Program Files\Inno Setup 6\ISCC.exe"
)
exit /b 0

:probe_path
for /f "delims=" %%P in ('where ISCC.exe 2^>nul') do if not defined ISCC set "ISCC=%%P"
exit /b 0
