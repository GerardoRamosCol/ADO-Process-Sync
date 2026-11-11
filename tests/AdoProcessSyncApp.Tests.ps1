#requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts/process-sync/AdoProcessApi.psm1') -Force
$checks = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:checks++
}
function Assert-Blocked {
    param([scriptblock]$Action, [string]$Pattern)
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert-True ($message -match $Pattern) "Expected '$Pattern', received '$message'."
}
$credential = [PSCredential]::new('test-org', (ConvertTo-SecureString 'offline-fake-pat' -AsPlainText -Force))
$consoleOutput = [Console]::Out
$traceOutput = [IO.StringWriter]::new()
$traceWorker = [PowerShell]::Create()
try {
    [Console]::SetOut($traceOutput)
    Write-AdoTrace 'test.action' @{ method = 'PATCH'; path = 'work/processes/example/workItemTypes/Child.Example'; writerPat = 'SECRET-PAT'; Authorization = 'SECRET-HEADER'; Body = 'SECRET-BODY' }
    $failure = [System.Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('SECRET-ERROR-BODY'), 'TestFailure', 'InvalidOperation', $null)
    $failure.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"typeKey":"InvalidWorkItemTypeReferenceNameException","errorCode":123,"message":"SECRET-SERVICE-MESSAGE","Authorization":"SECRET-HEADER"}')
    Write-AdoFailureTrace 'test.failure' $failure @{ command = 'Get-ADOWorkItemType' }
    $null = $traceWorker.AddScript('param($Path) Import-Module $Path; Write-AdoTrace "test.worker" @{ kind = "Preview" }').AddArgument((Join-Path $root 'scripts/process-sync/AdoProcessApi.psm1'))
    $workerOutput = @($traceWorker.Invoke())
}
finally {
    [Console]::SetOut($consoleOutput)
    $traceWorker.Dispose()
}
$traceText = $traceOutput.ToString()
$traceOutput.Dispose()
Assert-True ($traceText -match 'test.action' -and $traceText -match 'PATCH' -and $traceText -match 'test.worker') 'Action traces from the app and background runspace reach the process console.'
Assert-True ($workerOutput.Count -eq 0) 'Console tracing never contaminates function response objects.'
Assert-True ($traceText -match 'System.InvalidOperationException' -and $traceText -match 'Get-ADOWorkItemType') 'Failure diagnostics identify the exception and attempted command.'
Assert-True ($traceText -match 'InvalidWorkItemTypeReferenceNameException' -and $traceText -match '"serviceErrorCode":123') 'Failure diagnostics retain structured Azure DevOps error types and codes without raw response messages.'
Assert-True ($traceText -notmatch 'SECRET|writerPat|Authorization') 'Console traces exclude credentials, headers, request bodies, and arbitrary exception response text.'
$psDevOps = New-Module -Name PSDevOps -ScriptBlock {
    $script:calls = [Collections.Generic.List[object]]::new()
    $script:fail = $false
    $script:empty = $false
    $script:CachedPersonalAccessToken = 'offline-stale-cache'
    function Get-ADOWorkItemType {
        [CmdletBinding()]
        param($Organization, $ProcessID, $PersonalAccessToken, $ApiVersion, $Server, $ReferenceName)
        if ($script:CachedPersonalAccessToken -or $script:CachedCredential) { throw 'Stale module credential cache.' }
        if ($PersonalAccessToken -ne 'offline-fake-pat') { throw 'Expected explicit PAT authentication.' }
        $script:CachedPersonalAccessToken = $PersonalAccessToken
        $script:calls.Add(@{ command = 'Get'; parameters = $PSBoundParameters })
        if ($script:fail) { throw 'SENSITIVE-MODULE-RESPONSE' }
        if ($script:empty) { return [pscustomobject]@{ count = 0; value = @() } }
        if ($ReferenceName) { return [pscustomobject]@{ name = 'Example'; ReferenceName = 'Child.Example'; description = 'details' } }
        [pscustomobject]@{ name = 'Example'; referenceName = 'Child.Example'; description = 'details' }
    }
    function New-ADOWorkItemType {
        [CmdletBinding(SupportsShouldProcess)]
        param($Organization, $ProcessID, $PersonalAccessToken, $ApiVersion, $Server, $Name, $Description, $Color, $Icon)
        if ($PersonalAccessToken -ne 'offline-fake-pat') { throw 'Expected explicit PAT authentication.' }
        $script:CachedPersonalAccessToken = $PersonalAccessToken
        $script:calls.Add(@{ command = 'New'; parameters = $PSBoundParameters })
        [pscustomobject]@{ name = $Name; referenceName = 'Child.Example' }
    }
    Export-ModuleMember -Function Get-ADOWorkItemType, New-ADOWorkItemType
}
Import-Module $psDevOps -Global
try {
    $modulePath = 'work/processes/22222222-2222-2222-2222-222222222222/workItemTypes'
    $moduleList = Invoke-AdoApi -Organization 'test-org' -Credential $credential -Path $modulePath
    Assert-True ($moduleList.value -is [array] -and $moduleList.value.Count -eq 1) 'PSDevOps singleton output is normalized to an API collection.'
    $details = Invoke-AdoApi -Organization 'test-org' -Credential $credential -Path "$modulePath/Child.Example"
    Assert-True ($details.description -eq 'details' -and $details.referenceName -eq 'Child.Example') 'WIT details normalize the capitalized ReferenceName decoration from PSDevOps.'
    $created = Invoke-AdoApi -Organization 'test-org' -Credential $credential -Path $modulePath -Method POST -Body @{ name = 'Example'; description = 'approved'; color = '009ccc'; icon = 'icon_bug' }
    $moduleCalls = & $psDevOps { $script:calls.ToArray() }
    Assert-True ($created.referenceName -eq 'Child.Example' -and $moduleCalls[2].command -eq 'New') 'WIT creation uses New-ADOWorkItemType and returns the child-local reference.'
    Assert-True ($moduleCalls[1].parameters.ReferenceName -eq 'Child.Example' -and $moduleCalls[1].parameters.ProcessID -eq '22222222-2222-2222-2222-222222222222') 'Detail retrieval uses the selected child and its local reference.'
    Assert-True ($moduleCalls[2].parameters.Organization -eq 'test-org' -and $moduleCalls[2].parameters.ApiVersion -eq '7.1' -and $moduleCalls[2].parameters.ProcessID -eq '22222222-2222-2222-2222-222222222222') 'Module creation is scoped to the child and API 7.1.'
    Assert-True ($moduleCalls[2].parameters.Description -eq 'approved' -and $moduleCalls[2].parameters.PersonalAccessToken -eq 'offline-fake-pat' -and -not $moduleCalls[2].parameters.ContainsKey('Credential') -and -not $moduleCalls[2].parameters.Confirm) 'Approved creation uses explicit PAT authentication without an interactive confirmation.'
    Assert-True ($moduleCalls[0].parameters.PersonalAccessToken -eq 'offline-fake-pat' -and $moduleCalls[1].parameters.PersonalAccessToken -eq 'offline-fake-pat' -and -not $moduleCalls[1].parameters.ContainsKey('Credential')) 'WIT list and detail reads use the explicit PAT header path rather than challenge-based credentials.'
    Assert-True (& $psDevOps { $null -eq $script:CachedCredential -and $null -eq $script:CachedPersonalAccessToken }) 'PSDevOps credential caches are cleared after success.'
    Assert-Blocked { Invoke-AdoApi -Organization 'test-org' -Credential $credential -Path "$modulePath/Wrong.Reference" } '^PSDevOps work item type request failed'
    Assert-Blocked { Invoke-AdoApi -Organization 'test-org' -Credential $credential -Path $modulePath -Method POST -Body @{ name = 'Example'; color = '009ccc'; isDisabled = $true } } '^PSDevOps work item type request failed'
    & $psDevOps { $script:empty = $true }
    $moduleList = Invoke-AdoApi -Organization 'test-org' -Credential $credential -Path $modulePath
    Assert-True ($moduleList.value -is [array] -and $moduleList.value.Count -eq 0) 'An empty PSDevOps collection remains empty.'
    & $psDevOps { $script:fail = $true }
    Assert-Blocked { Invoke-AdoApi -Organization 'test-org' -Credential $credential -Path "$modulePath/Child.Example" } '^PSDevOps work item type request failed'
    Assert-True (& $psDevOps { $null -eq $script:CachedCredential -and $null -eq $script:CachedPersonalAccessToken -and $script:calls.Count -eq 6 }) 'Failure clears cached credentials and does not retry the module call.'
}
finally { Remove-Module $psDevOps }
$end = [DateTimeOffset]::UtcNow.AddMinutes(-1)
$start = $end.AddHours(-1)
$requests = [Collections.Generic.List[object]]::new()
$transport = {
    param($parameters)
    $requests.Add($parameters)
    $more = $parameters.Uri -notmatch 'continuationToken='
    return @{ value = @{
        decoratedAuditLogEntries = @(@{ id = 'event-1'; timestamp = $start.AddMinutes(2).ToString('o'); actionId = 'Process.Test'; correlationId = 'correlation'; data = @{ ProcessId = '11111111-1111-1111-1111-111111111111'; actor = 'private' }; actorUserId = 'private' })
        hasMore = $more; continuationToken = if ($more) { 'next+page/=' } else { $null }
    } }
}.GetNewClosure()
$rawPages = [Collections.Generic.List[object]]::new()
$audit = Get-AdoAudit -Organization 'test-org' -Credential $credential -StartTime $start.ToString('o') -EndTime $end.ToString('o') -Transport $transport -RawPages $rawPages
Assert-True ($rawPages.Count -eq 2 -and $rawPages[0].value.decoratedAuditLogEntries[0].actorUserId -eq 'private') 'Raw response pages retain original wrappers and fields separately from plan evidence.'
Assert-True ($audit.complete -and $audit.pageCount -eq 2 -and $audit.events.Count -eq 1) 'All pages read and event IDs deduplicated.'
Assert-True ($requests[1].Uri -match 'continuationToken=next%2Bpage%2F%3D') 'Continuation token is encoded.'
Assert-True ($requests[0].Uri -match '^https://auditservice.dev.azure.com/test-org/_apis/audit/auditlog\?api-version=7.1-preview.1') 'Audit host and version pinned.'
Assert-True ($requests[0].MaximumRedirection -eq 0) 'Redirects blocked.'
Assert-True ((ConvertTo-Json $audit -Depth 20) -notmatch 'private|offline-fake') 'Minimal evidence excludes actor and credentials.'
Assert-Blocked { Invoke-AdoApi -Organization 'test-org' -Credential $credential -Path 'work/processes/../other' -Transport $transport } 'Invalid API path'
Assert-Blocked { Invoke-AdoApi -Organization 'test-org' -Credential $credential -Path 'projects' -Transport $transport } 'not allowed'
Assert-Blocked { Assert-AdoWindow $end.ToString('o') $start.ToString('o') } 'increasing UTC'
$repeated = { param($parameters) @{ decoratedAuditLogEntries = @(); hasMore = $true; continuationToken = 'same' } }
Assert-Blocked { Get-AdoAudit -Organization 'test-org' -Credential $credential -StartTime $start.ToString('o') -EndTime $end.ToString('o') -Transport $repeated } 'repeated'
$missing = { param($parameters) @{ decoratedAuditLogEntries = @(); hasMore = $true; continuationToken = '' } }
Assert-Blocked { Get-AdoAudit -Organization 'test-org' -Credential $credential -StartTime $start.ToString('o') -EndTime $end.ToString('o') -Transport $missing } 'Missing'
Assert-Blocked { Invoke-AdoApi -Organization 'test-org' -Credential $credential -Path 'work/processes' -Transport { throw 'SENSITIVE-BODY' } } '^Azure DevOps request failed \(transport'
Import-Module (Join-Path $root 'scripts/process-sync/AdoProcessSync.psm1') -Force
Assert-True ((Get-AdoHash @{ second = 2; first = 1 }) -eq (Get-AdoHash @{ first = 1; second = 2 })) 'Object key order does not affect hashes.'
Assert-True ((Get-AdoHash @(1, 2)) -ne (Get-AdoHash @(2, 1))) 'Meaningful array order is preserved.'
$sourceId = '11111111-1111-1111-1111-111111111111'
$targetId = '22222222-2222-2222-2222-222222222222'
$scope = @{ organization = 'test-org'; sourceProcessId = $sourceId; targetProcessIds = @($targetId) }
function New-TestSnapshot {
    param([string]$ProcessId, [string]$Description)
    @{ process = @{ typeId = $ProcessId; name = $ProcessId; customizationType = 'inherited'; parentProcessTypeId = '33333333-3333-3333-3333-333333333333' }; entities = @{
        'wit:Bug' = @{ key = 'wit:Bug'; category = 'WorkItemType'; identity = 'System.Bug'; parent = ''; definition = @{ name = 'Bug'; description = $Description; color = '009ccc'; icon = 'icon_bug'; isDisabled = $false; inherits = $null }; path = "work/processes/$ProcessId/workItemTypes/System.Bug"; createPath = "work/processes/$ProcessId/workItemTypes"; customization = 'inherited'; witRef = 'System.Bug' }
    } }
}
$snapshots = @{ $sourceId = (New-TestSnapshot $sourceId 'before'); $targetId = (New-TestSnapshot $targetId 'before') }
$emptyAudit = @{ complete = $true; startTime = $start.ToString('o'); endTime = $end.ToString('o'); events = @(); pageCount = 1 }
$adoption = New-AdoPlan $scope $null $snapshots $emptyAudit @{} 'Project impact accepted'
Assert-True ($adoption.mode -eq 'adopt' -and $adoption.operations.Count -eq 0) 'First run is baseline-only.'
$baseline = @{ snapshots = (Copy-AdoObject $snapshots); checkpoint = $start.AddMinutes(1).ToString('o'); eventIds = @() }
$snapshots[$sourceId].entities['wit:Bug'].definition.description = 'after'
$audit = Copy-AdoObject $emptyAudit
$audit.events = @(@{ id = 'change-1'; timestamp = $start.AddMinutes(5).ToString('o'); actionId = 'Process.WorkItemType.Update'; data = @{ ProcessId = $sourceId; WorkItemTypeReferenceName = 'System.Bug' } })
$plan = New-AdoPlan $scope $baseline $snapshots $audit @{} 'Project impact accepted'
Assert-True ($plan.blockers.Count -eq 0 -and $plan.operations.Count -eq 1) 'Evidenced source edit generates one operation.'
Assert-True ($plan.operations[0].path -match $targetId -and $plan.operations[0].body.Count -eq 1 -and $plan.operations[0].body.description -eq 'after') 'Only changed property targets the mapped child.'
$inheritedSnapshots = Copy-AdoObject $baseline.snapshots
foreach ($processId in @($sourceId, $targetId)) { $inheritedSnapshots[$processId].entities['wit:Bug'].definition.inherits = 'Microsoft.VSTS.WorkItemTypes.Bug' }
$inheritedBaseline = @{ snapshots = (Copy-AdoObject $inheritedSnapshots); checkpoint = $baseline.checkpoint; eventIds = @() }
$inheritedSnapshots[$sourceId].entities['wit:Bug'].definition.description = 'after'
$inheritedPlan = New-AdoPlan $scope $inheritedBaseline $inheritedSnapshots $audit @{} 'Project impact accepted'
Assert-True ($inheritedPlan.blockers.Count -eq 0 -and $inheritedPlan.operations.Count -eq 1) 'Audited inherited work item type updates are supported.'
Assert-True ($inheritedPlan.operations[0].method -eq 'PATCH' -and $inheritedPlan.operations[0].path -eq "work/processes/$targetId/workItemTypes/System.Bug" -and $inheritedPlan.operations[0].body.Count -eq 1 -and $inheritedPlan.operations[0].body.description -eq 'after') 'Documented WIT PATCH changes only the child description, never inheritance metadata.'
Assert-True ($inheritedPlan.operations[0].actionIds.Count -eq 1 -and $inheritedPlan.operations[0].actionIds[0] -eq 'Process.WorkItemType.Update') 'Child PATCH retains the originating audit action.'
$mappedSnapshots = Copy-AdoObject $baseline.snapshots
foreach ($processId in @($sourceId, $targetId)) {
    $localReference = if ($processId -eq $sourceId) { 'Universal.Bug' } else { 'Child.Bug' }
    $mappedSnapshots[$processId].entities['wit:Bug'].identity = $localReference
    $mappedSnapshots[$processId].entities['wit:Bug'].witRef = $localReference
    $mappedSnapshots[$processId].entities['wit:Bug'].path = "work/processes/$processId/workItemTypes/$localReference"
    $mappedSnapshots[$processId].entities['wit:Bug'].customization = 'custom'
}
$mappedBaseline = @{ snapshots = (Copy-AdoObject $mappedSnapshots); checkpoint = $baseline.checkpoint; eventIds = @() }
$mappedSnapshots[$sourceId].entities['wit:Bug'].definition.description = 'after'
$mappedAudit = Copy-AdoObject $audit
$mappedAudit.events[0].data.WorkItemTypeReferenceName = 'Universal.Bug'
$mappedPlan = New-AdoPlan $scope $mappedBaseline $mappedSnapshots $mappedAudit @{} 'Project impact accepted'
Assert-True ($mappedPlan.blockers.Count -eq 0 -and $mappedPlan.operations.Count -eq 1 -and $mappedPlan.operations[0].path -eq "work/processes/$targetId/workItemTypes/Child.Bug" -and $mappedPlan.operations[0].targetIdentity -eq 'Child.Bug') 'An audited update resolves the child-local WIT reference instead of copying the Universal reference.'
$createdSnapshots = Copy-AdoObject $baseline.snapshots
$createdType = Copy-AdoObject $createdSnapshots[$sourceId].entities['wit:Bug']
$createdType.key = 'wit:Change%20Request'; $createdType.identity = 'Universal.ChangeRequest'; $createdType.witRef = $createdType.identity; $createdType.customization = 'custom'
$createdType.definition.name = 'Change Request'; $createdType.definition.description = 'Audited creation'
$createdType.path = "work/processes/$sourceId/workItemTypes/Universal.ChangeRequest"
$createdSnapshots[$sourceId].entities[$createdType.key] = $createdType
$createAudit = Copy-AdoObject $emptyAudit
$createAudit.events = @(@{ id = 'type-created'; actionId = 'Process.WorkItemType.Create'; data = @{ ProcessId = $sourceId; WorkItemTypeReferenceName = 'Universal.ChangeRequest' } })
$createPlan = New-AdoPlan $scope $baseline $createdSnapshots $createAudit @{} 'Project impact accepted'
Assert-True ($createPlan.blockers.Count -eq 0 -and $createPlan.operations.Count -eq 1) 'Audited custom WIT creation generates an executable child operation.'
Assert-True ($createPlan.operations[0].method -eq 'POST' -and $createPlan.operations[0].path -eq "work/processes/$targetId/workItemTypes" -and $createPlan.operations[0].body.Count -eq 4 -and $createPlan.operations[0].body.name -eq 'Change Request') 'WIT Create uses the documented child collection POST and writable create fields only.'
Assert-True ($createPlan.operations[0].actionIds[0] -eq 'Process.WorkItemType.Create' -and $createPlan.operations[0].evidence[0] -eq 'type-created') 'Create operation identifies its exact originating audit row.'
$createdSnapshots[$targetId].entities[$createdType.key] = Copy-AdoObject $createdType
$createdSnapshots[$targetId].entities[$createdType.key].identity = 'Child.ChangeRequest'
$createdNoop = New-AdoPlan $scope $baseline $createdSnapshots $createAudit @{} 'Project impact accepted'
Assert-True ($createdNoop.operations.Count -eq 0 -and $createdNoop.noOps.Count -eq 1 -and $createdNoop.noOps[0].actionIds[0] -eq 'Process.WorkItemType.Create') 'An already matching child type is not created again.'
$deleteAudit = Copy-AdoObject $audit
$deleteAudit.events[0].actionId = 'Process.WorkItemType.Delete'
$deletePlan = New-AdoPlan $scope $baseline $snapshots $deleteAudit @{} 'Project impact accepted'
Assert-True ($deletePlan.blockers.Count -gt 0 -and $deletePlan.operations.Count -eq 0) 'A destructive WIT audit action cannot become a PATCH or DELETE write.'
$orderedSnapshots = Copy-AdoObject $baseline.snapshots
$orderedSnapshots[$sourceId].entities['wit:Bug'].definition.description = 'after'
$orderedState = @{ key = 'wit:Bug/State:Review'; category = 'State'; identity = '88888888-8888-8888-8888-888888888888'; parent = 'wit:Bug'; definition = @{ name = 'Review'; color = '009ccc'; stateCategory = 'InProgress'; order = 2; hidden = $false }; customization = 'custom'; witRef = 'System.Bug' }
$orderedSnapshots[$sourceId].entities[$orderedState.key] = $orderedState
$orderedAudit = Copy-AdoObject $emptyAudit
$orderedAudit.events = @(
    @{ id = 'bug-latest'; timestamp = $start.AddMinutes(10).ToString('o'); actionId = 'Process.WorkItemType.Update'; data = @{ ProcessId = $sourceId; WorkItemTypeReferenceName = 'System.Bug' } },
    @{ id = 'state-created'; timestamp = $start.AddMinutes(7).ToOffset([TimeSpan]::FromHours(2)).ToString('o'); actionId = 'Process.State.Create'; data = @{ ProcessId = $sourceId; WorkItemTypeReferenceName = 'System.Bug'; StateId = $orderedState.identity } },
    @{ id = 'bug-early'; timestamp = $start.AddMinutes(5).ToString('o'); actionId = 'Process.WorkItemType.Update'; data = @{ ProcessId = $sourceId; WorkItemTypeReferenceName = 'System.Bug' } }
)
$orderedPlan = New-AdoPlan $scope $baseline $orderedSnapshots $orderedAudit @{} 'Project impact accepted'
Assert-True ($orderedPlan.blockers.Count -eq 0 -and $orderedPlan.operations.Count -eq 2) 'Out-of-order audit pages produce an executable chronological plan.'
Assert-True ($orderedPlan.operations[0].category -eq 'State' -and $orderedPlan.operations[1].category -eq 'WorkItemType') 'Older state creation precedes a newer WIT update, regardless of entity rank or timezone offset.'
Assert-True ($orderedPlan.operations[1].evidence.Count -eq 2 -and $orderedPlan.operations[1].auditOrder -eq 2) 'A combined entity change is positioned at its latest contributing audit row.'
Assert-True (($orderedPlan.audit.events.id -join ',') -eq 'bug-early,state-created,bug-latest') 'The persisted audit sequence is oldest to newest.'
$tiedAudit = Copy-AdoObject $orderedAudit
$tiedAudit.events[1].timestamp = $tiedAudit.events[0].timestamp
$tiedAudit.selectedEventIds = @('bug-early', 'state-created', 'bug-latest')
$tiedPlan = New-AdoPlan $scope $baseline $orderedSnapshots $tiedAudit @{} 'Project impact accepted'
Assert-True ($tiedPlan.operations[0].category -eq 'State' -and $tiedPlan.operations[1].category -eq 'WorkItemType') 'Equal timestamps follow the displayed audit row order rather than API page order.'
$fractionalAudit = Copy-AdoObject $tiedAudit
$tieTicks = $start.AddMinutes(10).Ticks
$tieBase = [DateTimeOffset]::new(($tieTicks - ($tieTicks % [TimeSpan]::TicksPerMillisecond)), [TimeSpan]::Zero)
$fractionalAudit.events[0].timestamp = $tieBase.AddTicks(1).ToString('o')
$fractionalAudit.events[1].timestamp = $tieBase.AddTicks(9).ToString('o')
$fractionalPlan = New-AdoPlan $scope $baseline $orderedSnapshots $fractionalAudit @{} 'Project impact accepted'
Assert-True ($fractionalPlan.operations[0].category -eq 'State') 'Sub-millisecond timestamp differences retain the same tie order as the JavaScript audit table.'
$secondTargetId = '99999999-9999-9999-9999-999999999999'
$multiScope = @{ organization = 'test-org'; sourceProcessId = $sourceId; targetProcessIds = @($targetId, $secondTargetId) }
$multiSnapshots = Copy-AdoObject $orderedSnapshots
$multiSnapshots[$secondTargetId] = New-TestSnapshot $secondTargetId 'before'
$multiBaseline = Copy-AdoObject $baseline
$multiBaseline.snapshots[$secondTargetId] = Copy-AdoObject $multiSnapshots[$secondTargetId]
$multiPlan = New-AdoPlan $multiScope $multiBaseline $multiSnapshots $orderedAudit @{} 'Project impact accepted'
Assert-True ($multiPlan.blockers.Count -eq 0 -and $multiPlan.operations.Count -eq 4) 'Chronological planning includes every explicitly selected child.'
Assert-True (($multiPlan.operations.auditOrder -join ',') -eq '1,1,2,2') 'The older audit change is applied to all children before the newer change starts.'
$stagedSnapshots = Copy-AdoObject $baseline.snapshots
$stagedSnapshots[$sourceId].entities[$createdType.key] = Copy-AdoObject $createdType
$stagedSnapshots[$sourceId].entities['wit:Bug'].definition.description = 'after'
$stagedField = @{ key = "$($createdType.key)/Field:System.Title"; category = 'Field'; identity = 'System.Title'; parent = $createdType.key; definition = @{ referenceName = 'System.Title'; type = 'string'; required = $true; readOnly = $false }; customization = 'custom'; witRef = $createdType.identity }
$stagedSnapshots[$sourceId].entities[$stagedField.key] = $stagedField
$stagedAudit = Copy-AdoObject $emptyAudit
$stagedAudit.events = @(
    @{ id = 'parent-created'; timestamp = $start.AddMinutes(5).ToString('o'); actionId = 'Process.WorkItemType.Create'; data = @{ ProcessId = $sourceId; WorkItemTypeReferenceName = $createdType.identity } },
    @{ id = 'field-added'; timestamp = $start.AddMinutes(7).ToString('o'); actionId = 'Process.Field.Add'; data = @{ ProcessId = $sourceId; WorkItemTypeReferenceName = $createdType.identity; FieldReferenceName = 'System.Title' } },
    $orderedAudit.events[0]
)
$stagedPlan = New-AdoPlan $scope $baseline $stagedSnapshots $stagedAudit @{ 'System.Title' = @{ type = 'string' } } 'Project impact accepted'
Assert-True ($stagedPlan.blockers.Count -eq 0 -and $stagedPlan.operations.Count -eq 1 -and $stagedPlan.operations[0].key -eq $createdType.key) 'A dependency stage executes only the earlier parent creation.'
Assert-True ($stagedPlan.deferred.Count -eq 2 -and $stagedPlan.deferred[1].key -eq 'wit:Bug' -and $stagedPlan.deferred[1].reason -match 'cannot overtake') 'A later update waits behind an earlier row with an unresolved dependency.'
$conflictingStageAudit = Copy-AdoObject $stagedAudit
$conflictingStageAudit.events += @{ id = 'parent-updated'; timestamp = $start.AddMinutes(9).ToString('o'); actionId = 'Process.WorkItemType.Update'; data = @{ ProcessId = $sourceId; WorkItemTypeReferenceName = $createdType.identity } }
$conflictingStagePlan = New-AdoPlan $scope $baseline $stagedSnapshots $conflictingStageAudit @{ 'System.Title' = @{ type = 'string' } } 'Project impact accepted'
Assert-True ($conflictingStagePlan.operations.Count -eq 0 -and $conflictingStagePlan.blockers.Count -gt 0) 'A net-state dependency conflict blocks instead of silently reordering audit rows.'
$snapshots[$targetId].entities['wit:Bug'].definition.color = 'ffffff'
$preserved = New-AdoPlan $scope $baseline $snapshots $audit @{} 'Project impact accepted'
Assert-True ($preserved.operations.Count -eq 1 -and -not $preserved.operations[0].body.ContainsKey('color')) 'Unrelated target customization preserved.'
$snapshots[$targetId].entities['wit:Bug'].definition.description = 'child-only'
$conflict = New-AdoPlan $scope $baseline $snapshots $audit @{} 'Project impact accepted'
Assert-True ($conflict.blockers.Count -gt 0 -and $conflict.operations.Count -eq 0) 'Conflicting child edits block writes.'
$snapshots[$targetId].entities['wit:Bug'].definition.description = 'after'
$noop = New-AdoPlan $scope $baseline $snapshots $audit @{} 'Project impact accepted'
Assert-True ($noop.operations.Count -eq 0 -and $noop.noOps.Count -eq 1) 'Matching desired state is an idempotent no-op.'
$missingEvidence = New-AdoPlan $scope $baseline $snapshots $emptyAudit @{} 'Project impact accepted'
Assert-True ($missingEvidence.operations.Count -eq 0 -and $missingEvidence.blockers.Count -gt 0) 'Uncorroborated source changes block writes.'
$tableSnapshots = Copy-AdoObject $baseline.snapshots
$tableSnapshots[$sourceId].entities['wit:Bug'].definition.description = 'after'
$tableSnapshots[$sourceId].process.description = 'Unrelated process change'
$tableSnapshots[$sourceId].entities['wit:Unlisted'] = Copy-AdoObject $createdType
$tableAudit = Copy-AdoObject $audit
$tableAudit.selectedEventIds = @('change-1')
$tableAudit.events += @{ id = 'unlisted-row'; actionId = 'Process.Unsupported'; data = @{ ProcessId = $sourceId } }
$tablePlan = New-AdoPlan $scope $baseline $tableSnapshots $tableAudit @{} 'Project impact accepted'
Assert-True ($tablePlan.blockers.Count -eq 0 -and $tablePlan.operations.Count -eq 1 -and $tablePlan.changes.Count -eq 1 -and $tablePlan.changes[0].key -eq 'wit:Bug' -and $tablePlan.audit.events.Count -eq 1) 'Displayed-event plans ignore unlisted rows, unrelated source metadata, and unlisted entity differences.'
Import-Module (Join-Path $root 'scripts/process-sync/AdoProcessApp.psm1') -Force
$before = New-TestSnapshot $targetId 'before'
$after = New-TestSnapshot $targetId 'after'
$operation = $plan.operations[0]
Assert-True (Test-AdoPostcondition $operation $before $after) 'Postconditions verify expected field changes.'
$after.entities['wit:Bug'].definition.color = 'ffffff'
Assert-Blocked { Test-AdoPostcondition $operation $before $after } 'unexpected.*color'
$after = New-TestSnapshot $targetId 'after'
$after.entities['wit:Other'] = Copy-AdoObject $after.entities['wit:Bug']
Assert-Blocked { Test-AdoPostcondition $operation $before $after } 'extra target entity'
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('ado-app-tests-' + [guid]::NewGuid().ToString('N'))
try {
    Initialize-AdoStore $temporary
    $inheritedStore = Join-Path $temporary 'inherited-only'
    $null = New-Item -ItemType Directory -Path $inheritedStore
    $inheritedAcl = Get-Acl -LiteralPath $inheritedStore
    Assert-True ($inheritedAcl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]).Count -eq 0 -and $inheritedAcl.GetAccessRules($false, $true, [Security.Principal.SecurityIdentifier]).Count -gt 0) 'The regression folder starts with inherited access rules only.'
    Initialize-AdoStore $inheritedStore
    Initialize-AdoStore $inheritedStore
    $securedAcl = Get-Acl -LiteralPath $inheritedStore
    $securedRules = @($securedAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    $allowedSids = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18')
    Assert-True ($securedAcl.AreAccessRulesProtected -and $securedRules.Count -eq 2 -and @($securedRules | Where-Object { $_.IsInherited -or $_.IdentityReference.Value -notin $allowedSids -or $_.AccessControlType -ne 'Allow' -or $_.FileSystemRights -ne 'FullControl' -or $_.InheritanceFlags -ne 'ContainerInherit, ObjectInherit' }).Count -eq 0) 'Inherited-only stores initialize repeatedly with protected current-user and SYSTEM permissions.'
    $planPath = Join-Path $temporary 'plan.json'
    Write-AdoLocalJson $planPath $plan
    $bytes = [IO.File]::ReadAllBytes($planPath)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    $preview = @{ hash = $hash; runPath = $temporary; plan = $plan }
    $approved = Assert-AdoApprovedPlan $preview $hash
    Assert-True ($approved.operations.Count -eq 1) 'Exact approved file is parsed and accepted.'
    Assert-Blocked { Assert-AdoApprovedPlan $preview ('0' * 64) } 'exact plan'
    [IO.File]::AppendAllText($planPath, ' ')
    Assert-Blocked { Assert-AdoApprovedPlan $preview $hash } 'file changed'
    Assert-True ((Get-Content -LiteralPath $planPath -Raw) -notmatch 'offline-fake-pat') 'Plan artifacts never include the credential.'
}
finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force } }
$model = @{ events = @(); writes = 0; requests = [Collections.Generic.List[object]]::new(); descriptions = @{ $sourceId = 'initial'; $targetId = 'initial' }; rules = @{}; layouts = @{}; witRefs = @{}; extraWits = @(); failWrite = $false }
$modelTransport = {
    param($parameters)
    $model.requests.Add(@{ method = $parameters.Method; uri = $parameters.Uri })
    $uri = [Uri]$parameters.Uri
    $path = $uri.AbsolutePath -replace '^/test-org/_apis/', ''
    if ($path -eq 'audit/auditlog') {
        $query = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
        $events = @($model.events | Where-Object { [DateTimeOffset]::Parse($_.timestamp) -ge [DateTimeOffset]::Parse($query['startTime']) -and [DateTimeOffset]::Parse($_.timestamp) -le [DateTimeOffset]::Parse($query['endTime']) })
        return @{ decoratedAuditLogEntries = $events; hasMore = $false; continuationToken = $null }
    }
    if ($path -eq 'work/processes') {
        return @{ value = @($sourceId, $targetId | ForEach-Object { @{ typeId = $_; name = $_; customizationType = 'inherited'; parentProcessTypeId = '33333333-3333-3333-3333-333333333333' } }) }
    }
    if ($path -eq 'wit/fields') { return @{ value = @(@{ referenceName = 'System.Title'; type = 'string' }) } }
    if ($path -notmatch '^work/processes/([a-f0-9-]{36})(.*)$') { throw 'Unexpected fake API route.' }
    $processId = $Matches[1]; $suffix = $Matches[2]
    $witRef = if ($model.witRefs.ContainsKey($processId)) { $model.witRefs[$processId] } else { 'System.Bug' }
    $suffix = $suffix.Replace("/workItemTypes/$witRef", '/workItemTypes/System.Bug')
    if ($parameters.Method -ne 'GET') {
        $model.writes++
        if ($model.failWrite) { throw 'SENSITIVE simulated uncertain failure' }
        if ($suffix -ne '/workItemTypes/System.Bug' -or $parameters.Method -ne 'PATCH') { throw 'Unexpected fake write.' }
        $body = ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString($parameters.Body)) -AsHashtable -DateKind String
        $model.descriptions[$processId] = $body.description
        if ($model.failAfterWrite) { throw 'SENSITIVE simulated committed response loss' }
        return @{}
    }
    if ($processId -eq $targetId -and $suffix -eq '' -and $model.cancelCountdown -gt 0) {
        $model.cancelCountdown--
        if ($model.cancelCountdown -eq 0) { $model.cancelSession.cancel = $true }
    }
    switch ($suffix) {
        '' { return @{ typeId = $processId; name = $processId; customizationType = 'inherited'; parentProcessTypeId = '33333333-3333-3333-3333-333333333333' } }
        '/behaviors' { return @{ value = @() } }
        '/workItemTypes' { return @{ value = @(@{ name = 'Bug'; referenceName = $witRef; description = $model.descriptions[$processId]; color = '009ccc'; icon = 'icon_bug'; isDisabled = $false; inherits = $null; customization = 'inherited' }) + @($model.extraWits) } }
        '/workItemTypes/System.Bug' {
            $result = @{ name = 'Bug'; referenceName = $witRef; description = $model.descriptions[$processId]; color = '009ccc'; icon = 'icon_bug'; isDisabled = $false; inherits = $null; customization = 'inherited' }
            $query = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
            if ($query['$expand'] -eq 'layout') {
                $result.layout = if ($model.layouts.ContainsKey($processId)) { $model.layouts[$processId] } else { @{ pages = @(); extensions = @(); systemControls = @() } }
            }
            return $result
        }
        '/workItemTypes/System.Bug/fields' { return @{ value = @(@{ referenceName = 'System.Title'; type = 'string'; required = $true; readOnly = $false; customization = 'system' }) } }
        '/workItemTypes/System.Bug/states' { return @{ value = @(@{ name = 'New'; id = '55555555-5555-5555-5555-555555555555'; color = 'ffffff'; stateCategory = 'Proposed'; order = 1; hidden = $false; customizationType = 'system' }) } }
        '/workItemTypes/System.Bug/rules' { return @{ value = @($model.rules[$processId] | Where-Object { $null -ne $_ }) } }
        '/workitemtypesbehaviors/System.Bug/behaviors' { return @{ value = @() } }
        '/workItemTypes/System.Bug/layout' { throw 'HTTP 400: standalone layout route unavailable.' }
        default { throw "Unexpected fake GET $suffix" }
    }
}.GetNewClosure()
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('ado-app-flow-' + [guid]::NewGuid().ToString('N'))
try {
    Initialize-AdoStore $temporary
    $session = [hashtable]::Synchronized(@{ organization = 'test-org'; reader = $credential; writer = $null; storeRoot = $temporary; connected = $false; processes = @(); state = 'ready'; cancel = $false; expiresAt = [DateTimeOffset]::UtcNow.AddMinutes(30); error = $null; preview = $null; scope = $null; consumedHash = ''; result = $null; progress = ''; recoveryNeeded = $false })
    Invoke-AdoAppJob $session 'Connect' @{} $modelTransport
    Assert-True ($session.connected -and $session.processes.Count -eq 2) 'Real inventory path resolves processes without requiring source/target IDs.'
    $systemRules = @(
        @{ id = '66666666-6666-6666-6666-666666666666'; name = $null; customizationType = 'system'; conditions = @(); actions = @(); isDisabled = $false },
        @{ id = '77777777-7777-7777-7777-777777777777'; name = $null; customizationType = 'system'; conditions = @(); actions = @(); isDisabled = $false }
    )
    $model.rules[$sourceId] = $systemRules; $model.rules[$targetId] = $systemRules
    $ruleSnapshot = Get-AdoSnapshot -Organization 'test-org' -Credential $credential -ProcessId $sourceId -Transport $modelTransport
    Assert-True (@($ruleSnapshot.entities.Values | Where-Object { $_.category -eq 'Rule' }).Count -eq 2) 'Distinct unnamed system rules do not block a live WIT snapshot.'
    $model.rules[$sourceId] = @($systemRules[0], $systemRules[0])
    Assert-Blocked { Get-AdoSnapshot -Organization 'test-org' -Credential $credential -ProcessId $sourceId -Transport $modelTransport } 'Ambiguous or missing identity'
    $unnamedCustom = Copy-AdoObject $systemRules[0]; $unnamedCustom.customizationType = 'custom'
    $model.rules[$sourceId] = @($unnamedCustom)
    Assert-Blocked { Get-AdoSnapshot -Organization 'test-org' -Credential $credential -ProcessId $sourceId -Transport $modelTransport } 'Unnamed custom rules'
    $model.rules[$sourceId] = $systemRules
    $model.layouts[$sourceId] = @{ pages = @(
        @{ id = 'page-one'; label = 'Details'; inherited = $true; sections = @() },
        @{ id = 'page-two'; label = 'Details'; inherited = $true; sections = @() }
    ); extensions = @(); systemControls = @() }
    $layoutTrace = [IO.StringWriter]::new()
    $priorOutput = [Console]::Out
    try {
        [Console]::SetOut($layoutTrace)
        Assert-Blocked { Get-AdoSnapshot -Organization 'test-org' -Credential $credential -ProcessId $sourceId -Transport $modelTransport } 'Page.*wit:Bug/Page:Details.*Multiple entities'
    }
    finally { [Console]::SetOut($priorOutput) }
    $rejection = @($layoutTrace.ToString() -split '\r?\n' | Where-Object { $_ -match 'snapshot.entity.rejected' })
    $layoutTrace.Dispose()
    Assert-True ($rejection.Count -eq 1 -and $rejection[0] -match '"category":"Page"' -and $rejection[0] -match 'wit:Bug/Page:Details' -and $rejection[0] -match 'page-two') 'Layout collisions report the exact category, snapshot key, and API route before stopping.'
    $model.layouts[$sourceId].pages = @(@{ label = 'Details'; inherited = $true; sections = @() })
    Assert-Blocked { Get-AdoSnapshot -Organization 'test-org' -Credential $credential -ProcessId $sourceId -Transport $modelTransport } 'Page.*Entity has no API identity'
    $model.layouts[$sourceId] = @{ pages = @(
        @{ id = 'links'; label = 'Links'; pageType = 'links'; inherited = $true; sections = @(
            @{ id = 'Section1'; groups = @(
                @{ id = 'Agile.Feature.System_Links.Links'; label = 'Links'; inherited = $true; controls = @(
                    @{ id = $null; controlType = 'LinksControl'; visible = $true },
                    @{ controlType = 'LinksControl'; visible = $false }
                ) }
            ) }
        ) }
    ); extensions = @(); systemControls = @() }
    $linksSnapshot = Get-AdoSnapshot -Organization 'test-org' -Credential $credential -ProcessId $sourceId -Transport $modelTransport
    $opaqueControls = @($linksSnapshot.entities.Values | Where-Object { $_.key -match '/SystemControl:' } | Sort-Object key)
    Assert-True ($opaqueControls.Count -eq 2 -and $opaqueControls[0].identity -ne $opaqueControls[1].identity) 'Multiple ID-less built-in Links controls have distinct snapshot-only identities.'
    Assert-True ($opaqueControls[0].customization -eq 'system' -and -not $opaqueControls[0].path -and -not $opaqueControls[0].createPath -and $opaqueControls[0].definition.control.controlType -eq 'LinksControl') 'Built-in controls retain metadata without exposing a REST write route.'
    $linksRepeat = Get-AdoSnapshot -Organization 'test-org' -Credential $credential -ProcessId $sourceId -Transport $modelTransport
    Assert-True ((Get-AdoSnapshotHash $linksSnapshot) -eq (Get-AdoSnapshotHash $linksRepeat)) 'ID-less built-in control snapshot identities are stable across reads.'
    $model.layouts[$sourceId].pages[0].sections[0].groups[0].controls[0].visible = $false
    $linksChanged = Get-AdoSnapshot -Organization 'test-org' -Credential $credential -ProcessId $sourceId -Transport $modelTransport
    Assert-True ((Get-AdoSnapshotHash $linksSnapshot) -ne (Get-AdoSnapshotHash $linksChanged)) 'Changes to opaque built-in controls remain visible to drift detection.'
    Assert-Blocked { New-AdoOperation @{ key = $opaqueControls[0].key; before = $null; after = $opaqueControls[0] } @{ process = $linksSnapshot.process; entities = @{ $opaqueControls[0].parent = $linksSnapshot.entities[$opaqueControls[0].parent] } } @{} } 'System-owned definitions are read-only'
    $model.layouts[$sourceId].pages[0].pageType = 'custom'
    Assert-Blocked { Get-AdoSnapshot -Organization 'test-org' -Credential $credential -ProcessId $sourceId -Transport $modelTransport } 'Control.*Entity has no API identity'
    $model.layouts[$sourceId].pages[0].pageType = 'history'
    $historySnapshot = Get-AdoSnapshot -Organization 'test-org' -Credential $credential -ProcessId $sourceId -Transport $modelTransport
    Assert-True (@($historySnapshot.entities.Values | Where-Object { $_.key -match '/SystemControl:' }).Count -eq 2) 'ID-less built-in History controls are also retained read-only.'
    $model.layouts[$sourceId].pages[0].pageType = 'custom'
    foreach ($control in $model.layouts[$sourceId].pages[0].sections[0].groups[0].controls) { $control.inherited = $true }
    $inheritedControlSnapshot = Get-AdoSnapshot -Organization 'test-org' -Credential $credential -ProcessId $sourceId -Transport $modelTransport
    Assert-True (@($inheritedControlSnapshot.entities.Values | Where-Object { $_.key -match '/SystemControl:' }).Count -eq 2) 'Explicitly inherited ID-less controls on other pages remain read-only.'
    $selectedPageEvent = @(@{ actionId = 'Process.Page.Add'; data = @{ WorkItemTypeReferenceName = 'System.Bug'; PageId = 'links' } })
    $model.layouts[$sourceId].pages[0].sections[0].groups[0].controls[0].inherited = $false
    $pageOnlySnapshot = Get-AdoSnapshot -Organization 'test-org' -Credential $credential -ProcessId $sourceId -Transport $modelTransport -AuditEvents $selectedPageEvent
    Assert-True ($pageOnlySnapshot.entities.ContainsKey('wit:Bug/Page:Links') -and @($pageOnlySnapshot.entities.Values | Where-Object { $_.category -in @('Group', 'Control', 'Field', 'State', 'Rule') }).Count -eq 0) 'A displayed page event does not inventory its unlisted groups, ID-less controls, or unrelated categories.'
    $model.witRefs[$targetId] = 'Microsoft.VSTS.WorkItemTypes.Bug'
    $model.layouts[$targetId] = @{ pages = @(@{ id = 'child-links'; label = 'Links'; pageType = 'links'; inherited = $true; sections = @() }); extensions = @(); systemControls = @() }
    $childPageSnapshot = Get-AdoSnapshot -Organization 'test-org' -Credential $credential -ProcessId $targetId -Transport $modelTransport -AuditEvents $selectedPageEvent -SourceSnapshot $pageOnlySnapshot
    Assert-True ($childPageSnapshot.entities['wit:Bug/Page:Links'].identity -eq 'child-links' -and $childPageSnapshot.entities['wit:Bug'].identity -eq 'Microsoft.VSTS.WorkItemTypes.Bug') 'Expanded layout reads preserve the API-returned system WIT reference and child-local page identity.'
    $expandedRead = @($model.requests | Where-Object { $_.uri -match "/$targetId/workItemTypes/Microsoft.VSTS.WorkItemTypes.Bug\?" -and [System.Web.HttpUtility]::ParseQueryString(([Uri]$_.uri).Query)['$expand'] -eq 'layout' })
    Assert-True ($expandedRead.Count -eq 1 -and @($model.requests | Where-Object { $_.uri -match '/layout\?' }).Count -eq 0) 'Layout inventory uses the documented WIT expand query without calling the failing standalone layout endpoint.'
    $model.layouts[$targetId] = $null
    Assert-Blocked { Get-AdoSnapshot -Organization 'test-org' -Credential $credential -ProcessId $targetId -Transport $modelTransport -AuditEvents $selectedPageEvent -SourceSnapshot $pageOnlySnapshot } 'Incomplete work item form layout'
    $model.layouts.Remove($targetId)
    $model.witRefs.Clear()
    $model.layouts.Remove($sourceId)
    $namedRule = @{ id = 'source-rule'; name = 'Selected rule'; customizationType = 'custom'; conditions = @(); actions = @(); isDisabled = $false }
    $childRule = Copy-AdoObject $namedRule; $childRule.id = 'child-rule'
    $model.rules[$sourceId] = @($namedRule, $unnamedCustom)
    $model.rules[$targetId] = @($childRule, $unnamedCustom)
    $model.witRefs[$sourceId] = 'Universal.Bug'; $model.witRefs[$targetId] = 'Child.Bug'
    $selectedRuleEvents = @(@{ actionId = 'Process.Rule.Update'; data = @{ WorkItemTypeReferenceName = 'Universal.Bug'; RuleId = 'source-rule' } })
    $selectedRuleSet = Get-AdoLiveSet $scope $credential $modelTransport $selectedRuleEvents
    Assert-True ($selectedRuleSet[$sourceId].entities.Count -eq 2 -and $selectedRuleSet[$targetId].entities.Count -eq 2) 'Selected rule reads exclude malformed unlisted rules in both processes.'
    Assert-True ($selectedRuleSet[$targetId].entities['wit:Bug'].identity -eq 'Child.Bug' -and $selectedRuleSet[$targetId].entities['wit:Bug/Rule:Selected%20rule'].identity -eq 'child-rule') 'Event-scoped reads translate source WIT and rule IDs to child-local references by their established names.'
    $tailEnd = [DateTimeOffset]::UtcNow.AddMinutes(-2).ToString('o')
    $tailModel = @{ events = @(@{ id = 'unlisted-newer-rule'; timestamp = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o'); actionId = 'Process.Rule.Update'; data = @{ ProcessId = $sourceId; WorkItemTypeReferenceName = 'Universal.Bug'; RuleId = 'unrelated-rule' } }) }
    $tailTransport = { param($parameters) @{ decoratedAuditLogEntries = $tailModel.events; hasMore = $false } }.GetNewClosure()
    Assert-AdoTail $scope $credential $tailEnd $tailTransport $selectedRuleEvents $selectedRuleSet[$sourceId]
    $script:checks++
    $tailModel.events[0].data.RuleId = 'source-rule'
    Assert-Blocked { Assert-AdoTail $scope $credential $tailEnd $tailTransport $selectedRuleEvents $selectedRuleSet[$sourceId] } 'Potential source changes'
    $model.rules[$sourceId] = $systemRules; $model.rules[$targetId] = $systemRules
    $model.witRefs.Clear()
    $inputData = @{ sourceProcessId = $sourceId; targetProcessIds = @($targetId); startTime = [DateTimeOffset]::UtcNow.AddHours(-2).ToString('o'); endTime = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o') }
    $requestStart = $model.requests.Count
    Invoke-AdoAppJob $session 'ReadAudit' @{ sourceProcessId = $sourceId; startTime = $inputData.startTime; endTime = $inputData.endTime } $modelTransport
    Assert-True ($session.state -eq 'ready' -and $session.rawAudit.Count -eq 1 -and $session.auditRead.sourceProcessId -eq $sourceId) "Audit-only read succeeds without selected children: $($session.error)"
    Assert-True ($model.requests.Count -eq $requestStart + 1 -and $model.requests[$requestStart].uri -match '/audit/auditlog\?' -and $model.requests[$requestStart].method -eq 'GET') 'Read Audit makes only an audit GET, with no process comparison.'
    Assert-True ($null -eq $session.preview -and $model.writes -eq 0) 'Reading audit cannot prepare or apply process changes.'
    Invoke-AdoAppJob $session 'Preview' $inputData $modelTransport
    Assert-True ($session.state -eq 'ready' -and $session.preview.plan.mode -eq 'adopt' -and $model.writes -eq 0) "Live-shaped preview adopts without writes: $($session.error)"
    Invoke-AdoAppJob $session 'Apply' @{ hash = $session.preview.hash; confirmed = $true; mappingsConfirmed = $true } $modelTransport
    Assert-True ($session.result.status -eq 'adopted' -and $model.writes -eq 0) "Approved baseline adoption never writes ADO: $($session.error)"
    $model.descriptions[$sourceId] = 'updated description'
    $eventTime = [DateTimeOffset]::UtcNow
    $model.events = @(@{ id = 'source-edit'; timestamp = $eventTime.ToString('o'); actionId = 'Process.WorkItemType.Update'; correlationId = 'correlation'; data = @{ ProcessId = $sourceId; WorkItemTypeReferenceName = 'System.Bug' } })
    $inputData.endTime = [DateTimeOffset]::UtcNow.ToString('o')
    Invoke-AdoAppJob $session 'ReadAudit' @{ sourceProcessId = $sourceId; startTime = $inputData.startTime; endTime = $inputData.endTime } $modelTransport
    $cachedRawPages = $session.rawAudit
    $cachedRequestStart = $model.requests.Count
    $inputData.auditEventIds = @('missing-displayed-event')
    Invoke-AdoAppJob $session 'Preview' $inputData $modelTransport
    Assert-True ($session.state -eq 'error' -and $null -eq $session.preview -and $model.writes -eq 0 -and $session.error -match 'no longer available') 'A stale displayed audit ID cannot produce an executable plan.'
    $inputData.auditEventIds = @('source-edit')
    $model.extraWits = @(@{ name = 'Unrelated'; referenceName = 'Universal.Unrelated' })
    $model.layouts[$sourceId] = @{ pages = @(@{ label = 'Invalid unrelated page' }); extensions = @(); systemControls = @() }
    $modalRequestStart = $model.requests.Count
    Invoke-AdoAppJob $session 'Preview' $inputData $modelTransport
    Assert-True ($session.preview.plan.operations.Count -eq 1 -and $session.preview.plan.blockers.Count -eq 0) "Subsequent API-shaped audit generates a supported operation: $($session.error)"
    Assert-True ($session.preview.plan.audit.events.Count -eq 1 -and $session.preview.plan.audit.selectedEventIds[0] -eq 'source-edit') 'Only displayed event IDs are included in the executable modal plan.'
    $modalReads = @($model.requests | Select-Object -Skip $modalRequestStart)
    Assert-True (@($modalReads | Where-Object { $_.uri -match '/(layout|fields|rules|states|behaviors)(/|\?)|Universal\.Unrelated' }).Count -eq 0) 'A displayed WIT update does not inventory layouts, fields, rules, states, behaviors, or unlisted WIT definitions.'
    Assert-True ($session.preview.snapshots[$sourceId].entities.Count -eq 1 -and $session.preview.snapshots[$targetId].entities.Count -eq 1) 'Modal WIT snapshots contain only the WIT addressed by the displayed row.'
    $syncAuditRequests = @($model.requests | Select-Object -Skip $cachedRequestStart | Where-Object { $_.uri -match '/audit/auditlog\?' })
    Assert-True ($syncAuditRequests.Count -eq 1 -and $syncAuditRequests[0].uri -notmatch [regex]::Escape([Uri]::EscapeDataString($inputData.startTime))) 'Modal sync does not re-read the loaded audit window; only the separate newer-change check queries audit.'
    Assert-True ([object]::ReferenceEquals($cachedRawPages, $session.rawAudit) -and -not $session.auditCache.audit.ContainsKey('selectedEventIds')) 'Modal planning preserves the original raw pages and does not mutate cached audit evidence.'
    $savedAuditCache = $session.auditCache
    $guardRequestStart = $model.requests.Count
    $session.auditCache = $null
    Invoke-AdoAppJob $session 'Preview' $inputData $modelTransport
    Assert-True ($session.state -eq 'error' -and $null -eq $session.preview -and $model.requests.Count -eq $guardRequestStart -and $session.error -match 'audit cache') 'A missing modal cache stops without any API request or automatic audit refetch.'
    $session.auditCache = $savedAuditCache
    $mismatchedWindow = Copy-AdoObject $inputData
    $mismatchedWindow.startTime = [DateTimeOffset]::Parse($inputData.startTime).AddMinutes(1).ToString('o')
    Invoke-AdoAppJob $session 'Preview' $mismatchedWindow $modelTransport
    Assert-True ($session.state -eq 'error' -and $null -eq $session.preview -and $model.requests.Count -eq $guardRequestStart) 'Changing the audit window does not silently fetch replacement events.'
    $mismatchedSource = Copy-AdoObject $inputData
    $mismatchedSource.sourceProcessId = $targetId; $mismatchedSource.targetProcessIds = @($sourceId)
    Invoke-AdoAppJob $session 'Preview' $mismatchedSource $modelTransport
    Assert-True ($session.state -eq 'error' -and $null -eq $session.preview -and $model.requests.Count -eq $guardRequestStart) 'Cached Universal events cannot be reused for a different source process.'
    $session.auditCache = Copy-AdoObject $savedAuditCache
    $session.auditCache.audit.complete = $false
    Invoke-AdoAppJob $session 'Preview' $inputData $modelTransport
    Assert-True ($session.state -eq 'error' -and $model.requests.Count -eq $guardRequestStart) 'Incomplete cached audit evidence cannot trigger a replacement read.'
    $session.auditCache = $savedAuditCache
    Invoke-AdoAppJob $session 'Preview' $inputData $modelTransport
    Assert-True ($session.state -eq 'ready' -and $session.preview.plan.operations.Count -eq 1) 'The original completed audit cache remains usable after rejected requests.'
    $scopedBaselinePath = $session.preview.baselinePath
    $unrelatedBaselineRule = Get-AdoHash $session.preview.baseline.snapshots[$sourceId].entities['wit:Bug/Rule:system:66666666-6666-6666-6666-666666666666']
    $inputData.Remove('auditEventIds')
    $session.writer = $credential
    $scopedApplyStart = $model.requests.Count
    Invoke-AdoAppJob $session 'Apply' @{ hash = $session.preview.hash; confirmed = $true; mappingsConfirmed = $true } $modelTransport
    Assert-True ($session.result.status -eq 'verified' -and $model.writes -eq 1 -and $model.descriptions[$targetId] -eq 'updated description') "Approved operation is applied, read back and checkpointed: $($session.error)"
    Assert-True (@($model.requests | Select-Object -Skip $scopedApplyStart | Where-Object { $_.uri -match '/(layout|fields|rules|states|behaviors)(/|\?)|Universal\.Unrelated' }).Count -eq 0) 'Applying and verifying a WIT row retain its event-only read scope.'
    $savedScopedBaseline = Read-AdoLocalJson $scopedBaselinePath
    Assert-True ((Get-AdoHash $savedScopedBaseline.snapshots[$sourceId].entities['wit:Bug/Rule:system:66666666-6666-6666-6666-666666666666']) -eq $unrelatedBaselineRule) 'Advancing an event-scoped baseline preserves unrelated prior entity records.'
    $model.extraWits = @()
    $model.layouts.Remove($sourceId)
    $actualWrite = @($model.requests | Where-Object { $_.method -eq 'PATCH' })[0]
    Assert-True ($actualWrite.uri -eq "https://dev.azure.com/test-org/_apis/work/processes/$targetId/workItemTypes/System.Bug?api-version=7.1") 'Approved WIT update executes against the documented child PATCH endpoint with API version 7.1.'
    Assert-True ($null -eq $session.writer) 'Writer credential is released after every job.'
    $inputData.endTime = [DateTimeOffset]::UtcNow.ToString('o')
    Invoke-AdoAppJob $session 'Preview' $inputData $modelTransport
    Assert-True ($session.preview.plan.operations.Count -eq 0 -and $session.preview.plan.blockers.Count -eq 0) 'Verified repeat scan is idempotent.'
    $priorBaselinePath = $session.preview.baselinePath
    $priorBaseline = [IO.File]::ReadAllText($priorBaselinePath)
    $model.descriptions[$sourceId] = 'second source edit'
    $model.events += @{ id = 'source-edit-2'; timestamp = [DateTimeOffset]::UtcNow.ToString('o'); actionId = 'Process.WorkItemType.Update'; correlationId = 'correlation-2'; data = @{ ProcessId = $sourceId; WorkItemTypeReferenceName = 'System.Bug' } }
    $inputData.endTime = [DateTimeOffset]::UtcNow.ToString('o')
    Invoke-AdoAppJob $session 'Preview' $inputData $modelTransport
    Assert-True ($session.preview.plan.operations.Count -eq 1) 'Second source change is previewed.'
    $model.failWrite = $true
    $session.writer = $credential
    Invoke-AdoAppJob $session 'Apply' @{ hash = $session.preview.hash; confirmed = $true; mappingsConfirmed = $true } $modelTransport
    Assert-True ($session.state -eq 'error' -and $session.result.status -eq 'stopped' -and $model.writes -eq 2) 'Uncertain write stops immediately without retry.'
    Assert-True ($priorBaseline -ceq [IO.File]::ReadAllText($priorBaselinePath)) 'Partial failure never advances the baseline.'
    $model.failWrite = $false
    Invoke-AdoAppJob $session 'Preview' $inputData $modelTransport
    Assert-True ($session.recoveryNeeded -and $session.preview.plan.operations.Count -eq 0) 'Pending uncertain journal blocks a new executable plan.'
    Invoke-AdoAppJob $session 'Reconcile' @{} $modelTransport
    Assert-True ($session.result.status -eq 'reconciled' -and $session.result.entries[0].status -eq 'reconciled-not-committed' -and $model.writes -eq 2) 'Reconciliation reads live state without repeating the mutation.'
    Invoke-AdoAppJob $session 'Preview' $inputData $modelTransport
    $model.cancelSession = $session
    $model.cancelCountdown = 2
    $session.writer = $credential
    Invoke-AdoAppJob $session 'Apply' @{ hash = $session.preview.hash; confirmed = $true; mappingsConfirmed = $true } $modelTransport
    Assert-True ($session.result.status -eq 'stopped' -and $model.writes -eq 2) 'Cancellation during preconditions prevents the next write.'
    $session.cancel = $false
    Invoke-AdoAppJob $session 'Preview' $inputData $modelTransport
    $model.failAfterWrite = $true
    $session.writer = $credential
    Invoke-AdoAppJob $session 'Apply' @{ hash = $session.preview.hash; confirmed = $true; mappingsConfirmed = $true } $modelTransport
    Assert-True ($session.result.status -eq 'stopped' -and $model.writes -eq 3 -and $model.descriptions[$targetId] -eq 'second source edit') 'Lost response is uncertain even when the target committed.'
    Assert-True ($priorBaseline -ceq [IO.File]::ReadAllText($priorBaselinePath)) 'Uncertain committed write preserves the prior baseline.'
    $model.failAfterWrite = $false
    Invoke-AdoAppJob $session 'Reconcile' @{} $modelTransport
    Assert-True ($session.result.entries[0].status -eq 'reconciled-committed' -and $model.writes -eq 3) 'Read-only reconciliation recognizes a committed write without retry.'
    Invoke-AdoAppJob $session 'Preview' $inputData $modelTransport
    Assert-True ($session.preview.plan.operations.Count -eq 0 -and $session.preview.plan.blockers.Count -eq 0) 'Reconciled committed operation is a no-op on the fresh plan.'
    Invoke-AdoAppJob $session 'Apply' @{ hash = $session.preview.hash; confirmed = $true; mappingsConfirmed = $true } $modelTransport
    Assert-True ($session.result.status -eq 'verified' -and $model.writes -eq 3) 'A fresh zero-write approval advances the reconciled baseline.'
    $model.descriptions[$sourceId] = 'scoped recovery edit'
    $model.events += @{ id = 'scoped-recovery'; timestamp = [DateTimeOffset]::UtcNow.ToString('o'); actionId = 'Process.WorkItemType.Update'; data = @{ ProcessId = $sourceId; WorkItemTypeReferenceName = 'System.Bug' } }
    $inputData.endTime = [DateTimeOffset]::UtcNow.ToString('o')
    Invoke-AdoAppJob $session 'ReadAudit' @{ sourceProcessId = $sourceId; startTime = $inputData.startTime; endTime = $inputData.endTime } $modelTransport
    $inputData.auditEventIds = @('scoped-recovery')
    Invoke-AdoAppJob $session 'Preview' $inputData $modelTransport
    $model.failWrite = $true; $session.writer = $credential
    Invoke-AdoAppJob $session 'Apply' @{ hash = $session.preview.hash; confirmed = $true; mappingsConfirmed = $true } $modelTransport
    Assert-True ($session.result.status -eq 'stopped' -and $model.writes -eq 4) 'An event-scoped uncertain write stops without retrying.'
    $model.failWrite = $false
    $model.extraWits = @(@{ name = 'Unrelated'; referenceName = 'Universal.Unrelated' })
    $recoveryRequestStart = $model.requests.Count
    Invoke-AdoAppJob $session 'Reconcile' @{} $modelTransport
    Assert-True ($session.result.status -eq 'reconciled' -and $session.result.entries[0].status -eq 'reconciled-not-committed' -and $model.writes -eq 4) 'Recovery uses the journaled event scope and never repeats the uncertain write.'
    Assert-True (@($model.requests | Select-Object -Skip $recoveryRequestStart | Where-Object { $_.uri -match '/(layout|fields|rules|states|behaviors)(/|\?)|Universal\.Unrelated' }).Count -eq 0) 'Recovery does not expand an event-scoped journal into full process inventory.'
    $model.extraWits = @()
    $artifacts = Get-ChildItem -LiteralPath $temporary -Recurse -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }
    Assert-True (($artifacts -join '') -notmatch 'offline-fake-pat|SENSITIVE') 'Full run artifacts exclude credentials and raw failures.'
    $session.expiresAt = [DateTimeOffset]::UtcNow.AddMinutes(-1)
    $inputData.auditEventIds = @('source-edit')
    $expiredRequestStart = $model.requests.Count
    Invoke-AdoAppJob $session 'Preview' $inputData $modelTransport
    Assert-True ($session.state -eq 'error' -and $model.requests.Count -eq $expiredRequestStart -and $null -eq $session.auditCache -and $null -eq $session.rawAudit) 'Expiry clears cached evidence and prevents any modal sync API request.'
}
finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force } }

$adapterTarget = New-TestSnapshot $targetId 'initial'
$globalFields = @{ 'Custom.Text' = @{ type = 'string' }; 'System.Title' = @{ type = 'string' } }
function New-TestEntity {
    param([string]$Key, [string]$Category, [string]$Parent, [hashtable]$Definition)
    @{ key = $Key; category = $Category; parent = $Parent; definition = $Definition; identity = 'source-local-id'; customization = 'custom'; witRef = 'System.Bug' }
}
$field = New-TestEntity 'wit:Bug/Field:Custom.Text' 'Field' 'wit:Bug' @{ referenceName = 'Custom.Text'; type = 'string'; required = $true; readOnly = $false }
$fieldOperation = New-AdoOperation @{ key = $field.key; before = $null; after = $field } $adapterTarget $globalFields
Assert-True ($fieldOperation.method -eq 'POST' -and $fieldOperation.body.referenceName -eq 'Custom.Text' -and -not $fieldOperation.body.ContainsKey('type')) 'Field attachment uses documented local schema, not a global field write.'
$globalFields['Custom.Text'].isPicklist = $true
$field.definition.allowedValues = @('One', 'Two')
Assert-Blocked { New-AdoOperation @{ key = $field.key; before = $null; after = $field } $adapterTarget $globalFields } 'Shared picklist'
$globalFields['Custom.Text'].isPicklist = $false
$stateEntity = New-TestEntity 'wit:Bug/State:Review' 'State' 'wit:Bug' @{ name = 'Review'; color = '009ccc'; stateCategory = 'InProgress'; order = 2; hidden = $false }
$stateOperation = New-AdoOperation @{ key = $stateEntity.key; before = $null; after = $stateEntity } $adapterTarget $globalFields
Assert-True ($stateOperation.body.name -eq 'Review' -and -not $stateOperation.body.ContainsKey('id') -and -not $stateOperation.body.ContainsKey('hidden')) 'State creation excludes generated and read-only identifiers.'
$behavior = New-TestEntity 'behavior:Portfolio' 'Behavior' '' @{ name = 'Portfolio'; color = '009ccc'; inherits = 'System.PortfolioBacklogBehavior'; rank = 50; fields = @('Microsoft.VSTS.Common.StackRank') }
$behaviorOperation = New-AdoOperation @{ key = $behavior.key; before = $null; after = $behavior } $adapterTarget $globalFields
Assert-True ($behaviorOperation.path -eq "work/processes/$targetId/behaviors" -and $behaviorOperation.body.Count -eq 3) 'Behavior creation uses name, color and system parent only.'
$adapterTarget.entities[$behavior.key] = Copy-AdoObject $behavior
$adapterTarget.entities[$behavior.key].identity = 'Custom.target-local-behavior'
$association = New-TestEntity 'wit:Bug/Association:Portfolio' 'Association' 'wit:Bug' @{ behaviorName = 'Portfolio'; isDefault = $false; isLegacyDefault = $false }
$associationOperation = New-AdoOperation @{ key = $association.key; before = $null; after = $association } $adapterTarget $globalFields
Assert-True ($associationOperation.path -eq "work/processes/$targetId/workitemtypesbehaviors/System.Bug/behaviors" -and $associationOperation.body.behavior.id -eq 'Custom.target-local-behavior') 'Association uses the documented route and the target-local behavior ID.'
$page = New-TestEntity 'wit:Bug/Page:Custom' 'Page' 'wit:Bug' @{ label = 'Custom'; visible = $true; pageType = 'custom'; order = 1 }
$pageOperation = New-AdoOperation @{ key = $page.key; before = $null; after = $page } $adapterTarget $globalFields
Assert-True ($pageOperation.body.sections.Count -eq 4 -and -not $pageOperation.body.ContainsKey('id')) 'Page creation uses new local layout identifiers.'
$section = New-TestEntity 'wit:Bug/Page:Custom/Section:Section1' 'Section' $page.key @{ id = 'Section1' }
$section.path = "work/processes/$targetId/workItemTypes/System.Bug/layout/pages/target-page/sections/Section1"
$adapterTarget.entities[$section.key] = $section
$group = New-TestEntity "$($section.key)/Group:Details" 'Group' $section.key @{ label = 'Details'; visible = $true; order = 0 }
$groupOperation = New-AdoOperation @{ key = $group.key; before = $null; after = $group } $adapterTarget $globalFields
Assert-True ($groupOperation.path -match '/target-page/sections/Section1/groups$' -and -not $groupOperation.body.ContainsKey('id')) 'Group creation uses target page and section mappings.'
$group.path = "work/processes/$targetId/workItemTypes/System.Bug/layout/groups/target-group"
$adapterTarget.entities[$group.key] = $group
$adapterTarget.entities['wit:Bug/Field:System.Title'] = New-TestEntity 'wit:Bug/Field:System.Title' 'Field' 'wit:Bug' @{ referenceName = 'System.Title'; type = 'string' }
$control = New-TestEntity "$($group.key)/Control:System.Title" 'Control' $group.key @{ fieldId = 'System.Title'; label = 'Title'; visible = $true; order = 0; readOnly = $false }
$controlOperation = New-AdoOperation @{ key = $control.key; before = $null; after = $control } $adapterTarget $globalFields
Assert-True ($controlOperation.path -match '/target-group/controls$' -and $controlOperation.body.id -eq 'System.Title') 'Field controls reuse stable field IDs and target-local groups.'
$rule = New-TestEntity 'wit:Bug/Rule:RequiredTitle' 'Rule' 'wit:Bug' @{ name = 'RequiredTitle'; conditions = @(@{ conditionType = '$whenChanged'; field = 'System.Title'; value = '' }); actions = @(@{ actionType = '$makeRequired'; targetField = 'System.Title'; value = '' }); isDisabled = $false }
$ruleOperation = New-AdoOperation @{ key = $rule.key; before = $null; after = $rule } $adapterTarget $globalFields
Assert-True ($ruleOperation.body.actions[0].actionType -eq '$makeRequired' -and $ruleOperation.path -match '/System.Bug/rules$') 'Rule creation checks its existing field dependencies.'
$rule.definition.actions[0].actionType = '$hideTargetField'
Assert-Blocked { New-AdoOperation @{ key = $rule.key; before = $null; after = $rule } $adapterTarget $globalFields } 'destructive rule'
Assert-Blocked { New-AdoOperation @{ key = $field.key; before = $field; after = $null } $adapterTarget $globalFields } 'Deletion'
foreach ($file in Get-ChildItem (Join-Path $root 'scripts') -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') }) {
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "PowerShell parses: $($file.Name)"
}
Write-Output "Passed $checks app assertions. No network requests or real credentials used."