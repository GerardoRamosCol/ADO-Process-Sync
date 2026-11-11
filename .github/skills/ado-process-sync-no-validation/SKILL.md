---
name: ado-process-sync-no-validation
description: "Use when explicitly requested to prepare or submit Azure DevOps inherited-process changes from already loaded audit events without the ado-process-sync baseline, preflight, comparison, preview, approval-hash, or read-back verification stages. Includes Work Item Types REST API 7.1 field coverage and credential-free console tracing."
---

# Audit-led inherited-process synchronization without workflow validation

## Scope and relationship to ado-process-sync

This is the separately selectable variant of `ado-process-sync` for Azure DevOps
Services inherited-process changes using PowerShell or a local application.
It retains configuration, credential handling, audit input, endpoint preparation,
submission, and result reporting. It omits the original workflow's validation and
approval stages rather than modifying the original skill.

The following original workflow steps are absent:

- Organization/process preflight and same-system-parent comparisons.
- Audit-window, pagination-completeness, and audit-tail validation requests.
- Source/target inventory and repeated live-definition reads before writes.
- First-run baseline adoption, checkpoints, and three-way drift comparisons.
- Conflict detection and blanket destructive/shared-change blockers.
- Preview reports, plan SHA256 calculation, and exact-plan approval gates.
- Per-write live preconditions and post-write semantic verification.
- Reconciliation, idempotency scans, and verified-baseline advancement.

Loading this skill makes no API calls. Creating this file does not register a new
application button, change the existing server, or remove enforcement from
existing executables. The existing app, API module, and original REST gateway
still implement their own checks. This document is not a guard-free replacement
for those executables.

Audit records describe actions; they are not guaranteed request payloads or
historical before/after definitions. Removing workflow checks does not supply
missing parameters. API authentication, permissions, and server-side request
requirements still apply.

## 1. Collect non-secret configuration

Use the supplied organization slug, Universal source process ID, explicitly
selected child process IDs, and already loaded audit events. Retain the supplied
source-to-child work item type reference-name mapping and any supplied request
values. Configuration may live under `%LOCALAPPDATA%\AdoProcessSync` separately
from credentials.

The Universal process ID is the origin of the event. The process ID in a child
request URL is the selected child's ID. A custom work item type can have different
reference names in the Universal and child processes.

## 2. Establish credentials without exposing them

Use the host application's in-memory credentials or the existing local Windows
DPAPI credential setup. The original setup script is at
`.github/skills/ado-process-sync/scripts/Initialize-AdoProcessCredential.ps1`.
Credential enrollment is performed by the user in their own terminal or masked
application input, not through chat or an agent-run password prompt.

Work Item Types Get/List use `vso.work`; Create/Update/Delete use
`vso.work_write` and the identity's process permissions. Reading a new audit log
uses the audit permission, but consuming already loaded events makes no audit
request.

Keep PATs, authorization headers, cookies, CSRF/bootstrap values, and credential
files out of console logs, reports, source files, command arguments, and chat.
These credential protections remain in this variant; removal of workflow
validation is not removal of secret handling.

## 3. Consume the already loaded Universal audit events

Use the response pages or event list already supplied by the app or caller.
Response pages may put `decoratedAuditLogEntries` directly on the page or inside
`value`. Use the Universal events already selected for the supplied source.

Preserve the table's oldest-to-newest order. Timestamp ties preserve displayed
row order. In first-event mode, process only the first displayed row and the
explicitly selected children. This workflow does not refetch the audit window or
query an audit tail.

## 4. Determine the action and prepare each child's request

Use [Work Item Types endpoint and field coverage](./references/work-item-types-coverage.md)
for operation schemas and known audit-data gaps.

| Audit action or requested operation | Method | Route after `/_apis/` |
| --- | --- | --- |
| `Process.WorkItemType.Create` | POST | `work/processes/{childProcessId}/workitemtypes` |
| `Process.WorkItemType.Update` | PATCH | `work/processes/{childProcessId}/workitemtypes/{childWitRefName}` |
| `Process.WorkItemType.Delete` | DELETE | `work/processes/{childProcessId}/workitemtypes/{childWitRefName}` |
| Explicit Get operation | GET | `work/processes/{processId}/workitemtypes/{witRefName}` |
| Explicit List operation | GET | `work/processes/{processId}/workitemtypes` |

The base URL is `https://dev.azure.com/{organization}/_apis/`; the API version
query parameter is `api-version=7.1`. Get/List are data-retrieval operations, not
write actions inferred from a change row. They are not automatic prevalidation
steps in this variant.

Create body fields are `name`, `description`, `color`, `icon`, `isDisabled`, and
`inheritsFrom`. Update body fields are `description`, `color`, `icon`, and
`isDisabled`. Get/List/Delete have no documented request body. Get/List optionally
accept `$expand`.

Build the request from actual supplied values: structured event fields, supplied
definition values, and supplied child reference mappings. The event's source
reference is not automatically a child reference. A Create response's
`referenceName` provides the created child's reference for later requests.

Missing values are reported as missing inputs, not invented or extracted by
guessing from prose in `details`. This is request-data preparation, not a
baseline, preflight, source/target comparison, or approval stage. The other
process resources from the original skill (fields, states, rules, layout, and
behaviors) have their own operation schemas; the Work Item Types URL is not their
write endpoint.

## 5. Submit the prepared request

Use the local backend's authenticated REST client to submit each prepared request
in the supplied event order and retain the HTTP status and response. Use a
transport intended for this variant; the original `Invoke-AdoProcessRequest.ps1`
gateway and application do not become validation-free by selecting this skill.
This skill does not supply such an alternative transport implementation.

This workflow adds no baseline, preview, hash-approval, before-write inventory,
or after-write read-back step. The remote API can still reject the request.

For browser console tracing, emit the event ID, action ID, timestamp, organization,
source process ID, selected child process ID, child reference name, HTTP method,
endpoint, API version, supplied request-body fields, HTTP status, and a concise
result. Redact credential-like values and omit raw headers, raw audit pages,
actor/network metadata, and authentication error bodies.

## 6. Report submission results

Report which event and children were addressed, supplied versus missing inputs,
method/endpoint, HTTP status, returned child reference names, and any request
failure. Distinguish an operation that was prepared, one that was submitted, and
one accepted by the HTTP API.

There is no semantic verification, rollback, or verified checkpoint in this
workflow. Describe accepted requests as API responses, not as verified template
synchronization or reconstructed historical replay. State explicitly when no
request was submitted.