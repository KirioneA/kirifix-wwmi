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

from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
import difflib
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import threading
import time
import tempfile
import urllib.request
import urllib.error
import uuid

VERSION = '0.3.4'
MOONHOLDER_URL = 'https://github.com/Moonholder/Wuwa_Mod_Fixer/releases/download/v3.7.0/wuwa-mod-cli_v3.7.0.exe'
MOONHOLDER_SHA256 = '737c71507a8bc43a0794cace0aba07bccee6967de95cfb29291c9700cc85a370'
DATABASE_URL = 'https://raw.githubusercontent.com/Moonholder/Wuwa_Mod_Fixer/main/config.json'
HEX = re.compile(r'^[0-9a-fA-F]{8}$')
DB_HASH = re.compile(r'^(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{16})$')
SECTIONS = re.compile(r'^\[([^\]\r\n]+)\][ \t]*(?:;[^\r\n]*)?\r?\n.*?(?=^\[|\Z)', re.M | re.S)
HASH = re.compile(r'^([ \t]*hash[ \t]*=[ \t]*)([0-9a-fA-F]{8})([ \t]*(?:;[^\r\n]*)?)(?=\r?$)', re.M | re.I)
CHANNELS = {'D': 'Diffuse', 'L': 'Lightmap', 'N': 'Normalmap', 'M': 'Materialmap',
            'C': 'Cutoutmap', 'S': 'Specialmap'}
ROVER_SHAPE_KEY_CHANGE = 'RoverFemale: update legacy shape key batch offset and dispatch size'


@dataclass
class Plan:
    before: bytes
    after: bytes
    character: str | None = None
    changes: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    path: Path | None = None


class PathIssue(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def emit_support(event: str, *counts: int) -> None:
    print('KIRIFIX_SUPPORT', event, *counts, flush=True)


def support_error(exc: Exception) -> str | None:
    while exc is not None:
        if isinstance(exc, PathIssue):
            return exc.code
        if isinstance(exc, subprocess.TimeoutExpired):
            return 'timeout'
        if isinstance(exc, OSError):
            winerror = getattr(exc, 'winerror', None)
            if winerror == 206 or exc.errno == errno.ENAMETOOLONG:
                return 'path-too-long'
            if winerror in (32, 33):
                return 'file-in-use'
            if winerror == 123:
                return 'invalid-path'
            if winerror in (39, 112) or exc.errno == errno.ENOSPC:
                return 'disk-full'
            if isinstance(exc, PermissionError):
                return 'access-denied'
            if isinstance(exc, (FileNotFoundError, NotADirectoryError)):
                return 'missing-path'
        exc = exc.__cause__
    return None


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


def texture_selector(block):
    condition = r'\$\w+(?:\s*(?:==|!=)\s*-?\d+)?'
    branch = re.compile(rf'(if|else if) ({condition}(?:\s*(?:\|\||&&)\s*{condition})*)', re.I)
    template, resources, stack = [], [], []
    for raw in block.splitlines()[1:]:
        line = ' '.join(raw.split(';', 1)[0].split())
        if not line or re.match(r'^(hash|match_priority)\s*=', line, re.I):
            continue
        match = branch.fullmatch(line)
        if match and match[1].lower() == 'if':
            if (stack and stack[-1][1]) or (not stack and template):
                return None
            if stack:
                stack[-1][1] = True
            template.append((len(stack), line))
            stack.append([False, False])
        elif line.lower() == 'else' or match:
            if not stack or stack[-1][0] or not stack[-1][1]:
                return None
            stack[-1] = [line.lower() == 'else', False]
            template.append((len(stack) - 1, line))
        elif line.lower() == 'endif':
            if not stack or not stack.pop()[1]:
                return None
            template.append((len(stack), 'endif'))
        else:
            resource = re.fullmatch(r'this\s*=\s*(Resource[\w-]+)', line, re.I)
            if not resource or not stack or stack[-1][1]:
                return None
            stack[-1][1] = True
            template.append((len(stack), None))
            resources.append(resource[1])
    if not stack and resources:
        return template, resources
    return None


def conditional_outfit_bindings(block, candidates, resources, base, newline):
    channels = ('Diffuse', 'Lightmap', 'Normalmap')
    if 'Materialmap' in candidates:
        channels += ('Materialmap',)
    if base is None or set(candidates) != set(channels):
        return None
    selectors = {}
    template = None
    for channel, overrides in candidates.items():
        if len(overrides) != 1:
            return None
        selector = texture_selector(overrides[0])
        if not selector:
            return None
        shape, selected = selector
        if template is not None and template != shape:
            return None
        template = shape
        for resource in selected:
            section = resources.get(resource.lower(), '')
            files = re.findall(r'^[ \t]*filename[ \t]*=[ \t]*([^;\r\n]+)', section, re.M | re.I)
            try:
                if len(files) != 1 or not inside(base, files[0].strip().strip('"').replace('\\', '/')).is_file():
                    return None
            except ValueError:
                return None
        selectors[channel] = iter(selected)
    anchors = list(re.finditer(
        r'^([ \t]+)run[ \t]*=[ \t]*CommandListOverrideSharedResources[ \t]*\r?\n',
        block, re.M | re.I))
    draw = re.search(r'^[ \t]*drawindexed[ \t]*=', block, re.M | re.I)
    if len(anchors) != 1 or not draw or draw.start() < anchors[0].end():
        return None
    anchor = anchors[0]
    prefix = block[:anchor.start()].splitlines()
    if prefix[-1].rstrip().lower() != anchor[1] + 'run = commandlisttriggerresourceoverrides':
        return None
    if any(line.split(';', 1)[0].strip() for line in block[anchor.end():draw.start()].splitlines()):
        return None
    lines = []
    for depth, command in template:
        indent = anchor[1] + '    ' * depth
        if command is not None:
            lines.append(indent + command)
            continue
        for channel in channels:
            lines.append(f'{indent}Resource\\RabbitFX\\{channel} = ref {next(selectors[channel])}')
        lines.append(indent + 'run = CommandList\\RabbitFX\\SetTextures')
    return block[:anchor.end()] + newline.join(lines) + newline + block[anchor.end():]


def ini_commands(block):
    return [' '.join(line.split(';', 1)[0].split()) for line in block.splitlines()[1:]
            if line.split(';', 1)[0].strip()]


def texture_asset(resource, resources, base):
    files = re.findall(r'^[ \t]*filename[ \t]*=[ \t]*([^;\r\n]+)',
                       resources.get(resource.lower(), ''), re.M | re.I)
    if base is not None and len(files) == 1:
        try:
            path = inside(base, files[0].strip().strip('"').replace('\\', '/'))
            if path.is_file():
                return path
        except ValueError:
            pass
    return None


def texture_choices(commands, target):
    """Accept resource selectors with variable-only conditions and no other effects."""
    condition = r'\$\w+(?:\s*(?:==|!=)\s*-?\d+)?'
    branch = re.compile(rf'(if|elif|else if) {condition}(?:\s*(?:\|\||&&)\s*{condition})*', re.I)
    assignment = re.compile(rf'{re.escape(target)}\s*=\s*(?:ref\s+)?(Resource[\w-]+)', re.I)
    stack, result = [], []
    for line in commands:
        control = branch.fullmatch(line)
        resource = assignment.fullmatch(line)
        if control and control[1].lower() == 'if':
            result.append((len(stack), line, None))
            stack.append(False)
        elif control or line.lower() == 'else':
            if not stack or stack[-1]:
                return None
            stack[-1] = line.lower() == 'else'
            result.append((len(stack) - 1, line, None))
        elif line.lower() == 'endif':
            if not stack:
                return None
            stack.pop()
            result.append((len(stack), 'endif', None))
        elif resource:
            result.append((len(stack), '', resource[1]))
        else:
            return None
    if not stack and any(resource for _, _, resource in result):
        return tuple(result)
    return None


def texture_profile(condition):
    """Map slots only for the two recognized hair and outfit layouts."""
    formats = {}
    for group in condition.split('&&'):
        group = group.strip()
        grouped = group.startswith('(') and group.endswith(')')
        alternatives = (group[1:-1] if grouped else group).split('||')
        probes = [re.fullmatch(r'ps-t(\d+)->format\s*==\s*dxgi_format_(\w+)', item.strip(), re.I)
                  for item in alternatives]
        if (any(probe is None for probe in probes) or (len(probes) > 1 and not grouped)
                or len({int(probe[1]) for probe in probes}) != 1 or int(probes[0][1]) in formats):
            return {}
        formats[int(probes[0][1])] = {probe[2].lower() for probe in probes}
    bc7 = {'bc7_unorm', 'bc7_unorm_srgb'}
    bc3 = {'bc3_unorm', 'bc3_unorm_srgb'}
    if (formats.get(0, set()) and formats[0] <= bc7 and formats.get(1) == {'bc3_unorm'}
            and formats.get(2) == {'r8_unorm'} and formats.get(3) == {'bc7_unorm_srgb'}
            and formats.get(4) == {'bc7_unorm_srgb'}):
        return {0: 'Normalmap', 1: 'Lightmap', 2: 'Materialmap', 3: 'Diffuse', 4: None}
    if (formats.get(0, set()) and formats[0] <= bc3 and formats.get(1) == {'bc7_unorm_srgb'}
            and formats.get(2) == {'b8g8r8a8_unorm'} and formats.get(5, set())
            and formats[5] <= bc7):
        return {0: 'Lightmap', 1: 'Diffuse', 5: 'Materialmap'}
    return {}


def slot_texture_choices(block, sections, resources, base):
    commands = ini_commands(block)
    if (len(commands) < 5 or commands[0].lower() != 'if $object_detected == 1'
            or [line.lower() for line in commands[-2:]] != ['endif', 'endif']):
        return None
    branches = []
    for line in commands[1:-2]:
        condition = re.fullmatch(r'(else if|elif|if) (.+)', line, re.I)
        if condition:
            if (condition[1].lower() == 'if') != (not branches):
                return None
            branches.append((condition[2], []))
        elif branches:
            branches[-1][1].append(line)
        else:
            return None
    if not branches:
        return None
    primary, layout = {}, None
    fallback = []
    for condition, body in branches:
        profile = texture_profile(condition)
        choices = {}
        cursor = 0
        while cursor < len(body):
            direct = re.fullmatch(r'ps-t(\d+) = ref (Resource[\w-]+)', body[cursor], re.I)
            temporary = re.fullmatch(r'(Resource\w+) = ref ps-t(\d+)', body[cursor], re.I)
            if temporary and cursor + 3 < len(body):
                name, slot = temporary.groups()
                call = re.fullmatch(r'run = (CommandList[\w-]+)', body[cursor + 1], re.I)
                if not call or [line.lower() for line in body[cursor + 2:cursor + 4]] != [
                    f'ps-t{slot} = ref {name}'.lower(), f'{name} = null'.lower()
                ]:
                    return None
                selector = ini_commands(sections.get(call[1].lower(), ''))
                selected = None
                if (selector and selector[0].lower() in ('if $object_detected', 'if $object_detected == 1')
                        and selector[-1].lower() == 'endif'):
                    selected = texture_choices(selector[1:-1], name)
                if selected is None:
                    selected = texture_choices(selector, name)
                cursor += 4
            elif direct:
                slot, resource = direct.groups()
                selected = ((0, '', resource),)
                cursor += 1
            else:
                return None
            slot = int(slot)
            if (not selected or slot in choices
                    or any(not texture_asset(resource, resources, base)
                           for _, _, resource in selected if resource)):
                return None
            choices[slot] = selected
        if not choices or not choices.keys() <= profile.keys():
            simple = re.fullmatch(r'ps-t(\d+)->format == dxgi_format_bc7_unorm(?:_srgb)?', condition, re.I)
            either = re.fullmatch(r'\(ps-t(\d+)->format == dxgi_format_bc7_unorm'
                                  r' \|\| ps-t\1->format == dxgi_format_bc7_unorm_srgb\)', condition, re.I)
            diffuse_fallback = simple or either
            if diffuse_fallback and choices.keys() == {int(diffuse_fallback[1])}:
                fallback.append(choices)
                continue
            return None
        if primary and (layout != profile or primary != choices):
            return None
        primary, layout = choices, profile
    if not primary:
        return None
    diffuse_slot = next(slot for slot, channel in layout.items() if channel == 'Diffuse')
    if any(next(iter(branch.values())) != primary.get(diffuse_slot) for branch in fallback):
        return None
    return {layout[slot]: choices for slot, choices in primary.items()}


def hash_covers_slot_choices(choices, candidates, hash_overrides, textures, resources, base, component_id):
    for channel, selector in choices.items():
        options = candidates.get(channel, [])
        if channel is None:
            # Shared, auxiliary textures may have no channel metadata. Require
            # the export's component list and the matching resource hash.
            if len(selector) != 1:
                return False
            resource = selector[0][2]
            path = texture_asset(resource, resources, base)
            label = re.fullmatch(r'Components-([\d-]+) t=([a-f0-9]{8})', path.stem, re.I)
            if not label or str(component_id) not in label[1].split('-'):
                return False
            options = hash_overrides.get(label[2].lower(), [])
        for override in options:
            hash_value = HASH.search(override)[2].lower()
            derived = textures.get(hash_value, {}).get('derive', {})
            if not isinstance(derived, dict):
                continue
            required = [hash_value, *(alias.lower() for aliases in derived.values()
                                      if isinstance(aliases, list) for alias in aliases if isinstance(alias, str))]
            for value in required:
                matches = hash_overrides.get(value, [])
                if len(matches) != 1:
                    break
                commands = [line for line in ini_commands(matches[0])
                            if not re.match(r'^(hash|match_priority)\s*=', line, re.I)]
                if (not commands or commands[0].lower() != 'if $object_detected'
                        or commands[-1].lower() != 'endif' or texture_choices(commands[1:-1], 'this') != selector):
                    break
            else:
                break
        else:
            return False
    return True


def repair_slot_bindings(block, component_id, sections, resources, base, rabbit, candidates, hash_overrides, textures, newline):
    calls = list(re.finditer(
        rf'^([ \t]*)(;[ \t]*)?run[ \t]*=[ \t]*(CommandListSetTexturesComponent{component_id})[ \t]*\r?$\n',
        block, re.M | re.I))
    if len(calls) != 1 or calls[0][2]:
        return block
    call = calls[0]
    indent = call[1]
    choices = slot_texture_choices(sections.get(call[3].lower(), ''), sections, resources, base)
    commands = ini_commands(block)
    trigger = 'run = CommandListTriggerResourceOverrides'
    shared = 'run = CommandListOverrideSharedResources'
    first_draw = re.search(r'^[ \t]*drawindexed\s*=', block, re.M | re.I)
    if (not choices or 'Diffuse' not in choices or commands.count(trigger) != 1 or commands.count(shared) != 1
            or '$object_detected = 1' not in commands[:commands.index(trigger)]
            or not block[call.end():].startswith(indent + trigger + newline + indent + shared + newline)
            or not first_draw or first_draw.start() < call.end()):
        return block
    rabbit_run = 'run = CommandList\\RabbitFX\\Run'
    fx_map = re.compile(r'Resource\\RabbitFX\\FXMap = ref Resource[\w-]+', re.I)
    rabbit_commands = [line for line in commands if 'rabbitfx' in line.lower()]
    existing_fx = len(rabbit_commands) == 2 and fx_map.fullmatch(rabbit_commands[0]) and rabbit_commands[1] == rabbit_run
    if rabbit_commands and not existing_fx:
        return block
    if existing_fx:
        anchor = indent + rabbit_run + newline
        fx_prefix = ini_commands('[Component]' + newline + block[call.end():first_draw.start()])
        if block.count(anchor) != 1 or fx_prefix[:4] != [trigger, shared, *rabbit_commands]:
            return block
    probes = ini_commands(sections.get('commandlisttriggerresourceoverrides', ''))
    if (not existing_fx and {'Diffuse', 'Lightmap', 'Normalmap', 'Materialmap'} <= choices.keys()
            and {f'CheckTextureOverride = ps-t{i}' for i in range(5)} <= set(probes)
            and hash_covers_slot_choices(choices, candidates, hash_overrides, textures, resources, base, component_id)):
        return block[:call.start()] + indent + '; ' + block[call.start() + len(indent):]
    if not rabbit or None in choices or any(candidates.values()):
        return block
    single_channel = len(choices) == 1
    lines = [] if existing_fx or single_channel else [indent + rabbit_run]
    for channel, selector in choices.items():
        for depth, command, resource in selector:
            prefix = indent + '    ' * depth
            assignment = f'Resource\\RabbitFX\\{channel} = ref {resource}' if resource else command
            if single_channel and resource and not existing_fx:
                lines.append(prefix + rabbit_run)
            lines.append(prefix + assignment)
            if single_channel and resource:
                lines.append(prefix + 'run = CommandList\\RabbitFX\\SetTextures')
    if not single_channel:
        lines.append(indent + 'run = CommandList\\RabbitFX\\SetTextures')
    insertion = newline.join(lines) + newline
    updated = block[:call.start()] + block[call.end():]
    if existing_fx:
        return updated.replace(anchor, anchor + insertion)
    return updated[:call.start()] + insertion + updated[call.start():]



def repair_rover_shape_keys(text: str, sections: list[re.Match]) -> str:
    signature = {
        'commandlistsetupshapekeysbatch': {
            'shapekey_checksum_batch0': '1398',
            'shapekey_checksum_batch1': '705',
            'shapekey_vertex_offset_original_batch0': '0',
            'shapekey_vertex_offset_original_batch1': '49931',
        },
        'commandlistloadshapekeysbatch': {
            'shapekey_dispatch_size_y_original_batch0': '1561',
            'shapekey_dispatch_size_y_original_batch1': '555',
        },
    }
    updates = {
        'shapekey_vertex_offset_original_batch1': '55177',
        'shapekey_dispatch_size_y_original_batch0': '1725',
    }
    by_name = {section[1].lower(): section for section in sections}
    edits = []
    for name, expected in signature.items():
        section = by_name.get(name)
        if section is None:
            return text
        for key, value in expected.items():
            pattern = r'^[ \t]*\$\\WWMIv1\\' + key + r'[ \t]*=[ \t]*(\d+)[ \t]*(?:;[^\r\n]*)?\r?$'
            matches = list(re.finditer(pattern, section[0], re.I | re.M))
            if len(matches) != 1 or matches[0][1] != value:
                return text
            if key in updates:
                start, end = matches[0].span(1)
                edits.append((section.start() + start, section.start() + end, updates[key]))
    for start, end, value in sorted(edits, reverse=True):
        text = text[:start] + value + text[end:]
    return text


def plan_bytes(data: bytes, db: dict, rabbit: bool, base: Path | None = None,
               *, after_moonholder: bool = False) -> Plan:
    text, encoding = decode(data)
    p = Plan(data, data)
    sections = list(SECTIONS.finditer(text))
    names = [m.group(1).lower() for m in sections if m.group(1).lower() not in ('constants', 'present')]
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
    texture_overrides: dict[int, dict[str, list[str]]] = {}
    named_sections = {m.group(1).lower(): m.group() for m in sections}
    hash_overrides = {}

    def override(block: str) -> str:
        name = section_name(block)
        if not name.lower().startswith('textureoverride') or re.fullmatch(r'TextureOverrideComponent\d+', name, re.I):
            return block
        hm = list(HASH.finditer(block))
        if len(hm) != 1:
            return block
        old = hm[0].group(2).lower()
        new = replace.get(old, old)
        if new == old:
            hash_overrides.setdefault(old, []).append(block)
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
                texture_overrides.setdefault(i, {}).setdefault(channel, []).append(block)
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
        if re.search(r'^[ \t]*(?:;[ \t]*)?run[ \t]*=[ \t]*CommandListSetTexturesComponent\d+\b', block, re.M | re.I):
            current = {channel: [item for item in items if HASH.search(item).group(2).lower() not in replace]
                       for channel, items in texture_overrides.get(i, {}).items()}
            fixed = repair_slot_bindings(block, i, named_sections, resources, base, rabbit,
                                         current, hash_overrides, textures, newline)
            if fixed != block:
                method = 'retain hash overrides' if '; run' in fixed else 'route slot textures through RabbitFX'
                p.changes.append(f'Component{i}: {method}')
            return fixed
        if rabbit and not re.search(r'RabbitFX', block, re.I):
            outfit = conditional_outfit_bindings(block, texture_overrides.get(i, {}), resources, base, newline)
            if outfit is not None:
                p.changes.append(f'Component{i}: bind conditional outfit textures')
                return outfit
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
    if after_moonholder and p.character == 'RoverFemale' and hashes == {'b7b6abd9'}:
        repaired = repair_rover_shape_keys(text, list(SECTIONS.finditer(text)))
        if repaired != text:
            p.changes.append(ROVER_SHAPE_KEY_CHANGE)
            text = repaired
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
    if rel.is_absolute() or '..' in rel.parts or rel.drive or ':' in relative or '\x00' in relative:
        code = 'outside-mods' if '..' in rel.parts or rel.is_absolute() else 'invalid-path'
        raise PathIssue(code, f'Unsafe relative path: {relative}')
    path = root
    for part in rel.parts:
        path = path / part
        if path.exists() and is_link(path):
            raise PathIssue('linked-path', f'Links/reparse points are not supported: {path}')
    if not path.resolve().is_relative_to(root):
        raise PathIssue('outside-mods', 'Path escapes root')
    return path


def ini_files(root: Path):
    for directory, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d.lower() not in ('kirifix-wwmi', 'kirifix-wwmi-logs', 'logs-kirifix') and not d.lower().startswith(('disabled', '.')) and not is_link(Path(directory) / d))
        for name in sorted(files):
            if name.lower().endswith('.ini') and not name.lower().startswith('disabled'):
                path = Path(directory) / name
                if not is_link(path):
                    yield path


def scan(root: Path, db: dict, *, after_moonholder: bool = False) -> list[Plan]:
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
        p = plan_bytes(path.read_bytes(), db, rabbit, path.parent, after_moonholder=after_moonholder)
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


def check_database(destination: Path, force: bool = False, now: float | None = None) -> None:
    now = time.time() if now is None else now
    metadata_path = destination.with_suffix('.source.json')
    raw = None
    metadata = {}
    try:
        raw = destination.read_bytes()
        validate_database(json.loads(raw))
    except (OSError, ValueError, KeyError, TypeError):
        raw = None
    try:
        value = json.loads(metadata_path.read_bytes())
        if isinstance(value, dict) and raw is not None and value.get('sha256') == digest(raw):
            metadata = value
    except (OSError, ValueError):
        pass
    next_check = metadata.get('next_check', 0)
    if not isinstance(next_check, (int, float)):
        next_check = 0
    if raw is not None and not force and now < next_check:
        print('Database check not due; using validated local cache.', flush=True)
        if metadata.get('last_error'):
            print('WARNING: Last database check failed; using local rules until the next retry.', flush=True)
        return
    headers = {'User-Agent': 'KiriFix-WWMI/' + VERSION}
    if raw is not None:
        if metadata.get('etag'):
            headers['If-None-Match'] = metadata['etag']
        if metadata.get('last_modified'):
            headers['If-Modified-Since'] = metadata['last_modified']
    print('Checking official database updates (network timeout: 3s)...', flush=True)
    try:
        request = urllib.request.Request(DATABASE_URL, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=3) as response:
                if not response.url.startswith('https://raw.githubusercontent.com/Moonholder/Wuwa_Mod_Fixer/'):
                    raise ValueError('Unexpected database redirect')
                downloaded = response.read(8_000_001)
                if len(downloaded) > 8_000_000:
                    raise ValueError('Database too large')
                validate_database(json.loads(downloaded))
                metadata['etag'] = response.headers.get('ETag')
                metadata['last_modified'] = response.headers.get('Last-Modified')
            if downloaded != raw:
                destination.parent.mkdir(parents=True, exist_ok=True)
                atomic_write(destination, downloaded)
                print('Database updated; checking which character rules changed.', flush=True)
            else:
                print('Database unchanged.', flush=True)
            raw = downloaded
        except urllib.error.HTTPError as exc:
            if exc.code != 304 or raw is None:
                raise
            print('Database unchanged (HTTP 304); no database body downloaded.', flush=True)
        metadata.update({'url': DATABASE_URL, 'sha256': digest(raw), 'checked_utc': now,
                         'next_check': now + 86400, 'last_error': None})
        save_json(metadata_path, metadata)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        if raw is None:
            raise ValueError(f'Database download failed and no valid cache exists: {exc}') from exc
        metadata.update({'url': DATABASE_URL, 'sha256': digest(raw), 'next_check': now + 600,
                         'last_error': str(exc)})
        save_json(metadata_path, metadata)
        print(f'WARNING: Database check failed ({exc}); using validated local cache. Retry in 10 minutes.', flush=True)


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
        'scope': 'Texture bindings and any shape key repairs listed per file',
    })
    (destination / 'changes.diff').write_bytes(''.join(diffs).encode('utf-8'))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description='KiriFix WWMI: known texture fixes, backups and rollback')
    parser.add_argument('--version', action='version', version=VERSION)
    parser.add_argument('--support-events', action='store_true', help=argparse.SUPPRESS)
    sub = parser.add_subparsers(dest='command', required=True)
    up = sub.add_parser('update-db', help='Explicitly download official JSON database (no programs)')
    up.add_argument('--database', type=Path, default=Path('data/moonholder.json'))
    for name in ('scan', 'apply', 'run', 'full-run'):
        command = sub.add_parser(name)
        command.add_argument('mods', type=Path)
        command.add_argument('--database', type=Path, default=Path('data/moonholder.json'))
        command.add_argument('--reports', type=Path, default=Path('reports'))
        if name in ('apply', 'run', 'full-run'):
            command.add_argument('--state', type=Path, default=Path('backups'))
        if name == 'full-run':
            command.add_argument('--force', action='store_true', help='Ignore successful-run cache and process all mods')
            command.add_argument('--refresh-db', action='store_true', help='Download database before processing')
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
            journal_data = json.loads(args.journal.read_text(encoding='utf-8'))
            if journal_data.get('format') == 2:
                rollback_full(args.mods, args.journal)
            else:
                rollback(args.mods, args.journal)
            print('Rollback verified.')
            return 0
        if args.support_events:
            emit_support('check-mods')
        root = args.mods.resolve(strict=True)
        # os.walk ignores an inaccessible root by default.
        with os.scandir(root):
            pass
        if not has_wwmi_components(root):
            if args.support_events:
                emit_support('no-mods')
            return location_warning()
        if args.support_events:
            emit_support('database')
        if args.command in ('run', 'full-run'):
            print(f'Automatic run. Mods: {root}', flush=True)
            if args.command == 'full-run':
                with activity('Checking database freshness'):
                    check_database(args.database, force=args.refresh_db)
            try:
                use_cache = False
                if args.command == 'full-run' and args.database.is_file():
                    try:
                        validate_database(json.loads(args.database.read_bytes()))
                        use_cache = True
                    except (ValueError, KeyError, TypeError):
                        pass
                if use_cache:
                    print('Using validated local database.', flush=True)
                else:
                    print('Updating official texture database...', flush=True)
                    with activity('Updating official texture database'):
                        update_database(args.database)
            except (OSError, ValueError, KeyError, TypeError) as exc:
                if not args.database.is_file():
                    raise ValueError(f'Database download failed and no cache exists: {exc}') from exc
                print(f'WARNING: update failed ({exc}); using validated local cache.', flush=True)
        raw = args.database.read_bytes()
        db = json.loads(raw)
        validate_database(db)
        print(f'Database version: {db.get("version", {}).get("current_version")}; SHA256: {digest(raw)}', flush=True)
        if args.command == 'full-run':
            full_run(root, args.database, args.state, args.reports, force=args.force, support=args.support_events)
            return 0
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
            if args.support_events:
                emit_support('no-mods')
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
        if args.support_events:
            emit_support('scanned', len(plans), changed, warnings)
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
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as exc:
        if args.support_events and (code := support_error(exc)):
            emit_support(code)
        print(f'ERROR: {exc}', file=sys.stderr)
        return 2


def moonholder_cli(runtime: Path) -> Path:
    runtime.mkdir(parents=True, exist_ok=True)
    executable = inside(runtime, 'wuwa-mod-cli-3.7.0.exe')
    if executable.exists():
        if digest(executable.read_bytes()) != MOONHOLDER_SHA256:
            raise ValueError('Moonholder executable checksum mismatch; refusing execution')
        return executable
    print('Downloading official Moonholder CLI 3.7.0...', flush=True)
    with urllib.request.urlopen(MOONHOLDER_URL, timeout=60) as response:
        raw = response.read(40_000_001)
    if len(raw) > 40_000_000 or digest(raw) != MOONHOLDER_SHA256:
        raise ValueError('Moonholder download checksum mismatch; refusing execution')
    atomic_write(executable, raw)
    return executable


def file_digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def copy_and_hash(source: Path, target: Path) -> str:
    value = hashlib.sha256()
    with source.open('rb') as reader, target.open('xb') as writer:
        for block in iter(lambda: reader.read(1024 * 1024), b''):
            writer.write(block)
            value.update(block)
    return value.hexdigest()


@contextmanager
def activity(label: str, interval: float = 5):
    started = time.monotonic()
    stopped = threading.Event()
    print(f'STAGE: {label}', flush=True)
    def heartbeat():
        while not stopped.wait(interval):
            print(f'WORKING: {label}; elapsed {time.monotonic() - started:.0f}s', flush=True)
    worker = threading.Thread(target=heartbeat, daemon=True)
    worker.start()
    try:
        yield
    finally:
        stopped.set()
        worker.join()
        print(f'TIME: {label}: {time.monotonic() - started:.2f}s', flush=True)


def prepare_stage(root: Path, stage: Path, skipped: list | None = None, selected: set | None = None) -> dict[str, str]:
    originals = {}
    files = list(ini_files(root))
    if not files:
        raise ValueError('No INI files to stage')
    groups = {}
    single_root = any(path.parent == root for path in files)
    for path in files:
        key = '.' if single_root else path.relative_to(root).parts[0]
        groups.setdefault(key, []).append(path)
    for index, (name, configs) in enumerate(groups.items(), 1):
        if selected is not None and name not in selected:
            continue
        print(f'COPY: mod {index}/{len(groups)} - {name}', flush=True)
        resources = {}
        missing = []
        for path in configs:
            text, _ = decode(path.read_bytes())
            paths = [path]
            for value in re.findall(r'^[ \t]*filename[ \t]*=[ \t]*([^\r\n]+)', text, re.M | re.I):
                resource = path.parent / value.strip()
                try:
                    relative = resource.relative_to(root).as_posix()
                except ValueError as exc:
                    raise PathIssue('outside-mods', str(exc)) from exc
                resource = inside(root, relative)
                try:
                    is_file = stat.S_ISREG(resource.stat().st_mode)
                except (FileNotFoundError, NotADirectoryError):
                    is_file = False
                if not is_file:
                    missing.append(relative)
                else:
                    paths.append(resource)
            for item in paths:
                resources[item.relative_to(root).as_posix()] = item
        if missing:
            reason = 'Missing resource: ' + ', '.join(missing)
            print(f'WARNING: Skipping entire mod {name}; {reason}', flush=True)
            if skipped is not None:
                skipped.append({'mod': name, 'reason': reason})
            continue
        for relative, item in resources.items():
            if relative not in originals:
                target = inside(stage, relative)
                target.parent.mkdir(parents=True, exist_ok=True)
                originals[relative] = copy_and_hash(item, target)
                if file_digest(item) != originals[relative]:
                    raise ValueError(f'Concurrent edit during staging: {relative}')
    if not originals:
        raise ValueError('Missing resources: no complete mods remain; no mod files changed')
    return originals


def commit_full(root: Path, stage: Path, originals: dict[str, str], state: Path) -> Path | None:
    changes = []
    staged_files = list(stage.rglob('*'))
    last_progress = 0
    for index, path in enumerate(staged_files, 1):
        if not path.is_file():
            continue
        relative = path.relative_to(stage).as_posix()
        if relative not in originals and path.suffix.lower() != '.png':
            continue
        if time.monotonic() - last_progress >= 2:
            print(f'CHECK: staged entry {index}/{len(staged_files)} - {relative}', flush=True)
            last_progress = time.monotonic()
        expected = originals.get(relative)
        if expected != file_digest(path):
            target = inside(root, relative)
            before = target.read_bytes() if expected is not None else None
            if before is not None and digest(before) != expected:
                raise ValueError(f'Concurrent edit; no changes applied: {relative}')
            changes.append((relative, before, path.read_bytes()))
    for index, (relative, expected) in enumerate(originals.items(), 1):
        if time.monotonic() - last_progress >= 2:
            print(f'CHECK: original file {index}/{len(originals)} - {relative}', flush=True)
            last_progress = time.monotonic()
        if not inside(stage, relative).is_file():
            raise ValueError(f'Staged resource disappeared: {relative}')
        if file_digest(inside(root, relative)) != expected:
            raise ValueError(f'Concurrent edit; no changes applied: {relative}')
    for relative, before, after in changes:
        target = inside(root, relative)
        if before is None and target.exists():
            raise ValueError(f'New resource already exists: {relative}')
    if not changes:
        print('No automatic changes needed.', flush=True)
        return None
    run = state.resolve() / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8])
    run.mkdir(parents=True, exist_ok=False)
    entries = []
    for i, (relative, before, after) in enumerate(changes):
        print(f'BACKUP: {i + 1}/{len(changes)} - {relative}', flush=True)
        backup = f'{i:04d}.bak' if before is not None else None
        if backup:
            atomic_write(run / backup, before)
        entries.append({'path': relative, 'backup': backup,
                        'before': digest(before) if before is not None else None, 'after': digest(after)})
    journal = run / 'journal.json'
    save_json(journal, {'format': 2, 'tool': VERSION, 'root': str(root), 'entries': entries})
    print(f'Recovery journal: {journal}', flush=True)
    try:
        for index, ((relative, before, after), entry) in enumerate(zip(changes, entries), 1):
            target = inside(root, relative)
            current = target.read_bytes() if target.exists() else None
            if current != before:
                raise ValueError(f'Concurrent edit: {relative}')
            target.parent.mkdir(parents=True, exist_ok=True)
            atomic_write(target, after)
            if target.read_bytes() != after:
                raise ValueError(f'Write verification failed: {relative}')
            print(f'APPLIED: {index}/{len(changes)} - {relative}', flush=True)
    except (OSError, ValueError) as exc:
        raise ValueError(f'{exc}; recovery journal: {journal}') from exc
    print(f'Applied and verified: {len(changes)} files. Rollback journal: {journal}', flush=True)
    return journal


def rollback_full(root: Path, journal: Path) -> None:
    root = root.resolve(strict=True)
    data = json.loads(journal.read_text(encoding='utf-8'))
    if data.get('format') != 2 or Path(data['root']).resolve() != root:
        raise ValueError('Journal root/format mismatch')
    restore, seen = [], set()
    for entry in data['entries']:
        target = inside(root, entry['path'])
        if target in seen:
            raise ValueError('Duplicate journal entry')
        seen.add(target)
        before = None
        if entry['before'] is not None:
            before = inside(journal.parent, entry['backup']).read_bytes()
            if digest(before) != entry['before']:
                raise ValueError('Backup checksum mismatch')
        elif entry['backup'] is not None:
            raise ValueError('Invalid new-file backup')
        current = target.read_bytes() if target.exists() else None
        if current == before:
            continue
        if current is None or digest(current) != entry['after']:
            raise ValueError(f'Later edits detected; refusing rollback: {target}')
        restore.append((target, current, before))
    for target, expected, before in restore:
        if target.read_bytes() != expected:
            raise ValueError('Concurrent edit during rollback')
        if before is None:
            target.unlink()
        else:
            atomic_write(target, before)
            if target.read_bytes() != before:
                raise ValueError('Rollback verification failed')


def run_moonholder(command: list[str], cwd: str, destination: Path, timeout: float = 900) -> tuple[int, list]:
    events = []
    pending = b''
    last_progress = 0
    def consume(data: bytes, final: bool = False):
        nonlocal pending, last_progress
        pending += data
        lines = pending.split(b'\n')
        pending = b'' if final else lines.pop()
        for line in lines:
            try:
                event = json.loads(line.decode('utf-8'))
            except (ValueError, UnicodeError):
                continue
            events.append(event)
            if not isinstance(event, dict):
                continue
            if event.get('event') in ('progress', 'file_success', 'file_skipped'):
                now = time.monotonic()
                if now - last_progress >= 1 or event.get('percent') == 100:
                    print(f'MOONHOLDER: {event.get("current", "?")}/{event.get("total", "?")} INI; {event.get("percent", "?")}%'
                          + (f' - {Path(event["path"]).name}' if event.get('path') else ''), flush=True)
                    last_progress = now
    stdout_path = destination / 'moonholder.stdout.log'
    with stdout_path.open('wb') as output, (destination / 'moonholder.stderr.log').open('wb') as errors:
        process = subprocess.Popen(command, cwd=cwd, stdout=output, stderr=errors)
        started = time.monotonic()
        try:
            with stdout_path.open('rb') as reader:
                while process.poll() is None:
                    consume(reader.read())
                    if time.monotonic() - started >= timeout:
                        raise subprocess.TimeoutExpired(command, timeout)
                    time.sleep(0.2)
                consume(reader.read(), final=True)
            return process.wait(), events
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()


def fast_inventory(root: Path) -> tuple[dict, set]:
    configs = list(ini_files(root))
    single = any(p.parent == root for p in configs)
    groups = {}
    rabbits = set()
    for config in configs:
        key = '.' if single else config.relative_to(root).parts[0]
        groups.setdefault(key, {})
        text, _ = decode(config.read_bytes())
        if re.search(r'^namespace[ \t]*=[ \t]*RabbitFX[ \t]*\r?$', text, re.M | re.I):
            rabbits.add(key)
    for directory, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d.lower() not in ('kirifix-wwmi', 'kirifix-wwmi-logs', 'logs-kirifix')
                         and not d.lower().startswith(('disabled', '.')) and not is_link(Path(directory) / d))
        for name in sorted(files):
            if name.lower().endswith(('.bak', '.log')) or name.lower().startswith(('disabled', '.')):
                continue
            path = Path(directory) / name
            if is_link(path):
                continue
            relative = path.relative_to(root)
            key = '.' if single else relative.parts[0]
            if key in groups:
                info = path.stat()
                groups[key][relative.as_posix()] = [info.st_size, info.st_mtime_ns, info.st_ctime_ns]
    return groups, rabbits


def rules_digest(value) -> str:
    return digest(json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8'))


def mod_rule_signatures(root: Path, db: dict, inventory: dict) -> dict:
    signatures = {}
    hashes_by_mod = {name: set() for name in inventory}
    single = '.' in inventory
    for path in ini_files(root):
        name = '.' if single else path.relative_to(root).parts[0]
        if name in hashes_by_mod:
            text, _ = decode(path.read_bytes())
            hashes_by_mod[name].update(m.group(2).lower() for m in HASH.finditer(text))
    lookup = {}
    for name, cfg in db['characters'].items():
        for item in cfg.get('main_hashes', []):
            for value in [item['new']] + item.get('old', []):
                lookup.setdefault(value.lower(), set()).add(name)
    for name, hashes in hashes_by_mod.items():
        characters = set().union(*(lookup.get(value, set()) for value in hashes)) if hashes else set()
        rules = {character: db['characters'][character] for character in sorted(characters)}
        signatures[name] = rules_digest(rules if characters else db['characters'])
    return signatures


def global_rules(db: dict) -> str:
    common = {key: value for key, value in db.items() if key not in ('characters', 'lang', 'version')}
    common['min_required_version'] = db.get('version', {}).get('min_required_version')
    return rules_digest(common)


def full_run(root: Path, database: Path, state: Path, reports: Path, force: bool = False,
             *, support: bool = False) -> None:
    started = time.monotonic()
    raw = database.read_bytes()
    db = json.loads(raw)
    with activity('Checking mod file lists, sizes and modification times'):
        inventory, rabbits = fast_inventory(root)
        rules = mod_rule_signatures(root, db, inventory)
    cache_path = database.resolve().parent / 'processed-mods.json'
    context = {'root': str(root.resolve()), 'logic': 'full-repair-v8', 'global_rules': global_rules(db),
               'moonholder': MOONHOLDER_SHA256,
               'rabbitfx': {name: inventory[name] for name in sorted(rabbits)}}
    cached = {}
    if not force and cache_path.is_file():
        try:
            saved = json.loads(cache_path.read_bytes())
            if isinstance(saved, dict) and saved.get('context') == context and isinstance(saved.get('mods'), dict):
                cached = saved.get('mods', {})
            elif isinstance(saved, dict) and isinstance(saved.get('context'), dict) and isinstance(saved.get('mods'), dict):
                previous = dict(saved['context'])
                if context['logic'] == 'full-repair-v2' and previous.pop('database', None) == digest(raw) and previous.pop('logic', None) == '0.3.0-preview.4':
                    expected = {key: value for key, value in context.items() if key not in ('logic', 'global_rules')}
                    if previous == expected:
                        cached = {name: dict(record, rules=rules.get(name)) for name, record in saved['mods'].items()
                                  if isinstance(record, dict)}
                        print('CACHE: Migrated verified preview.4 results; repair logic is unchanged.', flush=True)
        except (OSError, ValueError):
            print('WARNING: Invalid processing cache; full verification required.', flush=True)
    dirty = {name for name, signature in inventory.items()
             if not isinstance(cached.get(name), dict) or cached[name].get('files') != signature
             or cached[name].get('rules') != rules[name]}
    if support:
        emit_support('inventory', len(inventory) - len(dirty), len(dirty))
        cached_skips = sum(bool(cached[name].get('skipped')) for name in inventory.keys() - dirty)
        if cached_skips:
            emit_support('missing-resources', cached_skips)
    print(f'CACHE: {len(inventory) - len(dirty)}/{len(inventory)} mod folders unchanged; {len(dirty)} require processing.', flush=True)
    for name in sorted(inventory.keys() - dirty):
        if cached[name].get('skipped'):
            print(f'WARNING: Still skipping incomplete mod {name}: {cached[name]["skipped"]}', flush=True)
    if not dirty:
        save_json(cache_path, {'context': context, 'mods': {name: cached[name] for name in inventory}})
        print(f'FAST RUN: No changed mods or repair rules. Nothing copied or modified. Total: {time.monotonic() - started:.2f}s', flush=True)
        return
    runtime = database.resolve().parent.parent / '.runtime'
    if support:
        emit_support('moonholder-setup')
    with activity('Checking/downloading Moonholder CLI'):
        executable = moonholder_cli(runtime)
    destination = reports.resolve() / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8])
    destination.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix='full-stage-', dir=runtime) as temporary:
        stage = Path(temporary) / 'Mods'
        stage.mkdir()
        skipped = []
        if support:
            emit_support('staging')
        with activity('1/4 Copying mod resources and verifying checksums; originals unchanged'):
            try:
                originals = prepare_stage(root, stage, skipped, selected=dirty | rabbits)
            finally:
                if support and skipped:
                    emit_support('missing-resources', len(skipped))
                save_json(destination / 'skipped-mods.json', skipped)
        config = Path(temporary) / 'config.json'
        config.write_bytes(raw)
        print(f'Moonholder stage: {len(originals)} input files copied. Originals remain untouched.', flush=True)
        if support:
            emit_support('moonholder')
        with activity('2/4 Moonholder model and bone repair on temporary copies'):
            returncode, events = run_moonholder(
                [str(executable), '--path', str(stage), '--config', str(config), '--format', 'json'],
                temporary, destination)
        finishes = [e for e in events if isinstance(e, dict) and e.get('event') == 'finish']
        if returncode or not finishes or not finishes[-1].get('success') or finishes[-1].get('summary', {}).get('failure_count', 0):
            if support:
                emit_support('moonholder-failed')
            raise ValueError(f'Moonholder repair failed; originals unchanged. Details: {destination}')
        print('Moonholder stage verified. Running RabbitFX texture stage...', flush=True)
        if support:
            emit_support('textures')
        with activity('3/4 Texture and shape key processing on temporary copies'):
            plans = scan(stage, db, after_moonholder=True)
            if support:
                emit_support('scanned', len(plans), sum(p.after != p.before for p in plans),
                             sum(len(p.warnings) for p in plans))
                emit_support('rover-eyes', sum(ROVER_SHAPE_KEY_CHANGE in p.changes for p in plans))
            report(plans, stage, raw, db, destination / 'textures')
            for p in plans:
                if p.after != p.before:
                    atomic_write(p.path, p.after)
        if support:
            emit_support('applying')
        with activity('4/4 Validating originals, saving backups and applying changes'):
            journal = commit_full(root, stage, originals, state)
        save_json(destination / 'full-report.json', {'tool': VERSION, 'root': str(root),
                  'moonholder': '3.7.0', 'database_sha256': digest(raw),
                  'journal': str(journal) if journal else None, 'skipped_mods': skipped, 'events': events})
        if skipped:
            print(f"WARNING: {len(skipped)} incomplete mod(s) skipped; see {destination / 'skipped-mods.json'}", flush=True)
        print(f'Full report: {destination}', flush=True)
        current, current_rabbits = fast_inventory(root)
        eligible = set(inventory) - dirty | {name for name in dirty if name in current}
        changed_paths = set()
        if journal:
            changed_paths = {e['path'] for e in json.loads(journal.read_bytes())['entries']}
        if support:
            emit_support('applied', len(changed_paths))
        for name in inventory:
            old_unwritten = {p: v for p, v in inventory[name].items() if p not in changed_paths}
            new_unwritten = {p: v for p, v in current.get(name, {}).items() if p not in changed_paths}
            if old_unwritten != new_unwritten:
                eligible.discard(name)
        if any(name not in eligible for name in rabbits) or current_rabbits != rabbits:
            eligible.clear()
        reasons = {entry['mod']: entry['reason'] for entry in skipped}
        records = {name: {'files': current[name], 'skipped': reasons.get(name) if name in dirty else cached.get(name, {}).get('skipped')}
                   for name in eligible if name in current}
        post_rules = mod_rule_signatures(root, db, current)
        for name, record in records.items():
            record['rules'] = post_rules[name]
        context['rabbitfx'] = {name: current[name] for name in sorted(current_rabbits)}
        save_json(cache_path, {'context': context, 'mods': records})
        print(f'TIME: Full run total: {time.monotonic() - started:.2f}s', flush=True)


if __name__ == '__main__':
    raise SystemExit(main())
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
