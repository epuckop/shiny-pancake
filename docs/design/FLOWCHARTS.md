# Log Rotation & Archiving Script — Flowchart Diagrams

Companion to `ARCHITECTURE.md` — these Mermaid diagrams visualize the script's logic flows.

> **Note:** Mermaid diagrams render in GitHub, GitLab, Notion, Obsidian, and VS Code with the Mermaid Preview extension.

---

## 1. Top-Level Execution Flow

```mermaid
flowchart TD
    A[Start] --> B[Load Parameters]
    B --> C[Import Modules]
    C --> D[Start-LogProcessor]
    D --> E[Phase 1: Prerequisites]
    E --> F{7-Zip exists?}
    F -->|No| G[ERROR: 7-Zip not found]
    G --> Z[Abort]
    F -->|Yes| H{7-Zip functional?}
    H -->|No| I[ERROR: 7-Zip not functional]
    I --> Z
    H -->|Yes| J[Load JSON Config]
    J --> K{Config loaded?}
    K -->|No| L[ERROR: Config load failed]
    L --> Z
    K -->|Yes| M[Validate Config]
    M --> N{Valid?}
    N -->|No| O[ERROR: Validation failed]
    O --> Z
    N -->|Yes| P[Create receipt dir]
    P --> Q[Phase 2: Rules Processing]
    Q --> R[Phase 3: Cleanup]
    R --> S[Stop-LogProcessor]
    S --> T[End]
```

---

## 2. Prerequisites Validation

```mermaid
flowchart TD
    A[Start Prerequisites] --> B[Test 7-Zip path]
    B --> C{Path exists?}
    C -->|No| D[Log ERROR]
    D --> E[Throw]
    C -->|Yes| F[Run 7za.exe]
    F --> G{Exit code = 0?}
    G -->|No| H[Log ERROR]
    H --> E
    G -->|Yes| I[Log INFO: 7-Zip OK]
    I --> J[Get-JsonContent]
    J --> K{Parse success?}
    K -->|No| L[Log ERROR]
    L --> E
    K -->|Yes| M[Validate each rule]
    M --> N{All valid?}
    N -->|No| O[Log ERROR]
    O --> E
    N -->|Yes| P[Create receipt dir]
    P --> Q[Return OK]
```

---

## 3. Config Validation (Per Rule)

```mermaid
flowchart TD
    A[Validate Rule] --> B{Name blank?}
    B -->|Yes| C[Log ERROR]
    B -->|No| D{SourcePath blank?}
    D -->|Yes| C
    D -->|No| E{DestPath blank?}
    E -->|Yes| C
    E -->|No| F{CleanSourceFiles missing?}
    F -->|Yes| C
    F -->|No| G{Mandatory missing?}
    G -->|Yes| C
    G -->|No| H{Name has invalid chars?}
    H -->|Yes| C
    H -->|No| I{ArchiveNamePrefix invalid?}
    I -->|Yes| C
    I -->|No| J{ArchiveNameSuffix invalid?}
    J -->|Yes| C
    J -->|No| K{DateFormat set?}
    K -->|No| L{FileNamePattern set?}
    K -->|Yes| M{DateFormat valid?}
    M -->|No| C
    M -->|Yes| L
    L -->|No| N[Return OK]
    L -->|Yes| O{Regex valid?}
    O -->|No| C
    O -->|Yes| N
```

---

## 4. Rule Processing Flow

```mermaid
flowchart TD
    A[Start Rule: Name] --> B{SourcePath exists?}
    B -->|No| C[Log WARN, SKIP]
    B -->|Yes| D{DestPath exists?}
    D -->|No| E[Log ERROR, SKIP]
    D -->|Yes| F[Get-ChildItem files]
    F --> G{Files found?}
    G -->|No| H{Mandatory?}
    H -->|Yes| I[Log ERROR]
    H -->|No| J[Log INFO]
    I --> C
    J --> C
    G -->|Yes| K[Apply FileNamePattern]
    K --> L{Pattern set?}
    L -->|No| M[Keep all files]
    L -->|Yes| N[Regex match filter]
    N --> O{Any match?}
    O -->|No| P{Mandatory?}
    P -->|Yes| Q[Log ERROR, SKIP]
    P -->|No| R[Log INFO, SKIP]
    Q --> C
    R --> C
    O -->|Yes| S[Job Generation]
    S --> T
```

---

## 5. Job Generation (CleanSourceFiles Branching)

```mermaid
flowchart TD
    A[Start Job Generation] --> B{CleanSourceFiles?}
    B -->|true| C[Exclude today's files]
    C --> D[Group by LastWriteTime date]
    D --> E{Groups found?}
    E -->|No| F[Log INFO, SKIP]
    E -->|Yes| G[Create one job per group]
    G --> H[Return jobs]
    B -->|false| I[Single job for all files]
    I --> J[Use current date]
    J --> K[Return single job]
    H --> T[End]
    K --> T
    F --> T
```

---

## 6. Job Execution (Per Job)

```mermaid
flowchart TD
    A[Start Job] --> B[Build ArchiveName]
    B --> C[Create temp dir]
    C --> D{CleanSourceFiles?}
    D -->|true| E[Move-Item to temp]
    D -->|false| F[Copy-Item to temp]
    E --> G[7za.exe compress -sdel]
    F --> G
    G --> H{7-Zip success?}
    H -->|No| I[Log ERROR, throw]
    H -->|Yes| J{Archive exists?}
    J -->|No| K[Log ERROR, throw]
    J -->|Yes| L[Remove temp dir]
    L --> M[Write JSON receipt]
    M --> N[Log INFO: Job done]
    I --> O[Log ERROR: Job failed]
    K --> O
    N --> P[End Job]
    O --> P
```

---

## 7. Archive Name Construction

```mermaid
flowchart LR
    A[ArchiveNamePrefix] --> C[Prefix]
    D[env:COMPUTERNAME] --> E[ComputerName]
    F[BackupDate] --> G[Date dd-MM-yy]
    H[ArchiveNameSuffix] --> I[Suffix]
    C --> J[ArchiveName]
    E --> J
    G --> J
    I --> J
    J --> K["<prefix>_<COMPUTERNAME>_<date>_<suffix>.zip"]
```

---

## 8. Receipt File Structure

```mermaid
flowchart TD
    A[Receipt Path] --> B["receipt/YYYY-MM-DD/"]
    B --> C["<JobName>_<unix_timestamp>.json"]
    C --> D[JSON Content]
    D --> E["Name: Job display name"]
    D --> F["UTC: Timestamp ISO 8601"]
    D --> G["Archive: Full archive path"]
    D --> H["Files: Array of file info"]
    H --> I["  Name: filename"]
    H --> J["  LastWriteTimeUtc: UTC ISO 8601"]
```

---

## 9. Error Handling Hierarchy

```mermaid
flowchart TD
    A[Global try] --> B[Rule try]
    B --> C[Job try]
    C --> D[Job catch]
    D --> E[Log ERROR, continue]
    C --> F[Job finally]
    F --> G[Log INFO]
    B --> H[Rule catch]
    H --> I[Log WARN, continue]
    B --> J[Rule finally]
    J --> K[Log INFO]
    A --> L[Global catch]
    L --> M[throw critical error]
    A --> N[Global finally]
    N --> O[Stop-LogProcessor]
```

---

## 10. Async Logger Architecture

```mermaid
flowchart TD
    A[main.ps1] -->|Add-LogMessage| B[Message Queue]
    B --> C[Background Runspace]
    C --> D{Queue has items?}
    D -->|No| E[Wait 100ms]
    E --> D
    D -->|Yes| F[Dequeue message]
    F --> G[Write to log file]
    G --> D
    H[Stop-LogProcessor] --> I[Signal shutdown]
    I --> J[Flush remaining]
    J --> K[Close queue]
    K --> L[Stop runspace]
```

---

## 11. CleanSourceFiles = true — File Lifecycle

```mermaid
flowchart TD
    A[Original file: app.log<br/>LastWrite: 2025-01-14] --> B{Today's date?}
    B -->|Yes| C[EXCLUDED from archive]
    B -->|No| D[Move to temp dir]
    D --> E[Temp dir: app.log<br/>Move-Item removes original]
    E --> F[7za.exe compress]
    F --> G[Archive: AppLog_14-01-25.zip]
    G --> H[Temp dir deleted<br/>-sdel flag]
    H --> I[Receipt entry:<br/>LastWriteTimeUtc: 2025-01-14T...]
    C --> J[File remains in source]
```

---

## 12. CleanSourceFiles = false — File Lifecycle

```mermaid
flowchart TD
    A[Original file: app.log<br/>LastWrite: 2025-01-14] --> B[Copy to temp dir]
    B --> C[Temp dir: app.log<br/>Copy preserves original]
    C --> D[Original still in source]
    D --> E[7za.exe compress]
    E --> F[Archive: AppLog_14-01-25.zip]
    F --> G[Temp dir deleted]
    G --> H[Receipt entry:<br/>LastWriteTimeUtc: 2025-01-14T...]
    H --> I[File still exists in source]
```

---

## 13. Full Rule Processing — Decision Tree

```mermaid
flowchart TD
    Start([Rule Start]) --> SP{Source<br/>Path?}
    SP -->|No| SR1[WARN + Skip]
    SP -->|Yes| DP{Dest<br/>Path?}
    DP -->|No| SR2[ERROR + Skip]
    DP -->|Yes| FC{Files<br/>Found?}
    FC -->|No| FM{Mandatory?}
    FM -->|Yes| SR3[ERROR + Skip]
    FM -->|No| SR4[INFO + Skip]
    FC -->|Yes| FP{Pattern<br/>Set?}
    FP -->|No| FA[All files]
    FP -->|Yes| FR{Match<br/>Found?}
    FR -->|No| FM2{Mandatory?}
    FM2 -->|Yes| SR5[ERROR + Skip]
    FM2 -->|No| SR6[INFO + Skip]
    FR -->|Yes| JG{CleanSrc<br/>Files?}
    JG -->|true| GD[Group by Date]
    GD --> GJ[Multiple Jobs]
    JG -->|false| SJ[Single Job]
    SJ --> JE[Job Execution]
    GJ --> JE
    JE --> End([Rule End])
    SR1 --> End
    SR2 --> End
    SR3 --> End
    SR4 --> End
    SR5 --> End
    SR6 --> End
    FA --> JG
```

---

## Diagram Legend

| Symbol | Meaning |
|---|---|
| `flowchart TD` | Top-to-bottom layout |
| `flowchart LR` | Left-to-right layout |
| `[]` | Process / Action |
| `{}` | Decision / Condition |
| `([ ])` | Start / End |
| `-->` | Flow direction |
| `|Yes\|No\|true\|false\|...` | Branch label |

---

## Rendering Tips

- **VS Code**: Install the "Markdown Preview Mermaid Support" extension
- **GitHub/GitLab**: Mermaid renders natively in `.md` files
- **Notion**: Paste the raw `mermaid` code block
- **Obsidian**: Mermaid diagrams render automatically
- **Static sites**: Use `mermaid-cli` (`mmdc`) to export to PNG/SVG