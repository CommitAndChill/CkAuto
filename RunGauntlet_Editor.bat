@echo off
REM Drive a UGauntletTestController in -game -unattended mode using the host
REM project's editor binary. Fast headless smoke loop, skips packaging.
REM
REM Auto-discovers the project (any *.uproject one directory up from this
REM script) and derives the editor binary as <ProjectName>Editor-Cmd.exe.
REM
REM Usage:
REM   RunGauntlet_Editor.bat <ControllerName> [<Map>]
REM
REM Args:
REM   ControllerName  Name of the in-game UGauntletTestController subclass to
REM                   instantiate (passed as -gauntlet=<name>). Required.
REM   Map             Optional /Game/... path. If omitted, the engine loads
REM                   GameDefaultMap from DefaultEngine.ini.
REM
REM Exit code reflects the controller's EndTest(N) result.

setlocal

if "%~1"=="" (
    echo Usage: %~n0 ^<ControllerName^> [^<Map^>]
    echo.
    echo   ControllerName  UGauntletTestController subclass name without the U prefix
    echo                   e.g. "MyBootSmokeController"
    echo   Map             Optional. /Game/... map path. Defaults to GameDefaultMap.
    exit /b 2
)

set "CONTROLLER=%~1"
set "MAP=%~2"

set "PROJECT_DIR=%~dp0.."
set "UPROJECT="
for %%f in ("%PROJECT_DIR%\*.uproject") do (
    if not defined UPROJECT set "UPROJECT=%%~ff"
)

if not defined UPROJECT (
    echo ERROR: no .uproject found alongside CkAuto directory ^(%PROJECT_DIR%^)
    exit /b 3
)

for %%f in ("%UPROJECT%") do set "PROJECT_NAME=%%~nf"

set "EDITOR_CMD=%PROJECT_DIR%\Binaries\Win64\%PROJECT_NAME%Editor-Cmd.exe"

if not exist "%EDITOR_CMD%" (
    echo ERROR: %PROJECT_NAME%Editor-Cmd.exe not found at %EDITOR_CMD%
    echo Build the editor target first.
    exit /b 4
)

echo Project:    %UPROJECT%
echo Editor:     %EDITOR_CMD%
echo Controller: %CONTROLLER%
if defined MAP echo Map:        %MAP%

if defined MAP (
    "%EDITOR_CMD%" "%UPROJECT%" "%MAP%" ^
        -game ^
        -gauntlet=%CONTROLLER% ^
        -unattended ^
        -nullrhi ^
        -nosound ^
        -nosplash ^
        -stdout ^
        -FullStdOutLogOutput
) else (
    "%EDITOR_CMD%" "%UPROJECT%" ^
        -game ^
        -gauntlet=%CONTROLLER% ^
        -unattended ^
        -nullrhi ^
        -nosound ^
        -nosplash ^
        -stdout ^
        -FullStdOutLogOutput
)

set "EXIT_CODE=%ERRORLEVEL%"
echo.
echo === Editor exited with code %EXIT_CODE% ===
exit /b %EXIT_CODE%
