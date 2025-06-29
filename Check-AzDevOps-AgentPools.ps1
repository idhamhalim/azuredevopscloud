<#
.SYNOPSIS
    Audits Azure DevOps build and release pipelines to check their configured agent pools.

.DESCRIPTION
    This script connects to an Azure DevOps project and checks agent pools for pipelines.
    For build pipelines, it can be configured to only check pipelines matching specific name patterns.

    It reads configuration from a `config.json` file. The file can include an array named
    'BuildPipelinePatterns' to filter build pipelines. Wildcards (*) are supported in patterns.
    If no patterns are configured, all build pipelines are checked.

.PARAMETER OrganizationName
    (Optional) The name of your Azure DevOps organization. Overrides the value in config.json.

.PARAMETER ProjectName
    (Optional) The name of your Azure DevOps project. Overrides the value in config.json.

.PARAMETER Pat
    (Optional) Your Personal Access Token (PAT). Overrides values from config.json or the environment.

.PARAMETER BuildPipelinePatterns
    (Optional) An array of build pipeline name patterns to check. Supports wildcards (*).
    Overrides the 'BuildPipelinePatterns' setting in config.json.

.EXAMPLE
    # With config.json containing BuildPipelinePatterns, audit only matching build pipelines.
    PS C:\> .\Check-AzDevOps-AgentPools.ps1

.EXAMPLE
    # Override the patterns from the command line for a single run.
    PS C:\> .\Check-AzDevOps-AgentPools.ps1 -BuildPipelinePatterns "WebApp-CI-*", "API-CI"

.EXAMPLE
    # To check ALL build pipelines, ignoring the config file, pass an empty array.
    PS C:\> .\Check-AzDevOps-AgentPools.ps1 -BuildPipelinePatterns @()
#>
param(
    [Parameter(Mandatory=$false)]
    [string]$OrganizationName,

    [Parameter(Mandatory=$false)]
    [string]$ProjectName,

    [Parameter(Mandatory=$false)]
    [string]$Pat,

    [Parameter(Mandatory=$false)]
    [array]$BuildPipelinePatterns
)

# --- Script Initialization & Configuration Loading ---
try {
    $configPath = Join-Path $PSScriptRoot "config.json"
    $config = $null
    if (Test-Path $configPath) {
        $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
    }

    $org = $OrganizationName -or $config.OrganizationName
    $proj = $ProjectName -or $config.ProjectName
    $token = $Pat -or $config.Pat -or $env:AZDO_PAT
    # Override logic for patterns: command-line parameter takes precedence over config file.
    # The [array] cast handles the case where $BuildPipelinePatterns is not provided (becomes $null).
    $patterns = if ($PSBoundParameters.ContainsKey('BuildPipelinePatterns')) { $BuildPipelinePatterns } else { $config.BuildPipelinePatterns }


    if (-not $org) { throw "OrganizationName is missing. Provide it via parameter or in config.json." }
    if (-not $proj) { throw "ProjectName is missing. Provide it via parameter or in config.json." }
    if (-not $token) { throw "PAT is missing. Provide it via parameter, in config.json, or as AZDO_PAT environment variable." }

    # --- Helper Functions ---
    function Get-AzDevOpsApiUri {
        param([string]$CurrentOrg, [string]$CurrentProj, [string]$ApiPath)
        if ($CurrentProj) { return "https://dev.azure.com/$CurrentOrg/$CurrentProj/_apis/$ApiPath" }
        return "https://dev.azure.com/$CurrentOrg/_apis/$ApiPath"
    }

    function Get-AuthHeader {
        param([string]$PersonalAccessToken)
        $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PersonalAccessToken)"))
        return @{ Authorization = "Basic $base64AuthInfo" }
    }

    $headers = Get-AuthHeader -PersonalAccessToken $token

    # --- Logic Functions ---

    function Check-BuildPipelines {
        param($CurrentOrg, $CurrentProj, $ApiHeaders, [array]$FilterPatterns)
        Write-Host "--- Checking Build Pipelines ---" -ForegroundColor Cyan

        $useFilter = $null -ne $FilterPatterns -and $FilterPatterns.Count -gt 0
        if ($useFilter) {
            Write-Host "Filtering builds matching patterns: $($FilterPatterns -join ', ')" -ForegroundColor Gray
        } else {
            Write-Host "No filters specified, checking all build pipelines." -ForegroundColor Gray
        }

        $buildDefsUri = Get-AzDevOpsApiUri -CurrentOrg $CurrentOrg -CurrentProj $CurrentProj -ApiPath "build/definitions?api-version=7.1-preview.7"
        $definitions = Invoke-RestMethod -Uri $buildDefsUri -Method Get -Headers $ApiHeaders

        if ($definitions.count -eq 0) {
            Write-Host "No build pipelines found in project." -ForegroundColor Yellow
            return
        }

        $matchedCount = 0
        foreach ($def in $definitions.value) {
            $pipelineName = $def.name
            $shouldCheck = -not $useFilter # If not using a filter, check everything.

            if ($useFilter) {
                foreach ($pattern in $FilterPatterns) {
                    if ($pipelineName -like $pattern) {
                        $shouldCheck = $true
                        break # Match found, no need to check other patterns for this pipeline
                    }
                }
            }

            if ($shouldCheck) {
                $matchedCount++
                $poolName = $def.process.pool.name
                if ($poolName) {
                    Write-Host "  [BUILD] '$pipelineName' -> Pool: '$poolName'" -ForegroundColor Green
                }
                else {
                    Write-Host "  [BUILD] '$pipelineName' -> WARNING: No agent pool configured!" -ForegroundColor Yellow
                }
            }
        }

        if ($useFilter -and $matchedCount -eq 0) {
            Write-Host "No build pipelines found matching the specified patterns." -ForegroundColor Yellow
        }
    }

    function Check-ReleasePipelines {
        param($CurrentOrg, $CurrentProj, $ApiHeaders)
        Write-Host "--- Checking Release Pipelines ---" -ForegroundColor Cyan
        $releaseDefsUri = "https://vsrm.dev.azure.com/$CurrentOrg/$CurrentProj/_apis/release/definitions?`$expand=environments&api-version=7.1-preview.4"
        $definitions = Invoke-RestMethod -Uri $releaseDefsUri -Method Get -Headers $ApiHeaders
        if ($definitions.count -eq 0) {
            Write-Host "No release pipelines found." -ForegroundColor Yellow
            return
        }
        foreach ($def in $definitions.value) {
            Write-Host "  [RELEASE] '$($def.name)'"
            foreach ($stage in $def.environments) {
                $agentPhase = $stage.deployPhases | Where-Object { $_.phaseType -eq 'agentBasedDeployment' }
                if ($agentPhase) {
                    $poolName = $agentPhase.deploymentInput.pool.name
                    if ($poolName) {
                        Write-Host "    - Stage: '$($stage.name)' -> Pool: '$poolName'" -ForegroundColor Gray
                    } else {
                        Write-Host "    - Stage: '$($stage.name)' -> WARNING: No agent pool configured for this agent-based stage!" -ForegroundColor Yellow
                    }
                } else {
                    Write-Host "    - Stage: '$($stage.name)' -> (No agent-based jobs)" -ForegroundColor DarkGray
                }
            }
        }
    }

    # --- Script Body ---
    Write-Host "Starting audit for project '$proj' in organization '$org'..." -ForegroundColor White
    
    Check-BuildPipelines -CurrentOrg $org -CurrentProj $proj -ApiHeaders $headers -FilterPatterns $patterns
    Write-Host ""
    Check-ReleasePipelines -CurrentOrg $org -CurrentProj $proj -ApiHeaders $headers

}
catch {
    Write-Host "An error occurred:" -ForegroundColor Red
    Write-Host $_.Exception.ToString() -ForegroundColor Red
}
finally {
    Write-Host ""
    Write-Host "Script finished." -ForegroundColor White
}
