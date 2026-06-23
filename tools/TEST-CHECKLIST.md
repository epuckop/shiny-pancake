# Test Checklist

Critical behaviours worth verifying before trusting a change — especially any
change that touches file movement, deletion, or the exit-code contract. This is
a list of **what** to assert, not **how**; pick your own method (Pester, manual
runs with `seed-testdata.ps1`, etc.). Each item states the expected outcome.

> This is a deletion-capable tool. The highest-priority items are the ones that
> protect source data from being lost.

---

## Prerequisites & config validation

- [ ] Missing `7za.exe` → ERROR logged, run aborts with exit code `2`.
- [ ] Present but non-functional `7za.exe` → ERROR, exit `2`.
- [ ] Unparseable / malformed JSON config → ERROR, exit `2`.
- [ ] Rule missing a required field (`Name`, `SourcePath`, `DestinationPath`, `CleanSourceFiles`, `Mandatory`) → validation ERROR, run aborts.
- [ ] `Name` / `ArchiveNamePrefix` / `ArchiveNameSuffix` containing invalid filename chars → validation ERROR.
- [ ] Invalid `DateFormat` → validation ERROR.
- [ ] Invalid `FileNamePattern` regex → validation ERROR.
- [ ] Fully valid config → validation passes, processing begins, receipt dir created.

## Rule processing

- [ ] Non-existent `SourcePath` → WARN, rule skipped, other rules still run.
- [ ] Non-existent `DestinationPath` → ERROR, rule skipped, other rules still run.
- [ ] No files in source, `Mandatory = true` → ERROR (exit `2`).
- [ ] No files in source, `Mandatory = false` → INFO, no error.
- [ ] `FileNamePattern` set → only matching files are processed; non-matching ignored.
- [ ] No files match pattern, `Mandatory = true` → ERROR; `Mandatory = false` → INFO.
- [ ] A failing rule does not stop subsequent rules.

## Job generation

- [ ] `CleanSourceFiles = true` → files modified **today** are excluded (left in source).
- [ ] `CleanSourceFiles = true` → remaining files grouped by `LastWriteTime` date; one job per date group.
- [ ] `CleanSourceFiles = false` → single job for all matching files, named with the current date.
- [ ] Jobs run smallest-first (ascending uncompressed size).
- [ ] Archive name resolves to `[prefix_]COMPUTERNAME_date[_suffix].zip` with the configured `DateFormat`.

## Job execution & data safety (highest priority)

- [ ] Staged files are deleted **only after** `7za t` integrity test passes.
- [ ] Compression failure → fresh partial archive removed; temp dir left in place; source data intact.
- [ ] Integrity-test failure → same as above (archive cleaned, temp dir preserved, no data loss).
- [ ] Pre-existing same-day archive (append case) is **not** deleted on a later failure.
- [ ] `CleanSourceFiles = true` → originals removed only on success; locked file falls back to copy + WARN.
- [ ] `CleanSourceFiles = false` → originals always preserved.
- [ ] Successful job writes a receipt with job name, UTC, archive path, and per-file original UTC write times.

## Disk-space pre-flight

- [ ] Destination free space checked before staging (estimate uses `ExpectedCompressionPercent` + existing-archive size + safety buffer).
- [ ] Keep mode (`CleanSourceFiles = false`) also checks source volume for the temp copy.
- [ ] A job that won't fit → ERROR, and it plus all larger remaining jobs in that rule are skipped (exit `2`).
- [ ] Free space undeterminable → WARN, job proceeds without the check.

## Crash recovery (leftover temp dirs)

- [ ] Leftover temp dir from an interrupted run is detected at rule start, archived, integrity-tested, removed.
- [ ] Recovery writes a receipt with `"Recovered": true`.
- [ ] Empty leftover dir → WARN, deleted.
- [ ] Recovery failure (compress or test) → ERROR, that dir left in place, normal processing still continues.

## Resource throttling

- [ ] `-LimitResources $true` → priority + CPU affinity applied; failure to apply → WARN, run continues normally.
- [ ] `-LimitResources $false` → no throttling attempted; `CpuPercent` / `ProcessPriority` ignored.
- [ ] `CpuPercent` floored, minimum 1 core.

## Logging & exit codes (scheduler contract)

- [ ] Clean run → exit `0`.
- [ ] Warnings only, no errors → exit `1`.
- [ ] Any error → exit `2`.
- [ ] Exit code is set deterministically even on an unhandled exception (errors logged, never re-thrown).
- [ ] Log processor flushes all queued messages before the process exits.
