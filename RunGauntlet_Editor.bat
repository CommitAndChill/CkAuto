@echo off
REM Drive a UGauntletTestController in -game -unattended mode using the host
REM project's editor binary. Fast headless smoke loop, skips packaging.
REM
REM Auto-discovers the project (any *.uproject one directory up from this
REM script) and derives the editor binary as <ProjectName>Editor-Cmd.exe.
REM
REM Usage:
REM   RunGauntlet_Editor.bat <ControllerName> [<AsTestClass>] [<Map>]
REM
REM Args:
REM   ControllerName  Name of the in-game UGauntletTestController subclass to
REM                   instantiate (passed as -gauntlet=<name>). Required.
REM                   For AS-authored tests, use "Ck_GauntletAsBridgeController".
REM   AsTestClass     Optional. AS-defined UCk_GauntletAsTest_Base subclass name
REM                   (with or without the U prefix). Passed as -asgauntlet=<n>.
REM                   Only meaningful when ControllerName is the bridge.
REM   Map             Optional. /Game/... map path. If omitted, the engine
REM                   loads GameDefaultMap from DefaultEngine.ini.
REM
REM Exit code reflects the controller's EndTest(N) result.

setlocal

if "%~1"=="" (
    echo Usage: %~n0 ^<ControllerName^> [^<AsTestClass^>] [^<Map^>]
    echo.
    echo   ControllerName  UGauntletTestController subclass name without the U prefix
    echo                   e.g. "MyBootSmokeController" or "Ck_GauntletAsBridgeController"
    echo   AsTestClass     Optional. AS UCk_GauntletAsTest_Base subclass name.
    echo                   Pairs with the bridge controller above.
    echo   Map             Optional. /Game/... map path. Defaults to GameDefaultMap.
    exit /b 2
)

set "CONTROLLER=%~1"
set "ASTEST=%~2"
set "MAP=%~3"

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

set "ASTEST_ARG="
if defined ASTEST set "ASTEST_ARG=-asgauntlet=%ASTEST%"

echo Project:    %UPROJECT%
echo Editor:     %EDITOR_CMD%
echo Controller: %CONTROLLER%
if defined ASTEST echo AS Test:    %ASTEST%
if defined MAP    echo Map:        %MAP%

if defined MAP (
    "%EDITOR_CMD%" "%UPROJECT%" "%MAP%" ^
        -game ^
        -gauntlet=%CONTROLLER% ^
        %ASTEST_ARG% ^
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
        %ASTEST_ARG% ^
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
