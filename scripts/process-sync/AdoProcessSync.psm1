#requires -Version 7.5
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AdoProcessApi.psm1')

function ConvertTo-AdoCanonical {
    param([AllowNull()][object]$Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) { $ordered[$key] = ConvertTo-AdoCanonical $Value[$key] }
        return $ordered
    }
    if ($Value -is [array]) { return ,@($Value | ForEach-Object { ConvertTo-AdoCanonical $_ }) }
    return $Value
}

function Get-AdoHash {
    param([AllowNull()][object]$Value)
    $json = ConvertTo-Json -InputObject (ConvertTo-AdoCanonical $Value) -Depth 100 -Compress
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
}

function Copy-AdoObject {
    param([object]$Value)
    return ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 100) -AsHashtable -DateKind String
}

function Select-AdoProperties {
    param([System.Collections.IDictionary]$Value, [string[]]$Names)
    $result = @{}
    foreach ($name in $Names) { if ($Value.Contains($name)) { $result[$name] = $Value[$name] } }
    return $result
}

function Get-AdoSnapshotHash {
    param([hashtable]$Snapshot)
    return Get-AdoHash @{ process = $Snapshot.process; entities = $Snapshot.entities }
}

function Assert-AdoScope {
    param([hashtable]$Scope, [array]$Processes)
    Assert-AdoOrganization $Scope.organization
    $sourceId = [guid]::Parse($Scope.sourceProcessId).ToString()
    if ($Scope.targetProcessIds -isnot [array] -or $Scope.targetProcessIds.Count -eq 0) { throw 'Select explicit child processes.' }
    $targetIds = @($Scope.targetProcessIds | ForEach-Object { [guid]::Parse($_).ToString() })
    if ($sourceId -in $targetIds -or @($targetIds | Select-Object -Unique).Count -ne $targetIds.Count -or
        [guid]::Empty.ToString() -in (@($sourceId) + $targetIds)) { throw 'Source and children must be distinct, nonempty process IDs.' }
    $source = @($Processes | Where-Object { $_.typeId -eq $sourceId })
    if ($source.Count -ne 1 -or $source[0].customizationType -ne 'inherited' -or -not $source[0].parentProcessTypeId) { throw 'Universal process must be inherited.' }
    foreach ($targetId in $targetIds) {
        $target = @($Processes | Where-Object { $_.typeId -eq $targetId })
        if ($target.Count -ne 1 -or $target[0].customizationType -ne 'inherited' -or
            $target[0].parentProcessTypeId -ne $source[0].parentProcessTypeId) { throw 'Children must be inherited processes with the same system parent.' }
    }
}

function Add-AdoEntity {
    param([hashtable]$Entities, [string]$Key, [string]$Category, [string]$Identity, [string]$Parent,
        [hashtable]$Definition, [string]$Path, [string]$CreatePath, [string]$Customization, [string]$WitRef = '')
    if (-not $Identity -or $Entities.ContainsKey($Key)) {
        $reason = if (-not $Identity) { 'Entity has no API identity.' } else { 'Multiple entities share the same semantic snapshot key.' }
        Write-AdoTrace 'snapshot.entity.rejected' @{ command = 'Add-AdoEntity'; category = $Category; key = $Key; path = $Path; reason = $reason }
        throw "Ambiguous or missing identity for $Category at '$Key'. $reason Explicit mapping is required."
    }
    $Entities[$Key] = @{ key = $Key; category = $Category; identity = $Identity; parent = $Parent; definition = $Definition;
        path = $Path; createPath = $CreatePath; customization = $Customization; witRef = $WitRef }
}

function Test-AdoSelectedEntity {
    param([array]$Events, [string]$Category, [string]$Identity, [string]$Label, [hashtable]$SourceSnapshot)
    $pattern = switch ($Category) {
        Field { '^Process\.Field\.' }; State { '^Process\.State\.' }; Rule { '^Process\.Rule\.' }
        Page { '^Process\.Page\.' }; Group { '^Process\.Group\.' }; Control { '^Process\.Control\.' }
        Behavior { '^Process\.Behavior\.' }
    }
    foreach ($event in @($Events | Where-Object { $_.actionId -match $pattern })) {
        $values = if ($SourceSnapshot) {
            foreach ($entity in @(Get-AdoEventEntity $event $SourceSnapshot)) {
                $entity.identity; $entity.definition.name; $entity.definition.label; $entity.definition.behaviorName
            }
        }
        else {
            switch ($Category) {
                Field { $event.data.FieldReferenceName; $event.data.FieldId }
                State { $event.data.StateId; $event.data.StateName }
                Rule { $event.data.RuleId; $event.data.RuleName }
                Page { $event.data.PageId; $event.data.PageName }
                Group { $event.data.GroupId; $event.data.GroupLabel }
                Control { $event.data.ControlId; $event.data.ControlLabel }
                Behavior { $event.data.BehaviorId; $event.data.BehaviorReferenceName; $event.data.BehaviorName }
            }
        }
        if (($Identity -and $Identity -in $values) -or ($Label -and $Label -in $values)) { return $true }
    }
    return $false
}

function Get-AdoSnapshot {
    param([string]$Organization, [PSCredential]$Credential, [string]$ProcessId, [scriptblock]$Transport,
        [AllowNull()][array]$AuditEvents, [hashtable]$SourceSnapshot)
    $processId = [guid]::Parse($ProcessId).ToString()
    $base = "work/processes/$processId"
    $request = @{ Organization = $Organization; Credential = $Credential; Transport = $Transport }
    $metadata = Invoke-AdoApi @request -Path $base
    if ($metadata.typeId -ne $processId -or $metadata.customizationType -ne 'inherited') { throw 'Live process is not the selected inherited process.' }
    $entities = @{}
    $scoped = $null -ne $AuditEvents
    $needsBehaviors = -not $scoped -or @($AuditEvents | Where-Object { $_.actionId -match '^Process\.Behavior\.' }).Count -gt 0
    $behaviors = if ($needsBehaviors) { Get-AdoCollection (Invoke-AdoApi @request -Path "$base/behaviors") } else { @() }
    $behaviorNames = @{}
    foreach ($behavior in $behaviors) {
        if ($scoped -and -not (Test-AdoSelectedEntity $AuditEvents 'Behavior' $behavior.referenceName $behavior.name $SourceSnapshot)) { continue }
        $key = 'behavior:' + [Uri]::EscapeDataString($behavior.name)
        $definition = Select-AdoProperties $behavior @('name', 'color', 'rank', 'description')
        $definition.inherits = if ($behavior.inherits -is [System.Collections.IDictionary]) { $behavior.inherits.behaviorRefName } else { $behavior.inherits }
        $definition.fields = @($behavior.fields | ForEach-Object { $_.referenceName } | Sort-Object)
        Add-AdoEntity $entities $key 'Behavior' $behavior.referenceName '' $definition "$base/behaviors/$($behavior.referenceName)" "$base/behaviors" $behavior.customization
        $behaviorNames[$behavior.referenceName] = $behavior.name
    }
    $wits = Get-AdoCollection (Invoke-AdoApi @request -Path "$base/workItemTypes")
    foreach ($wit in $wits) {
        $witEvents = $AuditEvents
        if ($scoped) {
            $sourceWit = $wit
            if ($SourceSnapshot) {
                $sourceEntity = @($SourceSnapshot.entities.Values | Where-Object { $_.category -eq 'WorkItemType' -and $_.definition.name -ceq $wit.name })
                if ($sourceEntity.Count -ne 1) { continue }
                $sourceWit = @{ referenceName = $sourceEntity[0].identity; name = $sourceEntity[0].definition.name }
            }
            $witEvents = @($AuditEvents | Where-Object {
                $references = @($_.data.WorkItemTypeReferenceName, $_.data.WorkItemTypeRefName, $_.data.WorkItemReferenceName, $_.data.WorkItemTypeId) | Where-Object { $_ }
                $sourceWit.referenceName -in $references -or ($_.data.WorkItemTypeName -and $_.data.WorkItemTypeName -ceq $sourceWit.name)
            })
            if (-not $witEvents.Count) { continue }
        }
        $witRef = [string]$wit.referenceName
        if (-not $witRef) { throw 'Work item type reference is missing.' }
        $wit = Invoke-AdoApi @request -Path "$base/workItemTypes/$witRef"
        if ($wit.referenceName -cne $witRef) { throw 'Work item type reference mismatch.' }
        $witKey = 'wit:' + [Uri]::EscapeDataString($wit.name)
        $witPath = "$base/workItemTypes/$witRef"
        $definition = Select-AdoProperties $wit @('name', 'description', 'color', 'icon', 'isDisabled', 'inherits')
        Add-AdoEntity $entities $witKey 'WorkItemType' $witRef '' $definition $witPath "$base/workItemTypes" $wit.customization $witRef
        foreach ($category in @('fields', 'states', 'rules')) {
            if ($scoped) {
                $actionPattern = switch ($category) { fields { '^Process\.(Field|Control)\.' }; states { '^Process\.State\.' }; rules { '^Process\.Rule\.' } }
                if (-not @($witEvents | Where-Object { $_.actionId -match $actionPattern }).Count) { continue }
            }
            $items = Get-AdoCollection (Invoke-AdoApi @request -Path "$witPath/$category")
            foreach ($item in $items) {
                $customization = if ($item.Contains('customizationType')) { $item.customizationType } else { $item.customization }
                switch ($category) {
                    fields {
                        $kind = 'Field'; $identity = $item.referenceName; $label = $identity
                        $definition = Select-AdoProperties $item @('referenceName', 'type', 'allowGroups', 'allowedValues', 'defaultValue', 'readOnly', 'required', 'isLocked')
                        if ($definition.ContainsKey('allowedValues')) { $definition.allowedValues = @($definition.allowedValues | Sort-Object) }
                    }
                    states { $kind = 'State'; $identity = $item.id; $label = $item.name; $definition = Select-AdoProperties $item @('name', 'color', 'order', 'stateCategory', 'hidden') }
                    rules { $kind = 'Rule'; $identity = $item.id; $label = $item.name; $definition = Select-AdoProperties $item @('name', 'conditions', 'actions', 'isDisabled') }
                }
                if ($scoped -and -not ($kind -eq 'Field' -and @($witEvents | Where-Object { $_.actionId -match '^Process\.Control\.' }).Count) -and
                    -not (Test-AdoSelectedEntity $witEvents $kind $identity $label $SourceSnapshot)) { continue }
                if ($kind -eq 'Rule' -and [string]::IsNullOrWhiteSpace($label)) {
                    if ($customization -ne 'system') { throw 'Unnamed custom rules require explicit identity mapping.' }
                    $label = "system:$identity"
                }
                $key = "$witKey/$kind`:$([Uri]::EscapeDataString($label))"
                Add-AdoEntity $entities $key $kind $identity $witKey $definition "$witPath/$category/$identity" "$witPath/$category" $customization $witRef
            }
        }
        $linksPath = "$base/workitemtypesbehaviors/$witRef/behaviors"
        $links = if (-not $scoped -or @($witEvents | Where-Object { $_.actionId -match '^Process\.Behavior\.(Add|Update|Remove)$' }).Count) { Get-AdoCollection (Invoke-AdoApi @request -Path $linksPath) } else { @() }
        foreach ($link in $links) {
            $behaviorId = [string]$link.behavior.id
            if ($scoped -and -not $behaviorNames.ContainsKey($behaviorId)) { continue }
            if (-not $behaviorNames.ContainsKey($behaviorId)) { throw 'Unresolved work item type behavior identity.' }
            $name = $behaviorNames[$behaviorId]
            $definition = @{ behaviorName = $name; isDefault = [bool]$link.isDefault; isLegacyDefault = [bool]$link.isLegacyDefault }
            Add-AdoEntity $entities "$witKey/Association:$([Uri]::EscapeDataString($name))" 'Association' $behaviorId $witKey $definition "$linksPath/$behaviorId" $linksPath 'custom' $witRef
        }
        if ($scoped -and -not @($witEvents | Where-Object { $_.actionId -match '^Process\.(Page|Group|Control)\.' }).Count) { continue }
        $expandedWit = Invoke-AdoApi @request -Path $witPath -Query @{ '$expand' = 'layout' }
        if ($expandedWit.referenceName -cne $witRef) { throw 'Expanded work item type reference mismatch.' }
        $layout = $expandedWit.layout
        if ($layout.pages -isnot [array]) { throw 'Incomplete work item form layout.' }
        if (-not $scoped) { Add-AdoEntity $entities "$witKey/SystemLayout" 'SystemLayout' $witRef $witKey @{ extensions = @($layout.extensions); controls = @($layout.systemControls) } '' '' 'system' $witRef }
        $pageOrder = 0
        foreach ($page in $layout.pages) {
            $currentPageOrder = $pageOrder++
            if ($scoped) {
                $selectedPage = Test-AdoSelectedEntity $witEvents 'Page' $page.id $page.label $SourceSnapshot
                $selectedDescendants = @($page.sections | ForEach-Object { $_.groups } | Where-Object {
                    (Test-AdoSelectedEntity $witEvents 'Group' $_.id $_.label $SourceSnapshot) -or
                    @($_.controls | Where-Object { Test-AdoSelectedEntity $witEvents 'Control' $_.id $_.label $SourceSnapshot }).Count
                })
                if (-not $selectedPage -and -not $selectedDescendants.Count) { continue }
            }
            $pageKey = "$witKey/Page:$([Uri]::EscapeDataString([string]$page.label))"
            $definition = Select-AdoProperties $page @('label', 'visible', 'locked', 'pageType', 'isContribution', 'contribution')
            $definition.order = $currentPageOrder
            Add-AdoEntity $entities $pageKey 'Page' $page.id $witKey $definition "$witPath/layout/pages/$($page.id)" "$witPath/layout/pages" $(if ($page.inherited) { 'system' } else { 'custom' }) $witRef
            foreach ($section in @($page.sections)) {
                if ($scoped -and -not @($section.groups | Where-Object {
                    (Test-AdoSelectedEntity $witEvents 'Group' $_.id $_.label $SourceSnapshot) -or
                    @($_.controls | Where-Object { Test-AdoSelectedEntity $witEvents 'Control' $_.id $_.label $SourceSnapshot }).Count
                }).Count) { continue }
                $sectionKey = "$pageKey/Section:$([Uri]::EscapeDataString($section.id))"
                Add-AdoEntity $entities $sectionKey 'Section' $section.id $pageKey @{ id = $section.id } "$witPath/layout/pages/$($page.id)/sections/$($section.id)" '' 'system' $witRef
                $groupOrder = 0
                foreach ($group in @($section.groups)) {
                    $currentGroupOrder = $groupOrder++
                    if ($scoped -and -not (Test-AdoSelectedEntity $witEvents 'Group' $group.id $group.label $SourceSnapshot) -and
                        -not @($group.controls | Where-Object { Test-AdoSelectedEntity $witEvents 'Control' $_.id $_.label $SourceSnapshot }).Count) { continue }
                    $groupKey = "$sectionKey/Group:$([Uri]::EscapeDataString([string]$group.label))"
                    $definition = Select-AdoProperties $group @('label', 'visible', 'isContribution', 'contribution', 'height')
                    $definition.order = $currentGroupOrder
                    Add-AdoEntity $entities $groupKey 'Group' $group.id $sectionKey $definition "$witPath/layout/groups/$($group.id)" "$witPath/layout/pages/$($page.id)/sections/$($section.id)/groups" $(if ($group.inherited) { 'system' } else { 'custom' }) $witRef
                    $controlOrder = 0
                    foreach ($control in @($group.controls)) {
                        $currentControlOrder = $controlOrder++
                        if ($scoped -and -not (Test-AdoSelectedEntity $witEvents 'Control' $control.id $control.label $SourceSnapshot)) { continue }
                        if (-not $control.id -and ($control.inherited -eq $true -or $page.pageType -in @('links', 'history'))) {
                            $definition = @{ control = (Copy-AdoObject $control); order = $currentControlOrder }
                            $identity = "system-control:$currentControlOrder"
                            Add-AdoEntity $entities "$groupKey/SystemControl:$currentControlOrder" 'SystemLayout' $identity $groupKey $definition '' '' 'system' $witRef
                            Write-AdoTrace 'snapshot.control.readonly' @{ category = 'SystemLayout'; key = "$groupKey/SystemControl:$currentControlOrder"; reason = 'ID-less built-in control retained as read-only snapshot data.' }
                            continue
                        }
                        $definition = Select-AdoProperties $control @('label', 'visible', 'readOnly', 'controlType', 'watermark', 'isContribution', 'contribution', 'height', 'metadata')
                        $definition.order = $currentControlOrder
                        $definition.fieldId = $control.id
                        Add-AdoEntity $entities "$groupKey/Control:$([Uri]::EscapeDataString($control.id))" 'Control' $control.id $groupKey $definition "$witPath/layout/groups/$($group.id)/controls/$($control.id)" "$witPath/layout/groups/$($group.id)/controls" $(if ($control.inherited) { 'system' } else { 'custom' }) $witRef
                    }
                }
            }
        }
    }
    return @{ process = (Select-AdoProperties $metadata @('typeId', 'name', 'description', 'parentProcessTypeId', 'customizationType')); entities = $entities; capturedAt = [DateTimeOffset]::UtcNow.ToString('o') }
}

function Get-AdoDelta {
    param([hashtable]$Before, [hashtable]$After)
    $delta = [Collections.Generic.List[object]]::new()
    foreach ($key in @(@($Before.entities.Keys) + @($After.entities.Keys) | Sort-Object -Unique)) {
        $old = $Before.entities[$key]; $new = $After.entities[$key]
        if ((Get-AdoHash $old) -eq (Get-AdoHash $new)) { continue }
        if ($old -and $new -and (Get-AdoHash $old.definition) -eq (Get-AdoHash $new.definition) -and $old.identity -eq $new.identity) { continue }
        $delta.Add(@{ key = $key; before = $old; after = $new })
    }
    return ,@($delta.ToArray())
}

function Get-AdoEventEntity {
    param([hashtable]$Event, [hashtable]$Source)
    $action = $Event.actionId
    $category = switch -Regex ($action) {
        '^Process\.WorkItemType\.(Create|Update|Delete)$' { 'WorkItemType'; break }
        '^Process\.Field\.(Add|Create|Update|Edit|Delete|Remove)$' { 'Field'; break }
        '^Process\.State\.(Create|Update|Delete)$' { 'State'; break }
        '^Process\.Rule\.(Add|Update|Delete)$' { 'Rule'; break }
        '^Process\.Page\.(Add|Update|Delete)$' { 'Page'; break }
        '^Process\.Group\.(Add|Update)$' { 'Group'; break }
        '^Process\.Control\.(Create|CreateWithoutLabel|Update|UpdateWithoutLabel|Delete)$' { 'Control'; break }
        '^Process\.Behavior\.(Create|Edit|Delete)$' { 'Behavior'; break }
        '^Process\.Behavior\.(Add|Update|Remove)$' { 'Association'; break }
        default { '' }
    }
    if (-not $category) { return @() }
    $data = $Event.data
    $witRef = @($data.WorkItemTypeReferenceName, $data.WorkItemTypeRefName, $data.WorkItemReferenceName, $data.WorkItemTypeId) | Where-Object { $_ } | Select-Object -First 1
    $witName = $data.WorkItemTypeName
    $matches = @($Source.entities.Values | Where-Object {
        $_.category -eq $category -and
        ((-not $witRef -and -not $witName) -or $_.witRef -eq $witRef -or
            ($witName -and $_.key -eq ('wit:' + [Uri]::EscapeDataString($witName))))
    })
    $identityValues = switch ($category) {
        WorkItemType { @($witRef, $witName) }
        Field { @($data.FieldReferenceName, $data.FieldId) }
        State { @($data.StateId, $data.StateName) }
        Rule { @($data.RuleId, $data.RuleName) }
        Behavior { @($data.BehaviorId, $data.BehaviorReferenceName, $data.BehaviorName) }
        Association { @($data.BehaviorId, $data.BehaviorReferenceName, $data.BehaviorName) }
        Page { @($data.PageId, $data.PageName) }
        Group { @($data.GroupId, $data.GroupLabel) }
        Control { @($data.ControlId, $data.ControlLabel) }
    }
    $identityValues = @($identityValues | Where-Object { $_ })
    if (-not $identityValues.Count) { return @() }
    return @($matches | Where-Object { $_.identity -in $identityValues -or $_.definition.name -in $identityValues -or $_.definition.label -in $identityValues -or $_.definition.behaviorName -in $identityValues })
}

function New-AdoOperation {
    param([hashtable]$Change, [hashtable]$Target, [hashtable]$GlobalFields)
    $source = $Change.after; $old = $Change.before
    if (-not $source) { throw 'Deletion is destructive and blocked.' }
    $existing = $Target.entities[$Change.key]
    if ($old -and $old.identity -ne $source.identity) { throw 'Identity replacement requires explicit mapping.' }
    if ($existing -and (Get-AdoHash $existing.definition) -eq (Get-AdoHash $source.definition)) { return $null }
    if ($source.parent -and -not $Target.entities.ContainsKey($source.parent)) { return @{ deferred = $true; reason = 'Parent creation needs a verified ID and a new approval stage.' } }
    if ($source.customization -eq 'system') { throw 'System-owned definitions are read-only.' }
    if ($old -and $old.identity -ne $source.identity) { throw 'Identity replacement requires explicit mapping.' }
    $create = -not $existing
    $definition = $source.definition
    $body = @{}
    if ($create) { $body = Copy-AdoObject $definition }
    else {
        if (-not $old) {
            if ((Get-AdoHash $existing.definition) -eq (Get-AdoHash $definition)) { return $null }
            throw 'An existing child entity conflicts with this source addition.'
        }
        foreach ($property in @(@($old.definition.Keys) + @($definition.Keys) | Sort-Object -Unique)) {
            if ((Get-AdoHash $old.definition[$property]) -eq (Get-AdoHash $definition[$property])) { continue }
            if ((Get-AdoHash $existing.definition[$property]) -eq (Get-AdoHash $definition[$property])) { continue }
            if ((Get-AdoHash $existing.definition[$property]) -ne (Get-AdoHash $old.definition[$property])) { throw "Child override conflicts on '$property'." }
            if (-not $definition.ContainsKey($property)) { throw 'Removing a property is blocked.' }
            $body[$property] = $definition[$property]
        }
        if ($body.Count -eq 0) { return $null }
    }
    $parent = if ($source.parent) { $Target.entities[$source.parent] } else { $null }
    if ($source.parent -and -not $parent) { return @{ deferred = $true; reason = 'Parent creation needs a verified ID and a new approval stage.' } }
    $base = "work/processes/$($Target.process.typeId)"
    $path = ''; $allowed = @(); $rank = 0
    switch ($source.category) {
        WorkItemType {
            $allowed = if ($create) { @('name', 'description', 'color', 'icon') } else { @('description', 'color', 'icon') }
            if ($definition.isDisabled -or ($create -and $definition.inherits)) { throw 'Disabled WIT changes or derived WIT creation require manual review.' }
            if ($create) { $body = Select-AdoProperties $definition $allowed; $path = "$base/workItemTypes" }
            else { $path = $existing.path }
            $rank = 10
        }
        Field {
            $ref = $definition.referenceName
            if (-not $GlobalFields.ContainsKey($ref) -or $GlobalFields[$ref].type -ne $definition.type) { throw 'Missing or incompatible organization field; global writes are blocked.' }
            $allowed = @('allowGroups', 'allowedValues', 'defaultValue', 'readOnly', 'required')
            if ($body.ContainsKey('allowedValues')) {
                if ($GlobalFields[$ref].isPicklist -or $GlobalFields[$ref].picklistId -or $definition.type -match '^picklist') { throw 'Shared picklist values cannot be changed.' }
                if (@($body.allowedValues | Where-Object { $_ -isnot [string] }).Count) { throw 'Only documented string allowed values are writable.' }
                if ($existing -and @($existing.definition.allowedValues | Where-Object { $_ -notin $body.allowedValues }).Count) { throw 'Removing allowed values is destructive.' }
            }
            if ($create) { $body = Select-AdoProperties $definition (@('referenceName') + $allowed); $path = "$($parent.path)/fields"; $allowed += 'referenceName' }
            else { $path = $existing.path }
            $rank = 20
        }
        State {
            $allowed = @('name', 'color', 'order', 'stateCategory')
            if ($definition.hidden) { throw 'Hidden states are blocked.' }
            if ($create) { $body = Select-AdoProperties $definition $allowed; $path = "$($parent.path)/states" }
            else { $path = $existing.path }
            $rank = 30
        }
        Rule {
            if (-not $create) { throw 'Rule replacement may remove validations; manual review required.' }
            if ($definition.isDisabled) { throw 'Disabled rules are blocked.' }
            $allowed = @('name', 'conditions', 'actions', 'isDisabled')
            $body = Select-AdoProperties $definition $allowed
            foreach ($condition in @($body.conditions)) {
                if ($condition.conditionType -notin @('$when', '$whenNot', '$whenChanged', '$whenNotChanged')) { throw 'Rule condition requires explicit identity/state translation.' }
                if (-not $Target.entities.ContainsKey("$($source.parent)/Field:$([Uri]::EscapeDataString($condition.field))")) { return @{ deferred = $true; reason = 'Rule field dependency needs a new approval stage.' } }
                if ($condition.field -eq 'System.State' -and -not $Target.entities.ContainsKey("$($source.parent)/State:$([Uri]::EscapeDataString($condition.value))")) { throw 'Rule state value has no target mapping.' }
            }
            foreach ($action in @($body.actions)) {
                if ($action.actionType -notin @('$makeRequired', '$makeReadOnly', '$setDefaultValue', '$copyValue')) { throw 'Unsupported or destructive rule action.' }
                if (-not $Target.entities.ContainsKey("$($source.parent)/Field:$([Uri]::EscapeDataString($action.targetField))")) { return @{ deferred = $true; reason = 'Rule field dependency needs a new approval stage.' } }
                if ($action.targetField -eq 'System.State') { throw 'Rule state mutations need explicit translation.' }
            }
            $path = "$($parent.path)/rules"; $rank = 60
        }
        Behavior {
            if (-not $create) { throw 'Behavior edits may change backlog ordering; manual review required.' }
            if ($definition.inherits -notmatch '^System\.') { throw 'Custom parent behavior requires explicit target mapping.' }
            $allowed = @('name', 'color', 'inherits'); $body = Select-AdoProperties $definition $allowed
            $path = "$base/behaviors"; $rank = 10
        }
        Association {
            if (-not $create -or $definition.isDefault -or $definition.isLegacyDefault) { throw 'Default/replaced backlog associations require manual review.' }
            $behaviorKey = 'behavior:' + [Uri]::EscapeDataString($definition.behaviorName)
            if (-not $Target.entities.ContainsKey($behaviorKey)) { return @{ deferred = $true; reason = 'Behavior creation needs a verified ID and new approval.' } }
            $allowed = @('behavior', 'isDefault'); $body = @{ behavior = @{ id = $Target.entities[$behaviorKey].identity }; isDefault = $false }
            $path = "$base/workitemtypesbehaviors/$($parent.identity)/behaviors"; $rank = 70
        }
        Page {
            if (-not $create -or $definition.isContribution -or $definition.pageType -ne 'custom' -or $definition.visible -eq $false) { throw 'Only visible non-extension page additions are supported.' }
            $allowed = @('label', 'order', 'visible', 'pageType', 'sections'); $body = Select-AdoProperties $definition @('label', 'order', 'visible', 'pageType')
            $body.sections = @(@{ id = 'Section1'; groups = @() }, @{ id = 'Section2'; groups = @() }, @{ id = 'Section3'; groups = @() }, @{ id = 'Section4'; groups = @() })
            $path = "$($parent.path)/layout/pages"; $rank = 40
        }
        Section { throw 'Section structure cannot be synchronized independently.' }
        Group {
            if (-not $create -or $definition.isContribution -or $definition.visible -eq $false) { throw 'Only visible non-extension group additions are supported.' }
            $allowed = @('label', 'order', 'visible'); $body = Select-AdoProperties $definition $allowed
            $path = "$($parent.path)/groups"; $rank = 50
        }
        Control {
            if (-not $create -or $definition.isContribution -or $definition.visible -eq $false -or -not $GlobalFields.ContainsKey($definition.fieldId)) { throw 'Only visible existing-field control additions are supported.' }
            $witKey = ($source.key -split '/')[0]
            if (-not $Target.entities.ContainsKey("$witKey/Field:$([Uri]::EscapeDataString($definition.fieldId))")) { return @{ deferred = $true; reason = 'Control field dependency needs a new approval stage.' } }
            $allowed = @('id', 'label', 'order', 'visible', 'readOnly', 'controlType', 'watermark')
            $body = Select-AdoProperties $definition @('label', 'order', 'visible', 'readOnly', 'controlType', 'watermark'); $body.id = $definition.fieldId
            $path = "$($parent.path)/controls"; $rank = 60
        }
        default { throw 'This source change has no safe REST adapter.' }
    }
    foreach ($property in $body.Keys) { if ($property -notin $allowed) { throw "Unsupported change to '$property'." } }
    return @{ method = $(if ($create) { 'POST' } else { 'PATCH' }); path = $path; body = $body; key = $Change.key;
        category = $source.category; targetId = $Target.process.typeId; rank = $rank; create = $create; deferred = $false;
        before = $(if ($existing) { Copy-AdoObject $existing.definition } else { $null }); desired = (Copy-AdoObject $definition); sourceIdentity = $source.identity;
        targetIdentity = $(if ($existing) { $existing.identity } else { $null }) }
}

function New-AdoPlan {
    param([hashtable]$Scope, [hashtable]$Baseline, [hashtable]$Snapshots, [hashtable]$Audit, [hashtable]$GlobalFields, [string]$Impact)
    $source = $Snapshots[$Scope.sourceProcessId]
    $events = if ($Audit.selectedEventIds) { @($Audit.events | Where-Object { $_.id -in $Audit.selectedEventIds }) } else { @($Audit.events) }
    $orderedEvents = @($events | Sort-Object -Stable @{ Expression = {
        $timestamp = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($_.timestamp, [ref]$timestamp)) { $timestamp.ToUnixTimeMilliseconds() } else { [long]::MaxValue }
    } }, @{ Expression = {
        if ($Audit.selectedEventIds) { [array]::IndexOf($Audit.selectedEventIds, $_.id) } else { 0 }
    } })
    $eventOrder = @{}
    for ($index = 0; $index -lt $orderedEvents.Count; $index++) { $eventOrder[$orderedEvents[$index].id] = $index }
    $plan = @{ schemaVersion = 1; organization = $Scope.organization; sourceProcessId = $Scope.sourceProcessId; targetProcessIds = @($Scope.targetProcessIds);
        mode = $(if ($Baseline) { 'sync' } else { 'adopt' }); createdAt = [DateTimeOffset]::UtcNow.ToString('o'); audit = (Copy-AdoObject $Audit);
        impact = $Impact; blockers = @(); changes = @(); operations = @(); mappings = @(); snapshots = @{}; deferred = @(); noOps = @() }
    $plan.audit.events = $orderedEvents
    foreach ($processId in $Snapshots.Keys) { $plan.snapshots[$processId] = Get-AdoSnapshotHash $Snapshots[$processId] }
    foreach ($targetId in $Scope.targetProcessIds) {
        foreach ($key in ($source.entities.Keys | Sort-Object)) {
            if ($Snapshots[$targetId].entities.ContainsKey($key)) {
                $plan.mappings += @{ key = $key; source = $source.entities[$key].identity; target = $Snapshots[$targetId].entities[$key].identity; targetId = $targetId }
            }
        }
    }
    if (-not $Baseline) { return $plan }
    if (-not $Audit.complete) { $plan.blockers += 'Audit window is incomplete.' }
    if ([DateTimeOffset]::Parse($Audit.startTime) -gt [DateTimeOffset]::Parse($Baseline.checkpoint)) { $plan.blockers += 'Audit window starts after the verified checkpoint; history gap.' }
    if ([DateTimeOffset]::Parse($Audit.endTime) -lt [DateTimeOffset]::Parse($Baseline.checkpoint)) { $plan.blockers += 'Audit window ends before the verified checkpoint.' }
    if (-not $Audit.selectedEventIds -and (Get-AdoHash $source.process) -ne (Get-AdoHash $Baseline.snapshots[$Scope.sourceProcessId].process)) { $plan.blockers += 'Source process metadata changed; process-root writes are unsupported.' }
    $changes = Get-AdoDelta $Baseline.snapshots[$Scope.sourceProcessId] $source
    $evidence = @{}
    foreach ($event in $orderedEvents) {
        if ($event.actionId -notmatch '^Process\.') { continue }
        $processValues = @($event.data.ProcessId, $event.data.ProcessTypeId) | Where-Object { $_ }
        $processIds = @($processValues | ForEach-Object { $parsed = [guid]::Empty; if ([guid]::TryParse($_, [ref]$parsed)) { $parsed.ToString() } } | Sort-Object -Unique)
        if ($processIds.Count -ne 1) { $plan.blockers += "Event $($event.id): unresolved structured process ID."; continue }
        if ($processIds[0] -ne $Scope.sourceProcessId) { continue }
        if ($event.id -in $Baseline.eventIds) { continue }
        $resolved = @(Get-AdoEventEntity $event $source)
        if ($resolved.Count -ne 1 -or $event.actionId -match '\.(Delete|Remove)$') { $plan.blockers += "Event $($event.id): destructive, unsupported, or ambiguous live entity evidence."; continue }
        $key = $resolved[0].key
        if (-not $evidence.ContainsKey($key)) { $evidence[$key] = @() }
        $evidence[$key] += $event.id
    }
    if ($Audit.selectedEventIds) { $changes = @($changes | Where-Object { $evidence.ContainsKey($_.key) }) }
    foreach ($change in $changes) {
        if ($change.after -and -not $change.before -and -not $evidence.ContainsKey($change.key)) {
            $ancestor = $change.after.parent
            while ($ancestor) {
                if (-not $Baseline.snapshots[$Scope.sourceProcessId].entities.ContainsKey($ancestor) -and $evidence.ContainsKey($ancestor)) {
                    $evidence[$change.key] = @($evidence[$ancestor]); break
                }
                $ancestor = if ($source.entities.ContainsKey($ancestor)) { $source.entities[$ancestor].parent } else { '' }
            }
        }
        $matchingEvents = @($orderedEvents | Where-Object { $_.id -in $evidence[$change.key] })
        $actionIds = @($matchingEvents | ForEach-Object { $_.actionId } | Sort-Object -Unique)
        $plan.changes += @{ key = $change.key; before = $(if ($change.before) { $change.before.definition } else { $null }); after = $(if ($change.after) { $change.after.definition } else { $null }); evidence = @($evidence[$change.key]); actionIds = $actionIds }
        if (-not $evidence.ContainsKey($change.key)) { $plan.blockers += "$($change.key): source delta has no unambiguous audit evidence."; continue }
        $auditOrder = $eventOrder[$matchingEvents[-1].id]
        foreach ($targetId in $Scope.targetProcessIds) {
            try {
                $target = $Snapshots[$targetId]
                $priorTarget = $Baseline.snapshots[$targetId].entities[$change.key]
                $currentTarget = $target.entities[$change.key]
                if ($priorTarget -and (-not $currentTarget -or $priorTarget.identity -ne $currentTarget.identity)) { throw 'Child entity was removed or replaced since its verified baseline.' }
                if ($change.before -and -not $priorTarget -and -not $currentTarget) { throw 'Child absence was adopted as an existing difference; bootstrap creation requires a separate mapping decision.' }
                if ($change.before -and $change.after -and $priorTarget -and $currentTarget) {
                    foreach ($property in @(@($change.before.definition.Keys) + @($change.after.definition.Keys) | Sort-Object -Unique)) {
                        if ((Get-AdoHash $change.before.definition[$property]) -eq (Get-AdoHash $change.after.definition[$property])) { continue }
                        if ((Get-AdoHash $priorTarget.definition[$property]) -ne (Get-AdoHash $currentTarget.definition[$property]) -and
                            (Get-AdoHash $currentTarget.definition[$property]) -ne (Get-AdoHash $change.after.definition[$property])) { throw "Child edited '$property' since its own verified baseline." }
                    }
                }
                if ($change.after -and -not $change.before) {
                    $renamed = @($Baseline.snapshots[$Scope.sourceProcessId].entities.Values | Where-Object { $_.identity -eq $change.after.identity -and $_.category -eq $change.after.category -and $_.key -ne $change.key })
                    if ($renamed.Count) { throw 'Rename requires an explicit identity mapping; delete-and-create is blocked.' }
                }
                $operation = New-AdoOperation $change $target $GlobalFields
                if ($null -eq $operation) { $plan.noOps += @{ targetId = $targetId; key = $change.key; actionIds = $actionIds; evidence = @($evidence[$change.key]); auditOrder = $auditOrder }; continue }
                if ($operation.deferred) { $plan.deferred += @{ targetId = $targetId; key = $change.key; reason = $operation.reason; actionIds = $actionIds; evidence = @($evidence[$change.key]); auditOrder = $auditOrder }; continue }
                $operation.evidence = @($evidence[$change.key])
                $operation.actionIds = $actionIds
                $operation.auditOrder = $auditOrder
                $plan.operations += $operation
            }
            catch { $plan.blockers += "$targetId / $($change.key): $($_.Exception.Message)" }
        }
    }
    $plan.operations = @($plan.operations | Sort-Object auditOrder, rank, targetId, key)
    if ($plan.deferred.Count) {
        $firstDeferredOrder = ($plan.deferred | Measure-Object -Property auditOrder -Minimum).Minimum
        foreach ($operation in @($plan.operations | Where-Object { $_.auditOrder -gt $firstDeferredOrder })) {
            $plan.deferred += @{ targetId = $operation.targetId; key = $operation.key; reason = 'An earlier audit row needs its dependency verified first; later rows cannot overtake it.'; actionIds = $operation.actionIds; evidence = $operation.evidence; auditOrder = $operation.auditOrder }
        }
        $plan.operations = @($plan.operations | Where-Object { $_.auditOrder -le $firstDeferredOrder })
    }
    $plan.deferred = @($plan.deferred | Sort-Object auditOrder, targetId, key)
    $plan.noOps = @($plan.noOps | Sort-Object auditOrder, targetId, key)
    if ($plan.blockers.Count) { $plan.operations = @() }
    if (-not $plan.operations.Count -and $plan.deferred.Count -and -not $plan.blockers.Count) { $plan.blockers += 'Dependencies could not be resolved into an executable stage.' }
    return $plan
}

Export-ModuleMember -Function ConvertTo-AdoCanonical, Get-AdoHash, Copy-AdoObject, Select-AdoProperties, Get-AdoSnapshotHash, Assert-AdoScope, Get-AdoSnapshot, Get-AdoDelta, Get-AdoEventEntity, New-AdoOperation, New-AdoPlan