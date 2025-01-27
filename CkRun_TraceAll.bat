@echo off
:: Find the first .exe file in the folder
for %%f in (*.exe) do (
    set EXE_NAME=%%~nf
    goto RunGame
)

:RunGame
if not defined EXE_NAME (
    echo No executable found in the current directory.
    pause
    exit /b
)

:: Launch the game with the given parameters
%EXE_NAME%.exe -log -nettrace=1 -trace=net,cpu,frame,bookmark -statnamedevents