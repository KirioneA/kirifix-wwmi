# KiriFix WWMI

An experimental one-click Wuthering Waves mod texture repair helper using
Moonholder's database, with backups, rollback and logs.

Version: **0.2.1 — Experimental**. This project is independent of Moonholder and Caverabbit.

## Requirements

- Windows with Windows PowerShell 5.1.
- Python 3.10 or newer. An existing Codex Python runtime can also be used.
- WWMI and RabbitFX installed separately.
- Internet access for the first database download.

## Run

Extract the release archive into a writable folder outside Mods. Close the game,
then double-click `KiriFix-WWMI.cmd`. It updates the database and applies unambiguous
known texture fixes automatically, without confirmation prompts.

The default Mods directory is `%APPDATA%\XXMI Launcher\WWMI\Mods`.
Drag another Mods folder onto the CMD file to override it.

The installed game version is not detected. Review the results in game.
Do not run multiple instances or edit mod files during a run.

## Files created locally

| Folder | Contents |
| --- | --- |
| `logs/` | Output and errors from the last three launches, including failed launches |
| `backups/` | Original INI bytes and recovery journals; never automatically deleted |
| `reports/` | Proposed changes, warnings and diffs |
| `data/` | Downloaded database and source metadata |
| `.runtime/` | Python source extracted from the CMD |

Logs can contain your Windows username, computer name and local paths.
Do not publish logs, backups or mod files without reviewing them.
The helper does not upload them. Network requests download the official database.

The CMD launcher uses Python isolated mode to prevent imports from the extracted
script directory and Python environment overrides. It rejects existing linked
service paths and allows only one CMD instance per Windows session. These checks
do not protect against an attacker who can modify the CMD itself or actively
change its folder during execution. Safety failures before logging starts are
shown in the console. Run from a trusted, writable folder without administrator rights.

## Scan and rollback

```bat
"KiriFix-WWMI.cmd" "D:\WWMI\Mods" scan
"KiriFix-WWMI.cmd" "D:\WWMI\Mods" rollback "backups\RUN-ID\journal.json"
```

Scan mode does not download the database or modify mods; an existing database cache
is required. Rollback verifies checksums and refuses to overwrite later manual edits.
The journal is created before INI changes. Writes are atomic per file, not per batch.

## Scope and limitations

The helper recognizes characters from component hashes, updates known texture hash
rules and adds RabbitFX texture assignments when the database and local resources
provide an unambiguous match. It preserves existing RabbitFX assignments and skips
unsupported or conditional resource logic. Disabled folders and internal links are skipped.

It does not repair geometry, vertex groups, expressions, buffers or every mod failure.
It does not install or update RabbitFX, change texture files, remove legacy
`CheckTextureOverride` commands or automatically update its own code.
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

## Credits, licensing and AI disclosure

Known repair data comes from [Moonholder / Wuwa_Mod_Fixer](https://github.com/Moonholder/Wuwa_Mod_Fixer).
RabbitFX is by [Caverabbit](https://gamebanana.com/mods/527815).
See [THIRD_PARTY.md](THIRD_PARTY.md) for dependency licensing information.
The helper's original code is provided under the MIT License.

The code was generated with AI assistance, including substantial implementation,
design and documentation work. Requirements and manual testing were supplied by the project owner.
This is a testing release and does not claim universal compatibility.
