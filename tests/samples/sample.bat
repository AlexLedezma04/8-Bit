@echo off
rem A script.
setlocal
set NAME=world
:: say hello
if "%NAME%"=="world" (
    echo Hello, %NAME%
) else goto end
:end
endlocal
