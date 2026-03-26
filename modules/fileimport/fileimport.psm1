<#
.SYNOPSIS
    Imports data from a file into PowerShell objects.
.DESCRIPTION
    This function reads the content of a specified file and converts it
    into PowerShell objects.
.NOTES
    Author: Dmitry Goldenberg
#>




#-----------------------------------------------------------------------------------
# Public Functions
#-----------------------------------------------------------------------------------


function Get-JsonContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, HelpMessage = "Specify the full path to the JSON file.")]
        [string]$Path
    )

    
    process {
        try {    
            $ResolvedPath = Resolve-Path -Path $Path -ErrorAction Stop
            if (-not (Test-Path -Path $ResolvedPath -PathType Leaf)) { throw "Path '$ResolvedPath' does not point to a file." }
            $JsonContent = Get-Content -Path $ResolvedPath -Raw -Encoding UTF8
            return ConvertFrom-Json -InputObject $JsonContent
        }
        catch { throw $_ }
    }
}


Export-ModuleMember -Function Get-JsonContent