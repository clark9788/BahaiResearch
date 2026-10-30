@echo off
setlocal

REM Resolution order for KEY_PATH:
REM 1) Existing KEY_PATH environment variable (preferred for secret key storage)
REM 2) Optional first argument to this script
REM 3) Local packaged file: .\bahai-research.properties

if defined KEY_PATH goto :validate_key_path

if not "%~1"=="" (
  set "KEY_PATH=%~1"
  goto :validate_key_path
)

set "DEFAULT_LOCAL_KEY_PATH=%~dp0bahai-research.properties"
if exist "%DEFAULT_LOCAL_KEY_PATH%" (
  set "KEY_PATH=%DEFAULT_LOCAL_KEY_PATH%"
  goto :validate_key_path
)

echo ERROR: No KEY_PATH was provided.
echo Set environment variable KEY_PATH, or pass a properties path argument,
echo or place bahai-research.properties next to run-app.bat.
exit /b 1

:validate_key_path
if not exist "%KEY_PATH%" (
  echo ERROR: KEY_PATH file not found: %KEY_PATH%
  exit /b 1
)

REM Resolve the jar: newest local build first, then the payload staged in dist\installer
REM (which is where a Linux build puts it), so a Windows checkout needs no Gradle run.
set "JAR="
for /f "delims=" %%F in ('dir /b /o-d "%~dp0build\libs\BahaiResearch-*-all.jar" 2^>nul') do (
  if not defined JAR set "JAR=%~dp0build\libs\%%F"
)
set "PAYLOAD=%~dp0dist\installer\BahaiResearch"
if not defined JAR if exist "%PAYLOAD%\app\BahaiResearch-all.jar" (
  set "JAR=%PAYLOAD%\app\BahaiResearch-all.jar"
)
if not defined JAR (
  echo ERROR: No application jar found.
  echo        Build one with: gradlew.bat shadowJar
  echo        Or copy the Windows payload zip to dist\ and run tools\release-windows.bat
  exit /b 1
)

set "JAVA_EXE=%~dp0runtime\bin\java.exe"
if not exist "%JAVA_EXE%" if exist "%PAYLOAD%\runtime\bin\java.exe" (
  set "JAVA_EXE=%PAYLOAD%\runtime\bin\java.exe"
)
if not exist "%JAVA_EXE%" (
  set "JAVA_EXE=java"
)

echo Running: "%JAVA_EXE%" -jar "%JAR%"
"%JAVA_EXE%" -jar "%JAR%"
