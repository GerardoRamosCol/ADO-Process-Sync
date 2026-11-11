#requires -Version 7.5
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

function Write-AdoTrace {
    param([string]$Event, [hashtable]$Data = @{})
    $record = [ordered]@{ timestamp = [DateTimeOffset]::UtcNow.ToString('o'); event = $Event }
    foreach ($key in @('kind', 'method', 'path', 'command', 'processId', 'sourceProcessId', 'targetProcessIds', 'eventId', 'actionId', 'eventTime', 'phase', 'count', 'mode', 'key', 'reason', 'exceptionType', 'exceptionTypes', 'category', 'httpStatus', 'serviceErrorType', 'serviceErrorCode', 'script', 'line')) {
        if ($Data.ContainsKey($key)) { $record[$key] = $Data[$key] }
    }
    [Console]::WriteLine('[ADO Sync] ' + (ConvertTo-Json -InputObject $record -Depth 5 -Compress))
}

function Write-AdoFailureTrace {
    param([string]$Event, [System.Management.Automation.ErrorRecord]$Failure, [hashtable]$Data = @{})
    $Data.exceptionType = $Failure.Exception.GetType().FullName
    $Data.category = [string]$Failure.CategoryInfo.Category
    $Data.script = [IO.Path]::GetFileName($Failure.InvocationInfo.ScriptName)
    $Data.line = $Failure.InvocationInfo.ScriptLineNumber
    if ($Failure.ErrorDetails -and $Failure.ErrorDetails.Message) {
        try {
            $serviceError = ConvertFrom-Json -InputObject $Failure.ErrorDetails.Message -AsHashtable -ErrorAction Stop
            if ($serviceError.typeKey -is [string] -and $serviceError.typeKey -cmatch '^[A-Za-z][A-Za-z0-9_.]{0,199}$') { $Data.serviceErrorType = $serviceError.typeKey }
            if ($serviceError.errorCode -is [int] -or $serviceError.errorCode -is [long]) { $Data.serviceErrorCode = $serviceError.errorCode }
        }
        catch { }
    }
    $exception = $Failure.Exception
    $types = [Collections.Generic.List[string]]::new()
    while ($null -ne $exception -and $types.Count -lt 10) {
        $types.Add($exception.GetType().FullName)
        if ($exception.PSObject.Properties['Response'] -and $null -ne $exception.Response -and $exception.Response.PSObject.Properties['StatusCode']) {
            $Data.httpStatus = [int]$exception.Response.StatusCode
        }
        if ($exception.Message -like '*Response was HTML*') { $Data.reason = 'PSDevOps returned HTML instead of JSON.' }
        $exception = $exception.InnerException
    }
    $Data.exceptionTypes = @($types.ToArray())
    Write-AdoTrace $Event $Data
}

function Assert-AdoOrganization {
    param([string]$Organization)
    if ($Organization -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,49}$') { throw 'Enter an organization slug, not a URL.' }
}

function Invoke-AdoWorkItemTypeModule {
    param([string]$Organization, [PSCredential]$Credential, [string]$ProcessId,
        [string]$ReferenceName, [string]$Method, [hashtable]$Body)
    $trace = @{ method = $Method; processId = $ProcessId; command = $(if ($Method -eq 'POST') { 'New-ADOWorkItemType' } else { 'Get-ADOWorkItemType' }); path = "work/processes/$ProcessId/workItemTypes" + $(if ($ReferenceName) { "/$ReferenceName" }) }
    Write-AdoTrace 'psdevops.start' $trace
    try {
        $module = Get-Module PSDevOps | Select-Object -First 1
        if (-not $module) { $module = Import-Module PSDevOps -PassThru -ErrorAction Stop }
    }
    catch {
        Write-AdoFailureTrace 'psdevops.import.failed' $_ $trace
        throw 'PSDevOps is required. Install-Module PSDevOps -Scope CurrentUser, then restart the app.'
    }
    try {
        & $module { $script:CachedCredential = $null; $script:CachedPersonalAccessToken = $null }
        $parameters = @{ Organization = $Organization; ProcessID = $ProcessId; PersonalAccessToken = $Credential.GetNetworkCredential().Password;
            ApiVersion = '7.1'; Server = 'https://dev.azure.com/'; ErrorAction = 'Stop'; Verbose = $false; Debug = $false }
        if ($Method -eq 'POST') {
            if (-not $Body.name -or -not $Body.color -or @($Body.Keys | Where-Object { $_ -notin @('name', 'description', 'color', 'icon') }).Count) {
                throw 'Unsupported work item type creation payload.'
            }
            $result = & $module { param($Parameters, $Payload) New-ADOWorkItemType @Parameters @Payload -Confirm:$false } $parameters $Body
        }
        else {
            if ($ReferenceName) { $parameters.ReferenceName = $ReferenceName }
            $items = @(& $module { param($Parameters) Get-ADOWorkItemType @Parameters } $parameters)
            if (-not $ReferenceName) {
                if ($items.Count -eq 1 -and $null -ne $items[0].value) { $items = @($items[0].value) }
                Write-AdoTrace 'psdevops.completed' ($trace + @{ count = $items.Count })
                return @{ value = @($items | ForEach-Object {
                    ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $_ -Depth 100) -AsHashtable -DateKind String
                }) }
            }
            if ($items.Count -ne 1) { throw 'Expected exactly one work item type.' }
            $result = $items[0]
        }
        $result = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $result -Depth 100) -AsHashtable -DateKind String
        if ($result -is [System.Collections.IDictionary]) {
            $normalized = @{}
            foreach ($property in $result.Keys) { $normalized[$property] = $result[$property] }
            $result = $normalized
        }
        if ($result -isnot [System.Collections.IDictionary] -or -not $result.referenceName) { throw 'Invalid work item type response.' }
        if ($ReferenceName -and $result.referenceName -cne $ReferenceName) { throw 'Work item type reference mismatch.' }
        Write-AdoTrace 'psdevops.completed' $trace
        return $result
    }
    catch {
        Write-AdoFailureTrace 'psdevops.failed' $_ $trace
        throw 'PSDevOps work item type request failed. Check permissions and live state before retrying; writes are never retried automatically.'
    }
    finally {
        if ($parameters) { $parameters.Remove('PersonalAccessToken') }
        & $module { $script:CachedCredential = $null; $script:CachedPersonalAccessToken = $null }
    }
}

function Invoke-AdoApi {
    param(
        [string]$Organization, [PSCredential]$Credential, [string]$Path,
        [hashtable]$Query = @{}, [ValidateSet('GET', 'POST', 'PATCH', 'PUT')][string]$Method = 'GET',
        [hashtable]$Body, [scriptblock]$Transport
    )
    Assert-AdoOrganization $Organization
    if ($null -eq $Credential -or $Credential.UserName -cne $Organization.ToLowerInvariant()) { throw 'Organization-matching credential required.' }
    if ($Path -notmatch '^[A-Za-z0-9_-]+(?:/[A-Za-z0-9_.-]+)*$' -or @($Path.Split('/') | Where-Object { $_ -in '.', '..' }).Count) {
        throw 'Invalid API path.'
    }
    $hostName = 'dev.azure.com'
    $version = '7.1'
    if ($Path -eq 'audit/auditlog') {
        if ($Method -ne 'GET') { throw 'Audit is read-only.' }
        $hostName = 'auditservice.dev.azure.com'
        $version = '7.1-preview.1'
    }
    elseif ($Path -notmatch '^(work/processes|wit/fields)(/|$)') { throw 'API route is not allowed.' }
    if ($Method -ne 'GET' -and $Path -notmatch '^work/processes/[a-fA-F0-9-]{36}/(workItemTypes|workitemtypesbehaviors|behaviors)(/|$)') {
        throw 'Only process-local entity writes are allowed.'
    }
    if (-not $Transport -and $Query.Count -eq 0 -and
        $Path -match '^work/processes/(?<processId>[a-fA-F0-9-]{36})/workItemTypes(?:/(?<witRef>[A-Za-z0-9_.-]+))?$' -and
        ($Method -eq 'GET' -or ($Method -eq 'POST' -and -not $Matches.witRef))) {
        return Invoke-AdoWorkItemTypeModule -Organization $Organization -Credential $Credential -ProcessId $Matches.processId -ReferenceName $Matches.witRef -Method $Method -Body $Body
    }
    $parts = @("api-version=$version")
    foreach ($key in ($Query.Keys | Sort-Object)) {
        if ($key -cnotin @('$expand', 'continuationToken', 'startTime', 'endTime', 'batchSize', 'skipAggregation')) { throw 'Unsupported query parameter.' }
        $parts += '{0}={1}' -f [Uri]::EscapeDataString($key), [Uri]::EscapeDataString([string]$Query[$key])
    }
    $parameters = @{
        Uri = "https://$hostName/$($Organization.ToLowerInvariant())/_apis/$Path`?$($parts -join '&')"
        Method = $Method; Authentication = 'Basic'; Credential = $Credential
        MaximumRedirection = 0; TimeoutSec = 60; ErrorAction = 'Stop'
    }
    if ($Method -ne 'GET') {
        if ($null -eq $Body) { throw 'An explicit object payload is required.' }
        $parameters.ContentType = 'application/json; charset=utf-8'
        $parameters.Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 100 -Compress))
    }
    try {
        Write-AdoTrace 'rest.start' @{ method = $Method; path = $Path }
        if ($Transport) { $result = & $Transport $parameters }
        else {
            $response = Invoke-WebRequest @parameters
            if ($response.Headers['x-ms-continuationtoken'] -and $Path -ne 'audit/auditlog') { throw 'Unexpected metadata pagination.' }
            $result = if ([string]::IsNullOrWhiteSpace($response.Content)) { @{} } else { ConvertFrom-Json -InputObject $response.Content -AsHashtable -DateKind String }
        }
        if ($result -is [string]) { throw 'Unexpected text response.' }
        if ($result -isnot [System.Collections.IDictionary]) {
            $result = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $result -Depth 100) -AsHashtable -DateKind String
        }
        Write-AdoTrace 'rest.completed' @{ method = $Method; path = $Path }
        return $result
    }
    catch {
        Write-AdoFailureTrace 'rest.failed' $_ @{ method = $Method; path = $Path }
        $status = 'transport or response failure'
        if ($_.Exception.PSObject.Properties['Response'] -and $null -ne $_.Exception.Response) {
            $status = "HTTP $([int]$_.Exception.Response.StatusCode)"
        }
        throw "Azure DevOps request failed ($status). Check permissions and auditing availability. Writes are never retried automatically."
    }
}

function Get-AdoCollection {
    param([hashtable]$Response)
    if (-not $Response.ContainsKey('value') -or $Response.value -isnot [array]) { throw 'Incomplete API collection response.' }
    if ($Response.ContainsKey('continuationToken') -and $Response.continuationToken) { throw 'Unexpected metadata pagination; cannot safely use an incomplete collection.' }
    return ,@($Response.value)
}

function Assert-AdoWindow {
    param([string]$StartTime, [string]$EndTime)
    $start = [DateTimeOffset]::Parse($StartTime, [Globalization.CultureInfo]::InvariantCulture)
    $end = [DateTimeOffset]::Parse($EndTime, [Globalization.CultureInfo]::InvariantCulture)
    if ($start.Offset -ne [TimeSpan]::Zero -or $end.Offset -ne [TimeSpan]::Zero -or
        $start -ge $end -or $start -lt [DateTimeOffset]::UtcNow.AddDays(-90) -or $end -gt [DateTimeOffset]::UtcNow) {
        throw 'Choose increasing UTC times within the past 90 days.'
    }
}

function Get-AdoAudit {
    param([string]$Organization, [PSCredential]$Credential, [string]$StartTime, [string]$EndTime, [scriptblock]$Transport,
        [Collections.Generic.List[object]]$RawPages)
    Assert-AdoWindow $StartTime $EndTime
    $query = @{ startTime = $StartTime; endTime = $EndTime; batchSize = '200'; skipAggregation = 'true' }
    $tokens = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $events = [Collections.Generic.List[object]]::new()
    $pageCount = 0
    do {
        if (++$pageCount -gt 10000) { throw 'Audit pagination limit reached; narrow the window.' }
        $response = Invoke-AdoApi -Organization $Organization -Credential $Credential -Path 'audit/auditlog' -Query $query -Transport $Transport
        if ($null -ne $RawPages) { $RawPages.Add($response) }
        $page = if ($response.ContainsKey('value')) { $response.value } else { $response }
        if ($page -isnot [System.Collections.IDictionary] -or $page.decoratedAuditLogEntries -isnot [array] -or $page.hasMore -isnot [bool]) {
            throw 'Invalid or incomplete audit page.'
        }
        foreach ($entry in $page.decoratedAuditLogEntries) {
            if (-not $entry.id -or -not $entry.timestamp -or -not $entry.actionId) { throw 'Audit event is missing required evidence.' }
            $eventTime = [DateTimeOffset]::Parse($entry.timestamp)
            if ($eventTime -lt [DateTimeOffset]::Parse($StartTime) -or $eventTime -gt [DateTimeOffset]::Parse($EndTime)) {
                throw 'Audit event is outside the requested fixed window.'
            }
            if ($ids.Add([string]$entry.id)) {
                $data = @{}
                if ($entry.data -is [System.Collections.IDictionary]) {
                    foreach ($key in @('ProcessId', 'ProcessTypeId', 'WorkItemTypeId', 'WorkItemTypeRefName', 'WorkItemTypeReferenceName', 'WorkItemReferenceName', 'WorkItemTypeName', 'FieldId', 'FieldReferenceName', 'StateId', 'StateName', 'RuleId', 'RuleName', 'BehaviorId', 'BehaviorName', 'BehaviorReferenceName', 'PageId', 'PageName', 'GroupId', 'GroupLabel', 'ControlId', 'ControlLabel')) {
                        if ($entry.data.Contains($key) -and $entry.data[$key] -is [string]) { $data[$key] = $entry.data[$key] }
                    }
                }
                $events.Add(@{ id = [string]$entry.id; timestamp = $eventTime.ToUniversalTime().ToString('o'); actionId = [string]$entry.actionId; correlationId = [string]$entry.correlationId; data = $data })
            }
        }
        if ($page.hasMore) {
            if (-not $page.continuationToken -or -not $tokens.Add([string]$page.continuationToken)) { throw 'Missing or repeated audit continuation token.' }
            $query.continuationToken = [string]$page.continuationToken
        }
    } while ($page.hasMore)
    return @{ events = @($events.ToArray()); pageCount = $pageCount; complete = $true; startTime = $StartTime; endTime = $EndTime }
}

Export-ModuleMember -Function Write-AdoTrace, Write-AdoFailureTrace, Assert-AdoOrganization, Invoke-AdoApi, Get-AdoCollection, Assert-AdoWindow, Get-AdoAudit