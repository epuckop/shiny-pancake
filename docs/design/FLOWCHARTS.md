# Log Rotation & Archiving Script — Flowchart Diagrams

Companion to [ARCHITECTURE.md](ARCHITECTURE.md): that document covers **structure** (system context, containers, resource bitmask, space calculations); this one covers the **step-by-step runtime flows**.

> [!NOTE]
> Mermaid diagrams render natively in GitHub, GitLab, Notion, Obsidian, and VS Code (with the Mermaid Preview extension).

---

## 1. Top-Level Execution Flow

The high-level lifecycle of the script execution from start to finish.

```mermaid
%%{init: {'theme': 'neutral', 'themeVariables': { 'fontFamily': 'Segoe UI, system-ui, -apple-system, sans-serif' }}}%%
flowchart TD
    classDef default fill:#fafafa,stroke:#ccc,stroke-width:1px,color:#333;
    classDef success fill:#e8f5e9,stroke:#2e7d32,stroke-width:1.5px,color:#2e7d32;
    classDef errNode fill:#ffebee,stroke:#c62828,stroke-width:1.5px,color:#c62828;
    classDef startNode fill:#f3e5f5,stroke:#7b1fa2,stroke-width:1.5px,color:#7b1fa2;

    A([Start]) --> B[Load Script Parameters]
    B --> C[Import Modules logger & fileimport]
    C --> D[Start-LogProcessor]
    D --> RT[Apply Resource Throttling<br/>priority + affinity bitmask]
    RT --> E[Phase 1: Prerequisites Validation]
    
    E --> F{7-Zip Exists at ZipPath?}
    F -->|No| G[Log ERROR & Throw] --> EndErr([Abort Execution])
    
    F -->|Yes| H{7-Zip Executable Functional?}
    H -->|No| I[Log ERROR & Throw] --> EndErr
    
    H -->|Yes| J[Load JSON Config Content]
    J --> K{Config Parsed Successfully?}
    K -->|No| L[Log ERROR & Throw] --> EndErr
    
    K -->|Yes| M[Validate Configuration Rules]
    M --> N{All Config Rules Valid?}
    N -->|No| O[Log ERROR & Throw] --> EndErr
    
    N -->|Yes| P[Create Daily Receipt Directory]
    P --> Q[Phase 2: Evaluate & Process Rules]
    Q --> R[Phase 3: Cleanup & Compile Metrics]
    R --> EC[Write Summary Log]
    EC --> S[Stop-LogProcessor]
    S --> T([End & Exit with Code 0/1/2])

    class A startNode;
    class T success;
    class EndErr errNode;
```

---

## 2. Prerequisites Validation

Pre-flight checks executing prior to processing rules.

```mermaid
%%{init: {'theme': 'neutral', 'themeVariables': { 'fontFamily': 'Segoe UI, system-ui, -apple-system, sans-serif' }}}%%
flowchart TD
    classDef default fill:#fafafa,stroke:#ccc,stroke-width:1px,color:#333;
    classDef success fill:#e8f5e9,stroke:#2e7d32,stroke-width:1.5px,color:#2e7d32;
    classDef errNode fill:#ffebee,stroke:#c62828,stroke-width:1.5px,color:#c62828;
    classDef startNode fill:#f3e5f5,stroke:#7b1fa2,stroke-width:1.5px,color:#7b1fa2;

    A([Start Prerequisites]) --> B[Test 7-Zip Path via Test-Path]
    B --> C{Path Exists?}
    C -->|No| D[Log ERROR] --> ErrEnd([Throw Prerequisite Exception])
    C -->|Yes| F[Execute 7za.exe with No Arguments]
    
    F --> G{LASTEXITCODE = 0?}
    G -->|No| H[Log ERROR] --> ErrEnd
    G -->|Yes| I[Log INFO: 7-Zip Version & Status OK]
    
    I --> J[Invoke Get-JsonContent]
    J --> K{JSON Parse Success?}
    K -->|No| L[Log ERROR] --> ErrEnd
    
    K -->|Yes| M[Iterate & Validate Rules Schema]
    M --> N{All Constraints Met?}
    N -->|No| O[Log ERROR] --> ErrEnd
    
    N -->|Yes| P[Create Daily Receipt Directory]
    P --> Q([Return Status OK])

    class A startNode;
    class Q success;
    class ErrEnd errNode;
```

---

## 3. Config Validation (Per Rule)

Schema and type validation applied to each configuration rule in the array.

```mermaid
%%{init: {'theme': 'neutral', 'themeVariables': { 'fontFamily': 'Segoe UI, system-ui, -apple-system, sans-serif' }}}%%
flowchart TD
    classDef default fill:#fafafa,stroke:#ccc,stroke-width:1px,color:#333;
    classDef errNode fill:#ffcdd2,stroke:#e53935,stroke-width:1.5px,color:#b71c1c;
    classDef success fill:#d5e8d4,stroke:#82b366,stroke-width:2px,color:#274e13;

    A[Validate Rule Constraints] --> B{Name Blank or Null?}
    B -->|Yes| E1([Error: Name required])
    B -->|No| D{SourcePath Blank or Null?}
    D -->|Yes| E2([Error: SourcePath required])
    D -->|No| E{DestinationPath Blank or Null?}
    E -->|Yes| E3([Error: DestinationPath required])
    E -->|No| F{CleanSourceFiles Missing?}
    F -->|Yes| E4([Error: CleanSourceFiles missing])
    F -->|No| G{Mandatory Missing?}
    G -->|Yes| E5([Error: Mandatory missing])
    G -->|No| H{Name has invalid chars?}
    H -->|Yes| E6([Error: Name contains invalid chars])
    H -->|No| I{ArchivePrefix invalid?}
    I -->|Yes| E7([Error: ArchiveNamePrefix has invalid chars])
    I -->|No| J{ArchiveSuffix invalid?}
    J -->|Yes| E8([Error: ArchiveNameSuffix has invalid chars])
    J -->|No| K{DateFormat Defined?}
    
    K -->|No| L{FileNamePattern Defined?}
    K -->|Yes| M{DateFormat Format Valid?}
    M -->|No| E9([Error: DateFormat invalid])
    M -->|Yes| L
    
    L -->|No| N([Return Validation Success])
    L -->|Yes| O{Regex Pattern Valid?}
    O -->|No| E10([Error: Regex Pattern invalid])
    O -->|Yes| N

    class E1,E2,E3,E4,E5,E6,E7,E8,E9,E10 errNode;
    class N success;
```

---

## 4. Rule Processing Flow

Orchestration sequence for an individual rule. Leftover recovery is performed prior to scanning files.

```mermaid
%%{init: {'theme': 'neutral', 'themeVariables': { 'fontFamily': 'Segoe UI, system-ui, -apple-system, sans-serif' }}}%%
flowchart TD
    classDef default fill:#fafafa,stroke:#ccc,stroke-width:1px,color:#333;
    classDef skip fill:#fffde7,stroke:#f57f17,stroke-width:1.5px,color:#f57f17;
    classDef errNode fill:#ffcdd2,stroke:#e53935,stroke-width:1.5px,color:#b71c1c;
    classDef success fill:#d5e8d4,stroke:#82b366,stroke-width:2px,color:#274e13;

    A[Start Rule Processing] --> B{SourcePath Directory Exists?}
    B -->|No| C[Log WARN & Skip Rule] --> EndSkip1([Rule Skipped])
    B -->|Yes| D{DestinationPath Directory Exists?}
    
    D -->|No| E[Log ERROR & Skip Rule] --> EndErr1([Rule Aborted])
    D -->|Yes| REC[Run Leftover Temp Directory Recovery]
    
    REC --> F[Get-ChildItem: Discovered Files]
    F --> G{Any Files Found?}
    
    G -->|No| H{Mandatory Rule?}
    H -->|Yes| I[Log ERROR & Skip Rule] --> EndErr2([Rule Aborted])
    H -->|No| J[Log INFO & Skip Rule] --> EndSkip2([Rule Skipped])
    
    G -->|Yes| L{FileNamePattern Configured?}
    L -->|No| M[Select All Discovered Files]
    L -->|Yes| N[Filter Files via Regex -match]
    
    M --> O{Any Filter Matches?}
    N --> O
    
    O -->|No| P{Mandatory Rule?}
    P -->|Yes| Q[Log ERROR & Skip Rule] --> EndErr3([Rule Aborted])
    P -->|No| R[Log INFO & Skip Rule] --> EndSkip3([Rule Skipped])
    
    O -->|Yes| S[Generate Scheduled Jobs]
    S --> T[Execute Scheduled Jobs] --> EndSuccess([Rule Execution Finished])

    class EndSkip1,EndSkip2,EndSkip3 skip;
    class EndErr1,EndErr2,EndErr3 errNode;
    class EndSuccess success;
```

---

## 5. Job Generation (CleanSourceFiles Branching)

How files are grouped and sorted into distinct jobs depending on clean vs. keep mode.

```mermaid
%%{init: {'theme': 'neutral', 'themeVariables': { 'fontFamily': 'Segoe UI, system-ui, -apple-system, sans-serif' }}}%%
flowchart TD
    classDef default fill:#fafafa,stroke:#ccc,stroke-width:1px,color:#333;
    classDef success fill:#e8f5e9,stroke:#2e7d32,stroke-width:1.5px,color:#2e7d32;
    classDef skip fill:#fffde7,stroke:#f57f17,stroke-width:1.5px,color:#f57f17;
    classDef startNode fill:#f3e5f5,stroke:#7b1fa2,stroke-width:1.5px,color:#7b1fa2;

    A([Start Job Generation]) --> B{CleanSourceFiles = true?}
    B -->|"Yes (Rotation Mode)"| C[Filter: Exclude files modified today]
    
    C --> D[Group files by LastWriteTime date dd-MM-yy]
    D --> E{Any Groups Found?}
    E -->|No| F[Log INFO & Skip Rule] --> EndSkip([Skip Rule & End])
    E -->|Yes| G[Create 1 Job per Date Group]
    
    B -->|"No (Keep Mode)"| I[Create 1 Job containing all matching files]
    
    G --> SZ[Sort Jobs in ascending order of SizeBytes]
    I --> SZ
    SZ --> T([End: Schedule Jobs queue])

    class A startNode;
    class T success;
    class EndSkip skip;
```

---

## 6. Job Execution (Per Job)

Processing loop for a single generated job. Space check and integrity testing act as safety gates.

```mermaid
%%{init: {'theme': 'neutral', 'themeVariables': { 'fontFamily': 'Segoe UI, system-ui, -apple-system, sans-serif' }}}%%
flowchart TD
    classDef default fill:#fafafa,stroke:#ccc,stroke-width:1px,color:#333;
    classDef success fill:#e8f5e9,stroke:#2e7d32,stroke-width:1.5px,color:#2e7d32;
    classDef errNode fill:#ffebee,stroke:#c62828,stroke-width:1.5px,color:#c62828;
    classDef startNode fill:#f3e5f5,stroke:#7b1fa2,stroke-width:1.5px,color:#7b1fa2;

    A([Start Job Execution]) --> B[Construct ArchiveName]
    B --> SP{Enough Free Space on Dest & Source?}
    
    SP -->|No| SX[Log ERROR, break loop: skip this & larger jobs] --> LoopBreak([Execution Aborted])
    SP -->|Yes| C[Create Temp Directory in SourcePath]
    
    C --> D{CleanSourceFiles = true?}
    D -->|Yes| E[Move files to temp directory<br/>copy fallback if locked]
    D -->|No| F[Copy files to temp directory]
    
    E --> G[Switch CWD to temp directory & run 7za a]
    F --> G
    
    G --> H{7za Success & Archive Created?}
    H -->|No| I[Log ERROR & Throw]
    
    H -->|Yes| T[Run 7za t integrity test]
    T --> T_Decision{Passed?}
    T_Decision -->|Failed check| I
    T_Decision -->|Passed check| L[Delete Temp Directory]
    
    L --> M[Write UTF-8 JSON audit receipt]
    M --> N[Log INFO: Job execution complete] --> JobSuccess([Job Finished Successfully])
    
    I --> O[Log ERROR, delete fresh partial archive only] --> JobErr([Job Failed])

    class A startNode;
    class JobSuccess success;
    class JobErr,LoopBreak errNode;
```

---

## 7. Archive Name Construction

Formatting resolution for archive file names.

```mermaid
%%{init: {'theme': 'neutral', 'themeVariables': { 'fontFamily': 'Segoe UI, system-ui, -apple-system, sans-serif' }}}%%
flowchart LR
    classDef configNode fill:#fffde7,stroke:#f57f17,stroke-width:1.5px,color:#e65100;
    classDef systemNode fill:#e3f2fd,stroke:#0d47a1,stroke-width:1.5px,color:#0d47a1;
    classDef concat fill:#fafafa,stroke:#ccc,stroke-width:1.5px,color:#333;
    classDef result fill:#e8f5e9,stroke:#2e7d32,stroke-width:2px,color:#2e7d32;

    Prefix["Config: Prefix<br/><i>(Optional)</i>"]
    Host["System: Host Name<br/><i>(Mandatory System)</i>"]
    Date["System: Date<br/><i>(Mandatory Calculated)</i>"]
    Suffix["Config: Suffix<br/><i>(Optional)</i>"]
    
    Join[Concatenation]
    
    ArchiveName(["[Prefix_]COMPUTERNAME_Date[_Suffix].zip"])

    Prefix --> Join
    Host --> Join
    Date --> Join
    Suffix --> Join
    
    Join --> ArchiveName

    class Prefix,Suffix configNode;
    class Host,Date systemNode;
    class Join concat;
    class ArchiveName result;
```

---

## 8. Receipt File Structure

Detailed layout of audit receipts stored under `receipt/YYYY-MM-DD/`.

```mermaid
%%{init: {'theme': 'neutral', 'themeVariables': { 'fontFamily': 'Segoe UI, system-ui, -apple-system, sans-serif' }}}%%
flowchart TD
    classDef default fill:#fafafa,stroke:#ccc,stroke-width:1px,color:#333;
    classDef folder fill:#fffde7,stroke:#f57f17,stroke-width:1.5px,color:#e65100;
    classDef file fill:#e1f5fe,stroke:#0288d1,stroke-width:1.5px,color:#01579b;

    A[Receipt Path] --> B["receipt/YYYY-MM-DD/"]
    B --> C["JobName_unix_timestamp.json"]
    C --> D[JSON Document Properties]
    
    D --> E["Name: Job display name"]
    D --> F["UTC: Execution Timestamp (ISO 8601)"]
    D --> G["Archive: Absolute target archive path"]
    D --> H["Files: Detailed metadata array"]
    
    H --> I["  Name: Original filename"]
    H --> J["  LastWriteTimeUtc: Original timestamp (ISO 8601)"]

    class B folder;
    class C file;
```

---

## 9. Error Handling Hierarchy

Nested try/catch/finally boundaries isolating failures.

```mermaid
%%{init: {'theme': 'neutral', 'themeVariables': { 'fontFamily': 'Segoe UI, system-ui, -apple-system, sans-serif' }}}%%
flowchart TD
    classDef default fill:#fafafa,stroke:#ccc,stroke-width:1px,color:#333;
    classDef globalScope fill:#ffebee,stroke:#c62828,stroke-width:2px,color:#b71c1c;
    classDef ruleScope fill:#fffde7,stroke:#f57f17,stroke-width:1.5px,color:#e65100;
    classDef jobScope fill:#e3f2fd,stroke:#0288d1,stroke-width:1.5px,color:#01579b;

    A[Global try] --> B[Rule try]
    B --> C[Job try]
    
    C --> D[Job catch] --> E[Log ERROR, remove partial archive, skip Job]
    C --> F[Job finally] --> G[Log Job Finished]
    
    B --> H[Rule catch] --> I[Log ERROR, skip Rule]
    B --> J[Rule finally] --> K[Log Rule Finished]
    
    A --> L[Global catch] --> M[Log CRITICAL unhandled exception]
    A --> N[Global finally] --> O[Compile Stats & Map Exit Code 0/1/2]
    
    O --> P[Stop-LogProcessor]

    class A,L,M,N,O,P globalScope;
    class B,H,I,J,K ruleScope;
    class C,D,E,F,G jobScope;
```

---

## 10. Async Logger Architecture

Producer-consumer runspace cycle isolating logging I/O.

```mermaid
%%{init: {'theme': 'neutral', 'themeVariables': { 'fontFamily': 'Segoe UI, system-ui, -apple-system, sans-serif' }}}%%
flowchart TD
    classDef default fill:#fafafa,stroke:#ccc,stroke-width:1px,color:#333;
    classDef thread fill:#e1f5fe,stroke:#0288d1,stroke-width:1.5px,color:#01579b;
    classDef queue fill:#e8f5e9,stroke:#2e7d32,stroke-width:1.5px,color:#2e7d32;

    A[main.ps1 Thread] -->|Add-LogMessage| B[ConcurrentQueue]
    B --> C[Background Runspace]
    
    C --> D{StopEvent Set?}
    D -->|No| E{Queue Has Items?}
    E -->|No| F[Wait 100ms]
    F --> D
    
    E -->|Yes| G[Dequeue Log Entry]
    G --> H[Write to Log File via Add-Content]
    H --> D
    
    D -->|Yes| I[Dequeue & Write Remaining Entries]
    I --> J[Dispose runspace resources]

    class A thread;
    class B queue;
    class C,J thread;
```

---

## 11. CleanSourceFiles = true — File Lifecycle

Staging and removal lifecycle when rotation mode is active.

```mermaid
%%{init: {'theme': 'neutral', 'themeVariables': { 'fontFamily': 'Segoe UI, system-ui, -apple-system, sans-serif' }}}%%
flowchart TD
    classDef default fill:#fafafa,stroke:#ccc,stroke-width:1px,color:#333;
    classDef success fill:#e8f5e9,stroke:#2e7d32,stroke-width:1.5px,color:#2e7d32;
    classDef skip fill:#fffde7,stroke:#f57f17,stroke-width:1.5px,color:#e65100;
    classDef errNode fill:#ffebee,stroke:#c62828,stroke-width:1.5px,color:#c62828;

    A[Original Log File in SourcePath] --> B{Modified Today?}
    B -->|Yes| C[Skip & Preserve in SourcePath] --> EndSkip([Preserved])
    B -->|No| D[Move to Temp Directory]
    
    D --> E[Zip Staged File via 7-Zip]
    E --> F[Verify Archive via 7-Zip Integrity Test]
    
    F --> G{Integrity Test Passed?}
    G -->|No| H[Preserve Temp Directory & Retain original logs] --> EndErr([Job Failed])
    G -->|Yes| I[Delete Temp Directory & Original Logs]
    
    I --> J([Write JSON Audit Receipt])

    class J success;
    class EndSkip skip;
    class EndErr errNode;
```

---

## 12. CleanSourceFiles = false — File Lifecycle

Staging lifecycle when keep mode is active.

```mermaid
%%{init: {'theme': 'neutral', 'themeVariables': { 'fontFamily': 'Segoe UI, system-ui, -apple-system, sans-serif' }}}%%
flowchart TD
    classDef default fill:#fafafa,stroke:#ccc,stroke-width:1px,color:#333;
    classDef success fill:#e8f5e9,stroke:#2e7d32,stroke-width:1.5px,color:#2e7d32;
    classDef skip fill:#fffde7,stroke:#f57f17,stroke-width:1.5px,color:#e65100;

    A[Original Log File in SourcePath] --> B[Copy to Temp Directory]
    B --> C[Original Remains Untouched in SourcePath]
    C --> D[Zip Staged File via 7-Zip]
    D --> E[Verify Archive via 7-Zip Integrity Test]
    
    E --> F{Integrity Test Passed?}
    F -->|No| G[Preserve Temp Directory & Warn] --> EndSkip([Job Warned])
    F -->|Yes| H[Delete Temp Directory]
    
    H --> I([Write JSON Audit Receipt])

    class I success;
    class EndSkip skip;
```

---

## 13. Full Rule Processing — Decision Tree

Decisions traversed during rule evaluation.

```mermaid
%%{init: {'theme': 'neutral', 'themeVariables': { 'fontFamily': 'Segoe UI, system-ui, -apple-system, sans-serif' }}}%%
flowchart TD
    classDef default fill:#fafafa,stroke:#ccc,stroke-width:1px,color:#333;
    classDef skip fill:#fffde7,stroke:#f57f17,stroke-width:1.5px,color:#e65100;
    classDef errNode fill:#ffcdd2,stroke:#e53935,stroke-width:1.5px,color:#b71c1c;
    classDef success fill:#d5e8d4,stroke:#82b366,stroke-width:2px,color:#274e13;

    Start([Rule Start]) --> SP{Source Path Valid?}
    SP -->|No| SR1[WARN, Skip Rule] --> EndSkip1([Rule Skipped])
    SP -->|Yes| DP{Destination Path Valid?}
    
    DP -->|No| SR2[ERROR, Skip Rule] --> EndErr1([Rule Aborted])
    DP -->|Yes| FC{Files Discovered?}
    
    FC -->|No| FM{Mandatory Rule?}
    FM -->|Yes| SR3[ERROR, Skip Rule] --> EndErr2([Rule Aborted])
    FM -->|No| SR4[INFO, Skip Rule] --> EndSkip2([Rule Skipped])
    
    FC -->|Yes| FP{Pattern Set?}
    FP -->|No| FA[Process All Discovered Files]
    FP -->|Yes| FR{Any Matches Exist?}
    
    FR -->|No| FM2{Mandatory Rule?}
    FM2 -->|Yes| SR5[ERROR, Skip Rule] --> EndErr3([Rule Aborted])
    FM2 -->|No| SR6[INFO, Skip Rule] --> EndSkip3([Rule Skipped])
    
    FA --> JG{CleanSourceFiles?}
    FR -->|Yes| JG
    
    JG -->|true| GD[Group by Date] --> GJ[Schedule Multiple Jobs] --> JE[Execute Scheduled Jobs] --> EndSuccess([Rule Execution Finished])
    JG -->|false| SJ[Schedule Single Job] --> JE

    class EndSkip1,EndSkip2,EndSkip3 skip;
    class EndErr1,EndErr2,EndErr3 errNode;
    class EndSuccess success;
```

---

## 14. Leftover Temp Directory Recovery Flow

Automatic recovery execution addressing crashed or terminated runs.

```mermaid
%%{init: {'theme': 'neutral', 'themeVariables': { 'fontFamily': 'Segoe UI, system-ui, -apple-system, sans-serif' }}}%%
flowchart TD
    classDef default fill:#fafafa,stroke:#ccc,stroke-width:1px,color:#333;
    classDef errNode fill:#ffcdd2,stroke:#e53935,stroke-width:1.5px,color:#b71c1c;
    classDef success fill:#d5e8d4,stroke:#82b366,stroke-width:2px,color:#274e13;
    classDef loopStyle fill:#e1f5fe,stroke:#0288d1,stroke-width:1.5px,color:#01579b;

    A[Start Leftover Recovery Scan] --> B[Scan SourcePath for Dirs]
    B --> C{Any Leftover Dirs Found?}
    C -->|No| D([Return Recovery Complete])
    C -->|Yes| E{More Dirs in List?}
    
    E -->|No| D
    E -->|"Yes (Get Next)"| F{Is Directory Empty?}
    
    F -->|Yes| G[Log WARN & Delete Directory] --> LoopNext[Loop: Next Directory]
    F -->|No| H[Capture Staged Files Metadata]
    
    H --> I[Execute 7za.exe to Compress]
    I --> J{LASTEXITCODE = 0 & Created?}
    
    J -->|No| K[Log ERROR & Skip Directory] --> LoopNext
    J -->|Yes| L[Execute 7za.exe Integrity Test]
    
    L --> M{LASTEXITCODE = 0?}
    M -->|No| K
    M -->|Yes| N[Delete Recovered Staging Directory]
    
    N --> O[Write Recovery Receipt with Recovered=true]
    O --> P[Log Success] --> LoopNext
    
    LoopNext -->|Next iteration| E

    class D success;
    class K errNode;
    class LoopNext loopStyle;
```

---

## Diagram Legend

Visual guides representing node shapes in Mermaid flowcharts.

| Symbol Shape | Logical Interpretation |
|---|---|
| `flowchart TD` | Top-to-bottom layout |
| `flowchart LR` | Left-to-right layout |
| `[ ]` | Action, Process, or Command execution |
| `{ }` | Condition, Decision, or Branching logic |
| `([ ])` | Terminal boundary (Start / End) |
| `-->` | Sequential flow connection |
| `|label|` | Condition/Branch match label |

---

## Rendering Tips

Information on how to visualize these charts locally or on hosting platforms:

*   **VS Code**: Install the **Markdown Preview Mermaid Support** extension to view diagrams directly inside markdown previews.
*   **GitHub/GitLab**: Diagrams render natively inside standard `.md` views.
*   **Notion**: Paste the raw `mermaid` code block and select the Mermaid renderer.
*   **Obsidian**: Mermaid diagrams render automatically in reading/editing modes.
*   **CLI / Static Sites**: Use `mermaid-cli` (`mmdc`) to build and export diagrams to static `PNG` or `SVG` formats.