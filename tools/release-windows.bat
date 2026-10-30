@echo off
setlocal

REM Compile the Windows installer from a payload built on Linux.
REM
REM The payload (app\, runtime\, VERSION) is downloaded from the GitHub release
REM asset BahaiResearch-win-payload-<version>.zip, produced on Linux by
REM tools/package-windows-payload.sh. Nothing is compiled here.
REM
REM Usage: tools\release-windows.bat <version>      e.g. tools\release-windows.bat 1.6.0

set "VERSION=%~1"
if "%VERSION%"=="" (
  echo Usage: tools\release-windows.bat ^<version^>    e.g. tools\release-windows.bat 1.6.0
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

if not exist "%ZIP%" (
  echo [1/4] Downloading payload %VERSION% ...
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Invoke-WebRequest -UseBasicParsing -Uri '%URL%' -OutFile '%ZIP%'"
  if errorlevel 1 (
    echo ERROR: download failed: %URL%
    echo Build and upload the payload first with: tools/package-windows-payload.sh
    exit /b 1
  )
) else (
  echo [1/4] Payload already present: %ZIP%
  for %%F in ("%ZIP%") do echo        %%~zF bytes, modified %%~tF
  echo        (delete it to download fresh from the release asset)
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
set "ISCC=%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe"
if not exist "%ISCC%" set "ISCC=%ProgramFiles%\Inno Setup 6\ISCC.exe"
if not exist "%ISCC%" (
  where ISCC >nul 2>&1
  if errorlevel 1 (
    echo ERROR: ISCC.exe not found. Install Inno Setup 6.
    exit /b 1
  )
  set "ISCC=ISCC"
)

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
