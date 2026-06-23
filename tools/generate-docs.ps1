<#
.SYNOPSIS
    Generates Markdown documentation for public functions in project modules.
.DESCRIPTION
    This script loads the project's modules (logger and fileimport), retrieves their
    exported functions, extracts help content using Get-Help, and outputs formatted
    Markdown files into the docs/ folder.
.NOTES
    Author: Dmitry Goldenberg
    Compatibility: Windows PowerShell 4 and later.
#>

$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path $PSScriptRoot -Parent
$DocsApiDir = Join-Path $ProjectRoot 'docs\api'

# Ensure the output directory exists
if (-not (Test-Path -Path $DocsApiDir)) {
    New-Item -Path $DocsApiDir -ItemType Directory -Force | Out-Null
}

$Modules = @{
    'logger'     = Join-Path $ProjectRoot 'modules\logger\logger.psm1'
    'fileimport' = Join-Path $ProjectRoot 'modules\fileimport\fileimport.psm1'
}

Write-Host "Starting API documentation generation..."

foreach ($ModuleName in $Modules.Keys) {
    $ModulePath = $Modules[$ModuleName]
    Write-Host "Processing module: $ModuleName ($ModulePath)"
    
    # Import the module temporarily to extract help info
    Import-Module -Name $ModulePath -Force -ErrorAction Stop
    
    # Get exported functions
    $Module = Get-Module -Name $ModuleName
    if (-not $Module) {
        Write-Warning "Module $ModuleName was loaded but not found in session."
        continue
    }
    
    $Functions = $Module.ExportedFunctions.Keys
    if (-not $Functions) {
        Write-Host "  No exported functions found for $ModuleName."
        continue
    }
    
    foreach ($FuncName in $Functions) {
        Write-Host "  Generating docs for function: $FuncName"
        
        $Help = Get-Help $FuncName -Full
        if (-not $Help) {
            Write-Warning "    Could not retrieve help for $FuncName"
            continue
        }
        
        $Markdown = New-Object System.Text.StringBuilder
        [void]$Markdown.AppendLine("# $FuncName")
        [void]$Markdown.AppendLine()
        
        # Synopsis
        $SynopsisText = if ($Help.synopsis) { $Help.synopsis.Trim() } else { "No synopsis provided." }
        [void]$Markdown.AppendLine("## Synopsis")
        [void]$Markdown.AppendLine($SynopsisText)
        [void]$Markdown.AppendLine()
        
        # Syntax
        [void]$Markdown.AppendLine("## Syntax")
        [void]$Markdown.AppendLine("``````powershell")
        # Extract syntax string
        $Syntax = ""
        if ($Help.syntax.syntaxItem) {
            foreach ($item in $Help.syntax.syntaxItem) {
                # Format syntax string nicely
                $parametersStr = ""
                if ($item.parameter) {
                    $paramList = @()
                    foreach ($p in $item.parameter) {
                        $pName = $p.name
                        $pType = if ($p.parameterValue) { $p.parameterValue } else { "Switch" }
                        $paramList += "-$pName <$pType>"
                    }
                    $parametersStr = " " + ($paramList -join " ")
                }
                $Syntax += "$FuncName$parametersStr`n"
            }
        }
        if (-not $Syntax) {
            # Fallback to simple name
            $Syntax = "$FuncName"
        }
        [void]$Markdown.AppendLine($Syntax.Trim())
        [void]$Markdown.AppendLine("``````")
        [void]$Markdown.AppendLine()
        
        # Description
        $DescText = ""
        if ($Help.description) {
            if ($Help.description.Text) {
                $DescText = $Help.description.Text
            } elseif ($Help.description -is [array]) {
                $DescText = $Help.description -join "`n"
            } else {
                $DescText = $Help.description.ToString()
            }
        }
        $DescText = if ($DescText.Trim()) { $DescText.Trim() } else { "No detailed description provided." }
        [void]$Markdown.AppendLine("## Description")
        [void]$Markdown.AppendLine($DescText)
        [void]$Markdown.AppendLine()
        
        # Parameters
        [void]$Markdown.AppendLine("## Parameters")
        if ($Help.parameters.parameter) {
            foreach ($Param in $Help.parameters.parameter) {
                $PName = $Param.name
                $PType = if ($Param.type.name) { $Param.type.name } else { "Object" }
                $PRequired = if ($Param.required -eq 'true') { "Yes" } else { "No" }
                $PPos = if ($Param.position) { $Param.position } else { "Named" }
                $PDefault = if ($Param.defaultValue) { $Param.defaultValue } else { "None" }
                
                $PDesc = ""
                if ($Param.description) {
                    if ($Param.description.Text) {
                        $PDesc = $Param.description.Text
                    } elseif ($Param.description -is [array]) {
                        $PDesc = $Param.description -join " "
                    } else {
                        $PDesc = $Param.description.ToString()
                    }
                }
                $PDesc = if ($PDesc.Trim()) { $PDesc.Trim() } else { "No description." }
                
                [void]$Markdown.AppendLine("### ``-$PName``")
                [void]$Markdown.AppendLine("*   **Type**: ``$PType``")
                [void]$Markdown.AppendLine("*   **Required**: ``$PRequired``")
                [void]$Markdown.AppendLine("*   **Position**: ``$PPos``")
                [void]$Markdown.AppendLine("*   **Default Value**: ``$PDefault``")
                [void]$Markdown.AppendLine()
                [void]$Markdown.AppendLine($PDesc)
                [void]$Markdown.AppendLine()
            }
        } else {
            [void]$Markdown.AppendLine("This function does not accept parameters.")
            [void]$Markdown.AppendLine()
        }
        
        # Examples
        if ($Help.examples.example) {
            [void]$Markdown.AppendLine("## Examples")
            [void]$Markdown.AppendLine()
            foreach ($Example in $Help.examples.example) {
                $ExTitle = $Example.title
                $ExCode = $Example.code.Trim()
                $ExRemarks = ""
                if ($Example.remarks) {
                    if ($Example.remarks.Text) {
                        $ExRemarks = $Example.remarks.Text.Trim()
                    } elseif ($Example.remarks -is [array]) {
                        $ExRemarks = ($Example.remarks -join "`n").Trim()
                    } else {
                        $ExRemarks = $Example.remarks.ToString().Trim()
                    }
                }
                
                [void]$Markdown.AppendLine("### $ExTitle")
                [void]$Markdown.AppendLine("``````powershell")
                [void]$Markdown.AppendLine($ExCode)
                [void]$Markdown.AppendLine("``````")
                if ($ExRemarks) {
                    [void]$Markdown.AppendLine()
                    [void]$Markdown.AppendLine($ExRemarks)
                }
                [void]$Markdown.AppendLine()
            }
        }
        
        # Notes
        $NotesText = ""
        if ($Help.alertSet.alert) {
            if ($Help.alertSet.alert.Text) {
                $NotesText = $Help.alertSet.alert.Text
            } elseif ($Help.alertSet.alert -is [array]) {
                $NotesText = $Help.alertSet.alert -join "`n"
            } else {
                $NotesText = $Help.alertSet.alert.ToString()
            }
        }
        if ($NotesText.Trim()) {
            [void]$Markdown.AppendLine("## Notes")
            [void]$Markdown.AppendLine($NotesText.Trim())
            [void]$Markdown.AppendLine()
        }
        
        # Write to file
        $OutPath = Join-Path $DocsApiDir "$FuncName.md"
        $Markdown.ToString() | Set-Content -Path $OutPath -Encoding utf8
        Write-Host "    Docs saved to: $OutPath"
    }
    
    # Remove module so session is clean
    Remove-Module -Name $ModuleName -ErrorAction SilentlyContinue
}

Write-Host "API documentation generation complete."
