@echo off
setlocal
powershell -NoExit -ExecutionPolicy Bypass -File "%~dp0migrate.ps1" %*
