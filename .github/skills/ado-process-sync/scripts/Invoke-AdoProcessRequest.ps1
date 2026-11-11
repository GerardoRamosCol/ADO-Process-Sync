#requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'Read')]
param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,
    [Parameter(Mandatory, ParameterSetName = 'Read')]
    [string]$ApiPath,
    [Parameter(ParameterSetName = 'Read')]
    [hashtable]$Query = @{},
    [Parameter(Mandatory, ParameterSetName = 'Apply')]
    [switch]$Apply,
    [Parameter(Mandatory, ParameterSetName = 'Apply')]
    [string]$PlanFile,
    [Parameter(Mandatory, ParameterSetName = 'Apply')]
    [ValidateRange(0, 2147483647)]
    [int]$OperationIndex,
    [Parameter(Mandatory, ParameterSetName = 'Apply')]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ApprovedPlanSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$VerbosePreference = 'SilentlyContinue'
$DebugPreference = 'SilentlyContinue'
if (-not $IsWindows) { throw 'Windows DPAPI is required.' }

function Get-ProcessScope {
    param([System.Collections.IDictionary]$Document)
    if ($Document.organization -isnot [string] -or
        $Document.organization -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,49}$') {
        throw 'A valid organization slug is required.'
    }
    $guidPattern = '^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$'
    if ($Document.sourceProcessId -isnot [string] -or $Document.sourceProcessId -notmatch $guidPattern) {
        throw 'A canonical source process GUID is required.'
    }
    if ($Document.targetProcessIds -isnot [array] -or $Document.targetProcessIds.Count -eq 0) {
        throw 'An explicit nonempty target process array is required.'
    }
    $targets = @($Document.targetProcessIds | ForEach-Object {
        if ($_ -isnot [string] -or $_ -notmatch $guidPattern) { throw 'Invalid target process GUID.' }
        $_.ToLowerInvariant()
    })
    $source = $Document.sourceProcessId.ToLowerInvariant()
    if ($targets -contains $source -or @($targets | Select-Object -Unique).Count -ne $targets.Count) {
        throw 'Targets must be unique and must not include the source.'
    }
    if ($source -eq [guid]::Empty.ToString() -or $targets -contains [guid]::Empty.ToString()) {
        throw 'Empty process GUIDs are not allowed.'
    }
    return @{
        Organization = $Document.organization.ToLowerInvariant()
        Source = $source
        Targets = $targets
    }
}

function Assert-ApiPath {
    param([string]$Path)
    if ($Path -notmatch '^[A-Za-z0-9_-]+(?:/[A-Za-z0-9_.-]+)*$' -or
        @($Path.Split('/') | Where-Object { $_ -in @('.', '..') }).Count -gt 0) {
        throw 'API paths must be relative literal segments without escapes, queries, or traversal.'
    }
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
if ($config -isnot [System.Collections.IDictionary]) { throw 'Configuration must be a JSON object.' }
$scope = Get-ProcessScope $config
$method = 'GET'
$body = $null
$role = 'reader'
$hostName = 'dev.azure.com'
$version = '7.1'

if ($Apply) {
    # Hash and parse the same bytes so a subsequent file edit cannot replace the approved payload.
    $bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $PlanFile).Path)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $actualHash = [BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
    if ($actualHash -ne $ApprovedPlanSha256) { throw 'Plan hash differs from the explicitly approved hash.' }
    $plan = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json -AsHashtable
    if ($plan -isnot [System.Collections.IDictionary]) { throw 'Plan must be a JSON object.' }
    $planScope = Get-ProcessScope $plan
    if ($planScope.Organization -ne $scope.Organization -or $planScope.Source -ne $scope.Source -or
        (($planScope.Targets | Sort-Object) -join ',') -ne (($scope.Targets | Sort-Object) -join ',')) {
        throw 'Plan scope must exactly match configuration.'
    }
    if ($plan.operations -isnot [array] -or $OperationIndex -ge $plan.operations.Count) {
        throw 'Operation index is outside the plan.'
    }
    $operation = $plan.operations[$OperationIndex]
    if ($operation -isnot [System.Collections.IDictionary] -or
        $operation.method -notin @('POST', 'PATCH', 'PUT') -or
        $operation.path -isnot [string] -or
        $operation.body -isnot [System.Collections.IDictionary]) {
        throw 'Only planned POST/PATCH/PUT operations with object bodies are supported.'
    }
    $ApiPath = $operation.path
    Assert-ApiPath $ApiPath
    $segments = $ApiPath.Split('/')
    if ($segments.Count -lt 4 -or $segments[0] -cne 'work' -or $segments[1] -cne 'processes' -or
        $segments[2].ToLowerInvariant() -notin $scope.Targets -or
        $segments[3] -cnotin @('workItemTypes', 'behaviors')) {
        throw 'Writes must address a selected target work item type or behavior resource.'
    }
    $method = $operation.method
    $body = ConvertTo-Json -InputObject $operation.body -Depth 100 -Compress
    $role = 'writer'
}
else {
    Assert-ApiPath $ApiPath
    if ($ApiPath -eq 'audit/auditlog') {
        $hostName = 'auditservice.dev.azure.com'
        $version = '7.1-preview.1'
        foreach ($key in @('startTime', 'endTime')) {
            if (-not $Query.ContainsKey($key)) { throw 'Audit reads require a fixed startTime and endTime.' }
        }
        $start = [DateTimeOffset]::Parse($Query.startTime, [Globalization.CultureInfo]::InvariantCulture)
        $end = [DateTimeOffset]::Parse($Query.endTime, [Globalization.CultureInfo]::InvariantCulture)
        if ($start.Offset -ne [TimeSpan]::Zero -or $end.Offset -ne [TimeSpan]::Zero -or
            $start -ge $end -or $start -lt [DateTimeOffset]::UtcNow.AddDays(-90) -or
            $end -gt [DateTimeOffset]::UtcNow) {
            throw 'Audit window must be increasing UTC times within the past 90 days.'
        }
    }
    elseif ($ApiPath -notmatch '^(work/processes|wit/fields)(/|$)') {
        throw 'Only audit, process metadata, and global field metadata reads are supported.'
    }
}

$allowedQueryKeys = @('$expand', 'continuationToken', 'startTime', 'endTime', 'batchSize', 'skipAggregation')
$queryParts = @("api-version=$version")
foreach ($key in $Query.Keys) {
    if ($key -cnotin $allowedQueryKeys) { throw 'Unsupported query parameter.' }
    $queryParts += '{0}={1}' -f [Uri]::EscapeDataString($key), [Uri]::EscapeDataString([string]$Query[$key])
}
$baseUri = "https://$hostName/$($scope.Organization)/_apis/"
$uri = $baseUri + $ApiPath + '?' + ($queryParts -join '&')
$credentialPath = Join-Path $env:LOCALAPPDATA ("AdoProcessSync\credentials\{0}-{1}.clixml" -f $scope.Organization, $role)
foreach ($path in @((Split-Path -Parent $credentialPath), $credentialPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Local $role credential missing. Enroll it in your own terminal." }
    if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Credential paths must not be reparse points.'
    }
}

function Invoke-ProtectedRequest {
    param([string]$Uri, [string]$Method, [AllowNull()][string]$Body)
    $parameters = @{
        Uri = $Uri
        Method = $Method
        Authentication = 'Basic'
        Credential = $credential
        MaximumRedirection = 0
        TimeoutSec = 60
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body -and $Body.Length -gt 0) {
        $parameters.ContentType = 'application/json; charset=utf-8'
        $parameters.Body = [Text.Encoding]::UTF8.GetBytes($Body)
    }
    try {
        Invoke-RestMethod @parameters
    }
    catch {
        $status = 'transport failure'
        if ($_.Exception.PSObject.Properties['Response'] -and $null -ne $_.Exception.Response) {
            $status = "HTTP $([int]$_.Exception.Response.StatusCode)"
        }
        # Do not expose server bodies, auth headers, or the underlying exception.
        throw "Azure DevOps request failed ($status). No automatic retry; inspect live state before retrying writes."
    }
}

try {
    $credential = Import-Clixml -LiteralPath $credentialPath
    if ($credential -isnot [PSCredential] -or $credential.UserName -ne $scope.Organization) {
        throw 'Credential is not an organization-matching PSCredential.'
    }
    if ($Apply) {
        $sourceUri = $baseUri + "work/processes/$($scope.Source)?api-version=7.1"
        $targetUri = $baseUri + "work/processes/$($segments[2])?api-version=7.1"
        $source = Invoke-ProtectedRequest -Uri $sourceUri -Method GET
        $target = Invoke-ProtectedRequest -Uri $targetUri -Method GET
        if ($source.typeId -ne $scope.Source -or $target.typeId -ne $segments[2] -or
            $source.customizationType -ne 'inherited' -or $target.customizationType -ne 'inherited' -or
            -not $source.parentProcessTypeId -or $source.parentProcessTypeId -eq [guid]::Empty.ToString() -or
            $source.parentProcessTypeId -ne $target.parentProcessTypeId) {
            throw 'Live source/target must be the selected inherited processes with the same system parent.'
        }
    }
    $result = Invoke-ProtectedRequest -Uri $uri -Method $method -Body $body
    if ($ApiPath -eq 'audit/auditlog') {
        $page = $result
        if ($result.PSObject.Properties['value']) { $page = $result.value }
        if (-not $page.PSObject.Properties['decoratedAuditLogEntries'] -or
            -not $page.PSObject.Properties['hasMore'] -or $page.hasMore -isnot [bool] -or
            ($page.hasMore -and (-not $page.PSObject.Properties['continuationToken'] -or -not $page.continuationToken))) {
            throw 'Invalid or incomplete audit page.'
        }
        $result = [ordered]@{
            decoratedAuditLogEntries = @($page.decoratedAuditLogEntries |
                Select-Object id, timestamp, actionId, correlationId, data, details)
            hasMore = $page.hasMore
            continuationToken = if ($page.PSObject.Properties['continuationToken']) { $page.continuationToken } else { $null }
        }
    }
    ConvertTo-Json -InputObject $result -Depth 100
}
finally {
    $credential = $null
}
