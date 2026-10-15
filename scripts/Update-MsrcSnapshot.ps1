#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

<#
.SYNOPSIS
    Refreshes the Workbook's embedded Microsoft security release snapshot.
.DESCRIPTION
    Downloads one public MSRC CVRF release, reduces it to KB-to-CVE rows, and
    stores the rows in the Workbook's static JSON data source. Embedding the
    snapshot avoids browser CORS restrictions on api.msrc.microsoft.com.
.PARAMETER Release
    MSRC release identifier in yyyy-MMM format. Defaults to the current UTC month.
.PARAMETER WorkbookPath
    Path to the Azure Workbook JSON file to update.
.EXAMPLE
    ./scripts/Update-MsrcSnapshot.ps1 -Release 2026-Oct
.NOTES
    Requires network access to the public MSRC CVRF API.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidatePattern('^\d{4}-(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)$')]
    [string]$Release = [DateTime]::UtcNow.ToString('yyyy-MMM', [Globalization.CultureInfo]::InvariantCulture),

    [Parameter(Mandatory = $false)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$WorkbookPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'workbook/azure-update-manager.workbook.json')
)

$ErrorActionPreference = 'Stop'

#region Functions

function ConvertTo-CompactCveSet {
    <#
    .SYNOPSIS
        Compacts CVE identifiers by grouping numeric identifiers under each year.
    .PARAMETER Cve
        CVE identifiers in CVE-yyyy-number format.
    .OUTPUTS
        [string] Lossless grouped notation such as CVE-2026-{100,200}.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Cve
    )

    $Groups = foreach ($Identifier in @($Cve | Sort-Object -Unique)) {
        if ($Identifier -notmatch '^CVE-(\d{4})-(\d+)$') {
            throw "Invalid CVE identifier '$Identifier'."
        }

        [pscustomobject]@{
            Year = $Matches[1]
            Number = $Matches[2]
        }
    }

    return @(
        $Groups |
            Group-Object Year |
            Sort-Object Name |
            ForEach-Object {
                "CVE-$($_.Name)-{$(($_.Group.Number | Sort-Object) -join ',')}"
            }
    ) -join '; '
}

function Get-MsrcKbRows {
    <#
    .SYNOPSIS
        Gets normalized KB-to-CVE rows for an MSRC security release.
    .PARAMETER ReleaseId
        MSRC release identifier in yyyy-MMM format.
    .OUTPUTS
        [object[]] Normalized KB rows with one comma-delimited CVE set per KB.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ReleaseId
    )

    $Uri = "https://api.msrc.microsoft.com/cvrf/v3.0/cvrf/$ReleaseId"
    $Document = Invoke-RestMethod -Method Get -Uri $Uri -Headers @{
        Accept = 'application/json'
    }

    $Mappings = foreach ($Vulnerability in @($Document.Vulnerability)) {
        $KnowledgeBases = @(
            $Vulnerability.Remediations |
                Where-Object { $_.SubType -match '^\d{6,8}$' } |
                ForEach-Object { "KB$($_.SubType)" } |
                Sort-Object -Unique
        )
        if ($KnowledgeBases.Count -eq 0) {
            continue
        }

        foreach ($KnowledgeBase in $KnowledgeBases) {
            [pscustomobject]@{
                KB = $KnowledgeBase
                CVE = $Vulnerability.CVE
                CVSS = @(
                    $Vulnerability.CVSSScoreSets |
                        ForEach-Object { $_.BaseScore }
                )
            }
        }
    }

    $Rows = foreach ($Group in @($Mappings | Group-Object KB)) {
        $Scores = @(
            $Group.Group.CVSS |
                Where-Object { $null -ne $_ } |
                ForEach-Object { [double]$_ }
        )
        $Cves = @($Group.Group.CVE | Sort-Object -Unique)

        [pscustomobject][ordered]@{
            Release = $ReleaseId
            KB = $Group.Name
            CVECount = $Cves.Count
            CVEs = ConvertTo-CompactCveSet -Cve $Cves
            MaximumCVSS = if ($Scores.Count -gt 0) {
                ($Scores | Measure-Object -Maximum).Maximum
            }
            else {
                $null
            }
            SecurityUpdateGuide = "https://msrc.microsoft.com/update-guide/en-US/search?query=$($Group.Name)"
        }
    }

    return @($Rows | Sort-Object KB)
}

function Update-WorkbookSnapshot {
    <#
    .SYNOPSIS
        Replaces the Workbook MSRC panel with static JSON rows.
    .PARAMETER Path
        Workbook JSON path.
    .PARAMETER ReleaseId
        MSRC release identifier.
    .PARAMETER Rows
        Normalized KB rows to embed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ReleaseId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [object[]]$Rows
    )

    $Workbook = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    $ParameterItem = @($Workbook.items | Where-Object { $_.name -eq 'report-parameters' })
    $SnapshotPanel = @($Workbook.items | Where-Object { $_.name -eq 'current-security-release-kb-cve-mapping' })
    $Heading = @($Workbook.items | Where-Object { $_.name -eq 'installed-updates-heading' })

    if ($ParameterItem.Count -ne 1 -or $SnapshotPanel.Count -ne 1 -or $Heading.Count -ne 1) {
        throw 'The Workbook does not contain the expected MSRC snapshot components.'
    }

    $ParameterItem[0].content.parameters = @(
        $ParameterItem[0].content.parameters |
            Where-Object { $_.name -ne 'SecurityRelease' }
    )

    $StaticJsonQuery = [ordered]@{
        version = '1.0.0'
        content = $Rows | ConvertTo-Json -Depth 5 -Compress
        transformers = $null
    }
    $SnapshotPanel[0].content.query = $StaticJsonQuery | ConvertTo-Json -Depth 5 -Compress
    $SnapshotPanel[0].content.queryType = 8
    $SnapshotPanel[0].content.title = "$ReleaseId Microsoft security release - KB to CVE mapping"

    $Heading[0].content.json = "## Installed update inventory`nInventory equivalents for SCCM per-update and per-computer reports. Dates are observation times from ``ConfigurationData``, not deployment timestamps.`n`nThe $ReleaseId security release snapshot maps Microsoft CVEs to remediation KBs from the public Microsoft Security Response Center (MSRC) CVRF feed. Use the table filter to find a KB or CVE. Run ``scripts/Update-MsrcSnapshot.ps1`` to capture a newer or revised release."

    $Workbook |
        ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

#endregion Functions

#region Main Execution

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $Rows = Get-MsrcKbRows -ReleaseId $Release
        if ($Rows.Count -eq 0) {
            throw "MSRC release '$Release' did not contain any KB-to-CVE mappings."
        }

        Update-WorkbookSnapshot -Path $WorkbookPath -ReleaseId $Release -Rows $Rows
        Write-Host "Updated '$WorkbookPath' with $($Rows.Count) KB-to-CVE rows from $Release."
        exit 0
    }
    catch {
        Write-Error -ErrorAction Continue "MSRC snapshot refresh failed: $($_.Exception.Message)"
        exit 1
    }
}

#endregion Main Execution
