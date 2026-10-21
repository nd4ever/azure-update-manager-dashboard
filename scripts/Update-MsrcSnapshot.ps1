#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

<#
.SYNOPSIS
    Refreshes the Workbook and Grafana Microsoft security release snapshots.
.DESCRIPTION
    Downloads one public MSRC CVRF release, reduces it to KB-to-CVE rows, and
    stores identical rows in the Workbook's static JSON data source and a Grafana
    Azure Monitor Logs query. Embedding the snapshot avoids browser CORS
    restrictions on api.msrc.microsoft.com.
.PARAMETER Release
    MSRC release identifier in yyyy-MMM format. Defaults to the current UTC month.
.PARAMETER WorkbookPath
    Path to the Azure Workbook JSON file to update.
.PARAMETER GrafanaPath
    Path to the Grafana dashboard JSON file to update.
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
    [string]$WorkbookPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'workbook/azure-update-manager.workbook.json'),

    [Parameter(Mandatory = $false)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$GrafanaPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'grafana/azure-update-manager.dashboard.json')
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

function Update-GrafanaSnapshot {
    <#
    .SYNOPSIS
        Embeds KB-to-CVE rows in a Grafana Azure Monitor Logs table.
    .PARAMETER Path
        Grafana dashboard JSON path.
    .PARAMETER ReleaseId
        MSRC release identifier.
    .PARAMETER Rows
        Normalized KB rows shared with the Workbook.
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

    $Dashboard = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    $SnapshotPanel = @($Dashboard.panels | Where-Object { $_.id -eq 19 })
    if ($SnapshotPanel.Count -gt 1 -or (
        $SnapshotPanel.Count -eq 1 -and
        $SnapshotPanel[0].title -notlike '* Microsoft security release - KB to CVE mapping'
    )) {
        throw 'Grafana panel ID 19 is not available for the MSRC snapshot.'
    }

    if ($SnapshotPanel.Count -eq 0) {
        $UpdatePanel = @($Dashboard.panels | Where-Object { $_.id -eq 10 -and $_.type -eq 'table' })
        if ($UpdatePanel.Count -ne 1) {
            throw 'The Grafana dashboard must contain the installed update summary table.'
        }

        $Panel = $UpdatePanel[0] | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $Panel.id = 19
        $Panel.gridPos = [pscustomobject]@{
            h = 14
            w = 24
            x = 0
            y = $UpdatePanel[0].gridPos.y
        }
        foreach ($ExistingPanel in $Dashboard.panels) {
            if ($ExistingPanel.gridPos.y -ge $Panel.gridPos.y) {
                $ExistingPanel.gridPos.y += $Panel.gridPos.h
            }
        }
        $Dashboard.panels = @($Dashboard.panels) + @($Panel)
    }
    else {
        $Panel = $SnapshotPanel[0]
    }

    $Panel.title = "$ReleaseId Microsoft security release - KB to CVE mapping"
    $Panel | Add-Member -Force -NotePropertyName description -NotePropertyValue (
        "Embedded public MSRC CVRF snapshot for $ReleaseId. Filter KB or CVEs using the column filters. " +
        'CVE-yyyy-{a,b} means CVE-yyyy-a and CVE-yyyy-b. This release reference is independent of ' +
        'dashboard time, computer, software, and KB baseline filters; it does not evaluate machine exposure. ' +
        'Refresh both dashboards with scripts/Update-MsrcSnapshot.ps1, then republish.'
    )
    $Panel.fieldConfig.defaults.custom | Add-Member -Force -NotePropertyName filterable -NotePropertyValue $true
    $Panel.fieldConfig.defaults.custom.inspect = $true
    $Panel.fieldConfig.overrides = @(
        [pscustomobject]@{
            matcher = [pscustomobject]@{ id = 'byName'; options = 'KB' }
            properties = @(
                [pscustomobject]@{
                    id = 'links'
                    value = @(
                        [pscustomobject]@{
                            targetBlank = $true
                            title = 'View CVEs in Microsoft Security Update Guide'
                            url = 'https://msrc.microsoft.com/update-guide/en-US/search?query=${__value.raw}'
                        }
                    )
                }
            )
        }
    )

    $SnapshotJson = ConvertTo-Json -InputObject @($Rows) -Depth 5 -Compress
    $Panel.targets[0].azureLogAnalytics.query = @"
print Snapshot = dynamic($SnapshotJson)
| mv-expand Snapshot
| project Release = tostring(Snapshot.Release), KB = tostring(Snapshot.KB), CVECount = toint(Snapshot.CVECount), CVEs = tostring(Snapshot.CVEs), MaximumCVSS = todouble(Snapshot.MaximumCVSS), SecurityUpdateGuide = tostring(Snapshot.SecurityUpdateGuide)
| order by KB asc
"@
    $Dashboard.panels = @($Dashboard.panels | Sort-Object { $_.gridPos.y }, { $_.gridPos.x })
    $Dashboard |
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
        Update-GrafanaSnapshot -Path $GrafanaPath -ReleaseId $Release -Rows $Rows
        Write-Host "Updated '$WorkbookPath' and '$GrafanaPath' with $($Rows.Count) KB-to-CVE rows from $Release."
        exit 0
    }
    catch {
        Write-Error -ErrorAction Continue "MSRC snapshot refresh failed: $($_.Exception.Message)"
        exit 1
    }
}

#endregion Main Execution
