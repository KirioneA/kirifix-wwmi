# Changelog

## 0.2.2 — Local Mods folder

- Use the CMD's containing folder as the default repair target.
- Group logs, backups, reports, database cache and runtime files under `Logs-KiriFix`.
- Exclude `Logs-KiriFix` from mod scanning.
- Keep explicit drag-and-drop folder selection and the 0.2.1 launcher protections.
- Preserve old service folders and backups without automatic migration.

## 0.2.1 — Security hardening

- Run Python probes and the embedded helper in isolated mode.
- Reject linked service paths before writing runtime files, logs or cached data.
- Block concurrent CMD instances in the same Windows session.
- Add three Windows integration tests covering module substitution, junction paths and concurrent launches.

## 0.2.0 — Experimental

- Adopted the KiriFix WWMI project name.
- Combined database download, scan and application into one CMD launcher.
- Added output and error logging for the last three launches.
- Retained byte backups, recovery journals, checksum checks and rollback.
- Preserved existing RabbitFX logic and skipped ambiguous texture assignments.
- Added English-only documentation and removed code comments.
- Kept RabbitFX and the upstream database outside release archives.
