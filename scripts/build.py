from pathlib import Path
import shutil

root = Path(__file__).resolve().parents[1]
header = r'''@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul
set "KIRIFIX_SELF=%~f0"
set "KIRIFIX_MODS=%~1"
set "KIRIFIX_MODE=%~2"
set "KIRIFIX_JOURNAL=%~3"
set "KIRIFIX_PACKAGE=%~dp0KiriFix-WWMI\"
for %%I in ("%~dp0.") do if /i "%%~nxI"=="KiriFix-WWMI" set "KIRIFIX_PACKAGE=%~dp0"
if not exist "%KIRIFIX_PACKAGE%runtime\python.exe" (
    echo ERROR: Extract the complete KiriFix-WWMI folder, including its runtime.
    exit /b 2
)
if not exist "%KIRIFIX_PACKAGE%kirifix.py" (
    echo ERROR: Extract the complete KiriFix-WWMI folder, including kirifix.py.
    exit /b 2
)
"%KIRIFIX_PACKAGE%runtime\python.exe" -I -X utf8 -u "%KIRIFIX_PACKAGE%kirifix.py" --windows-launcher
exit /b %ERRORLEVEL%
'''
destination = root / 'dist'
destination.mkdir(exist_ok=True)
(destination / 'KiriFix-WWMI.cmd').write_bytes(header.replace('\n', '\r\n').encode('ascii'))
shutil.copyfile(root / 'src/kirifix.py', destination / 'kirifix.py')
print('Built KiriFix-WWMI.cmd and kirifix.py')
