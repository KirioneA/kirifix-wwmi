$ErrorActionPreference = 'Stop'
$exitCode = 2
$transcriptStarted = $false
$runLock = $null
$lockHeld = $false
$scriptRoot = Split-Path -Parent $env:KIRIFIX_SELF
if ((Split-Path -Leaf $scriptRoot) -eq 'KiriFix-WWMI') {
    $root = $scriptRoot
    $defaultMods = Split-Path -Parent $scriptRoot
} else {
    $root = Join-Path $scriptRoot 'KiriFix-WWMI'
    $defaultMods = $scriptRoot
}
Set-Location -LiteralPath $scriptRoot
function Assert-LocalPath([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    while ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw ('Linked paths are not supported: ' + $item.FullName)
        }
        $parent = Split-Path -Parent $item.FullName
        if (!$parent -or $parent -eq $item.FullName) { break }
        $item = Get-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
    }
}
try {
    $runLock = [Threading.Mutex]::new($false, 'Local\KiriFix-WWMI')
    try { $lockHeld = $runLock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $lockHeld = $true }
    if (!$lockHeld) { throw 'KiriFix WWMI is already running in this Windows session.' }
    Assert-LocalPath $scriptRoot
    foreach ($relative in @('', 'logs', 'data', 'data\moonholder.json', 'data\moonholder.source.json', 'reports', 'backups', '.runtime', '.runtime\kirifix.py')) {
        Assert-LocalPath (Join-Path $root $relative)
    }
    $logDir = Join-Path $root 'logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $runId = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $logPath = Join-Path $logDir ('run-' + $runId + '.log')
    Start-Transcript -LiteralPath $logPath -Force | Out-Null
    $transcriptStarted = $true
    Get-ChildItem -LiteralPath $logDir -Filter 'run-*.log' -File |
        Sort-Object Name -Descending | Select-Object -Skip 3 |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
    Write-Host 'KiriFix WWMI 0.2.3'
    Write-Host ('Started: ' + (Get-Date -Format o))
    Write-Host ('Log: ' + $logPath)
    $mode = $env:KIRIFIX_MODE
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'run' }
    if ($mode -notin @('run','scan','rollback')) { throw 'Supported modes: run, scan, rollback.' }
    $mods = $env:KIRIFIX_MODS
    if ([string]::IsNullOrWhiteSpace($mods)) { $mods = $defaultMods }
    if (!(Test-Path -LiteralPath $mods -PathType Container)) {
        throw ('Mods folder not found: ' + $mods + '. Drag your Mods folder onto this CMD file.')
    }
    $mods = (Resolve-Path -LiteralPath $mods).ProviderPath
    $journal = $env:KIRIFIX_JOURNAL
    if ($mode -eq 'rollback' -and ![string]::IsNullOrWhiteSpace($journal)) {
        $journal = (Resolve-Path -LiteralPath $journal).ProviderPath
    }
    Set-Location -LiteralPath $root
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
        $probeArgs = @($candidate.Prefix) + @('-I','-c','import sys; print(sys.version); sys.exit(0 if sys.version_info >= (3,10) else 1)')
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
    $arguments = $runtimeArgs + @('-I','-u',$pythonPath,$mode,$mods)
    if ($mode -eq 'rollback') {
        if ([string]::IsNullOrWhiteSpace($env:KIRIFIX_JOURNAL)) { throw 'Rollback requires journal path as third argument.' }
        $arguments += $journal
    }
    Write-Host ('Python: ' + $runtime)
    $ErrorActionPreference = 'Continue'
    & $runtime @arguments 2>&1 | ForEach-Object {
        if ($_.ToString().StartsWith('WARNING:')) { Write-Host $_.ToString() -ForegroundColor Yellow }
        else { Write-Host $_.ToString() }
    }
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($exitCode -eq 3) {
        if (![Console]::IsInputRedirected) { Read-Host 'Press Enter to close' | Out-Null }
    } elseif ($exitCode -ne 0) { Write-Host ('ERROR: helper exited with code ' + $exitCode) -ForegroundColor Red }
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
    if ($lockHeld) { $runLock.ReleaseMutex() }
    if ($null -ne $runLock) { $runLock.Dispose() }
}
exit $exitCode
