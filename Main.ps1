# =============================================================================
# Main.ps1
# Entry point for PowerShell Log Collector & Archiver.
# =============================================================================

[CmdletBinding()]
param (
    # Path to the JSON file containing collection rules.
    # Defaults to Config\rules.json relative to this script.
    [Parameter(Mandatory = $false)]
    [string]$RulesFile = (Join-Path $PSScriptRoot "Config\rules.json"),

    # Directory where script log files will be written.
    # Defaults to logs\ relative to this script.
    [Parameter(Mandatory = $false)]
    [string]$LogPath = (Join-Path $PSScriptRoot "logs")
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# -----------------------------------------------------------------------------
# Global settings
# -----------------------------------------------------------------------------

# Root directory of the script — base for all relative paths
$script:RootPath = $PSScriptRoot

# Invariant culture for consistent date formatting regardless of server locale
$script:InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

# Date format used for staging folder names (e.g. 2026-02-26)
$script:DateFormat = "yyyy-MM-dd"

# Path to 7z.exe — resolved via Get-SevenZipPath after importing Functions.ps1
$script:SevenZipPath = $null

# Set to $true to echo log entries to the console during interactive runs
$script:VerboseLogging = $false

# -----------------------------------------------------------------------------
# Import helper functions
# -----------------------------------------------------------------------------

. (Join-Path $script:RootPath "Lib\Functions.ps1")

