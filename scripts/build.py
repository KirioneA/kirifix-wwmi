from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / 'src/kirifix.py').read_text(encoding='utf-8')
bootstrap = (root / 'src/launcher.ps1').read_text(encoding='utf-8')
license_text = (root / 'LICENSE').read_text(encoding='utf-8')
bootstrap = '<#\n' + license_text + '\n#>\n' + bootstrap
header = r'''@echo off
setlocal
chcp 65001 >nul
set "KIRIFIX_SELF=%~f0"
set "KIRIFIX_MODS=%~1"
set "KIRIFIX_MODE=%~2"
set "KIRIFIX_JOURNAL=%~3"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:KIRIFIX_SELF); $m=[char]35+'<KIRIFIX_POWERSHELL>'; & ([scriptblock]::Create($s.Substring($s.IndexOf($m)+$m.Length)))"
exit /b %ERRORLEVEL%
#<KIRIFIX_POWERSHELL>
'''
result = header + bootstrap.replace('__PYTHON_SOURCE__', source.rstrip())
destination = root / 'dist/KiriFix-WWMI.cmd'
destination.parent.mkdir(exist_ok=True)
destination.write_bytes(result.replace('\r\n', '\n').replace('\n', '\r\n').encode('utf-8'))
print(f'Built {destination.name}')
