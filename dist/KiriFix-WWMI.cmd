@echo off
setlocal
chcp 65001 >nul
set "KIRIFIX_SELF=%~f0"
set "KIRIFIX_MODS=%~1"
set "KIRIFIX_MODE=%~2"
set "KIRIFIX_JOURNAL=%~3"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:KIRIFIX_SELF); $m=[char]35+'<KIRIFIX_POWERSHELL>'; & ([scriptblock]::Create($s.Substring($s.IndexOf($m)+$m.Length)))"
exit /b %ERRORLEVEL%
#<KIRIFIX_POWERSHELL>
<#
MIT License

Copyright (c) 2026 KiriFix WWMI contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

#>
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

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
from datetime import datetime, timezone
import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import urllib.request
import uuid

VERSION = '0.2.3'
DATABASE_URL = 'https://raw.githubusercontent.com/Moonholder/Wuwa_Mod_Fixer/main/config.json'
HEX = re.compile(r'^[0-9a-fA-F]{8}$')
DB_HASH = re.compile(r'^(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{16})$')
SECTIONS = re.compile(r'^\[([^\]\r\n]+)\][ \t]*(?:;[^\r\n]*)?\r?\n.*?(?=^\[|\Z)', re.M | re.S)
HASH = re.compile(r'^([ \t]*hash[ \t]*=[ \t]*)([0-9a-fA-F]{8})([ \t]*(?:;[^\r\n]*)?)(?=\r?$)', re.M | re.I)
CHANNELS = {'D': 'Diffuse', 'L': 'Lightmap', 'N': 'Normalmap', 'M': 'Materialmap',
            'C': 'Cutoutmap', 'S': 'Specialmap'}


@dataclass
class Plan:
    before: bytes
    after: bytes
    character: str | None = None
    changes: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    path: Path | None = None


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def decode(data: bytes) -> tuple[str, str]:
    if data.startswith((b'\xff\xfe', b'\xfe\xff')):
        return data.decode('utf-16'), 'utf-16'
    if data.startswith(b'\xef\xbb\xbf'):
        return data.decode('utf-8-sig'), 'utf-8-sig'
    try:
        return data.decode('utf-8'), 'utf-8'
    except UnicodeDecodeError:
        
        return data.decode('latin-1'), 'latin-1'


def validate_database(db: dict) -> None:
    if not isinstance(db, dict) or not isinstance(db.get('characters'), dict) or not db['characters']:
        raise ValueError('Unsupported database: missing characters')
    for name, cfg in db['characters'].items():
        if not isinstance(cfg, dict):
            raise ValueError(f'Invalid character: {name}')
        for item in cfg.get('main_hashes', []):
            if not HEX.fullmatch(item.get('new', '')) or any(not HEX.fullmatch(x) for x in item.get('old', [])):
                raise ValueError(f'Invalid model hash: {name}')
        textures = cfg.get('textures', {})
        if not isinstance(textures, dict):
            raise ValueError(f'Invalid textures: {name}')
        for new, node in textures.items():
            if not DB_HASH.fullmatch(new) or not isinstance(node, dict):
                raise ValueError(f'Invalid texture: {name}')
            for old in node.get('replace', []):
                if not isinstance(old, str) or not DB_HASH.fullmatch(old):
                    raise ValueError(f'Invalid replacement: {name}')
            meta = node.get('meta')
            if meta and ('id' in meta or 'type' in meta):
                ids = meta.get('id')
                ids = ids if isinstance(ids, list) else [ids]
                if not ids or any(type(i) is not int or i < 0 for i in ids) or meta.get('type') not in CHANNELS:
                    raise ValueError(f'Unsupported texture metadata: {name}/{new}')


def section_name(block: str) -> str:
    return block.split(']', 1)[0][1:]


def one_resource(block: str) -> str | None:

    assignments = re.findall(r'^[ \t]*this[ \t]*=[ \t]*(Resource\w+)[ \t]*(?:;[^\r\n]*)?\r?$', block, re.M | re.I)
    guards = re.findall(r'^[ \t]*(if\b[^\r\n]*|else\b[^\r\n]*|elif\b[^\r\n]*)', block, re.M | re.I)
    if len(assignments) != 1 or any(not re.fullmatch(r'if\s+\$object_detected\s*(?:;.*)?', g, re.I) for g in guards):
        return None
    for line in block.splitlines()[1:]:
        line = line.split(';', 1)[0].strip()
        if not line or line.lower() == 'endif' or re.fullmatch(r'if\s+\$object_detected', line, re.I):
            continue
        if not re.match(r'^(?:hash|match_priority|this)\s*=', line, re.I):
            return None
    return assignments[0]


def plan_bytes(data: bytes, db: dict, rabbit: bool, base: Path | None = None) -> Plan:
    text, encoding = decode(data)
    p = Plan(data, data)
    sections = list(SECTIONS.finditer(text))
    names = [m.group(1).lower() for m in sections]
    if len(names) != len(set(names)):
        p.warnings.append('Duplicate section names; file skipped')
        return p
    components = [m for m in sections if re.fullmatch(r'TextureOverrideComponent\d+', m.group(1), re.I)]
    hashes = {m.group(2).lower() for s in components for m in HASH.finditer(s.group())}
    found = []
    for name, cfg in db['characters'].items():
        if any(h in hashes for item in cfg.get('main_hashes', []) for h in [item['new'].lower(), *(v.lower() for v in item.get('old', []))]):
            found.append(name)
    if len(found) != 1:
        p.warnings.append('Unknown character or multiple character matches; file skipped')
        return p
    p.character = found[0]
    cfg = db['characters'][p.character]
    textures = {k.lower(): v for k, v in cfg.get('textures', {}).items()}
    replace = {}
    for new, node in textures.items():
        for old in node.get('replace', []):
            old = old.lower()
            if (old in replace and replace[old] != new) or (old in textures and old != new):
                p.warnings.append(f'Ambiguous/chained upstream mapping {old}; character skipped')
                return p
            replace[old] = new
    resources = {m.group(1).lower(): m.group() for m in sections if m.group(1).lower().startswith('resource')}
    bindings: dict[int, dict[str, set[str]]] = {}
    ambiguous: set[tuple[int, str]] = set()

    def override(block: str) -> str:
        name = section_name(block)
        if not name.lower().startswith('textureoverride') or re.fullmatch(r'TextureOverrideComponent\d+', name, re.I):
            return block
        hm = list(HASH.finditer(block))
        if len(hm) != 1:
            return block
        old = hm[0].group(2).lower()
        new = replace.get(old, old)
        if new not in textures:
            return block
        node = textures[new]
        meta = node.get('meta')
        if meta and 'id' in meta and 'type' in meta:
            ids = meta['id'] if isinstance(meta['id'], list) else [meta['id']]
            resource = one_resource(block)
            if resource and resource.lower() not in resources:
                resource = None
            if resource and base is not None:
                rb = resources[resource.lower()]
                files = re.findall(r'^[ \t]*filename[ \t]*=[ \t]*([^;\r\n]+)', rb, re.M | re.I)
                if len(files) != 1:
                    resource = None
                else:
                    f = files[0].strip().strip('"').replace('\\', '/')
                    try:
                        asset = inside(base, f)
                        if not asset.is_file():
                            resource = None
                    except ValueError:
                        resource = None
            for i in ids:
                channel = CHANNELS[meta['type']]
                if resource:
                    bindings.setdefault(i, {}).setdefault(channel, set()).add(resource)
                else:
                    ambiguous.add((i, channel))
                    p.warnings.append(f'{name}: conditional, missing or unsupported texture resource; no {channel} injection')
        if new != old:
            p.changes.append(f'{name}: texture hash {old} -> {new}')
            return HASH.sub(lambda m: m.group(1) + new + m.group(3), block)
        return block

    text = SECTIONS.sub(lambda m: override(m.group()), text)
    newline = '\r\n' if '\r\n' in text else '\n'

    def component(block: str) -> str:
        match = re.fullmatch(r'TextureOverrideComponent(\d+)', section_name(block), re.I)
        if not match:
            return block
        i = int(match.group(1))
        if i in cfg.get('skip_components', []):
            return block
        candidates = bindings.get(i, {})
        if not candidates:
            return block
        if re.search(r'^[ \t]*(?:Resource\\RabbitFX\\|run[ \t]*=[ \t]*CommandList\\RabbitFX\\SetTextures)', block, re.M | re.I):
            p.warnings.append(f'Component{i}: existing RabbitFX texture logic preserved; inspect manually for missing channels')
            return block
        if not rabbit:
            p.warnings.append(f'Component{i}: RabbitFX SetTextures not detected; injection skipped')
            return block
        anchors = list(re.finditer(r'^([ \t]*)run[ \t]*=[ \t]*CommandListOverrideSharedResources[ \t]*(?:;[^\r\n]*)?\r?\n', block, re.M | re.I))
        if len(anchors) != 1 or not re.search(r'^[ \t]*drawindexed[ \t]*=', block, re.M | re.I):
            p.warnings.append(f'Component{i}: unsupported draw structure; injection skipped')
            return block
        anchor = anchors[0]
        if re.search(r'^[ \t]*drawindexed[ \t]*=', block[:anchor.end()], re.M | re.I):
            p.warnings.append(f'Component{i}: draws precede anchor; injection skipped')
            return block
        lines = []
        for channel in CHANNELS.values():
            values = candidates.get(channel, set())
            if len(values) > 1 or (i, channel) in ambiguous:
                p.warnings.append(f'Component{i}: ambiguous {channel}; injection skipped for channel')
            elif len(values) == 1:
                lines.append(f'{anchor.group(1)}Resource\\RabbitFX\\{channel} = ref {next(iter(values))}{newline}')
        if not lines:
            return block
        lines.append(f'{anchor.group(1)}run = CommandList\\RabbitFX\\SetTextures{newline}')
        p.changes.append(f'Component{i}: inject known texture bindings before draw')
        return block[:anchor.end()] + ''.join(lines) + block[anchor.end():]

    text = SECTIONS.sub(lambda m: component(m.group()), text)
    p.after = text.encode(encoding)
    
    if data.startswith(b'\xfe\xff'):
        p.after = b'\xfe\xff' + text.encode('utf-16-be')
    if cfg.get('shapekey_fix') and any(h in hashes for h in cfg['shapekey_fix'].get('trigger_hash', [])):
        p.warnings.append('Upstream also defines a mesh/expression repair for this model; use official fixer for that repair')
    return p


def is_link(path: Path) -> bool:
    info = path.lstat()
    return path.is_symlink() or bool(getattr(info, 'st_file_attributes', 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT)


def inside(root: Path, relative: str) -> Path:
    root = root.resolve()
    rel = Path(relative)
    if rel.is_absolute() or '..' in rel.parts or rel.drive or ':' in relative:
        raise ValueError(f'Unsafe relative path: {relative}')
    path = root
    for part in rel.parts:
        path = path / part
        if path.exists() and is_link(path):
            raise ValueError(f'Links/reparse points are not supported: {path}')
    if not path.resolve().is_relative_to(root):
        raise ValueError('Path escapes root')
    return path


def ini_files(root: Path):
    for directory, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d.lower() not in ('kirifix-wwmi', 'kirifix-wwmi-logs', 'logs-kirifix') and not d.lower().startswith(('disabled', '.')) and not is_link(Path(directory) / d))
        for name in sorted(files):
            if name.lower().endswith('.ini') and not name.lower().startswith('disabled'):
                path = Path(directory) / name
                if not is_link(path):
                    yield path


def scan(root: Path, db: dict) -> list[Plan]:
    validate_database(db)
    root = root.resolve(strict=True)
    if not root.is_dir():
        raise ValueError('Mods root must be a directory')
    files = list(ini_files(root))
    rabbit = False
    for path in files:
        text, _ = decode(path.read_bytes())
        if re.search(r'^namespace[ \t]*=[ \t]*RabbitFX[ \t]*\r?$', text, re.M | re.I) and re.search(r'^\[CommandListSetTextures\]', text, re.M | re.I):
            rabbit = True
    plans = []
    for path in files:
        text, _ = decode(path.read_bytes())
        if re.search(r'^namespace[ \t]*=[ \t]*RabbitFX[ \t]*\r?$', text, re.M | re.I):
            continue
        p = plan_bytes(path.read_bytes(), db, rabbit, path.parent)
        p.path = path
        plans.append(p)
    return plans


def has_wwmi_components(root: Path) -> bool:
    for path in ini_files(root):
        text, _ = decode(path.read_bytes())
        if any(re.fullmatch(r'TextureOverrideComponent\d+', s.group(1), re.I)
               and HASH.search(s.group()) for s in SECTIONS.finditer(text)):
            return True
    return False


def location_warning() -> int:
    print('WARNING: WWMI mods were not detected in this location.', flush=True)
    print('WARNING: Place the KiriFix-WWMI folder inside your Mods directory, or drag your Mods folder onto the CMD file.', flush=True)
    print('WARNING: The folder may be empty or contain unsupported mods. No mod files were changed.', flush=True)
    return 3


def atomic_write(path: Path, data: bytes) -> None:
    fd, temp = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def save_json(path: Path, data) -> None:
    atomic_write(path, (json.dumps(data, indent=2, ensure_ascii=False) + '\n').encode())


def apply(root: Path, plans: list[Plan], state: Path) -> Path:
    root = root.resolve(strict=True)
    changed = [p for p in plans if p.after != p.before]
    if not changed:
        raise ValueError('No changes to apply')
    
    for p in changed:
        rel = p.path.relative_to(root).as_posix()
        target = inside(root, rel)
        if target.read_bytes() != p.before:
            raise ValueError(f'File changed since scan: {rel}')
    run = state.resolve() / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8])
    run.mkdir(parents=True, exist_ok=False)
    entries = []
    for i, p in enumerate(changed):
        backup = f'{i:04d}.bak'
        with (run / backup).open('xb') as stream:
            stream.write(p.before)
            stream.flush()
            os.fsync(stream.fileno())
        entries.append({'path': p.path.relative_to(root).as_posix(), 'backup': backup,
                        'before': digest(p.before), 'after': digest(p.after)})
    journal = run / 'journal.json'
    save_json(journal, {'format': 1, 'tool': VERSION, 'root': str(root), 'entries': entries})
    try:
        for p, entry in zip(changed, entries):
            target = inside(root, entry['path'])
            if target.read_bytes() != p.before:
                raise ValueError('Concurrent edit; stopped')
            atomic_write(target, p.after)
            if target.read_bytes() != p.after:
                raise OSError(f'Write verification failed: {target}')
    except (OSError, ValueError) as exc:
        raise ValueError(f'{exc}; recovery journal: {journal}') from exc
    return journal


def rollback(root: Path, journal: Path) -> None:
    root = root.resolve(strict=True)
    journal = journal.resolve(strict=True)
    data = json.loads(journal.read_text(encoding='utf-8'))
    if data.get('format') != 1 or Path(data['root']).resolve() != root:
        raise ValueError('Journal root/format mismatch')
    restore = []
    seen = set()
    for entry in data['entries']:
        target = inside(root, entry['path'])
        if target in seen:
            raise ValueError('Duplicate journal entry')
        seen.add(target)
        backup = inside(journal.parent, entry['backup']).read_bytes()
        if digest(backup) != entry['before']:
            raise ValueError('Backup checksum mismatch')
        current = target.read_bytes()
        if digest(current) == entry['before']:
            continue  
        if digest(current) != entry['after']:
            raise ValueError(f'Later edits detected; refusing rollback: {target}')
        restore.append((target, current, backup))
    for target, expected, backup in restore:
        if target.read_bytes() != expected:
            raise ValueError('Concurrent edit during rollback')
        atomic_write(target, backup)
        if target.read_bytes() != backup:
            raise OSError(f'Rollback verification failed: {target}')


def update_database(destination: Path) -> None:
    request = urllib.request.Request(DATABASE_URL, headers={'User-Agent': 'KiriFix-WWMI/' + VERSION})
    with urllib.request.urlopen(request, timeout=30) as response:
        if not response.url.startswith('https://raw.githubusercontent.com/Moonholder/Wuwa_Mod_Fixer/'):
            raise ValueError('Unexpected database redirect')
        raw = response.read(8_000_001)
    if len(raw) > 8_000_000:
        raise ValueError('Database too large')
    db = json.loads(raw)
    validate_database(db)
    destination.parent.mkdir(parents=True, exist_ok=True)
    atomic_write(destination, raw)
    save_json(destination.with_suffix('.source.json'), {
        'url': DATABASE_URL, 'sha256': digest(raw),
        'downloaded_utc': datetime.now(timezone.utc).isoformat(),
        'database_version': db.get('version', {}).get('current_version'),
    })


def report(plans: list[Plan], root: Path, db_bytes: bytes, db: dict, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=False)
    results, diffs = [], []
    for p in plans:
        rel = p.path.relative_to(root).as_posix()
        results.append({'path': rel, 'character': p.character, 'changed': p.before != p.after,
                        'changes': p.changes, 'warnings': p.warnings,
                        'before_sha256': digest(p.before), 'after_sha256': digest(p.after)})
        if p.before != p.after:
            a, _ = decode(p.before)
            b, _ = decode(p.after)
            diffs.extend(difflib.unified_diff(a.splitlines(True), b.splitlines(True), fromfile=rel, tofile=rel))
    save_json(destination / 'report.json', {
        'tool': VERSION, 'database_version': db.get('version', {}).get('current_version'),
        'database_sha256': digest(db_bytes), 'files': results,
        'scope': 'Texture hashes and conservative RabbitFX injection only; no model/expression repair',
    })
    (destination / 'changes.diff').write_bytes(''.join(diffs).encode('utf-8'))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description='KiriFix WWMI: known texture fixes, backups and rollback')
    parser.add_argument('--version', action='version', version=VERSION)
    sub = parser.add_subparsers(dest='command', required=True)
    up = sub.add_parser('update-db', help='Explicitly download official JSON database (no programs)')
    up.add_argument('--database', type=Path, default=Path('data/moonholder.json'))
    for name in ('scan', 'apply', 'run'):
        command = sub.add_parser(name)
        command.add_argument('mods', type=Path)
        command.add_argument('--database', type=Path, default=Path('data/moonholder.json'))
        command.add_argument('--reports', type=Path, default=Path('reports'))
        if name in ('apply', 'run'):
            command.add_argument('--state', type=Path, default=Path('backups'))
        if name == 'apply':
            command.add_argument('--game-version', required=True, help='Your installed game version, for example 3.7')
            command.add_argument('--yes', action='store_true', help='Explicitly authorize this invocation to write INI files')
    rb = sub.add_parser('rollback')
    rb.add_argument('mods', type=Path)
    rb.add_argument('journal', type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == 'update-db':
            update_database(args.database)
            print(f'Database saved: {args.database}')
            return 0
        if args.command == 'rollback':
            rollback(args.mods, args.journal)
            print('Rollback verified.')
            return 0
        root = args.mods.resolve(strict=True)
        if not has_wwmi_components(root):
            return location_warning()
        if args.command == 'run':
            print(f'Automatic run. Mods: {root}', flush=True)
            try:
                print('Updating official texture database...', flush=True)
                update_database(args.database)
            except (OSError, ValueError, KeyError, TypeError) as exc:
                if not args.database.is_file():
                    raise ValueError(f'Database download failed and no cache exists: {exc}') from exc
                print(f'WARNING: update failed ({exc}); using validated local cache.', flush=True)
        raw = args.database.read_bytes()
        db = json.loads(raw)
        validate_database(db)
        print(f'Database version: {db.get("version", {}).get("current_version")}; SHA256: {digest(raw)}', flush=True)
        if args.command == 'apply':
            if not args.yes:
                raise ValueError('Apply requires --yes. Run scan and inspect changes.diff first.')
            version = str(db.get('version', {}).get('current_version', ''))
            major_minor = lambda v: re.match(r'^(\d+\.\d+)(?:\.\d+)?$', v)
            game, database = major_minor(args.game_version), major_minor(version)
            if not game or not database or game[1] != database[1]:
                raise ValueError(f'Game/database version mismatch: {args.game_version} vs {version}; no writes')
        plans = scan(root, db)
        if not any(p.character is not None for p in plans):
            return location_warning()
        for p in plans:
            print(f'[{p.character or "unrecognized"}] {p.path.relative_to(root)}', flush=True)
            for change in p.changes:
                print(f'  CHANGE: {change}', flush=True)
            for warning in p.warnings:
                print(f'  WARNING: {warning}', flush=True)
        destination = args.reports / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8])
        report(plans, root, raw, db, destination)
        changed = sum(p.before != p.after for p in plans)
        warnings = sum(len(p.warnings) for p in plans)
        print(f'Scanned: {len(plans)} INI; proposed changes: {changed}; warnings: {warnings}')
        print(f'Report: {destination / "report.json"}\nDiff: {destination / "changes.diff"}')
        if args.command in ('apply', 'run') and changed:
            journal = apply(root, plans, args.state)
            print(f'Applied and verified. Rollback journal: {journal}')
        elif args.command == 'scan':
            print('READ ONLY: no mod files changed.')
        elif not changed:
            print('No automatic changes needed; inspect warnings above.')
        return 0
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
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
