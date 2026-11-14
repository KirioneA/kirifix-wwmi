$ErrorActionPreference = 'Stop'
$exitCode = 2
$transcriptStarted = $false
$runLock = $null
$lockHeld = $false
$supportPath = $null
$support = [Collections.Generic.List[string]]::new()
$support.Add('KiriFix WWMI 0.3.4 | Support report')
$previousOutputEncoding = [Console]::OutputEncoding
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
            $support.Add('A folder or file used by the launcher is linked. Use a regular local folder.')
            throw ('Linked paths are not supported: ' + $item.FullName)
        }
        $parent = Split-Path -Parent $item.FullName
        if (!$parent -or $parent -eq $item.FullName) { break }
        $item = Get-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
    }
}
function Add-HelperSupport([string]$Line) {
    switch -CaseSensitive -Regex ($Line) {
        '\AKIRIFIX_SUPPORT check-mods\z' { $support.Add('Checking the selected Mods folder.') }
        '\AKIRIFIX_SUPPORT no-mods\z' { $support.Add('No compatible WWMI mods were detected in the selected folder. Check the Mods folder or drag it onto the CMD.') }
        '\AKIRIFIX_SUPPORT database\z' { $support.Add('Checking the repair database.') }
        '\AKIRIFIX_SUPPORT inventory (\d{1,9}) (\d{1,9})\z' { $support.Add("Mod folders: $($Matches[1]) cached, $($Matches[2]) to process.") }
        '\AKIRIFIX_SUPPORT moonholder-setup\z' { $support.Add('Checking the Moonholder repair tool.') }
        '\AKIRIFIX_SUPPORT staging\z' { $support.Add('Checking and copying mod resources.') }
        '\AKIRIFIX_SUPPORT missing-resources (\d{1,9})\z' { $support.Add("Skipped $($Matches[1]) incomplete mod folder(s) with missing resources. Extract the full mod archive and keep its folder structure.") }
        '\AKIRIFIX_SUPPORT moonholder\z' { $support.Add('Running Moonholder model repairs.') }
        '\AKIRIFIX_SUPPORT moonholder-failed\z' { $support.Add('Moonholder reported a repair failure before changes were applied.') }
        '\AKIRIFIX_SUPPORT textures\z' { $support.Add('Checking texture bindings and shape keys.') }
        '\AKIRIFIX_SUPPORT scanned (\d{1,9}) (\d{1,9}) (\d{1,9})\z' { $support.Add("Scanned $($Matches[1]) INI file(s), $($Matches[2]) with proposed changes and $($Matches[3]) warning(s).") }
        '\AKIRIFIX_SUPPORT rover-eyes (\d{1,9})\z' { $support.Add("Legacy female Rover eye fixes prepared: $($Matches[1]).") }
        '\AKIRIFIX_SUPPORT applying\z' { $support.Add('Validating backups and applying changes.') }
        '\AKIRIFIX_SUPPORT applied (\d{1,9})\z' { $support.Add("Applied and verified $($Matches[1]) file change(s).") }
        '\AKIRIFIX_SUPPORT outside-mods\z' { $support.Add('A file reference points outside the selected Mods folder.') }
        '\AKIRIFIX_SUPPORT linked-path\z' { $support.Add('A file reference uses a linked file or folder.') }
        '\AKIRIFIX_SUPPORT invalid-path\z' { $support.Add('A file reference uses a path that Windows or KiriFix cannot use.') }
        '\AKIRIFIX_SUPPORT path-too-long\z' { $support.Add('A file path is too long. Use a less deeply nested Mods folder.') }
        '\AKIRIFIX_SUPPORT missing-path\z' { $support.Add('A required file or folder is missing or could not be opened as a directory.') }
        '\AKIRIFIX_SUPPORT access-denied\z' { $support.Add('Access to a required file or folder was denied.') }
        '\AKIRIFIX_SUPPORT file-in-use\z' { $support.Add('A required file is in use by another process.') }
        '\AKIRIFIX_SUPPORT disk-full\z' { $support.Add('There is insufficient space to write the required files.') }
        '\AKIRIFIX_SUPPORT timeout\z' { $support.Add('The repair tool timed out.') }
    }
}
try {
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $runLock = [Threading.Mutex]::new($false, 'Local\KiriFix-WWMI')
    try { $lockHeld = $runLock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $lockHeld = $true }
    if (!$lockHeld) { throw 'KiriFix WWMI is already running in this Windows session.' }
    Assert-LocalPath $scriptRoot
    Assert-LocalPath $root
    $logDir = Join-Path $root 'logs'
    Assert-LocalPath $logDir
    $candidateSupportPath = Join-Path $logDir 'KiriFix-support.txt'
    Assert-LocalPath $candidateSupportPath
    $supportPath = $candidateSupportPath
    foreach ($relative in @('data', 'data\moonholder.json', 'data\moonholder.source.json', 'reports', 'backups', '.runtime', '.runtime\kirifix.py')) {
        Assert-LocalPath (Join-Path $root $relative)
    }
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $runId = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $logPath = Join-Path $logDir ('run-' + $runId + '.log')
    Start-Transcript -LiteralPath $logPath -Force | Out-Null
    $transcriptStarted = $true
    Get-ChildItem -LiteralPath $logDir -Filter 'run-*.log' -File |
        Sort-Object Name -Descending | Select-Object -Skip 3 |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
    Write-Host 'KiriFix WWMI 0.3.4'
    Write-Host ('Started: ' + (Get-Date -Format o))
    Write-Host ('Log: ' + $logPath)
    $mode = $env:KIRIFIX_MODE
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'run' }
    $mode = $mode.ToLowerInvariant()
    if ($mode -cnotin @('run','scan','rollback','force','update')) {
        $support.Add('The requested launch mode is not supported.')
        throw 'Supported modes: run, scan, rollback, force, update.'
    }
    $support.Add('Mode: ' + $mode)
    $mods = $env:KIRIFIX_MODS
    if ([string]::IsNullOrWhiteSpace($mods)) {
        $mods = $defaultMods
        $support.Add('Mods folder source: launcher location.')
    } else { $support.Add('Mods folder source: supplied folder.') }
    $support.Add('Checking whether the Mods folder is accessible.')
    if (!(Test-Path -LiteralPath $mods -PathType Container)) {
        $support.Add('The selected Mods folder does not exist or is not a directory. Drag your Mods folder onto the CMD.')
        throw ('Mods folder not found: ' + $mods + '. Drag your Mods folder onto this CMD file.')
    }
    $mods = (Resolve-Path -LiteralPath $mods).ProviderPath
    $journal = $env:KIRIFIX_JOURNAL
    if ($mode -eq 'rollback' -and ![string]::IsNullOrWhiteSpace($journal)) {
        $support.Add('Checking the selected rollback journal.')
        if (!(Test-Path -LiteralPath $journal -PathType Leaf)) {
            $support.Add('The selected rollback journal could not be found.')
        }
        $journal = (Resolve-Path -LiteralPath $journal).ProviderPath
    }
    Set-Location -LiteralPath $root
    Write-Host ('Mode: ' + $mode + '; Mods: ' + $mods)
    $support.Add('Checking Python 3.10 or later.')
    $runtime = $null
    $runtimeArgs = @()
    $candidates = @()
    $portable = Join-Path $scriptRoot 'runtime\python.exe'
    if (Test-Path -LiteralPath $portable -PathType Leaf) {
        Assert-LocalPath $portable
        $candidates += @{ Path = $portable; Prefix = @() }
    }
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
        $probeArgs = @($candidate.Prefix) + @('-I','-X','utf8','-c','import sys; print(sys.version); sys.exit(0 if sys.version_info >= (3,10) else 1)')
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
    if (!$runtime) {
        $support.Add('Python 3.10 or later could not be started.')
        throw 'Python 3.10+ not found. Install from https://www.python.org/downloads/windows/ .'
    }
    $support.Add('Preparing the KiriFix runtime.')
    $runtimeDir = Join-Path $root '.runtime'
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
    $pythonPath = Join-Path $runtimeDir 'kirifix.py'
    $pythonSource = @'
__PYTHON_SOURCE__
'@
    [IO.File]::WriteAllText($pythonPath, $pythonSource, [Text.UTF8Encoding]::new($false))
    $helperMode = $mode
    if ($mode -in @('run','force','update')) { $helperMode = 'full-run' }
    $arguments = $runtimeArgs + @('-I','-X','utf8','-u',$pythonPath,'--support-events',$helperMode,$mods)
    if ($mode -eq 'force') { $arguments += '--force' }
    if ($mode -eq 'update') { $arguments += '--refresh-db' }
    if ($mode -eq 'rollback') {
        if ([string]::IsNullOrWhiteSpace($env:KIRIFIX_JOURNAL)) {
            $support.Add('Rollback requires a journal file.')
            throw 'Rollback requires journal path as third argument.'
        }
        $arguments += $journal
    }
    Write-Host ('Python: ' + $runtime)
    $ErrorActionPreference = 'Continue'
    & $runtime @arguments 2>&1 | ForEach-Object {
        $line = $_.ToString()
        if ($line.StartsWith('KIRIFIX_SUPPORT ')) { Add-HelperSupport $line }
        elseif ($line.StartsWith('WARNING:')) { Write-Host $line -ForegroundColor Yellow }
        else { Write-Host $line }
    }
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($exitCode -ne 0 -and $exitCode -ne 3) { Write-Host ('ERROR: helper exited with code ' + $exitCode) -ForegroundColor Red }
} catch {
    $exitCode = 2
    for ($exception = $_.Exception; $null -ne $exception; $exception = $exception.InnerException) {
        if ($exception -is [IO.PathTooLongException]) {
            $support.Add('A file path is too long. Use a less deeply nested Mods folder.')
            break
        }
        if ($exception -is [UnauthorizedAccessException] -or $exception -is [Security.SecurityException]) {
            $support.Add('Access to a required file or folder was denied.')
            break
        }
    }
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
} finally {
    if ($supportPath) {
        switch ($exitCode) {
            0 { $support.Add('Result: completed.') }
            3 { $support.Add('Result: no supported WWMI mods detected.') }
            default { $support.Add('Result: stopped with an error.') }
        }
        $support.Add('Exit code: ' + $exitCode)
        $pendingSupport = $supportPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        try {
            [IO.File]::WriteAllLines($pendingSupport, $support, [Text.UTF8Encoding]::new($false))
            if ([IO.File]::Exists($supportPath)) { [IO.File]::Replace($pendingSupport, $supportPath, [NullString]::Value) }
            else { [IO.File]::Move($pendingSupport, $supportPath) }
            Write-Host 'For support, share KiriFix-WWMI\logs\KiriFix-support.txt.'
        } catch {
            Write-Host 'WARNING: Could not save the shareable report.' -ForegroundColor Yellow
        } finally {
            if ([IO.File]::Exists($pendingSupport)) { Remove-Item -LiteralPath $pendingSupport -ErrorAction SilentlyContinue }
        }
    }
    Write-Host ('Finished: ' + (Get-Date -Format o) + '; exit code: ' + $exitCode)
    if ($transcriptStarted) {
        Write-Host ('Saved log: ' + $logPath)
        Stop-Transcript | Out-Null
    }
    if ($lockHeld) { $runLock.ReleaseMutex() }
    if ($null -ne $runLock) { $runLock.Dispose() }
    [Console]::OutputEncoding = $previousOutputEncoding
}
if ($exitCode -eq 3 -and ![Console]::IsInputRedirected) { Read-Host 'Press Enter to close' | Out-Null }
exit $exitCode
