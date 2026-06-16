<#
.SYNOPSIS
    Generates pseudo log files for testing main.ps1, based on the rules in the JSON config.
.DESCRIPTION
    For each rule in the config, this creates files whose names match the rule's 'FileNamePattern',
    filled with random text up to a maximum size. Files go under -OutputRoot (a sandbox inside the
    project) instead of the rule's real SourcePath, so nothing touches production paths.

    Generation is mode-aware, mirroring how the archiver treats the rule:
      - CleanSourceFiles = true  -> rotation rule: files are spread across -Days past days
                                    (FilesPerDay each, backdated) so date grouping can be exercised.
      - CleanSourceFiles = false -> keep rule: the archiver makes a single archive and does not split
                                    by date, so we just create a flat batch of -KeepModeFileCount files.

    Note: a fixed/anchored pattern (e.g. '^current_active.log$') matches only one name, so only one
    file is produced for it regardless of the requested count.
.PARAMETER ConfigPath
    Path to the rules JSON. Defaults to <project>\configurations\directories_list.json.
.PARAMETER OutputRoot
    Root folder for generated files. Defaults to <project>\testdata. One subfolder per rule.
.PARAMETER Days
    Distinct past days to generate for rotation rules, counting back from today (default 30).
.PARAMETER FilesPerDay
    Files per day for rotation rules (default 10).
.PARAMETER KeepModeFileCount
    Files to create for keep rules (CleanSourceFiles = false), as flat filler (default 10).
.PARAMETER MaxFileSizeBytes
    Upper bound for each file; the actual size is random up to this value (default 1MB).
.NOTES
    Author: Dmitry Goldenberg
    Compatibility: Windows PowerShell 4 and later.
#>
param(
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'configurations\directories_list.json'),
    [string]$OutputRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'testdata'),
    [ValidateRange(1, 3650)][int]$Days = 30,
    [ValidateRange(1, 1000)][int]$FilesPerDay = 10,
    [ValidateRange(1, 1000)][int]$KeepModeFileCount = 10,
    [ValidateRange(1024, 1073741824)][long]$MaxFileSizeBytes = 1MB
)

$ErrorActionPreference = 'Stop'
$InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
$Rng = New-Object System.Random

# Build a filename that satisfies the regex by de-regexing it and inserting a unique token at the
# first wildcard position. Returns a best-effort candidate; the caller verifies it with -match.
function New-NameFromPattern {
    param([string]$Pattern, [string]$Token)
    if ([string]::IsNullOrWhiteSpace($Pattern)) { return "$Token.log" }
    $name = $Pattern -replace '^\^', '' -replace '\$$', ''   # strip anchors
    if ($name -match '\.\*|\.\+') {
        $name = [regex]::Replace($name, '\.\*|\.\+', $Token, 1)  # first wildcard -> unique token
        $name = $name -replace '\.\*|\.\+', ''                   # any remaining wildcards -> empty
    }
    # Unescape common classes and drop leftover regex metacharacters.
    $name = $name -replace '\\\.', '.' -replace '\\d', '0' -replace '\\w', 'x' -replace '\\s', '_' -replace '\\', ''
    return $name
}

# Fill ~TargetBytes of printable random text using concatenated GUIDs (fast and incompressible).
function New-RandomText {
    param([long]$TargetBytes)
    $sb = New-Object System.Text.StringBuilder
    while ($sb.Length -lt $TargetBytes) { [void]$sb.AppendLine([guid]::NewGuid().ToString('N')) }
    return $sb.ToString().Substring(0, [int]$TargetBytes)
}

# Create one seed file with a name matching $Pattern. Returns $true if a file was created, $false if
# the name could not be built or already exists (a fixed pattern yields the same name every time).
function New-SeedFile {
    param([string]$RuleDir, [string]$Pattern, [string]$Token, $Seen, [int]$SizeHi, [datetime]$Timestamp)
    $fileName = New-NameFromPattern -Pattern $Pattern -Token $Token
    if (-not [string]::IsNullOrWhiteSpace($Pattern) -and ($fileName -notmatch $Pattern)) {
        Write-Warning "Could not build a name matching '$Pattern'. Skipping."
        return $false
    }
    if (-not $Seen.Add($fileName)) { return $false }

    $path = Join-Path $RuleDir $fileName
    [System.IO.File]::WriteAllText($path, (New-RandomText -TargetBytes ($Rng.Next(1024, $SizeHi))))
    $fi = Get-Item -LiteralPath $path
    $fi.CreationTime = $Timestamp
    $fi.LastWriteTime = $Timestamp
    return $true
}

if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) { throw "Config not found: $ConfigPath" }
$Rules = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $Rules) { throw "Config contains no rules: $ConfigPath" }

$SizeHi = [int][Math]::Min([long]$MaxFileSizeBytes, 1073741823)
if ($SizeHi -le 1024) { $SizeHi = 1025 }

$RuleIndex = 0
foreach ($Rule in $Rules) {
    $RuleIndex++
    $RuleName = if (-not [string]::IsNullOrWhiteSpace($Rule.Name)) { $Rule.Name } else { "rule$RuleIndex" }
    $SafeName = ($RuleName -replace '[^\w\.\- ]', '_').Trim()
    $RuleDir = Join-Path $OutputRoot $SafeName
    if (-not (Test-Path -Path $RuleDir)) { New-Item -ItemType Directory -Path $RuleDir -Force | Out-Null }

    $Mode = if ($Rule.CleanSourceFiles) { 'rotation (date-spread)' } else { 'keep (flat filler)' }
    Write-Host "Rule '$RuleName' [$Mode] -> $RuleDir  (pattern: '$($Rule.FileNamePattern)')"

    $created = 0
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'

    if ($Rule.CleanSourceFiles) {
        # Rotation rule: spread files across past days so the archiver's date grouping is exercised.
        for ($d = 0; $d -lt $Days; $d++) {
            $date = (Get-Date).Date.AddDays(-$d)
            for ($n = 1; $n -le $FilesPerDay; $n++) {
                $token = "app_{0}_{1:D2}" -f $date.ToString('yyyyMMdd', $InvariantCulture), $n
                if (New-SeedFile -RuleDir $RuleDir -Pattern $Rule.FileNamePattern -Token $token -Seen $seen -SizeHi $SizeHi -Timestamp $date.AddHours(9).AddMinutes($n)) { $created++ }
            }
        }
        $expected = $Days * $FilesPerDay
    }
    else {
        # Keep rule: not split by date -> a flat batch of filler files is enough.
        $base = (Get-Date).Date.AddDays(-1).AddHours(9)
        for ($n = 1; $n -le $KeepModeFileCount; $n++) {
            $token = "app_{0:D2}" -f $n
            if (New-SeedFile -RuleDir $RuleDir -Pattern $Rule.FileNamePattern -Token $token -Seen $seen -SizeHi $SizeHi -Timestamp $base.AddMinutes($n)) { $created++ }
        }
        $expected = $KeepModeFileCount
    }

    if ($created -lt $expected) {
        Write-Host "  created $created file(s) (pattern allows fewer than the requested $expected distinct names)."
    }
    else {
        Write-Host "  created $created file(s)."
    }
}
Write-Host "Done. Set a rule's SourcePath to its folder under '$OutputRoot' to test main.ps1."
