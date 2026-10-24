$ErrorActionPreference = 'Stop'
$exitCode = 2
$transcriptStarted = $false
$root = Split-Path -Parent $env:KIRIFIX_SELF
Set-Location -LiteralPath $root
try {
    $logDir = Join-Path $root 'logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $runId = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $logPath = Join-Path $logDir ('run-' + $runId + '.log')
    Start-Transcript -LiteralPath $logPath -Force | Out-Null
    $transcriptStarted = $true
    Get-ChildItem -LiteralPath $logDir -Filter 'run-*.log' -File |
        Sort-Object Name -Descending | Select-Object -Skip 3 |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
    Write-Host 'KiriFix WWMI 0.2.0'
    Write-Host ('Started: ' + (Get-Date -Format o))
    Write-Host ('Log: ' + $logPath)
    $mode = $env:KIRIFIX_MODE
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'run' }
    if ($mode -notin @('run','scan','rollback')) { throw 'Supported modes: run, scan, rollback.' }
    $mods = $env:KIRIFIX_MODS
    if ([string]::IsNullOrWhiteSpace($mods)) { $mods = Join-Path $env:APPDATA 'XXMI Launcher\WWMI\Mods' }
    if (!(Test-Path -LiteralPath $mods -PathType Container)) {
        throw ('Mods folder not found: ' + $mods + '. Drag your Mods folder onto this CMD file.')
    }
    Write-Host ('Mode: ' + $mode + '; Mods: ' + $mods)
    $runtime = $null
    $runtimeArgs = @()
    $candidates = @()
    foreach ($name in @('py','python','python3')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) {
            $prefix = @()
            if ($name -eq 'py') { $prefix = @('-3') }
            $candidates += @{ Path = $command.Source; Prefix = $prefix }
        }
    }
    $bundled = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    if (Test-Path -LiteralPath $bundled) { $candidates += @{ Path = $bundled; Prefix = @() } }
    foreach ($candidate in $candidates) {
        Write-Host ('Checking Python: ' + $candidate.Path)
        $probeArgs = @($candidate.Prefix) + @('-c','import sys; print(sys.version); sys.exit(0 if sys.version_info >= (3,10) else 1)')
        try {
            $ErrorActionPreference = 'Continue'
            & $candidate.Path @probeArgs 2>&1 | ForEach-Object { Write-Host $_.ToString() }
            $probeExit = $LASTEXITCODE
        } catch {
            $probeExit = 1
            Write-Host ('Python probe failed: ' + $_.Exception.Message)
        } finally { $ErrorActionPreference = 'Stop' }
        if ($probeExit -eq 0) { $runtime = $candidate.Path; $runtimeArgs = @($candidate.Prefix); break }
    }
    if (!$runtime) { throw 'Python 3.10+ not found. Install from https://www.python.org/downloads/windows/ .' }
    $runtimeDir = Join-Path $root '.runtime'
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
    $pythonPath = Join-Path $runtimeDir 'kirifix.py'
    $pythonSource = @'
__PYTHON_SOURCE__
'@
    [IO.File]::WriteAllText($pythonPath, $pythonSource, [Text.UTF8Encoding]::new($false))
    $arguments = $runtimeArgs + @('-u',$pythonPath,$mode,$mods)
    if ($mode -eq 'rollback') {
        if ([string]::IsNullOrWhiteSpace($env:KIRIFIX_JOURNAL)) { throw 'Rollback requires journal path as third argument.' }
        $arguments += $env:KIRIFIX_JOURNAL
    }
    Write-Host ('Python: ' + $runtime)
    $ErrorActionPreference = 'Continue'
    & $runtime @arguments 2>&1 | ForEach-Object { Write-Host $_.ToString() }
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($exitCode -ne 0) { Write-Host ('ERROR: helper exited with code ' + $exitCode) -ForegroundColor Red }
} catch {
    $exitCode = 2
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
} finally {
    Write-Host ('Finished: ' + (Get-Date -Format o) + '; exit code: ' + $exitCode)
    if ($transcriptStarted) {
        Write-Host ('Saved log: ' + $logPath)
        Stop-Transcript | Out-Null
    }
}
exit $exitCode
