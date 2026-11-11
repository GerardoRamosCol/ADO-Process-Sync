#requires -Version 7.5
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AdoProcessApi.psm1')
Import-Module (Join-Path $PSScriptRoot 'AdoProcessSync.psm1')

function Initialize-AdoStore {
    param([string]$Path)
    if (-not $IsWindows) { throw 'This local application requires Windows and PowerShell 7.' }
    $ancestor = [IO.Path]::GetFullPath($Path)
    while ($ancestor) {
        if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Local store paths cannot contain reparse points.' }
        $ancestor = Split-Path -Parent $ancestor
    }
    $null = New-Item -ItemType Directory -Path $Path -Force
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in $acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier])) { $null = $acl.RemoveAccessRuleSpecific($rule) }
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
    }
    [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($Path), $acl)
}

function Write-AdoLocalJson {
    param([string]$Path, [object]$Value)
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $json = ConvertTo-Json -InputObject $Value -Depth 100
    try { [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false)); [IO.File]::Move($temporary, $Path, $true) }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}

function Read-AdoLocalJson {
    param([string]$Path)
    if ((Get-Item -LiteralPath $Path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Local artifact cannot be a reparse point.' }
    return ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path)) -AsHashtable -DateKind String
}

function Get-AdoScopeKey {
    param([hashtable]$Scope)
    return Get-AdoHash @{ organization = $Scope.organization; source = $Scope.sourceProcessId; targets = @($Scope.targetProcessIds | Sort-Object) }
}

function Get-AdoLiveSet {
    param([hashtable]$Scope, [PSCredential]$Credential, [scriptblock]$Transport, [AllowNull()][array]$AuditEvents)
    $snapshots = @{}
    foreach ($processId in (@($Scope.sourceProcessId) + @($Scope.targetProcessIds))) {
        $snapshots[$processId] = Get-AdoSnapshot -Organization $Scope.organization -Credential $Credential -ProcessId $processId -Transport $Transport -AuditEvents $AuditEvents -SourceSnapshot $snapshots[$Scope.sourceProcessId]
    }
    Assert-AdoScope $Scope @($snapshots.Values | ForEach-Object { $_.process })
    $repeat = Get-AdoSnapshot -Organization $Scope.organization -Credential $Credential -ProcessId $Scope.sourceProcessId -Transport $Transport -AuditEvents $AuditEvents
    if ((Get-AdoSnapshotHash $repeat) -ne (Get-AdoSnapshotHash $snapshots[$Scope.sourceProcessId])) { throw 'Source changed during inventory. Wait for stability and scan again.' }
    return $snapshots
}

function Assert-AdoTail {
    param([hashtable]$Scope, [PSCredential]$Credential, [string]$EndTime, [scriptblock]$Transport,
        [AllowNull()][array]$AuditEvents, [hashtable]$SourceSnapshot)
    $now = [DateTimeOffset]::UtcNow
    if ([DateTimeOffset]::Parse($EndTime) -ge $now) { return }
    $tail = Get-AdoAudit -Organization $Scope.organization -Credential $Credential -StartTime $EndTime -EndTime $now.ToString('o') -Transport $Transport
    foreach ($event in $tail.events) {
        if ($event.actionId -notmatch '^Process\.' -or [DateTimeOffset]::Parse($event.timestamp) -le [DateTimeOffset]::Parse($EndTime)) { continue }
        $processValues = @($event.data.ProcessId, $event.data.ProcessTypeId) | Where-Object { $_ }
        $processIds = @($processValues | ForEach-Object { $parsed = [guid]::Empty; if ([guid]::TryParse($_, [ref]$parsed)) { $parsed.ToString() } } | Sort-Object -Unique)
        if ($null -ne $AuditEvents -and $SourceSnapshot -and $processIds.Count -eq 1 -and $processIds[0] -eq $Scope.sourceProcessId) {
            $selectedKeys = @($AuditEvents | ForEach-Object { Get-AdoEventEntity $_ $SourceSnapshot } | ForEach-Object { $_.key })
            $affected = @(Get-AdoEventEntity $event $SourceSnapshot)
            $relevant = @($affected | Where-Object {
                $affectedKey = $_.key
                @($selectedKeys | Where-Object { $_ -eq $affectedKey -or $_.StartsWith("$affectedKey/", [StringComparison]::Ordinal) }).Count
            })
            if (-not $relevant.Count) { continue }
        }
        if ($processIds.Count -ne 1 -or $processIds[0] -eq $Scope.sourceProcessId) { throw 'Potential source changes exist after the audit end. Extend the window and scan again.' }
    }
}

function Test-AdoPostcondition {
    param([hashtable]$Operation, [hashtable]$Before, [hashtable]$After)
    $key = $Operation.key
    if (-not $After.entities.ContainsKey($key)) { throw 'Write was not verified: expected entity is missing.' }
    $entity = $After.entities[$key]
    $expected = if ($Operation.create) { $Operation.desired } else { Copy-AdoObject $Operation.before }
    if (-not $Operation.create) { foreach ($property in $Operation.body.Keys) { $expected[$property] = $Operation.body[$property] } }
    foreach ($property in $expected.Keys) {
        if ((Get-AdoHash $entity.definition[$property]) -ne (Get-AdoHash $expected[$property])) { throw "Write was not verified: unexpected '$property' value." }
    }
    if (-not $Operation.create -and $entity.identity -ne $Before.entities[$key].identity) { throw 'Target identity changed unexpectedly.' }
    foreach ($priorKey in $Before.entities.Keys) {
        if ($priorKey -eq $key) { continue }
        if (-not $After.entities.ContainsKey($priorKey) -or (Get-AdoHash $Before.entities[$priorKey]) -ne (Get-AdoHash $After.entities[$priorKey])) {
            throw 'Unexpected target-only or related configuration change after write; stop and inspect live state.'
        }
    }
    foreach ($newKey in $After.entities.Keys) {
        if ($newKey -eq $key -or $Before.entities.ContainsKey($newKey)) { continue }
        if (-not ($Operation.create -and $Operation.category -in @('WorkItemType', 'Page') -and $newKey.StartsWith("$key/", [StringComparison]::Ordinal))) {
            throw 'Unexpected extra target entity after write; stop and inspect live state.'
        }
    }
    if ((Get-AdoHash $Before.process) -ne (Get-AdoHash $After.process)) { throw 'Target process metadata changed unexpectedly.' }
    return $true
}

function Get-AdoPendingRuns {
    param([string]$StoreRoot, [string]$ScopeKey)
    $runs = Join-Path $StoreRoot 'runs'
    if (-not (Test-Path -LiteralPath $runs)) { return @() }
    $pending = @()
    foreach ($directory in Get-ChildItem -LiteralPath $runs -Directory) {
        if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Run directory cannot be a reparse point.' }
        $path = Join-Path $directory.FullName 'journal.json'
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $journal = Read-AdoLocalJson $path
        if ($journal.scopeKey -eq $ScopeKey -and @($journal.entries | Where-Object { $_.status -in @('attempting', 'uncertain') }).Count) { $pending += $path }
    }
    return $pending
}

function Invoke-AdoReconciliation {
    param([hashtable]$Session, [scriptblock]$Transport)
    $scope = $Session.scope
    $resolved = @()
    foreach ($path in @(Get-AdoPendingRuns $Session.storeRoot (Get-AdoScopeKey $scope))) {
        $journal = Read-AdoLocalJson $path
        $selection = if ($journal.ContainsKey('auditSelection')) { $journal.auditSelection } else { $null }
        $live = Get-AdoLiveSet $scope $Session.reader $Transport $selection
        foreach ($entry in $journal.entries) {
            if ($entry.status -notin @('attempting', 'uncertain')) { continue }
            $current = $live[$entry.operation.targetId]
            if ((Get-AdoSnapshotHash $current) -eq (Get-AdoSnapshotHash $entry.before)) { $entry.status = 'reconciled-not-committed' }
            else {
                $null = Test-AdoPostcondition $entry.operation $entry.before $current
                $entry.status = 'reconciled-committed'
            }
            $resolved += @{ key = $entry.operation.key; targetId = $entry.operation.targetId; status = $entry.status }
        }
        Write-AdoLocalJson $path $journal
    }
    $Session.result = @{ status = 'reconciled'; entries = @($resolved); message = 'Live state reconciled. The prior baseline is preserved. Scan again before any further writes.' }
    $Session.preview = $null
}

function New-AdoPreview {
    param([hashtable]$Session, [hashtable]$InputData, [scriptblock]$Transport)
    $Session.preview = $null
    $scope = @{ organization = $Session.organization; sourceProcessId = [guid]::Parse($InputData.sourceProcessId).ToString(); targetProcessIds = @($InputData.targetProcessIds | ForEach-Object { [guid]::Parse($_).ToString() }) }
    Assert-AdoScope $scope $Session.processes
    if ($InputData.impact -and $InputData.impact.Length -gt 4000) { throw 'Project impact notes cannot exceed 4000 characters.' }
    $Session.scope = $scope
    $scopeKey = Get-AdoScopeKey $scope
    if ($InputData.ContainsKey('auditEventIds')) {
        $cached = $Session.auditCache
        if ($Session.cancel -or [DateTimeOffset]::UtcNow -gt $Session.expiresAt -or -not $cached -or
            $cached.organization -ne $scope.organization -or $cached.sourceProcessId -ne $scope.sourceProcessId -or
            -not $cached.audit.complete -or
            [DateTimeOffset]::Parse($cached.audit.startTime) -ne [DateTimeOffset]::Parse($InputData.startTime) -or
            [DateTimeOffset]::Parse($cached.audit.endTime) -ne [DateTimeOffset]::Parse($InputData.endTime)) { throw 'Displayed audit cache is unavailable or does not match the source and window. Read audit explicitly before synchronizing.' }
        $Session.progress = 'Using the audit events already read'
        $audit = Copy-AdoObject $cached.audit
    }
    else {
        $Session.progress = 'Reading every audit page'
        $Session.auditCache = $null; $Session.auditRead = $null
        $Session.rawAudit = [Collections.Generic.List[object]]::new()
        $audit = Get-AdoAudit -Organization $scope.organization -Credential $Session.reader -StartTime $InputData.startTime -EndTime $InputData.endTime -Transport $Transport -RawPages $Session.rawAudit
        $Session.auditCache = @{ organization = $scope.organization; sourceProcessId = $scope.sourceProcessId; audit = (Copy-AdoObject $audit) }
        $Session.auditRead = @{ sourceProcessId = $scope.sourceProcessId; startTime = $audit.startTime; endTime = $audit.endTime }
    }
    $audit.events = @($audit.events | Where-Object { $_.actionId -match '^Process\.' })
    if ($InputData.ContainsKey('auditEventIds')) {
        $eventIds = $InputData.auditEventIds
        if ($eventIds -isnot [array] -or -not $eventIds.Count -or @($eventIds | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -or @($eventIds | Sort-Object -Unique).Count -ne $eventIds.Count) { throw 'Select distinct displayed audit event IDs.' }
        $observedIds = @($audit.events | ForEach-Object { $_.id })
        if (@($eventIds | Where-Object { $_ -notin $observedIds }).Count) { throw 'A displayed audit event is no longer available in the selected window. Read audit again.' }
        $audit.events = @($audit.events | Where-Object { $_.id -in $eventIds })
        $audit.selectedEventIds = @($eventIds)
    }
    Write-AdoTrace 'sync.scope' @{ sourceProcessId = $scope.sourceProcessId; targetProcessIds = $scope.targetProcessIds; count = $audit.events.Count }
    foreach ($event in $audit.events) {
        Write-AdoTrace 'sync.audit.event' @{ eventId = $event.id; actionId = $event.actionId; eventTime = $event.timestamp }
    }
    Write-AdoTrace 'sync.phase' @{ phase = 'Reading live source and child definitions' }
    $Session.progress = 'Reading and checking live process definitions'
    $selection = if ($audit.selectedEventIds) { @($audit.events) } else { $null }
    $snapshots = Get-AdoLiveSet $scope $Session.reader $Transport $selection
    Assert-AdoTail $scope $Session.reader $InputData.endTime $Transport $selection $snapshots[$scope.sourceProcessId]
    $baselinePath = Join-Path $Session.storeRoot "baseline-$scopeKey.json"
    $baseline = if (Test-Path -LiteralPath $baselinePath) { Read-AdoLocalJson $baselinePath } else { $null }
    if ($baseline -and ($baseline.schemaVersion -ne 1 -or (Get-AdoScopeKey $baseline.scope) -ne $scopeKey -or $baseline.snapshots -isnot [System.Collections.IDictionary])) { throw 'Invalid baseline. Do not silently adopt a replacement.' }
    $fields = if (-not $selection -or @($selection | Where-Object { $_.actionId -match '^Process\.(Field|Control|Rule)\.' }).Count) { Get-AdoCollection (Invoke-AdoApi -Organization $scope.organization -Credential $Session.reader -Path 'wit/fields' -Transport $Transport) } else { @() }
    $globalFields = @{}
    foreach ($field in $fields) { $globalFields[$field.referenceName] = Select-AdoProperties $field @('referenceName', 'type', 'isPicklist', 'picklistId') }
    $plan = New-AdoPlan $scope $baseline $snapshots $audit $globalFields $InputData.impact
    $pending = @(Get-AdoPendingRuns $Session.storeRoot $scopeKey)
    if ($pending.Count) { $plan.blockers += 'An earlier write has an uncertain outcome. Reconcile live state before proceeding.'; $plan.operations = @() }
    Write-AdoTrace 'sync.plan' @{ mode = $plan.mode; count = $plan.operations.Count }
    foreach ($operation in $plan.operations) {
        Write-AdoTrace 'sync.operation.planned' @{ method = $operation.method; path = $operation.path; processId = $operation.targetId; key = $operation.key }
    }
    foreach ($blocker in $plan.blockers) { Write-AdoTrace 'sync.blocked' @{ reason = $blocker } }
    foreach ($item in $plan.deferred) { Write-AdoTrace 'sync.deferred' @{ key = $item.key; processId = $item.targetId; reason = $item.reason } }
    foreach ($item in $plan.noOps) { Write-AdoTrace 'sync.noop' @{ key = $item.key; processId = $item.targetId } }
    $Session.recoveryNeeded = $pending.Count -gt 0
    $runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N')
    $runPath = Join-Path $Session.storeRoot "runs/$runId"
    Initialize-AdoStore $runPath
    Write-AdoLocalJson (Join-Path $runPath 'plan.json') $plan
    Write-AdoLocalJson (Join-Path $runPath 'snapshots.json') $snapshots
    $planBytes = [IO.File]::ReadAllBytes((Join-Path $runPath 'plan.json'))
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($planBytes)).ToLowerInvariant()
    $Session.preview = @{ plan = $plan; hash = $hash; runId = $runId; runPath = $runPath; snapshots = $snapshots; baseline = $baseline; baselinePath = $baselinePath; globalFields = $globalFields }
    $Session.result = $null
    $report = @("# Process synchronization preview", '', "Run: $runId", "Plan SHA256: $hash", "Organization: $($scope.organization)", "Universal: $($scope.sourceProcessId)", "Children: $($scope.targetProcessIds -join ', ')", "Audit UTC: $($audit.startTime) to $($audit.endTime); $($audit.pageCount) complete pages.", "Mode: $($plan.mode)", "Project impact: $($plan.impact)", "Operations: $($plan.operations.Count); deferred: $($plan.deferred.Count); blockers: $($plan.blockers.Count).", '', 'No writes have occurred. Operations are not transactional; partial changes cannot be automatically rolled back.', '')
    $report += @($plan.blockers | ForEach-Object { "- BLOCKED: $_" })
    $report += @($plan.operations | ForEach-Object { "- $($_.method) $($_.path) [$($_.key)]" })
    [IO.File]::WriteAllText((Join-Path $runPath 'report.md'), ($report -join "`n"), [Text.UTF8Encoding]::new($false))
}

function Assert-AdoApprovedPlan {
    param([hashtable]$Preview, [string]$Hash, [switch]$AllowBlocked)
    if (-not $Preview -or $Hash -cne $Preview.hash -or $Hash -notmatch '^[a-f0-9]{64}$') { throw 'Explicit approval must match this exact plan SHA256.' }
    $bytes = [IO.File]::ReadAllBytes((Join-Path $Preview.runPath 'plan.json'))
    $actual = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if ($actual -cne $Hash) { throw 'The plan file changed. Approval is invalid.' }
    $plan = ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString($bytes)) -AsHashtable -DateKind String
    if ((Get-AdoHash $plan) -ne (Get-AdoHash $Preview.plan)) { throw 'The server plan changed. Approval is invalid.' }
    if ($plan.blockers.Count -and -not $AllowBlocked) { throw 'Blocked plans cannot be applied or adopted.' }
    return $plan
}

function Save-AdoVerifiedBaseline {
    param([hashtable]$Session, [hashtable]$Snapshots, [hashtable]$Plan)
    $checkpoint = if ($Plan.mode -eq 'adopt') { [DateTimeOffset]::UtcNow.ToString('o') } else { $Plan.audit.endTime }
    $prior = $Session.preview.baseline
    $savedSnapshots = $Snapshots
    if ($Plan.audit.selectedEventIds -and $prior) {
        $savedSnapshots = Copy-AdoObject $prior.snapshots
        $selectedKeys = @($Plan.audit.events | ForEach-Object { Get-AdoEventEntity $_ $Snapshots[$Session.scope.sourceProcessId] } | ForEach-Object { $_.key })
        foreach ($processId in $Snapshots.Keys) {
            foreach ($key in $Snapshots[$processId].entities.Keys) {
                if ($key -in $selectedKeys -or -not $savedSnapshots[$processId].entities.ContainsKey($key)) { $savedSnapshots[$processId].entities[$key] = Copy-AdoObject $Snapshots[$processId].entities[$key] }
            }
        }
    }
    $baseline = @{ schemaVersion = 1; scope = $Session.scope; checkpoint = $checkpoint; snapshots = $savedSnapshots;
        eventIds = @(@($prior.eventIds) + @($Plan.audit.events | ForEach-Object { $_.id }) | Where-Object { $_ } | Sort-Object -Unique); verifiedAt = [DateTimeOffset]::UtcNow.ToString('o'); runId = $Session.preview.runId }
    Write-AdoLocalJson $Session.preview.baselinePath $baseline
}

function Invoke-AdoApprovedRun {
    param([hashtable]$Session, [hashtable]$InputData, [scriptblock]$Transport)
    $preview = $Session.preview
    if ($InputData.confirmed -ne $true -or $InputData.mappingsConfirmed -ne $true) { throw 'Confirm the exact plan, identity mappings, and project impact.' }
    $plan = Assert-AdoApprovedPlan $preview $InputData.hash
    if ($Session.consumedHash -eq $InputData.hash) { throw 'This approval has already been consumed. Scan again.' }
    $Session.consumedHash = $InputData.hash
    $scope = $Session.scope
    if ((Get-AdoScopeKey $scope) -ne (Get-AdoScopeKey @{ organization = $plan.organization; sourceProcessId = $plan.sourceProcessId; targetProcessIds = $plan.targetProcessIds })) { throw 'Approved scope no longer matches session.' }
    $Session.progress = 'Rechecking source and every child before approval execution'
    $selection = if ($plan.audit.selectedEventIds) { @($plan.audit.events) } else { $null }
    $live = Get-AdoLiveSet $scope $Session.reader $Transport $selection
    foreach ($processId in $live.Keys) { if ((Get-AdoSnapshotHash $live[$processId]) -ne $plan.snapshots[$processId]) { throw 'Source or child changed after preview. Scan and approve a new plan.' } }
    Assert-AdoTail $scope $Session.reader $plan.audit.endTime $Transport $selection $live[$scope.sourceProcessId]
    if ($Session.cancel -or [DateTimeOffset]::UtcNow -gt $Session.expiresAt) { throw 'Session expired or run canceled before execution.' }
    if ($plan.mode -eq 'adopt') {
        Save-AdoVerifiedBaseline $Session $live $plan
        $Session.result = @{ status = 'adopted'; message = 'Baseline adopted. No Azure DevOps writes occurred.'; counts = @(); runId = $preview.runId }
        $Session.preview = $null
        return
    }
    if ($plan.operations.Count -and -not $Session.writer) { throw 'A separate writer PAT is required.' }
    if (@(Get-AdoPendingRuns $Session.storeRoot (Get-AdoScopeKey $scope)).Count) { throw 'Reconcile the uncertain previous write before applying.' }
    $journal = @{ scopeKey = (Get-AdoScopeKey $scope); approvedHash = $InputData.hash; auditSelection = $selection; entries = @(); completed = $false }
    $journalPath = Join-Path $preview.runPath 'journal.json'
    $counts = @{}
    foreach ($targetId in $scope.targetProcessIds) { $counts[$targetId] = @{ targetId = $targetId; planned = @($plan.operations | Where-Object { $_.targetId -eq $targetId }).Count; applied = 0; verified = 0; noOp = @($plan.noOps | Where-Object { $_.targetId -eq $targetId }).Count; failed = 0 } }
    try {
        foreach ($operation in $plan.operations) {
            if ($Session.cancel -or [DateTimeOffset]::UtcNow -gt $Session.expiresAt) { throw 'Canceled or expired. No further writes will be attempted.' }
            $Session.progress = "Checking $($operation.category) on $($operation.targetId)"
            $current = Get-AdoLiveSet $scope $Session.reader $Transport $selection
            foreach ($processId in $current.Keys) { if ((Get-AdoSnapshotHash $current[$processId]) -ne (Get-AdoSnapshotHash $live[$processId])) { throw 'Unpredicted source or target drift before a write.' } }
            $target = $current[$operation.targetId]
            if ($operation.targetId -notin $scope.targetProcessIds -or $operation.path -notmatch "^work/processes/$([regex]::Escape($operation.targetId))/(workItemTypes|workitemtypesbehaviors|behaviors)(/|$)") { throw 'Write does not address an explicitly selected child.' }
            $change = @{ before = $preview.baseline.snapshots[$scope.sourceProcessId].entities[$operation.key]; after = $current[$scope.sourceProcessId].entities[$operation.key]; key = $operation.key }
            $validated = New-AdoOperation $change $target $preview.globalFields
            if (-not $validated -or $validated.deferred -or $validated.path -cne $operation.path -or $validated.method -cne $operation.method -or (Get-AdoHash $validated.body) -ne (Get-AdoHash $operation.body)) { throw 'Operation safety preconditions no longer match approval.' }
            if ($operation.category -eq 'Field') {
                $field = Invoke-AdoApi -Organization $scope.organization -Credential $Session.reader -Path "wit/fields/$($change.after.definition.referenceName)" -Transport $Transport
                if ((Get-AdoHash (Select-AdoProperties $field @('referenceName', 'type', 'isPicklist', 'picklistId'))) -ne (Get-AdoHash $preview.globalFields[$change.after.definition.referenceName])) { throw 'Global field compatibility changed after approval.' }
            }
            if ($Session.cancel -or [DateTimeOffset]::UtcNow -gt $Session.expiresAt) { throw 'Canceled or expired during preconditions. No write was submitted.' }
            $entry = @{ operation = $operation; before = $target; status = 'attempting'; at = [DateTimeOffset]::UtcNow.ToString('o') }
            $journal.entries += $entry
            Write-AdoLocalJson $journalPath $journal
            $Session.progress = "Applying and verifying $($operation.key)"
            Write-AdoTrace 'sync.operation.applying' @{ method = $operation.method; path = $operation.path; processId = $operation.targetId; key = $operation.key }
            try {
                $null = Invoke-AdoApi -Organization $scope.organization -Credential $Session.writer -Path $operation.path -Method $operation.method -Body $operation.body -Transport $Transport
                $counts[$operation.targetId].applied++
                $after = Get-AdoSnapshot -Organization $scope.organization -Credential $Session.reader -ProcessId $operation.targetId -Transport $Transport -AuditEvents $selection -SourceSnapshot $current[$scope.sourceProcessId]
                $null = Test-AdoPostcondition $operation $target $after
                $entry.status = 'verified'; $entry.afterHash = Get-AdoSnapshotHash $after
                $live[$operation.targetId] = $after
                $counts[$operation.targetId].verified++
                Write-AdoTrace 'sync.operation.verified' @{ processId = $operation.targetId; key = $operation.key }
                Write-AdoLocalJson $journalPath $journal
            }
            catch {
                Write-AdoFailureTrace 'sync.operation.uncertain' $_ @{ method = $operation.method; path = $operation.path; processId = $operation.targetId; key = $operation.key }
                $entry.status = 'uncertain'; $counts[$operation.targetId].failed++; Write-AdoLocalJson $journalPath $journal; throw
            }
        }
        $final = Get-AdoLiveSet $scope $Session.reader $Transport $selection
        foreach ($processId in $final.Keys) { if ((Get-AdoSnapshotHash $final[$processId]) -ne (Get-AdoSnapshotHash $live[$processId])) { throw 'Unexpected final drift; baseline was not advanced.' } }
        $remaining = New-AdoPlan $scope $preview.baseline $final $plan.audit $preview.globalFields $plan.impact
        if ($remaining.blockers.Count) { throw 'Final comparison has unexplained drift; prior baseline preserved.' }
        if ($remaining.operations.Count -or $remaining.deferred.Count) {
            $Session.result = @{ status = 'stage-verified'; message = 'This stage is verified. Scan again to approve the next exact stage. Prior baseline preserved.'; counts = @($counts.Values); runId = $preview.runId }
        }
        else {
            Save-AdoVerifiedBaseline $Session $final $plan
            $journal.completed = $true
            $Session.result = @{ status = 'verified'; message = 'All selected children verified; repeat preview requires zero new writes. Baseline advanced.'; counts = @($counts.Values); runId = $preview.runId }
        }
        Write-AdoLocalJson $journalPath $journal
        Write-AdoLocalJson (Join-Path $preview.runPath 'result.json') $Session.result
        $Session.preview = $null
    }
    catch {
        $Session.result = @{ status = 'stopped'; message = 'Stopped. Prior baseline preserved. Inspect live state and reconcile uncertain writes before continuing.'; counts = @($counts.Values); runId = $preview.runId }
        Write-AdoLocalJson (Join-Path $preview.runPath 'result.json') $Session.result
        $Session.preview = $null
        throw
    }
}

function Invoke-AdoAppJob {
    param([hashtable]$Session, [string]$Kind, [hashtable]$InputData, [scriptblock]$Transport)
    Write-AdoTrace 'job.start' @{ kind = $Kind }
    try {
        switch ($Kind) {
            Connect {
                $Session.progress = 'Reading organization process inventory'
                $processes = Get-AdoCollection (Invoke-AdoApi -Organization $Session.organization -Credential $Session.reader -Path 'work/processes' -Transport $Transport)
                $Session.processes = @($processes | ForEach-Object { Select-AdoProperties $_ @('typeId', 'name', 'customizationType', 'parentProcessTypeId', 'description') })
                if ($Session.cancel -or [DateTimeOffset]::UtcNow -gt $Session.expiresAt) { throw 'Connection canceled or session expired.' }
                $Session.connected = $true
            }
            ReadAudit {
                $Session.preview = $null; $Session.result = $null; $Session.rawAudit = $null; $Session.auditRead = $null; $Session.auditCache = $null
                $processId = [guid]::Parse($InputData.sourceProcessId).ToString()
                if (-not @($Session.processes | Where-Object { $_.typeId -eq $processId -and $_.customizationType -eq 'inherited' }).Count) { throw 'Select an inherited Universal process from the connected organization.' }
                $Session.progress = 'Reading every audit page'
                $pages = [Collections.Generic.List[object]]::new()
                $audit = Get-AdoAudit -Organization $Session.organization -Credential $Session.reader -StartTime $InputData.startTime -EndTime $InputData.endTime -Transport $Transport -RawPages $pages
                if ($Session.cancel -or [DateTimeOffset]::UtcNow -gt $Session.expiresAt) { throw 'Audit read canceled or session expired.' }
                $Session.rawAudit = $pages
                $Session.auditCache = @{ organization = $Session.organization; sourceProcessId = $processId; audit = (Copy-AdoObject $audit) }
                $Session.auditRead = @{ sourceProcessId = $processId; startTime = $audit.startTime; endTime = $audit.endTime }
            }
            Preview { New-AdoPreview $Session $InputData $Transport }
            Apply { Invoke-AdoApprovedRun $Session $InputData $Transport }
            Reconcile { Invoke-AdoReconciliation $Session $Transport }
            default { throw 'Unknown application job.' }
        }
        $Session.error = $null; $Session.state = 'ready'; $Session.progress = ''
        Write-AdoTrace 'job.completed' @{ kind = $Kind }
    }
    catch {
        Write-AdoFailureTrace 'job.failed' $_ @{ kind = $Kind }
        $Session.error = $_.Exception.Message; $Session.state = 'error'; $Session.progress = ''
    }
    finally {
        $Session.writer = $null
        if ($Session.cancel -or [DateTimeOffset]::UtcNow -gt $Session.expiresAt) { $Session.rawAudit = $null; $Session.auditRead = $null; $Session.auditCache = $null }
        if ($Kind -eq 'Connect' -and -not $Session.connected) { $Session.reader = $null }
    }
}

Export-ModuleMember -Function Initialize-AdoStore, Write-AdoLocalJson, Read-AdoLocalJson, Get-AdoScopeKey, Get-AdoLiveSet, Assert-AdoTail, Test-AdoPostcondition, Get-AdoPendingRuns, Invoke-AdoReconciliation, New-AdoPreview, Assert-AdoApprovedPlan, Invoke-AdoApprovedRun, Invoke-AdoAppJob