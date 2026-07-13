@echo off
setlocal
pushd "%~dp0"
powershell -NoLogo -NoExit -ExecutionPolicy Bypass -File "%~dp0migrate.ps1" %*
popd
