# tools

Helper scripts for developing and testing the archiver. Not used by `main.ps1` at runtime.

## seed-testdata.ps1

Generates pseudo log files for testing `main.ps1`. It reads the rules from the JSON config and, for
each rule, creates files whose names **match that rule's `FileNamePattern`**, filled with random
(incompressible) text up to a maximum size.

Files are written to a sandbox folder (`testdata\` by default, one subfolder per rule), so the
generator never touches the real `SourcePath` from the config. `testdata\` is git-ignored.

### Mode-aware generation

The script mirrors how the archiver treats each rule:

| `CleanSourceFiles` | Mode | What it generates |
|---|---|---|
| `true` | rotation | Files spread across `-Days` past days (`-FilesPerDay` each), backdated — so date grouping and today-exclusion can be tested |
| `false` | keep | A flat batch of `-KeepModeFileCount` files (the archiver makes a single archive and does not split by date) |

> **Fixed patterns:** a fully anchored literal such as `^current_active.log$` matches only one name,
> so exactly one file is produced for it regardless of the requested count. The script reports this.

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `ConfigPath` | `..\configurations\directories_list.json` | Path to the rules JSON |
| `OutputRoot` | `..\testdata` | Root folder for generated files (one subfolder per rule) |
| `Days` | `30` | Distinct past days for rotation rules |
| `FilesPerDay` | `10` | Files per day for rotation rules |
| `KeepModeFileCount` | `10` | Files for keep rules (`CleanSourceFiles = false`) |
| `MaxFileSizeBytes` | `1MB` | Upper bound per file; actual size is random up to this |

### Examples

```powershell
# Full default set: rotation rules get 10 files/day x 30 days, up to 1 MB each
.\tools\seed-testdata.ps1

# Lightweight run (faster, smaller) while iterating
.\tools\seed-testdata.ps1 -Days 5 -FilesPerDay 3 -KeepModeFileCount 4 -MaxFileSizeBytes 200KB

# Use a different config and output location
.\tools\seed-testdata.ps1 -ConfigPath .\configurations\polygon.json -OutputRoot D:\seed
```

### Using the output

The bundled config already points each rule's `SourcePath` at `testdata\<rule>`, so after seeding you
can run the archiver straight away. The seeder also creates each rule's `DestinationPath` (the archiver
does **not** create it), so no manual setup is needed:

```powershell
.\tools\seed-testdata.ps1   # generates source files AND creates destination folders
.\main.ps1                  # run from the project root (paths are relative to the current directory)
```

> Both scripts resolve relative paths against the current directory, so run them from the project root.

### Notes

- **Volume/time:** the default set produces up to ~300 files (up to ~300 MB) per rotation rule and
  takes a little while to generate. Dial it down with `-Days` / `-FilesPerDay` / `-MaxFileSizeBytes`.
- **PowerShell 4 compatible**, like the rest of the project.
