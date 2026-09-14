@echo off
REM Wrapper per lanciare img23d.ps1 senza problemi di ExecutionPolicy.
REM Uso:  img23d foto.png -Rig
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0img23d.ps1" %*
