<#
.SYNOPSIS
    Moves unfinished Azure DevOps work items from a source sprint to a destination sprint.

.DESCRIPTION
    This script connects to Azure DevOps to move work items. It reads configuration details
    (OrganizationName, ProjectName, Pat) from a `config.json` file located in the same directory.

    You can override any setting from the config file by providing it as a command-line parameter.
    For the PAT, the script prioritizes:
    1. The -Pat parameter.
    2. The 'Pat' value in config.json.
    3. The 'AZDO_PAT' environment variable.

.PARAMETER OrganizationName
    (Optional) The name of your Azure DevOps organization. Overrides the value in config.json.

.PARAMETER ProjectName
    (Optional) The name of your Azure DevOps project. Overrides the value in config.json.

.PARAMETER SourceSprintName
    (Mandatory) The name of the sprint to move work items FROM.

.PARAMETER DestinationSprintName
    (Mandatory) The name of the sprint to move work items TO.

.PARAMETER Pat
    (Optional) Your Personal Access Token (PAT). Overrides values from config.json or the environment variable.
#>
param(
    [Parameter(Mandatory=$false)]
    [string]$OrganizationName,

    [Parameter(Mandatory=$false)]
    [string]$ProjectName,

    [Parameter(Mandatory=$true)]
    [string]$SourceSprintName,

    [Parameter(Mandatory=$true)]
    [string]$DestinationSprintName,

    [Parameter(Mandatory=$false)]
    [string]$Pat
)

try {
    # --- Script Initialization & Configuration Loading ---
    $configPath = Join-Path $PSScriptRoot "config.json"
    $config = $null

    if (Test-Path $configPath) {
        Write-Host "Loading settings from $configPath..." -ForegroundColor Gray
        $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
    }

    $org = $OrganizationName -or $config.OrganizationName
    $proj = $ProjectName -or $config.ProjectName
    $token = $Pat -or $config.Pat -or $env:AZDO_PAT

    if (-not $org)   { throw "OrganizationName is missing. Provide it via -OrganizationName or in config.json." }
    if (-not $proj)  { throw "ProjectName is missing. Provide it via -ProjectName or in config.json." }
    if (-not $token) { throw "PAT is missing. Provide it via -Pat, in config.json, or AZDO_PAT environment variable." }

    function Get-AzDevOpsApiUri {
        param($CurrentOrg, $CurrentProj, $ApiPath)
        return "https://dev.azure.com/$CurrentOrg/$CurrentProj/_apis/$ApiPath"
    }

    function Get-AuthHeader {
        param($PersonalAccessToken)
        $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PersonalAccessToken)"))
        return @{ Authorization = "Basic $base64AuthInfo" }
    }

    Write-Host "Starting script..." -ForegroundColor Cyan
    $headers = Get-AuthHeader -PersonalAccessToken $token

    # 1. Get the full iteration paths for the source and destination sprints
    Write-Host "Fetching sprint information for project '$proj'..."
    $iterationsUri = Get-AzDevOpsApiUri -CurrentOrg $org -CurrentProj $proj -ApiPath "work/teamsettings/iterations?api-version=7.1-preview.1"
    $iterations = Invoke-RestMethod -Uri $iterationsUri -Method Get -Headers $headers

    $sourceSprint = $iterations.value | Where-Object { $_.name -eq $SourceSprintName }
    $destinationSprint = $iterations.value | Where-Object { $_.name -eq $DestinationSprintName }

    if (-not $sourceSprint)      { throw "Source sprint '$SourceSprintName' not found." }
    if (-not $destinationSprint) { throw "Destination sprint '$DestinationSprintName' not found." }

    $sourceIterationPath      = $sourceSprint.path
    $destinationIterationPath = $destinationSprint.path
    Write-Host " -> Source Sprint Path: $sourceIterationPath" -ForegroundColor Green
    Write-Host " -> Destination Sprint Path: $destinationIterationPath" -ForegroundColor Green

    # 2. Find all unfinished work items in the source sprint
    Write-Host "Querying for unfinished work items in '$SourceSprintName'..."
    $wiqlUri = Get-AzDevOpsApiUri -CurrentOrg $org -CurrentProj $proj -ApiPath "wit/wiql?api-version=7.1-preview.2"
    $wiqlQuery = @{
        query = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '$proj' AND [System.IterationPath] = '$sourceIterationPath' AND [System.State] <> 'Done' AND [System.State] <> 'Closed'"
    } | ConvertTo-Json

    $queryResult = Invoke-RestMethod -Uri $wiqlUri -Method Post -Headers $headers -Body $wiqlQuery -ContentType "application/json"
    $workItems = $queryResult.workItems

    if (-not $workItems) {
        Write-Host "No unfinished work items found in '$SourceSprintName'. Nothing to move." -ForegroundColor Yellow
        exit
    }

    $workItemIds = $workItems | ForEach-Object { $_.id }
    $itemCount = $workItemIds.Count
    Write-Host "Found $itemCount work item(s) to move." -ForegroundColor Cyan

    # 3. Move work items in batches (up to 200 per batch)
    $batchSize = 200
    $movedCount = 0

    for ($i = 0; $i -lt $itemCount; $i += $batchSize) {
        $batchIds = $workItemIds[$i..([Math]::Min($i + $batchSize - 1, $itemCount - 1))]
        foreach ($workItemId in $batchIds) {
            Write-Host " -> Moving work item ID: $workItemId..."
            $updateUri = Get-AzDevOpsApiUri -CurrentOrg $org -CurrentProj $proj -ApiPath "wit/workitems/$($workItemId)?api-version=7.1-preview.3"
            $updateBody = @( @{ op = "add"; path = "/fields/System.IterationPath"; value = $destinationIterationPath } ) | ConvertTo-Json
            try {
                Invoke-RestMethod -Uri $updateUri -Method Patch -Headers $headers -Body $updateBody -ContentType "application/json-patch+json" | Out-Null
                $movedCount++
            } catch {
                Write-Warning "Failed to move work item ID: $workItemId"
            }
        }
    }

    Write-Host "Successfully moved $movedCount work item(s) from '$SourceSprintName' to '$DestinationSprintName'." -ForegroundColor Green
}
catch {
    Write-Host "An error occurred:" -ForegroundColor Red
    Write-Host $_.Exception.ToString() -ForegroundColor Red
}
finally {
    Write-Host "Script finished." -ForegroundColor Cyan
}