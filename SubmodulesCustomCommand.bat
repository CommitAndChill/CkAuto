@echo off
echo ==========================================
echo         BEGIN - Submodules %*
echo ------------------------------------------
echo.

set FOREACH_CMD=%*

set CALL_DIR=%CD%
cd %~dp0/..
cmd.exe /c ""C:\Program Files\Git\bin\sh.exe" --login -i -- %~dp0SubmodulesForEach.sh '%FOREACH_CMD%'"
cd %CALL_DIR%

echo.
echo -----------------------------------------
echo          END - Submodules %*
echo =========================================
echo.

pause