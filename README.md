# Azure DevOps Universal Template Synchronization

A local application for synchronizing supported changes from a **universal
Azure DevOps (ADO) process template** to explicitly selected **child process
templates** in the same organization. It helps maintain shared work item
definitions while preserving target-only customizations.

The app reads Azure DevOps Services audit events, resolves the relevant live
process definitions, and prepares a plan for review. Synchronization is one-way,
from the universal template to the selected children, and requires explicit
approval. No synchronization starts automatically.

## Synchronization Model

In this project, "template" means an Azure DevOps **inherited process**, not a
pipeline YAML template or an exported XML process template.

| Term | Meaning |
| --- | --- |
| Universal template | The inherited process selected as the source of shared customizations. |
| Child template | An explicitly selected inherited process receiving supported source changes. |
| System parent | The common system process from which both source and targets inherit. |
| Baseline | The approved local snapshot/checkpoint used to evaluate subsequent synchronization windows. |

"Universal" and "child" are synchronization roles, not extra Azure DevOps
inheritance levels. Children do not inherit directly from the universal process;
source and targets must share the same system parent. This app propagates
approved changes between those processes.

Synchronization covers supported work item types, fields, states, rules,
behaviors, and layouts. It is not a full-template clone, a two-way merge, or an
automatic repair of existing differences. **First-run approval adopts a baseline
only and makes no Azure DevOps writes.** Subsequent runs use selected audit
events and verified live definitions to prepare eligible changes.

## Local Application

### Requirements

| Requirement | Details |
| --- | --- |
| Operating system | Windows; run as your normal user, not as administrator. |
| PowerShell | **7.5 or later** (`pwsh`). Windows PowerShell 5.1 is not supported by this app. |
| PowerShell module | **PSDevOps**, installed in the PowerShell environment running the app; used for work item type reads and creation. |
| Browser | A modern browser, such as Microsoft Edge or Chrome. |
| Azure DevOps | An Entra-backed **Azure DevOps Services** organization with auditing already enabled, and network access to its process and audit APIs. |
| Process scope | An inherited source process and explicitly selected inherited targets with the same system parent. |
| Credentials | A short-lived reader PAT; a separate writer PAT is needed only when applying a write plan. See scopes and permissions below. |

Node.js, npm, GitHub Copilot, and a GitHub account are **not required to run
the local app**. Node.js and npm are needed only for browser tests.

### Run Locally

1. Install [PowerShell 7.5 or later](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows)
	if `pwsh` is unavailable. Open PowerShell 7 and check its version:

	```powershell
	$PSVersionTable.PSVersion
	```

2. In that PowerShell 7 session, install the work item type dependency for your
	user, then verify that it imports:

	```powershell
	Install-Module PSDevOps -Scope CurrentUser
	Import-Module PSDevOps -ErrorAction Stop
	Get-Command Get-ADOWorkItemType, New-ADOWorkItemType -Module PSDevOps
	```

	Installation needs access to an approved PowerShell module repository.
	Follow your organization's repository and execution policies; do not bypass
	them or run the app elevated.

3. From the repository root (the folder containing this README), start the app:

	```powershell
	pwsh -NoLogo -NoProfile -File .\scripts\Start-AdoProcessSyncApp.ps1
	```

4. Keep the terminal open. The launcher opens your browser and prints a
	one-time URL like `http://127.0.0.1:8765/#key=<generated-token>`.
	Use the **full printed URL**, including `#key=...`, to initialize the browser
	session. Do not open the HTML file directly or use a static file server:
	the PowerShell backend is required. Do not share the launch URL.

5. Connect with the organization slug and reader PAT, then follow
	**Credentials and workflow** below. Nothing synchronizes automatically;
	first-run approval adopts a baseline without writing to Azure DevOps.
	Stop the server with **Ctrl+C** in its terminal.

For manual browser launch or a different starting port:

```powershell
pwsh -NoLogo -NoProfile -File .\scripts\Start-AdoProcessSyncApp.ps1 -NoBrowser -Port 8766
```

| Launcher option | Default | Purpose |
| --- | --- | --- |
| `-Port` | `8765` | Starting port; checks up to 50 ports beginning with this value. Use the actual URL printed in the terminal. |
| `-NoBrowser` | Off | Prints the launch URL without opening a browser. |
| `-StoreRoot` | `%LOCALAPPDATA%\AdoProcessSync\web` | Overrides the private local state directory. Retain the same directory to reuse baselines and recovery journals. |

The launcher binds only to `127.0.0.1` and never takes over another server.
Do not expose this service through a tunnel, reverse proxy, shared machine,
or remote network interface.

### Local Startup Troubleshooting

| Symptom | Action |
| --- | --- |
| `pwsh` is not recognized or the version check fails | Install PowerShell 7.5+, reopen your terminal, and use `pwsh`, not `powershell.exe`. |
| PSDevOps is missing or cannot import | Run the dependency installation/import checks above in PowerShell 7, then restart the app. Use an organization-approved module source if installation is restricted. |
| Browser did not open | Open the full one-time URL printed in the launcher terminal. |
| Session/bootstrap request is rejected | Use the printed `127.0.0.1` host, not `localhost`. A consumed launch token cannot initialize a different browser session; restart the launcher for a new URL. |
| No available loopback listener | Try another starting port. If local listener permissions are blocked, ask your administrator to review policy; do not run the app elevated. |
| Azure DevOps rejects a request | Check network access, PAT expiry/scopes, identity permissions, and whether organization auditing is enabled. Keep PATs out of terminal commands and chat. |

### Credentials and workflow

1. Enter the organization **slug**, not its URL, and a short-lived reader PAT in
	the masked local input. Reader scopes: **Audit Log (Read)** and **Work Items
	(Read)**, with the identity's required organization/process read permissions.
2. Select the universal process and each child by name and displayed GUID.
	Project impact is accepted at final approval, not entered in Process Scope.
	The application does not infer that a process is unused or discover project assignments.
3. Choose an increasing UTC window within retained audit history (90 days).
	Choose **Read Audit**, then open **Raw Audit API Response**. Reading requires
	no children and makes no process comparisons or writes. Select child processes,
	then choose **Sync Childs** inside the modal to resolve supported changes from
	the displayed Universal audit events. There is no separate Preview Sync action.
	Incomplete pages, unresolved evidence, later source changes, conflicts, and
	unsupported operations block executable plans and show the reason in the modal.
4. **First run adopts a baseline only, with zero ADO writes.** Existing differences
	remain accepted drift. A different target set needs its own approved adoption.
	Subsequent windows must cover the last verified checkpoint; overlap is allowed.
5. Review audit evidence, source changes, exact target mappings and request bodies.
	The same modal shows the resolved plan and its exact SHA256. One confirmation
	checkbox approves that displayed plan, its mappings, and project impact; there
	is no hash to copy or separate mappings checkbox in the modal.
	**Confirm & Sync Childs** applies it; **Approve Baseline** only adopts the
	first-run baseline. Closing the modal clears entered approval and writer PAT.
	For a write plan, enter a **separate writer PAT** with **Work Items (Read &
	write)** and the required **Edit process** permission. Scopes do not grant
	permissions the identity lacks. Do not use Full access or paste PATs into chat.
6. Apply executes one operation at a time with fresh preconditions and read-back
	verification. Generated identifiers can require another preview and a new
	exact approval for the next stage. Only a fully verified run advances the
	baseline. A zero-operation sync preview is an idempotency check, not a drift
	repair tool.

Changes to required fields, defaults, state categories/order and rules affect
existing projects and work items. Validate against disposable inherited processes
before production use. Audits corroborate live changes; they cannot reconstruct
historical definitions or replay deleted/intermediate states.

### Supported boundaries

| Category | Eligible operations |
| --- | --- |
| Custom work item types | Create; update description, color or icon |
| Fields | Attach existing compatible global fields; supported local properties and additive non-shared string allowed values |
| States | Create custom states; safe color/order/category updates |
| Rules | Add enabled rules using supported field conditions and required/read-only/default/copy actions |
| Behaviors | Create from a system parent; add nondefault WIT associations |
| Layout | Add visible custom pages, groups and existing-field controls with target-local mappings |

This is deliberately narrower than all Azure DevOps UI operations. Renames,
deletions, disabling/hiding, shared field/picklist mutations, field type changes,
unsupported rule actions, rule/layout/behavior edits, backlog configuration,
system-owned changes and unresolved mappings are blocked. Target-only customizations
are preserved; competing child edits require manual resolution and a new preview.
ID-less controls on built-in Links/History pages and explicitly inherited controls
are retained as read-only snapshot metadata, not addressable field controls. They
remain covered by drift detection and cannot generate REST writes. Custom controls
without an API ID still block synchronization.

### Audit action routing

Modal synchronization sends the IDs shown in **Universal Audit Events**. The
server reuses the completed, session-cached audit read for the same organization,
source, and fixed time window. It does not re-read that window when **Sync Childs**
is clicked and never silently refetches missing cached evidence. A changed scope
or missing cache requires an explicit **Read Audit**. Only displayed IDs present
in that cache can provide evidence for the modal's operations.
Each operation, deferred change, and no-op identifies its originating audit actions.
Modal synchronization inventories only the listed work item types, entity
categories, and required parent/field mappings. WIT create/update rows read WIT
definitions, not layouts, rules, states, fields, or behaviors. A field, state,
rule, page, group, or control row scopes inventory to that entity and its needed
dependencies. Child-local references are resolved from the selected source type's
name; unlisted WIT definitions and unrelated layout branches are not inventoried.
Only entities resolved from displayed rows can generate changes. Unlisted source
differences are left alone, and unrelated prior baseline records are preserved.
The same selection is retained for apply, read-back, and uncertain-write recovery.

Relevant live definitions and a separate audit query after the selected end time
are still checked for newer changes to the selected entities or their parents
during preparation and before apply. Unrelated newer entity changes do not block
the selected rows. Exact-plan
confirmation and per-write safety checks remain required; this is not unchecked
audit-row replay. The cache is cleared on a new read, disconnect, cancel, or expiry.

For work item types, the application uses
[PSDevOps](https://github.com/StartAutomating/PSDevOps) for creation and collection/detail
reads (`New-ADOWorkItemType` and `Get-ADOWorkItemType`, API version `7.1`).
Each live snapshot retrieves individual type details by the process-local reference.
When selected events require a layout, a separate REST WIT detail read uses
`$expand=layout` and validates the returned reference and layout. It does not
call the standalone layout GET or substitute a guessed child reference.
Updates and other supported process changes continue to use the documented
[Azure DevOps REST API 7.1](https://learn.microsoft.com/en-us/rest/api/azure/devops/processes/work-item-types?view=azure-devops-rest-7.1):

| Audit action | Child operation |
| --- | --- |
| `Process.WorkItemType.Create` | `New-ADOWorkItemType -ProcessID {childProcessId}` for a missing custom type (collection POST) |
| `Process.WorkItemType.Update` | `PATCH work/processes/{childProcessId}/workItemTypes/{childWitRefName}` for supported description, color, or icon changes |
| Already matching child | No write |
| Delete, disable, unresolved identity, or unsupported change | Blocked; not silently converted into another action |

Payloads come from verified live definitions, not audit descriptions or copied
GET responses. Existing inherited-type properties can be updated without copying
inheritance metadata. Child-local references are used for child requests, and
target-only customizations are preserved. Several audit rows for one entity
corroborate its current net change; they are not replayed as historical transitions.
Executable operations follow **Universal Audit Events**, oldest to newest, across
all selected children. Equal timestamps preserve the displayed row order. A
combined entity change is placed at its latest contributing row so a later value
is not applied early. Dependency rank only orders operations from the same row.
If an earlier row needs a later approval stage, newer operations wait; a dependency
conflict blocks rather than silently changing the audit order.
First-run approval still adopts a baseline only and does not apply historical rows.
PSDevOps receives the session reader or writer PAT through `-PersonalAccessToken`
for the current call, so its first request sends an explicit Basic authorization
header rather than relying on a credential challenge. The adapter releases its
plaintext parameter reference and clears module credential caches afterward.
Module errors stop the run without an
automatic retry or a silent REST fallback.

### Console tracing

The PowerShell terminal running the launcher prints timestamped `[ADO Sync]`
JSON entries, including background jobs. Clicking **Sync Childs** traces the
selected scope, every selected audit event ID/action/time, live-definition API
calls, planned operations, blockers, deferred changes, and no-ops. Confirmation
also traces each attempted write and its verification or uncertain outcome.
Failures include the command or API route, exception types, script line, and HTTP
status when available. Structured service error types and integer error codes
are included when available. PATs, authorization headers, payloads, and raw exception
response text are not printed. These traces still contain internal process IDs
and metadata; keep the terminal output private. Restart the launcher to load changes.

### Local state and recovery

Session credentials remain in process memory, not browser storage or credential
files. Inputs are cleared after submission; the writer reference is released after
apply. Disconnect, shutdown, or the 30-minute session expiry releases credentials.
Managed browser/.NET memory cannot guarantee physical erasure. Expiry or cancel
prevents subsequent writes but cannot abort an already submitted ADO operation.
The app does not load the optional CLI's DPAPI credentials.

Plans, minimal audit evidence, snapshots, journals and results are stored under
`%LOCALAPPDATA%\AdoProcessSync\web`, restricted to the current Windows user and
SYSTEM. These contain internal process metadata, not PATs. Keep them private and
retain the baseline and journals when investigating failures.

There is **no transaction, automatic write retry, or rollback**. A failed operation
stops the run and preserves the prior baseline, even if some changes committed.
An uncertain journal blocks further apply until **Reconcile Uncertain Writes**
reads the target to establish the outcome. Reconciliation does not repeat a write;
rescan and approve a fresh plan afterward. Unexpected drift requires manual review.

### App verification

```powershell
pwsh -NoLogo -NoProfile -File .\tests\AdoProcessSync.Tests.ps1
pwsh -NoLogo -NoProfile -File .\tests\AdoProcessSyncApp.Tests.ps1
npm install
npx playwright install chromium
npm test
```

Node/npm are development-only requirements. Do not weaken corporate registry
policies if installation is denied; use approved local package artifacts instead.
Browser tests launch a temporary localhost server and use fake credentials/mocked
ADO responses. They also check real unauthenticated route rejection. Offline tests
do not establish live API compatibility, permissions, audit schema coverage, or
production readiness. Local icons are from Lucide; see the bundled
[license](web/process-sync/LICENSE).

To test with an already installed Microsoft Edge instead of downloading Chromium:

```powershell
$env:PLAYWRIGHT_CHANNEL = 'msedge'
npm test
```

