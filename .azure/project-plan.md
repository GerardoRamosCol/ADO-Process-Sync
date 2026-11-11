# Project Plan

**Status**: Approved
**Approval**: User explicitly selected "Approve and build"; confirmed in implementation request on 2026-10-29. Local implementation and offline validation only; no live ADO calls or synchronization authorized.
**Created**: 2026-10-29
**Mode**: AUGMENT

---

## 1. Project Overview

**Goal**: Add Ado Process Sync, a local Windows HTML application for inspecting Azure DevOps inherited-process changes and explicitly approving supported synchronization to selected targets. Reuse the existing PowerShell REST gateway, but implement the missing reconciliation, approval, and verification engine. The project is designed so that every module is independently testable.

**App Type**: Static + API

**API Login**: No

**Mode**: AUGMENT

**Deployment Plan**: No deployment plan found. Local Windows execution only; no Azure provisioning, cloud storage, hosted service, deployment, or live Azure DevOps calls are authorized by this plan.

The two services are `process-sync-host` and `process-sync-ui`. The host serves the static UI and API on a single loopback origin. No separate frontend development server, database, Azure Functions, or background worker is required. Existing repository automation and tests remain intact.

Approval of this project plan authorizes scaffolding, not synchronization. Every future live apply requires a separate explicit approval of the exact operation plan. Offline fixtures are synthetic and never automatically become connection settings, target selections, or permission to write.

---

## 2. Local Loopback Host — Backend

| Component | Technology |
|-----------|------------|
| **Language** | C# (.NET) |
| **Framework** | ASP.NET Core Minimal API |
| **Runtime** | .NET 10, Windows target for DPAPI |
| **Package Manager** | dotnet (NuGet) |
| **Test Runner** | xUnit; retain existing PowerShell tests with Pester |
| **Mocking Library** | NSubstitute; Pester Mock for PowerShell |
| **Test Command** | `dotnet test tests/AdoProcessSync.Host.Tests/AdoProcessSync.Host.Tests.csproj` |
| **Orchestration** | docker-compose |

The orchestration value is plan metadata only. Windows DPAPI and the local PowerShell gateway run natively; do not generate or require containers for this application.

**Transport boundary**: Reuse `.github/skills/ado-process-sync/scripts/Invoke-AdoProcessRequest.ps1` through a bounded PowerShell 7 adapter. The gateway is not a reconciliation engine. Before implementation, inspect its exact request, credential, and response contracts and the existing credential enrollment path. Add only the narrow adapter capabilities required; do not duplicate or silently replace gateway safeguards.

Use interfaces for audit acquisition, process snapshots, project-impact enumeration, mappings, supported operation adapters, credential storage, journals, and clocks. Keep reconciliation pure and offline-testable. Launch the fixed gateway with `ProcessStartInfo.ArgumentList`, not a shell command string; allowlist routes and methods, cap request/output sizes and execution time, and terminate abandoned process trees. Never pass secrets in arguments or environment variables. Any encrypted-file credential handoff must be supported by the gateway contract and restricted to the current Windows user; otherwise stop and implement a reviewed secret-safe enrollment/transport boundary before integration.

**Connection and eligibility**:

- Ask for organization, source/universal process search name, explicit target search names, and a fixed inclusive UTC start/end window in the actual app. Resolve and confirm immutable GUIDs before planning; ambiguous or duplicate names block selection.
- Source and targets must be inherited processes in the same organization with the same system parent. A child is an explicitly selected sibling target, not a nested inherited process. Never infer all targets from a name, relationship, or project membership.
- Discover all affected projects, permissions, and relevant process dependencies with complete pagination. Unknown project impact blocks apply. Do not broaden permissions to overcome a blocker.
- Read every audit page for the frozen UTC window, honor continuation tokens, deduplicate boundary events, and retain completion evidence. Bind relevant events to the resolved source GUID; timestamps or display names alone cannot authorize an operation.
- Audit is evidence, not replayable process history. Missing retention coverage, incomplete pagination, unresolved event semantics, or unstable snapshots blocks write planning. Where API responses cannot establish coverage, require an explicit blocker rather than treating an empty audit result as proof.

**Baseline and reconciliation**:

1. Read source and target state to stable canonical snapshots, excluding volatile metadata but retaining all semantically relevant identifiers, values, and ordering. Use versioned canonical serialization and deterministic SHA256 fingerprints. Re-read until stable within a bounded attempt budget; instability is a blocker.
2. On first run, explicitly adopt a baseline without ADO writes. Record source and each selected target independently; show existing differences but do not convert them to automatic repairs. Existing drift requires a separate, explicitly approved bootstrap plan with complete current-state evidence, impact, mappings, and supported-operation checks.
3. Keep explicit source-to-target local-ID mappings scoped to organization, process pair, and entity type. Never copy process-local IDs or assume display-name equality proves identity. Missing, ambiguous, stale, or incompatible mappings block dependent operations.
4. Perform three-way reconciliation using the last verified source and target baselines and current snapshots. Preserve target-only customizations. Distinguish unchanged values, source-only changes, target-only changes, compatible identical edits, and true conflicts. Never overwrite target edits or infer destructive remediation.
5. Match every incremental candidate to source-GUID-bound audit evidence within the completed window. Build deterministic ordered operations with dependencies, target GUID, entity mapping, before/after semantics, live preconditions, impact, evidence references, and a supported adapter/version. Suppress unsupported candidates with explicit blockers.

**Supported operation contract**: Start with a conservative allowlist of additive process-scoped work-item-type state additions and additive associations of already-existing organization fields to a target work-item type, only when gateway/API contracts, inherited ownership, field compatibility, dependencies, and semantic readback support them. These are candidates, not a promise of API support: leave an adapter disabled until offline contract tests and a separately authorized disposable-target acceptance test demonstrate it. Block deletes, renames, destructive property changes, shared/global field or picklist mutation, rules, layouts, permissions, and all unknown operation families. Do not create global objects to satisfy a process-local change.

**Approval and apply**:

- Freeze the complete plan, organization/source/target GUIDs, window, baseline and snapshot hashes, mappings, operations and order, impact acknowledgments, blocker state, and schema/adapter versions in a canonical SHA256 digest. The server recomputes it; never trust a submitted digest alone.
- Approval records reference that immutable digest and current launch session, expire after a bounded lifetime, and are one-use. Any changed data, mappings, targets, impact, or plan content invalidates approval. Blocked plans cannot be approved or applied. A bootstrap approval is distinct from incremental approval.
- Load the separate writer credential only after valid approval and immediately before apply. Serialize applies and baseline mutations for the affected organization/processes across app instances using an OS-level lock plus durable journal state.
- Before every operation, re-read live source/target dependencies and check approved preconditions. Stop on drift or failure. No unchecked time-of-check/time-of-use assumption: when the remote API lacks conditional writes, document the residual concurrency risk and require a maintenance window; do not promise atomic compare-and-swap.
- Write durable intent before a remote mutation; record the response and semantic readback afterward. An HTTP success is not verification. An interrupted or timed-out write has an unknown outcome until live state is reconciled; do not automatically repeat it. Bounded retries are allowed only for safe reads, honoring rate limits and the fixed window.
- Stop subsequent work, including other targets, after the first failure or uncertain result. Preserve earlier verified successes and report partial completion. No automatic rollback or transactional all-target guarantee. Recovery requires readback and a newly approved plan for remaining operations.
- Advance baselines/checkpoints only after all selected targets verify and a fresh idempotent preview is empty for supported synchronized source changes. Preserved target-only customizations remain visible but are not proposed operations. Baseline adoption records no completed synchronization. No checkpoint advance on partial success or unresolved blockers.

**Local security and persistence**:

- Bind only to an OS-assigned `127.0.0.1` port; validate the exact Host and port, deny proxy/forwarded-host trust, and reject cross-origin requests. No wildcard interfaces or permissive CORS. Require strict Origin checks for mutations and per-launch authorization plus anti-CSRF checks on privileged requests; test DNS-rebinding and hostile-webpage scenarios.
- Bootstrap the launch session through a cryptographically random, single-use, short-lived launch capability delivered only to the user's local browser, never logs or reports. Exchange it for an HttpOnly, SameSite=Strict session cookie, clear it from the browser location, and require a separate in-memory anti-CSRF value. Reject missing/foreign origins on API mutations. Revisit loopback HTTP limitations during security validation; no network exposure is supported.
- The user enters separate short-lived reader/writer PATs only in local password fields. Clear inputs immediately after enrollment; never return a PAT to the frontend. A hardened same-origin enrollment adapter persists only current-user Windows DPAPI ciphertext with restricted ACLs and atomic writes. Do not collect secrets through chat, requirements forms, command lines, environment variables, browser storage, fixtures, telemetry, or logs. Avoid request-body logging and redact exception/PowerShell output before reporting.
- Store durable baselines, minimal redacted evidence, immutable plans, approvals, and journals under `%LOCALAPPDATA%/AdoProcessSync`, outside the repository. Credentials occupy a separate directory. Restrict ACLs to the current user, refuse reparse-point/path traversal escapes, cap disk usage and retention, and fail closed on corrupt/incompatible state. Hashing is not tamper-proof against the same Windows account; privileged malware is outside the threat model.
- Restrict outbound requests to HTTPS fixed Microsoft ADO/audit hosts, validated organization paths, and known API routes. Disable redirects; validate any server-provided continuation target rather than following arbitrary URLs. Never accept user-supplied gateway URLs.
- Serve bundled local assets with a restrictive CSP, `frame-ancestors 'none'`, no remote scripts/fonts, `nosniff`, no-referrer, and no-store for sensitive responses. Render all process metadata and errors as text, never raw HTML. Health/status responses contain no secrets or raw gateway output. No telemetry or persisted raw audit payloads, actor identities, or network identities.

**Verification gates**: Unit-test canonicalization, mapping isolation, three-way cases, evidence binding, retention/pagination failures, stable snapshots, and baseline adoption/bootstrap separation. Test approval tampering/replay/expiry, per-operation drift, single-flight locking, unknown write outcome recovery, partial failures, journal crash recovery, semantic readback, and no checkpoint advance until all targets verify and idempotency is empty. Adapter tests must use bounded sanitized fixtures, never credentials. Retain `tests/AdoProcessSync.Tests.ps1`; add focused gateway/enrollment contract regressions there where appropriate. Live validation is opt-in against explicitly approved disposable inherited targets, using a maintenance window and documented unsupported cases; it is not authorized by planning or scaffolding.

---

## 3. Local HTML Process-Sync UI — Frontend

| Component | Technology |
|-----------|------------|
| **Language** | JavaScript |
| **Framework** | Plain HTML + Pico.css |
| **Runtime** | Browser ES modules; Node.js for development tests only |
| **Package Manager** | npm, frontend-scoped manifest and lockfile |
| **Test Runner** | Vitest for UI logic; Playwright for browser/security flows |
| **Mocking Library** | vi.mock; Playwright route fixtures |
| **Test Command** | `npm --prefix apps/ado-process-sync/web test` |

Serve native semantic forms, tables, dialogs, and locally bundled Pico.css and Lucide icons through the host. No CDN and no frontend build requirement for ordinary startup. Scope test tooling to the new app; do not replace repository-wide package or build conventions.

Connection setup collects organization and reader/writer credentials, confirms credential status without displaying secret values, resolves source and explicitly selected targets, displays project impact, and freezes UTC endpoints. Baseline adoption is explicitly read-only toward ADO.

Review shows evidence completeness, GUID-confirmed mappings, source/base/target comparisons, target-only customizations, conflicts, excluded unsupported operations, and impacted projects. An immutable plan detail displays its full digest and exact operations. Approve and apply are separate commands; both are disabled while blocked, incomplete, stale, or baseline-only. Confirm the exact approved plan and targets, never a generic "sync everything" command.

Results show per-target/per-operation state, verified readback, blockers, partial successes, unknown outcomes, and checkpoint status. Closing or cancelling a browser request does not imply remote rollback. Retry controls regenerate/reconcile; never silently repeat a write. Redacted report downloads exclude credentials and raw audit responses.

Every data-bearing screen implements loading, empty, error, and populated states, keyboard navigation, visible focus, accessible labels, and narrow-screen layouts. Offline sample records belong only to test/mock mode; live mode must never fall back to successful mock responses. Browser tests cover secret-field clearing, no browser-secret storage, escaped metadata, malicious origins/Host headers, CSRF, missing launch session, disabled blocked approval, hash changes, and accessible desktop/mobile workflows.

---

## 4. Services Required

| Azure Service | Role in App | Environment Variable | Default Value (Local) | Classification |
|---------------|-------------|----------------------|-----------------------|----------------|
| No provisioned Azure resource | Native ASP.NET Core host serves UI and API | None required | Loopback only, OS-assigned port | Essential |
| Azure DevOps REST and audit APIs (external dependency) | Process discovery, impact, evidence, approved mutation, verification | None; app enrollment and non-secret settings | Unconfigured; explicit connection required | Essential for live operations |
| Protected local files | Baselines, redacted evidence, plans, approvals, journals | Built-in Windows LOCALAPPDATA location | `%LOCALAPPDATA%/AdoProcessSync` | Essential |
| Windows DPAPI | Separate current-user encrypted reader/writer credential storage | None | Current Windows user | Essential for live operations |

No database, Blob Storage, queue, cache, storage account, Application Insights, Azure Functions, or cloud resource is selected. External API failure leaves offline reports available but blocks live preview/apply; never report simulated success. Storage or credential failure blocks dependent actions. No enhancement services are planned.

---

## 5. Prerequisites

Inventory performed locally on 2026-10-29 without installation, provisioning, or ADO access. Installed means positively detected; unknown requires user confirmation before the relevant implementation/test gate.

### Run

| Tool | Service(s) | Installed | Version |
|------|------------|-----------|---------|
| .NET SDK | process-sync-host | ✅ | 10.0.403 |
| ASP.NET Core Runtime | process-sync-host | ✅ | 10.0.14 |
| PowerShell | process-sync-host | ✅ | 7.6.9 |
| Node.js | process-sync-ui | ✅ | 26.12.1; development tests only |
| npm | process-sync-ui | ✅ | 11.20.0; local asset/test dependency setup |
| Pester | process-sync-host | ❓ | 3.4.0 detected; planned 5.x test compatibility unconfirmed |

### Debug

| Tool | Service(s) | Installed | Version |
|------|------------|-----------|---------|
| Chrome | process-sync-ui | ✅ | 156.0.8078.48; use chrome debug adapter |

Verify Pester 5.x availability before claiming the PowerShell regression gate passes. No container/emulator tooling or Azure Functions extension is required. Playwright test packages and a compatible browser build must be restored during authorized implementation; system Chrome detection alone does not establish Playwright readiness. Never install prerequisites during planning.

---

## 6. Design System & UI

**Component Library**: Pico.css
**Style Direction**: Compact, light operational console with unframed page sections, dense evidence tables, emerald action accents, violet evidence highlights, and explicit semantic warnings. Avoid marketing heroes, decorative cards, nested panels, and dashboards of invented metrics; use 4px control corners and restrained elevation for dialogs only.
**Typography**: Segoe UI Variable, Segoe UI, sans-serif; fixed 14px body and 22px page headings, zero letter spacing. Bundle no remote font.

### Color Palette

| Token | Hex | Usage |
|-------|-----|-------|
| `primary` | `#146447` | Connection actions, selected workflow tab, eligible plan approval |
| `accent` | `#7351A3` | Audit evidence references and mapping emphasis, not full-page fills |
| `surface` | `#F5F7F6` | Local review workspace with white table and input surfaces |
| `text` | `#202823` | Process names, operation diffs, and confirmation text |
| `muted` | `#59665E` | UTC timestamps, GUID labels, checkpoint metadata |
| `border` | `#C9D3CD` | Evidence rows, form controls, and workflow dividers |

Use separate accessible success, warning, and danger tokens with text/icon labels; color never carries status alone. Native password fields and checkboxes, select menus for candidates, tabs for views, and icon buttons with accessible names/tooltips for refresh and report download. Stack forms and wrap identifiers on mobile; give dense tables labeled horizontal scroll, not page-wide overflow. Respect reduced motion.

### Pages

| Page | Route | Purpose | Layout |
|------|-------|---------|--------|
| Connection & Scope | `/` | Enroll credentials, resolve GUIDs, select explicit targets and UTC window, adopt baseline | `header + nav + main + form + table + action-bar` |
| Evidence & Approval | `/review` | Inspect evidence, mappings, project impact, conflicts, and immutable operation approval | `header + nav + main + tabs + table + action-bar + modal` |
| Verification & History | `/runs` | Read target verification, partial outcomes, recovery blockers, and checkpoint state | `header + nav + main + table + tabs + action-bar` |

### Sample Content

All records below are synthetic design/test fixtures, not a discovered organization or authorization. The shipped live app starts unconfigured. Sample identifiers are distinct fixture GUIDs; never resolve these display names automatically. No PAT values appear in previews or fixtures.

Connection & Scope - form: Organization `contoso-process-lab` (fixture only); source `Universal Agile`; reader PAT empty; writer PAT empty; UTC start `2026-10-28T00:00:00Z`; inclusive UTC end `2026-10-28T23:59:59Z`. Preview depicts an empty credential validation state and a loading skeleton for project-impact discovery; baseline adoption is the only eligible first-run action.

| Process | Role | System Parent | Project Impact | State |
|---------|------|---------------|----------------|-------|
| Universal Agile | Source | Agile | Platform Standards | Resolved |
| Payments Agile | Explicit target | Agile | Payments API, Payment Operations | Selected |
| Fulfillment Agile | Explicit target | Agile | Warehouse Portal | Selected |

Evidence & Approval - populated review with three-way comparison; inline error banner `Audit continuation incomplete; approval blocked` and a read-only retry action. The disabled approval dialog shows full digest, exact source/target GUIDs, UTC window, impacted projects, operation count, and blocker acknowledgment. Display a complete synthetic 64-character digest, never an abbreviated-only approval reference.

| Entity | Source Delta | Payments Agile | Fulfillment Agile | Decision |
|--------|--------------|----------------|-------------------|----------|
| Bug / Ready for QA | Add process-local state | Missing | Missing | Candidate; evidence incomplete |
| User Story / Custom.ReleaseTrain | Associate existing compatible field | Already associated | Missing | Candidate; mapping review |
| Bug / Custom.TargetNotes | Unchanged source | Target-only customization | No change | Preserve target value |
| Bug / Custom.PriorityHint | Source changed label | Target changed label | Unchanged | Conflict; blocked |

Verification & History - historical run `run-20261028-01` with three operation outcomes; this is a partial-failure fixture distinct from the currently blocked review above. An empty `Completed checkpoints` tab shows `No verified checkpoint` and a `Review remaining operations` action. Export only a redacted report.

| Target | Operation | Outcome | Checkpoint |
|--------|-----------|---------|------------|
| Payments Agile | Add Ready for QA state | Semantically verified | Not advanced |
| Fulfillment Agile | Associate Custom.ReleaseTrain | Unknown write outcome; readback required | Not advanced |
| Fulfillment Agile | Add Ready for QA state | Not attempted after stop | Not advanced |

Preview state assignment: Connection & Scope depicts loading; Evidence & Approval depicts inline error; Verification & History depicts empty checkpoints. Each also includes its populated records. Planning previews are static and secret-free. Scaffold mock-state switching is development-only and removed when integrating live data; never override security or apply behavior through UI sample-state controls.

---

## 7. Project Structure

```text
.azure/
  requirements.json                         confirmed inputs, unchanged
  project-plan.md                           this plan, awaiting approval
  .preview-temp/                            transient static visual specification
apps/ado-process-sync/
  host/
    AdoProcessSync.Host.csproj               Windows .NET 10 host
    Program.cs                              loopback startup and composition
    Api/                                    validated endpoint contracts
    Engine/                                 pure reconciliation and canonical plans
    Adapters/                               bounded gateway and operation adapters
    Security/                               launch session, CSRF, DPAPI enrollment
    Storage/                                restricted files, atomic journals, locks
  web/
    package.json                            scoped npm tests and local UI assets
    package-lock.json
    index.html                              native HTML application shell
    js/                                     pages, client, text-only rendering
    css/                                    Pico theme and responsive layout
    vendor/                                 licensed local Pico.css/Lucide assets
    tests/                                  UI logic and browser/security tests
  README.md                                 local setup, scope, recovery, acceptance
tests/
  AdoProcessSync.Tests.ps1                   preserve; extend nearby gateway tests
  AdoProcessSync.Host.Tests/                 focused xUnit/adapter/security tests
.github/skills/ado-process-sync/
  scripts/Invoke-AdoProcessRequest.ps1       existing gateway; reuse, do not replace
```

These are planned paths, not files created during planning. Serve `web` from a fixed physical provider/content root with an explicit publish asset list; do not expose the repository or local evidence folders as static files. No database migrations or seed data. Keep API DTOs and validation authoritative in the host; frontend consumes the documented JSON contract instead of duplicating engine rules. Preserve existing unrelated tests and skill files.

---

## 8. Route Definitions

All routes below are loopback-only. API state changes require the launch session, exact-origin validation, and anti-CSRF checks. Limits, GUID validation, bounded UTC windows, and typed error codes apply server-side. The host never accepts arbitrary file paths, PowerShell commands, gateway hosts, or operation bodies from the browser for execution. Resource identifiers refer only to server-owned restricted records.

| # | Method | Path | Description | Request Body | Response Body | Status Codes |
|---|--------|------|-------------|--------------|---------------|--------------|
| 1 | GET | `/api/health` | Minimal local health, no ADO probe | None | `{status, services}` | 200, 503 |
| 2 | POST | `/api/session` | Consume single-use launch capability | `{capability}` | `{csrf, expiresAt}` plus session cookie | 200, 403, 409 |
| 3 | POST | `/api/credentials` | Separate reader/writer DPAPI enrollment; never echo secret | `{role, pat}` | `{role, enrolled}` | 201, 403, 422, 503 |
| 4 | GET | `/api/credentials/status` | Credential presence only | None | `{readerEnrolled, writerEnrolled}` | 200, 403 |
| 5 | DELETE | `/api/credentials/{role}` | Clear a selected credential and dependent approvals | None | None | 204, 403, 409 |
| 6 | POST | `/api/discovery` | Explicit read-only connection/process/impact discovery | `{organization, sourceName, targetNames}` | `{discoveryId, sourceCandidates, targetCandidates, projects, blockers}` | 200, 403, 422, 502, 503 |
| 7 | POST | `/api/scopes` | Confirm resolved GUIDs, impact, fixed inclusive UTC window | `{discoveryId, sourceId, targetIds, startUtc, endUtc, impactAcknowledged}` | `{scopeId, blockers}` | 201, 403, 409, 422 |
| 8 | POST | `/api/scopes/{scopeId}/baseline` | Adopt stable first-run snapshots; no ADO mutation | `{acknowledgeBaselineOnly}` | `{baselineId, hashes, existingDrift, blockers}` | 201, 403, 409, 422, 502 |
| 9 | PUT | `/api/scopes/{scopeId}/mappings` | Explicit versioned local entity mappings; invalidates old plans | `{mappingVersion, mappings}` | `{mappingVersion, blockers}` | 200, 403, 409, 422 |
| 10 | POST | `/api/plans` | Read-only audit/snapshot acquisition and reconciliation | `{scopeId, mode: incremental-or-bootstrap}` | `{planId, digest, evidence, impact, comparisons, operations, blockers}` | 201, 403, 409, 422, 502 |
| 11 | GET | `/api/plans/{planId}` | Inspect frozen redacted server-owned plan | None | `{planId, digest, scope, evidence, mappings, operations, blockers}` | 200, 403, 404 |
| 12 | POST | `/api/plans/{planId}/approvals` | Approve exact unblocked digest and explicit targets | `{digest, targetIds, impactAcknowledged, approvalKind}` | `{approvalId, digest, expiresAt}` | 201, 403, 409, 422 |
| 13 | POST | `/api/plans/{planId}/apply` | Consume approval; durable single-flight execution | `{approvalId, digest}` | `{runId, status}` | 202, 403, 409, 422, 503 |
| 14 | GET | `/api/runs` | List restricted local redacted run summaries | None | `{runs, nextCursor}` | 200, 403 |
| 15 | GET | `/api/runs/{runId}` | Observe operation/target verification and checkpoint status | None | `{runId, status, targets, operations, blockers, checkpoint}` | 200, 403, 404 |
| 16 | POST | `/api/runs/{runId}/reconcile` | Readback unknown outcomes; never reapply automatically | None | `{runId, outcomes, remainingOperations, requiresNewApproval}` | 200, 403, 409, 502 |
| 17 | GET | `/api/runs/{runId}/report` | Download bounded redacted report | None | Redacted JSON report | 200, 403, 404 |

Error contract: `{ "error": { "code": "CONFLICT", "message": "Approved plan is stale", "details": null } }`. Use 400 for malformed requests, 403 for denied session/origin/permission checks, 404 for absent resources, 409 for drift/replay/invalid state, 422 for typed validation failures, 429 for throttling, 502/503 for sanitized dependency failure, and 500 for sanitized unexpected failure. No stack traces, PATs, raw gateway stderr, or raw audit payloads in errors. Use bounded asynchronous acquisition with cancellation/status reporting if discovery/planning duration exceeds interactive request limits; cancellation cannot erase a remote mutation already dispatched.

---

## 9. Next Steps

1. Review the project plan and embedded static UI preview. Explicit plan approval is required before invoking **azure-project-scaffold**. Keep status Planning until that approval; create no app code, run no app server, and make no live ADO calls during planning.
2. After approval, **azure-project-scaffold** implements the local host, static UI, credential enrollment, engine contracts, conservative adapters, fixtures, and focused tests. Inspect existing gateway/enrollment/test contracts first; unsupported remote capabilities stay disabled. No ADO write is authorized by scaffolding.
3. **azure-project-integrate** wires UI to the local real backend and gateway using offline fixtures first; removes mock success paths and development state overrides; performs no database migrations and no live ADO calls without separate permission.
4. Validate offline xUnit, existing/focused Pester, Vitest, and browser/security gates. Verify desktop/mobile rendering, launch security, redaction, baseline adoption, conflict handling, exact hash approval, partial-failure recovery, semantic verification, and empty idempotent preview. Document local startup/shutdown, credential removal, restricted persistence, evidence limits, unsupported operations, concurrency limits, and disposable-target acceptance procedure.
5. Use **azure-debug-plan** and **azure-debug-generate** only when local debug artifacts are requested, with native Windows processes and no Docker emulators. Deploy is out of scope; do not invoke **azure-deploy**. Any disposable-target live acceptance or actual synchronization requires separate explicit authorization and operation-plan approval.