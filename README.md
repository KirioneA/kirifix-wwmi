# KiriFix WWMI

An experimental one-click Wuthering Waves mod repair helper combining the official Moonholder CLI with conservative RabbitFX texture repairs, backups, rollback and logs.

Created and maintained by **Kiri1**.

Version: **0.3.0 — Experimental**. This project is independent of Moonholder and Caverabbit.

## Requirements

- Windows with Windows PowerShell 5.1.
- The Windows x64 release includes a portable Python runtime.
- WWMI and RabbitFX installed separately.
- Internet access for the first database download.

## Run

Extract the archive's `KiriFix-WWMI` folder into the Mods folder you want to repair.
Close the game and double-click `KiriFix-WWMI/KiriFix-WWMI.cmd`.
It checks the official database automatically at most once per day, using conditional
HTTP requests when the server provides validators. It downloads the pinned official
Moonholder CLI 3.7.0 on first use,
and verifies its SHA-256 before every execution. It copies enabled INIs and referenced
resources to temporary disk storage, runs Moonholder first and RabbitFX processing second,
then saves a combined recovery journal before applying verified changes.
Allow additional free disk space for the referenced mod resources and backups.
The tool hashes resources in chunks; it does not retain all textures in memory.
Progress shows four processing stages, file counters and live Moonholder completion events.
Long operations print a working message every five seconds with elapsed time. Counters
are per stage, not an overall percentage or an estimated completion time.
This build is provided for testing before public release.

When the CMD is inside a folder named `KiriFix-WWMI`, its parent is the default target.
If you move the CMD out into Mods, it scans the CMD's containing folder and keeps using
the `KiriFix-WWMI` subfolder for service files. Both layouts use the same backups and cache.
It does not search AppData or other drives. Drag another Mods folder onto the CMD to override
the target. For desktop access, create a shortcut to the installed CMD instead of moving it.

```text
Mods/
  Shorekeeper/
  RabbitFX/
  KiriFix-WWMI/
    KiriFix-WWMI.cmd
    logs/
    backups/
    reports/
    data/
    .runtime/
```

If no WWMI component sections or no recognizable characters are found, the helper stops
without modifying mod files and displays a yellow warning. A missing structure is detected
before downloading the database. An empty or unsupported mod folder can also trigger this warning.
Interactive warning launches wait for Enter so the message remains visible; successful launches
do not prompt. The warning is recorded in the launch log. Exit code `3` indicates no detected mods.

The installed game version is not detected. Review the results in game.
Do not run multiple instances or edit mod files during a run.

## Fast repeat runs

Successful runs save a metadata cache per mod folder. Unchanged file lists, sizes and
modification/creation times skip copying and Moonholder execution. Changed character rules invalidate the cache for matching mods. Changes to shared
settings, repair logic, CLI version or RabbitFX can require broader processing.
Database version labels and translations alone do not force repairs. Unknown-character
mods conservatively depend on all character rules so newly supported characters are detected. Changed
mods are staged separately; RabbitFX dependencies are included when needed. Missing
resource warnings remain visible even when an incomplete folder is cached.

Metadata checks do not detect edits that preserve all recorded metadata. Use force
mode for a full recheck. The preview.4 cache is migrated only if its database checksum, root and dependencies
match. Other incompatible caches require a new full run and can take longer. This cache is an optimization,
not a security verification of mod content.

Normal runs check database freshness once per day. The network socket timeout is
three seconds. If the server responds HTTP 304, no database body is downloaded.
A failed check keeps a validated local database, displays a warning and delays the
next retry for ten minutes. Without a valid local database, download failure stops
the operation. Use update mode to bypass the daily schedule. Network latency on a
scheduled check is additional to the fast file inventory; this is not a hard total
wall-clock timeout for slow streaming responses.

```bat
"D:\WWMI\Mods\KiriFix-WWMI\KiriFix-WWMI.cmd" "D:\WWMI\Mods" force
"D:\WWMI\Mods\KiriFix-WWMI\KiriFix-WWMI.cmd" "D:\WWMI\Mods" update
```

Stage timings and total helper time are printed to the launch log. The entire CMD
startup includes PowerShell/Python startup time in addition to the helper timing.

## Files created locally

| Folder | Contents |
| --- | --- |
| `KiriFix-WWMI/logs/run-*.log` | Output and errors from the last three launches |
| `KiriFix-WWMI/backups/` | Original INI bytes and recovery journals; never automatically deleted |
| `KiriFix-WWMI/reports/` | Proposed changes, warnings and diffs |
| `KiriFix-WWMI/data/` | Downloaded database and source metadata |
| `KiriFix-WWMI/.runtime/` | Python source extracted from the CMD |

The `KiriFix-WWMI` folder is excluded from scanning. Old `KiriFix-WWMI-Logs` and
`Logs-KiriFix` service folders are also excluded. Existing backups and service folders from older
versions are not moved or deleted automatically; keep old backups for rollback.

Logs can contain your Windows username, computer name and local paths.
Do not publish logs, backups or mod files without reviewing them.
The helper does not upload them. Network requests download the official database and the pinned official CLI executable. No mod data is uploaded.

The CMD launcher uses Python isolated mode to prevent imports from the extracted
script directory and Python environment overrides. It rejects existing linked
service paths and allows only one CMD instance per Windows session. These checks
do not protect against an attacker who can modify the CMD itself or actively
change its folder during execution. Safety failures before logging starts are
shown in the console. Run from a trusted, writable folder without administrator rights.

## Scan and rollback

```bat
"D:\WWMI\Mods\KiriFix-WWMI\KiriFix-WWMI.cmd" "D:\WWMI\Mods" scan
"D:\WWMI\Mods\KiriFix-WWMI\KiriFix-WWMI.cmd" "D:\WWMI\Mods" rollback "D:\WWMI\Mods\KiriFix-WWMI\backups\RUN-ID\journal.json"
```

Scan mode does not download the database or modify mods; an existing database cache
is required. Rollback verifies checksums and refuses to overwrite later manual edits.
The format-2 journal is created before original mod files are changed. It covers INIs,
binary buffers and new resource files. Rollback removes newly created files after checking
their hashes. Legacy format-1 journals remain supported. Writes are atomic per file,
not per batch; an interrupted batch requires rollback with the printed journal.

## Scope and limitations

The helper recognizes characters from component hashes, updates known texture hash
rules and adds RabbitFX texture assignments when the database and local resources
provide an unambiguous match. It preserves existing RabbitFX assignments and skips
unsupported or conditional resource logic. Disabled folders and internal links are skipped.

The default run delegates model hashes, supported vertex-group remaps and other default
repairs to Moonholder. Its optional rendering/stable-texture switches are not enabled.
Moonholder can add fallback textures and resource checks. The second stage remains
limited to conservative texture hash updates and RabbitFX assignments.
Scan mode previews ONLY the texture stage and does not run Moonholder.
It does not install RabbitFX or automatically update the pinned CLI or its own code.
Mods with missing resources are skipped as a whole, with a warning and a skipped-mods.json report.
Other complete mods continue. A mod is grouped by its top-level folder under the selected root;
when the selected root contains an INI directly, it is treated as a single mod.
References outside the selected root still stop full repair before writes.
Manually changing a model hash can prevent a matching vertex-group repair from triggering:
restore the original INI and buffers together before retrying. Never restore just an old INI
over already repaired buffers. Some authoring errors still require Blender.
The temporary stage includes declared filename resources; unusual undeclared dependencies
may be unsupported. Start with a copy of one mod and inspect the result in game.
Its RabbitFX check detects namespace and command-list declarations; it does not
validate the installed version or detect duplicate installations.

When a database update fails, an existing validated cache is used. Without a usable
database, the operation fails. A successful exit verifies file operations, not visual correctness.

## Development

```text
python -m unittest discover -s tests -v
python scripts/build.py
```

The build creates `dist/KiriFix-WWMI.cmd` from readable source files.
The release archive should contain the CMD, this README, LICENSE and THIRD_PARTY.md.
The database and other third-party software are not bundled.

## Credits and licensing

Known repair data comes from [Moonholder / Wuwa_Mod_Fixer](https://github.com/Moonholder/Wuwa_Mod_Fixer).
RabbitFX is by [Caverabbit](https://gamebanana.com/mods/527815).
See [THIRD_PARTY.md](THIRD_PARTY.md) for dependency licensing information.
The helper's original code is provided under the MIT License.

Project direction, feature decisions and in-game testing by Kiri1.
AI tools were used for code generation, review and documentation.
This is a testing release and does not claim universal compatibility.
