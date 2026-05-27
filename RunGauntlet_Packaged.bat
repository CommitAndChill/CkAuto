@echo off
REM Drive a Gauntlet UnrealTestNode against an already-staged packaged client.
REM Build pipeline / CI shape — slower than the editor variant but closer to
REM what shipping builds actually run.
REM
REM Auto-discovers the project (any *.uproject one directory up from this
REM script) and the engine via Get-ProjectEnginePath.ps1.
REM
REM Prerequisites:
REM   - Editor closed (the BB-style guard hook treats this conservatively).
REM   - Packaged client already staged (e.g. via RunUAT BuildCookRun -archive).
REM   - Project has a Build/Scripts/<Project>.Automation.csproj with the
REM     UnrealTestNode subclass referenced by <TestNodeFullName>.
REM
REM Usage:
REM   RunGauntlet_Packaged.bat <TestNodeFullName> <StagedBuildPath> [<Map>]
REM
REM Args:
REM   TestNodeFullName  Fully-qualified C# UnrealTestNode class name,
REM                     e.g. "MyProject.Automation.MyBootSmokeTest".
REM   StagedBuildPath   Absolute path to the staged client directory
REM                     (the one containing <ProjectName>.exe / Binaries/).
REM   Map               Optional. Currently ignored — the C# node controls
REM                     map selection via its UnrealTestConfiguration.

setlocal

if "%~1"=="" (
    echo Usage: %~n0 ^<TestNodeFullName^> ^<StagedBuildPath^> [^<Map^>]
    echo.
    echo   TestNodeFullName  e.g. "MyProject.Automation.MyBootSmokeTest"
    echo   StagedBuildPath   e.g. "%%CD%%\Saved\StagedBuilds\Windows"
    echo   Map               Optional, currently unused by this wrapper
    exit /b 2
)

if "%~2"=="" (
    echo ERROR: StagedBuildPath required.
    exit /b 2
)

set "TEST_NODE=%~1"
set "BUILD_PATH=%~2"

set "PROJECT_DIR=%~dp0.."
set "UPROJECT="
for %%f in ("%PROJECT_DIR%\*.uproject") do (
    if not defined UPROJECT set "UPROJECT=%%~ff"
)

if not defined UPROJECT (
    echo ERROR: no .uproject found alongside CkAuto directory ^(%PROJECT_DIR%^)
    exit /b 3
)

for /f "delims=" %%i in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Get-ProjectEnginePath.ps1"') do set "ENGINE_DIR=%%i"

if not exist "%ENGINE_DIR%\Engine\Build\BatchFiles\RunUAT.bat" (
    echo ERROR: RunUAT.bat not found at %ENGINE_DIR%\Engine\Build\BatchFiles\RunUAT.bat
    exit /b 4
)

set "ARTIFACT_DIR=%PROJECT_DIR%\Saved\Gauntlet\%TEST_NODE%"
if not exist "%ARTIFACT_DIR%" mkdir "%ARTIFACT_DIR%"

echo Project:    %UPROJECT%
echo Engine:     %ENGINE_DIR%
echo Test node:  %TEST_NODE%
echo Build:      %BUILD_PATH%
echo Artifacts:  %ARTIFACT_DIR%

REM -ScriptsForProject= tells UAT to scan this project's Build/Scripts/ for
REM *.Automation.csproj. Without it, project-side test classes won't be found.
call "%ENGINE_DIR%\Engine\Build\BatchFiles\RunUAT.bat" ^
    -ScriptsForProject="%UPROJECT%" ^
    RunUnreal ^
    -test=%TEST_NODE% ^
    -project="%UPROJECT%" ^
    -build="%BUILD_PATH%" ^
    -platform=Win64 ^
    -configuration=Development ^
    -tempdir="%ARTIFACT_DIR%\Temp" ^
    -logdir="%ARTIFACT_DIR%\Logs"

set "UAT_EXIT=%ERRORLEVEL%"
echo.
echo === UAT exited with %UAT_EXIT% ===
exit /b %UAT_EXIT%
