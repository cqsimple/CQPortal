@echo off
REM ============================================================
REM  kitty_handler.bat
REM  CQ Simple LLC - KiTTY Protocol Handler
REM
REM  Browsers append a trailing "/" to custom protocol URLs with
REM  no path (e.g. kitty://root@1.2.3.4 becomes
REM  kitty://root@1.2.3.4/ when passed to the handler).
REM  This script strips that trailing slash before launching KiTTY.
REM
REM  KiTTY is a PuTTY fork - same -ssh syntax, plus built-in
REM  WinSCP integration (Ctrl+Alt+F2 inside a session, or via
REM  the system menu on the title bar).
REM ============================================================

set "RAW=%~1"

REM Strip the kitty:// prefix if present
set "RAW=%RAW:kitty://=%"

REM Strip a trailing slash if present
if "%RAW:~-1%"=="/" set "RAW=%RAW:~0,-1%"

REM Adjust this path if KiTTY is installed elsewhere
start "" "C:\Program Files\KiTTY\kitty.exe" -ssh "%RAW%"
