---
name: ado-process-sync
description: "Use to read Azure DevOps audit logs via REST and synchronize approved changes between inherited process templates in one organization. Includes Windows DPAPI PAT setup, explicit process mapping, audit pagination, dry-run planning, approval, and verification."
---

# Audit-led inherited-process synchronization

## Scope and limitations

Azure DevOps Services, Microsoft Entra-backed organization, inherited processes,
interactive Windows execution with PowerShell 7. No changes are made simply by
loading this skill. No organization or PAT is bundled.

Cover work item types, fields/allowed values, states, rules, layout, and
behaviors/backlogs where the documented REST API supports the particular change.
Coverage is not a promise that every UI operation has a safe REST equivalent.
Unsupported backlog changes, deletions, disabling/hiding, field type changes,
and shared/global resource mutations are blockers.

Audit records are not complete before/after process definitions. This workflow
reconciles an evidence-backed source delta with current targets; it does not replay
historical transitions or reconstruct missing history. First run requires an
approved adoption baseline before any existing source/target difference is applied.

## 1. Collect non-secret configuration

Use the host's structured question tool to collect:

- Organization slug (not a URL), one source process ID, explicit target IDs.
- Fixed inclusive UTC audit start/end window, within retained history.
- Feature selection, work item type/state/field/behavior mappings, baseline path.
- Which projects use each target and who accepts the impact on existing work items.

List processes with `GET work/processes` and let the user resolve display names
to IDs. Never select targets by wildcard, display-name similarity, or parent alone.
Save non-secret configuration outside the repository by default:

```json
{
  "organization": "your-org",
  "sourceProcessId": "11111111-1111-1111-1111-111111111111",
  "targetProcessIds": ["22222222-2222-2222-2222-222222222222"]
}
```

Every process must be inherited, and source/targets must have the same system
parent. A target may not be the source. Obtain the project-to-process mapping
through approved organization inventory or have the user confirm it; do not infer
that a process is unused. Block apply while impact is unknown.

## 2. Establish credentials without exposing them

Read [authentication and API reference](./references/auth-and-api.md).
Prefer Microsoft Entra short-lived credentials for a future unattended service.
For this user's selected interactive PAT workflow:

1. Use organization-scoped, short-lived PATs. Reader: **Audit Log (Read)** plus
   **Work Items (Read)**. Writer: **Work Items (Read & write)** only, with the
   necessary process-specific Edit process permission. No Full access PAT.
   PAT scopes do not grant permissions the identity does not already have.
2. Have the user run the following in their own local PowerShell 7 terminal.
   Never run credential enrollment as an agent tool: the password prompt must
   not enter a chat/tool transcript.

```powershell
& '.\.github\skills\ado-process-sync\scripts\Initialize-AdoProcessCredential.ps1' -Organization 'your-org' -Role Reader
# Only enroll a writer if applying is needed:
& '.\.github\skills\ado-process-sync\scripts\Initialize-AdoProcessCredential.ps1' -Organization 'your-org' -Role Writer
```

The script uses hidden input, Windows DPAPI (`Export-Clixml`), and a restricted
local directory. It does not store a plaintext PAT or add one to environment
variables. Reader and writer are separate files. Never read or attach them.
Organization name is not secret and belongs in the non-secret config, not the vault.

The agent may invoke [the REST gateway](./scripts/Invoke-AdoProcessRequest.ps1);
it loads credentials internally and does not print tokens or authorization headers.
The helper is not a full synchronization engine. The approval, semantic comparison,
live preconditions, and verification below remain the agent's responsibility.

## 3. Inventory and audit (read-only)

Example gateway requests, after creating the non-secret configuration:

```powershell
$gateway = '.\.github\skills\ado-process-sync\scripts\Invoke-AdoProcessRequest.ps1'
& $gateway -ConfigPath "$env:LOCALAPPDATA\AdoProcessSync\config.json" -ApiPath 'work/processes'
& $gateway -ConfigPath "$env:LOCALAPPDATA\AdoProcessSync\config.json" -ApiPath 'audit/auditlog' -Query @{
    startTime = '2026-10-26T00:00:00Z'
    endTime = '2026-10-27T00:00:00Z'
    batchSize = '200'
    skipAggregation = 'true'
}
```

- Auditing must already be enabled. Do not enable it or broaden permissions
  automatically. A 401/403/404 or missing history is a blocker, not an empty log.
- Query the organization audit endpoint with API `7.1-preview.1`; other
  supported process requests use `7.1`. The gateway selects versions/hosts.
- Query a fixed start/end on every page. Normalize the documented response
  wrapper (`value` when present); use `decoratedAuditLogEntries`, `hasMore`,
  and `continuationToken`. URL encoding is handled by the gateway's Query map.
  Continue until `hasMore` is false. Missing or repeated continuation tokens,
  invalid response shapes, and incomplete pages are errors.
- Deduplicate by event ID. Preserve minimal evidence: ID, UTC timestamp, actionId,
  correlationId, confirmed process ID, affected entity IDs. Do not persist
  entire raw audit responses, actor identities, IP addresses, or user agents.
  Gateway audit output strips top-level identity/network fields, but `data` and
  `details` may still be sensitive: extract only the necessary evidence.
- Discover relevant action IDs from actual returned events and the official
  event catalog; do not invent an event filter or rely on text containing a name.
  Bind events to the source GUID using structured data. If a GUID or entity cannot
  be resolved unambiguously, report unresolved evidence and block that change.
- Read live definitions for source and every target: work item types, fields,
  states, rules, layout, behaviors, and WIT-to-behavior links. Fetch global field
  and picklist metadata read-only when needed. Honor any documented pagination.
- Detect source changes during inventory with repeated canonical snapshots.
  Record the snapshot time: live state may be newer than the audit end.
  Do not claim to reconstruct state as of the audit end or silently include later
  changes; widen the window with approval or postpone until stable.

Persist minimal snapshots, plans, mappings, and checkpoints in a fresh run folder
under `%LOCALAPPDATA%\AdoProcessSync\runs\<UTC>-<GUID>`, never credential files.
Treat process metadata as internal business data. Keep runs local and access-restricted;
do not upload to public issues, external analysis services, or repositories.

## 4. Determine the source delta and map it to each target

- Compare against the last fully verified source baseline and per-target
  baseline. Compute canonical hashes by sorting object keys and semantically
  unordered arrays, while preserving meaningful layout/backlog order.
- On the first run, propose adoption of the current source baseline with no writes.
  Existing drift requires a separate, explicitly approved bootstrap comparison.
- Only propagate source changes corroborated by the audit window. Report source
  deltas without matching audit evidence and audit events without sufficient live
  data; do not silently treat either as successfully synchronized.
- Distinguish inherited, system, and custom definitions. Never copy read-only
  system properties or source-generated IDs into target writes.
- Use stable field reference names; map process-local WIT reference names,
  state IDs, rule IDs, behavior IDs, and layout IDs explicitly. Source-created
  custom WIT references may have different process prefixes in each target.
  Resolve newly created IDs from responses and re-read metadata.
- A rename is not delete-and-create. If stable identity/mapping is unavailable,
  stop for a mapping decision.
- Use a three-way comparison: prior source, current source, current target
  against its verified baseline. Preserve target-only entities and unrelated
  properties. Matching desired state is an idempotent no-op; conflicting edits
  require a human decision.
- Fields/picklists are organization-shared resources. Reuse an existing compatible
  field by reference name; block missing global fields, incompatible field types,
  and shared picklist edits. Process-local allowed values are only eligible when
  the documented field API supports them without changing a shared list.
- Required fields, defaults, validation rules, state categories/order, and behavior
  mappings affect projects/work items. Explain that impact before approval.
  Removing an allowed value, layout control, rule, state, or association is a
  destructive change even if the API implements it as PATCH/PUT: block it.
- Layout and rules require target-local identifier translation and preservation of
  target-only customizations. For backlogs, distinguish behavior definitions and
  WIT associations from unsupported backlog-level configuration; never mutate
  project/team boards as a substitute.

## 5. Produce and approve an exact plan

Write a preview report and JSON plan in the run folder. Include audit event IDs,
per-target mappings, ordered dependencies, old/new values, canonical source and
target snapshot hashes, live preconditions, expected verification, blockers,
project impact, and rollback limitations. Use empty `operations` when blocked.

The gateway accepts this execution subset (other evidence properties may coexist):

```json
{
  "organization": "your-org",
  "sourceProcessId": "11111111-1111-1111-1111-111111111111",
  "targetProcessIds": ["22222222-2222-2222-2222-222222222222"],
  "operations": [
    {
      "method": "POST",
      "path": "work/processes/22222222-2222-2222-2222-222222222222/workItemTypes",
      "body": {"name": "Approved example", "description": "Example only", "color": "009CCC", "icon": "icon_clipboard"}
    }
  ]
}
```

This is only a shape example, not authorization or a ready-to-run plan.
Payloads must come from the exact operation's current official schema, not copied
GET responses. The gateway rejects DELETE, global writes, unselected targets,
process-root changes, and query/path escapes. It cannot judge semantic safety.

Calculate `Get-FileHash -Algorithm SHA256` on the final plan. Show the hash,
targets, operation count, impacts, and blockers. Use a structured approval question.
Require explicit approval of that exact hash; approval of a general intention
is insufficient. Any plan edit invalidates approval. No approval means no writes.

## 6. Apply and verify

- Before every mutation, re-read the relevant source and target definitions and
  compare canonical hashes/preconditions to the approved plan. If unrelated earlier
  operations changed a snapshot, use the explicitly predicted post-state. Stop for
  any unpredicted change; do not silently regenerate/reapprove a plan.
- Check no unsupported, destructive, or unresolved changes slipped into the plan.
- Execute one dependency-ordered operation at a time:

```powershell
& $gateway -ConfigPath "$env:LOCALAPPDATA\AdoProcessSync\config.json" `
    -Apply -PlanFile 'C:\local-run\plan.json' -OperationIndex 0 `
    -ApprovedPlanSha256 '<explicitly-approved-64-character-hash>'
```

- Gateway checks plan integrity/scope, loads the writer only on apply, and verifies
  the live source/target are inherited with the same system parent.
- Check response and re-read the affected target. Verify semantic postconditions,
  ID mappings, and preservation of target-only configuration. Persist an operation
  journal after each verified step.
- Stop on first failure or drift. Do not retry POST/PATCH/PUT automatically after
  timeouts, 429, 5xx, or transport failure: first read the target to determine whether
  the operation committed. For GET throttling, honor Retry-After with bounded retry
  only if the transport exposes it; otherwise stop with an actionable diagnostic.
- APIs are not transactional across entities/targets. Report partial completion.
  Do not automatically compensate with deletions or claim rollback.
- Re-run a read-only comparison. Require zero unexplained in-scope drift and an
  idempotent preview (zero new writes). Advance the checkpoint only after all
  selected targets and operations are verified. Preserve the prior checkpoint on
  partial failure; journaled completed operations must be reconciled before resuming.
  Use a small overlapping audit window and event-ID deduplication to tolerate
  delayed events; monitor retention gaps and never silently skip them.

## Completion output

Report source/target IDs, audit UTC window and completeness, matched/unresolved
events, baseline/adoption status, approval hash, and per-target
planned/applied/verified/no-op/blocked/failed counts. Link local report and plan.
Explicitly say when no writes occurred. Never equate a successful HTTP response
with complete synchronization.
