set CMD=git fetch origin dev; git fetch . origin/dev:main
call %~dp0SubmodulesCustomCommand.bat %CMD%