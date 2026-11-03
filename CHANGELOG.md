# Changelog

## 0.3.0 — Model repairs and fast repeat runs

- Run official Moonholder CLI 3.7.0 on temporary copies before RabbitFX texture processing.
- Download the CLI separately and verify its pinned SHA-256 before execution.
- Back up changed INIs and binary buffers, with checksummed rollback for added resources.
- Skip incomplete mods without blocking other complete mod folders.
- Show processing progress, elapsed time and per-stage timings.
- Cache successful processing and stage only changed mods and required dependencies.
- Check database updates once per day, with conditional requests and validated offline fallback.
- Invalidate matching character caches for changed rules; retain conservative shared-rule checks.
- Preserve Unicode mod paths in console output and logs.

## 0.2.4 — Unicode output

- Force UTF-8 for Python output and PowerShell decoding, including isolated Python launches.
- Preserve Chinese, Cyrillic and emoji mod paths in launch logs.
- Restore the previous console output encoding when the launcher exits.
- Add a regression test using a legacy Windows console encoding.

## 0.2.3 — Contained installation

- Package the CMD and documentation inside one `KiriFix-WWMI` folder.
- Scan the parent Mods folder when the CMD is inside `KiriFix-WWMI`.
- Support moving the CMD into Mods while retaining the same service folder.
- Keep the last three launch logs under `KiriFix-WWMI/logs`.
- Stop with a yellow, logged placement warning when WWMI mods cannot be detected.
- Exclude current and legacy service directories from scanning.

## 0.2.2 — Local Mods folder

- Use the CMD's containing folder as the default repair target.
- Group logs, backups, reports, database cache and runtime files under `KiriFix-WWMI-Logs`.
- Exclude `KiriFix-WWMI-Logs` from mod scanning.
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
