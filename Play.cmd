@echo off
REM Double-click this. It rebuilds from HEAD, tells you exactly what it is
REM opening -- commit, tuning profile, hash -- and opens it in Studio.
REM Click the same file every time; read the banner; know which build you have.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0play.ps1"
