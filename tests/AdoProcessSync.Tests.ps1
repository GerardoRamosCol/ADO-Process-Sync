#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'These DPAPI tests require Windows.' }

$root = Split-Path -Parent $PSScriptRoot
$scripts = Join-Path $root '.github\skills\ado-process-sync\scripts'
$setup = Join-Path $scripts 'Initialize-AdoProcessCredential.ps1'
$gateway = Join-Path $scripts 'Invoke-AdoProcessRequest.ps1'
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ("ado-process-sync-test-" + [guid]::NewGuid().ToString('N'))
$originalLocalAppData = $env:LOCALAPPDATA
$null = New-Item -ItemType Directory -Path $temporaryDirectory
$env:LOCALAPPDATA = $temporaryDirectory
$requests = [Collections.Generic.List[object]]::new()
$sourceId = '11111111-1111-1111-1111-111111111111'
$targetId = '22222222-2222-2222-2222-222222222222'
$parentId = '33333333-3333-3333-3333-333333333333'
$mockMode = 'normal'
$checks = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:checks++
}

function Assert-Blocked {
    param([scriptblock]$Action, [string]$MessagePattern)
    $caught = $null
    try { & $Action | Out-Null }
    catch { $caught = $_.Exception.Message }
    Assert-True ($null -ne $caught -and $caught -match $MessagePattern) "Expected failure matching '$MessagePattern'; got '$caught'."
}

function Read-Host {
    param([string]$Prompt, [switch]$AsSecureString)
    if (-not $AsSecureString) { throw 'Credential input must be hidden.' }
    ConvertTo-SecureString 'offline-dummy-pat-not-a-real-credential' -AsPlainText -Force
}

function Invoke-RestMethod {
    param(
        [string]$Uri, [string]$Method, [string]$Authentication,
        [PSCredential]$Credential, [int]$MaximumRedirection, [int]$TimeoutSec,
        [string]$ErrorAction, [string]$ContentType, [byte[]]$Body
    )
    $requests.Add([pscustomobject]@{
        Uri = $Uri; Method = $Method; Authentication = $Authentication
        UserName = $Credential.UserName; MaximumRedirection = $MaximumRedirection
        Body = if ($null -ne $Body) { [Text.Encoding]::UTF8.GetString($Body) } else { $null }
    })
    if ($mockMode -eq 'failure') { throw 'SENSITIVE-SERVER-BODY' }
    if ($Uri -match '/audit/auditlog[?]') {
        return [pscustomobject]@{
            value = [pscustomobject]@{
                decoratedAuditLogEntries = @([pscustomobject]@{
                    id = 'event-1'; timestamp = '2026-01-01T00:00:00Z'; actionId = 'Observed.Action'
                    correlationId = 'correlation-1'; data = @{ processId = $sourceId }
                    details = 'Process change'; actorUserId = 'omit-me'; ipAddress = 'omit-me'
                })
                hasMore = $true
                continuationToken = if ($mockMode -eq 'bad-audit') { '' } else { 'next+page/=' }
            }
        }
    }
    if ($Uri -match "/work/processes/($sourceId|$targetId)[?]") {
        return [pscustomobject]@{
            typeId = $Matches[1]
            customizationType = if ($mockMode -eq 'system') { 'system' } else { 'inherited' }
            parentProcessTypeId = if ($mockMode -eq 'different-parent' -and $Matches[1] -eq $targetId) {
                '44444444-4444-4444-4444-444444444444'
            } else { $parentId }
        }
    }
    return [pscustomobject]@{ value = @(); count = 0 }
}

function Write-Json {
    param([string]$Path, [object]$Value)
    ConvertTo-Json -InputObject $Value -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8
}

try {
    foreach ($path in @($setup, $gateway, $PSCommandPath)) {
        $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$parseErrors)
        Assert-True ($parseErrors.Count -eq 0) "PowerShell parses: $path"
    }
    $agentPath = Join-Path $root '.github\agents\ado-process-sync.agent.md'
    $skillPath = Join-Path $root '.github\skills\ado-process-sync\SKILL.md'
    $noValidationSkillPath = Join-Path $root '.github\skills\ado-process-sync-no-validation\SKILL.md'
    foreach ($path in @($agentPath, $skillPath, $noValidationSkillPath)) {
        $text = Get-Content -LiteralPath $path -Raw
        Assert-True ($text -match '(?s)^---\r?\nname: [^\r\n]+\r?\ndescription: "[^"\r\n]+"\r?\n---') "Expected simple valid YAML frontmatter: $path"
    }
    Assert-True ((Get-Content -LiteralPath $skillPath -Raw) -match '(?m)^name: ado-process-sync\r?$') 'Skill name matches folder.'
    Assert-True ((Get-Content -LiteralPath $noValidationSkillPath -Raw) -match '(?m)^name: ado-process-sync-no-validation\r?$') 'No-validation skill name matches its separate folder.'
    $coveragePath = Join-Path (Split-Path -Parent $noValidationSkillPath) 'references\work-item-types-coverage.md'
    Assert-True (Test-Path -LiteralPath $coveragePath) 'No-validation skill endpoint coverage reference exists.'
    foreach ($operation in @('create', 'delete', 'get', 'list', 'update')) {
        Assert-True ((Get-Content -LiteralPath $coveragePath -Raw) -match "work-item-types/$operation\?view=azure-devops-rest-7\.1") "Coverage cites official API 7.1 documentation for $operation."
    }
    $null = & $setup -Organization 'test-org' -Role Reader
    $null = & $setup -Organization 'test-org' -Role Writer
    $credentialPath = Join-Path $temporaryDirectory 'AdoProcessSync\credentials\test-org-reader.clixml'
    Assert-True (Test-Path -LiteralPath $credentialPath) 'Credential persisted.'
    Assert-True ((Get-Content -LiteralPath $credentialPath -Raw) -notmatch 'offline-dummy-pat') 'Dummy credential is not stored in plaintext.'
    $credential = Import-Clixml -LiteralPath $credentialPath
    Assert-True ($credential -is [PSCredential] -and $credential.UserName -eq 'test-org') 'DPAPI credential round trip.'
    $credential = $null
    $allowedSids = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18')
    foreach ($path in @((Split-Path -Parent $credentialPath), $credentialPath)) {
        $acl = Get-Acl -LiteralPath $path
        Assert-True $acl.AreAccessRulesProtected 'Credential ACL inheritance is restricted.'
        foreach ($rule in $acl.Access) {
            $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
            Assert-True ($sid -in $allowedSids) 'Only current user and SYSTEM have credential access.'
        }
    }
    Assert-Blocked { & $setup -Organization 'test-org' -Role Reader } 'already exists'
    $null = & $setup -Organization 'test-org' -Role Reader -Replace
    $config = @{
        organization = 'test-org'; sourceProcessId = $sourceId; targetProcessIds = @($targetId)
    }
    $configPath = Join-Path $temporaryDirectory 'config.json'
    Write-Json $configPath $config
    $null = & $gateway -ConfigPath $configPath -ApiPath 'work/processes'
    Assert-True ($requests.Count -eq 1) 'Inventory performs one GET.'
    Assert-True ($requests[0].Uri -eq 'https://dev.azure.com/test-org/_apis/work/processes?api-version=7.1') 'Fixed process host/version.'
    Assert-True ($requests[0].MaximumRedirection -eq 0 -and $requests[0].Authentication -eq 'Basic') 'Redirects blocked; credential passed through HTTP client.'
    $end = [DateTimeOffset]::UtcNow.AddHours(-1)
    $query = @{
        startTime = $end.AddHours(-1).ToString('o')
        endTime = $end.ToString('o')
        continuationToken = 'next+page/='
    }
    $audit = & $gateway -ConfigPath $configPath -ApiPath 'audit/auditlog' -Query $query | ConvertFrom-Json
    Assert-True ($requests[1].Uri -match '^https://auditservice.dev.azure.com/test-org/_apis/audit/auditlog[?]api-version=7.1-preview.1') 'Fixed audit host/version.'
    Assert-True ($requests[1].Uri -match 'continuationToken=next%2Bpage%2F%3D') 'Continuation token URL encoded.'
    Assert-True ($audit.hasMore -and $audit.continuationToken -eq 'next+page/=') 'Pagination evidence preserved.'
    Assert-True (-not $audit.decoratedAuditLogEntries[0].PSObject.Properties['ipAddress']) 'Audit network/actor fields excluded.'
    Assert-True ($audit.decoratedAuditLogEntries[0].data.processId -eq $sourceId) 'Process evidence retained.'
    foreach ($path in @('https://attacker.example', 'work/processes/../other', 'work/processes/%2e%2e', 'work/processes?x=1', 'work//processes', 'projects')) {
        Assert-Blocked { & $gateway -ConfigPath $configPath -ApiPath $path } 'paths must|Only audit'
    }
    Assert-Blocked { & $gateway -ConfigPath $configPath -ApiPath 'work/processes' -Query @{ 'api-version' = 'other' } } 'Unsupported query'
    Assert-Blocked { & $gateway -ConfigPath $configPath -ApiPath 'audit/auditlog' } 'fixed startTime'
    $oldQuery = @{ startTime = $end.AddDays(-91).ToString('o'); endTime = $end.ToString('o') }
    Assert-Blocked { & $gateway -ConfigPath $configPath -ApiPath 'audit/auditlog' -Query $oldQuery } 'past 90 days'
    $mockMode = 'bad-audit'
    Assert-Blocked { & $gateway -ConfigPath $configPath -ApiPath 'audit/auditlog' -Query $query } 'incomplete audit'
    $mockMode = 'normal'
    $plan = @{
        organization = 'test-org'; sourceProcessId = $sourceId; targetProcessIds = @($targetId)
        operations = @(@{
            method = 'POST'; path = "work/processes/$targetId/workItemTypes"; body = @{ name = 'Example' }
        })
    }
    $planPath = Join-Path $temporaryDirectory 'plan.json'
    Write-Json $planPath $plan
    $hash = (Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash
    $before = $requests.Count
    $null = & $gateway -ConfigPath $configPath -Apply -PlanFile $planPath -OperationIndex 0 -ApprovedPlanSha256 $hash
    Assert-True ($requests.Count -eq $before + 3) 'Apply reads live source/target then writes once.'
    Assert-True ($requests[-1].Method -eq 'POST' -and $requests[-1].Body -eq '{"name":"Example"}') 'Only exact planned payload sent.'
    Assert-Blocked { & $gateway -ConfigPath $configPath -Apply -PlanFile $planPath -OperationIndex 1 -ApprovedPlanSha256 $hash } 'outside the plan'
    Add-Content -LiteralPath $planPath -Value ' '
    Assert-Blocked { & $gateway -ConfigPath $configPath -Apply -PlanFile $planPath -OperationIndex 0 -ApprovedPlanSha256 $hash } 'hash differs'
    Write-Json $planPath $plan
    $hash = (Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash
    foreach ($mode in @('system', 'different-parent')) {
        $mockMode = $mode
        $before = $requests.Count
        Assert-Blocked { & $gateway -ConfigPath $configPath -Apply -PlanFile $planPath -OperationIndex 0 -ApprovedPlanSha256 $hash } 'inherited processes'
        Assert-True ($requests.Count -eq $before + 2) 'Invalid inheritance prevents write.'
    }
    $mockMode = 'normal'
    foreach ($path in @("work/processes/$sourceId/workItemTypes", "work/processes/$targetId", 'wit/fields', "work/processes/$targetId/unknown")) {
        $plan.operations[0].path = $path
        Write-Json $planPath $plan
        $hash = (Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash
        Assert-Blocked { & $gateway -ConfigPath $configPath -Apply -PlanFile $planPath -OperationIndex 0 -ApprovedPlanSha256 $hash } 'selected target'
    }
    $plan.operations[0].path = "work/processes/$targetId/workItemTypes"
    $plan.operations[0].method = 'DELETE'
    Write-Json $planPath $plan
    $hash = (Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash
    Assert-Blocked { & $gateway -ConfigPath $configPath -Apply -PlanFile $planPath -OperationIndex 0 -ApprovedPlanSha256 $hash } 'Only planned'
    $plan.operations[0].method = 'POST'
    $plan.organization = 'other-org'
    Write-Json $planPath $plan
    $hash = (Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash
    Assert-Blocked { & $gateway -ConfigPath $configPath -Apply -PlanFile $planPath -OperationIndex 0 -ApprovedPlanSha256 $hash } 'scope must exactly'
    $config.targetProcessIds = @($sourceId)
    Write-Json $configPath $config
    Assert-Blocked { & $gateway -ConfigPath $configPath -ApiPath 'work/processes' } 'must not include the source'
    $config.targetProcessIds = @($targetId)
    Write-Json $configPath $config
    $mockMode = 'failure'
    Assert-Blocked { & $gateway -ConfigPath $configPath -ApiPath 'work/processes' } '^Azure DevOps request failed \(transport failure\)'
    Remove-Item -LiteralPath $credentialPath
    Assert-Blocked { & $gateway -ConfigPath $configPath -ApiPath 'work/processes' } 'credential missing'
    Write-Output "Passed $checks offline assertions. No network requests or real credentials used."
}
finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
}
