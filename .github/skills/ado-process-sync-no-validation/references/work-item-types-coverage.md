# Work Item Types REST API 7.1: audit-data coverage

Assessment date: 2026-11-10.

## Evidence and limits

This report compares the official API 7.1 schemas with the repository's current
audit-data handling and offline fixtures. No live Universal audit response was
provided or accessed for this assessment. There is no claim that every field is
present in the user's current first row, that credentials have the right
permissions, or that a live request has been executed.

Evidence inspected:

- [Normalized audit extraction](../../../../scripts/process-sync/AdoProcessApi.psm1):
  `Get-AdoAudit` copies only an explicit set of structured identifier strings.
- [Server-side audit cache](../../../../scripts/process-sync/AdoProcessApp.psm1):
  `auditCache` stores that normalized evidence; raw pages are stored separately.
- [Browser fixture](../../../../tests/process-sync.browser.spec.js):
  raw rows demonstrate action/timestamp/ProcessName, not complete WIT bodies.
  The fixture's write payload is a separate prepared-plan object, not audit data.
- [Backend fixtures](../../../../tests/AdoProcessSyncApp.Tests.ps1):
  audit rows carry source process and entity identifiers; source definitions and
  desired write values are separate mocked process data.

## What is actually available

| Value | Current source | Coverage |
| --- | --- | --- |
| Event ID, timestamp, actionId, correlationId | Normalized audit envelope | Retained |
| ProcessId, ProcessTypeId | Audit `data`, when present as strings | Source identifiers, not selected child IDs |
| WorkItemTypeId, WorkItemTypeRefName, WorkItemTypeReferenceName, WorkItemReferenceName | Audit `data`, when present as strings | Potential source identity; `WorkItemTypeId` is not proof of a reference name |
| WorkItemTypeName | Audit `data`, when present as a string | Potential Create `name` value |
| Field/state/rule/behavior/layout identifiers | Audit `data`, when present as strings | Other resource identities; not WIT definition values |
| organization | Connected app session or supplied configuration | Not guaranteed by an audit row |
| Child process IDs | Explicit app selection or supplied configuration | Not supplied by a Universal source event |
| Child-local witRefName | Supplied mapping or earlier child Create response | Not guaranteed by a source event |
| description, color, icon, isDisabled, inheritsFrom | Not copied by normalized audit extraction | Missing from the normalized event/cache field set |
| Additional raw `data` and `details` | Original response pages, if the service emitted them | Unknown for the user's live rows; not a guaranteed REST request body |

The displayed table's timestamp, actionId, details, category, and
categoryDisplayName are not sufficient to construct every write request. Display
names and prose descriptions do not establish target-local reference names or
exact new property values.

## Common request parameters

Base URL: `https://dev.azure.com/{organization}/_apis/`.

All five operations require `organization`, `processId`, and the query parameter
`api-version=7.1`. For a child request, `processId` is that selected child's GUID,
not the Universal process ID from the source event. Get, Update, and Delete also
require `witRefName`, the reference name in the addressed process.

The API tables explicitly mark those URI parameters required. The Create/Update
body tables list properties without marking every property required. Therefore,
this report does not label every body property mandatory. Supplying enough data
for an exact audited change is different from submitting a minimally accepted
request or relying on server defaults.

## Endpoint matrix

Routes below are relative to the base URL and include `?api-version=7.1`.

| Operation | Method and route | Documented body | Audit-only conclusion |
| --- | --- | --- | --- |
| Create | POST `work/processes/{processId}/workitemtypes` | name, description, color, icon, isDisabled, inheritsFrom | Not established: optional source name may exist, but definition values and destination context are not all in normalized audit evidence |
| Delete | DELETE `work/processes/{processId}/workitemtypes/{witRefName}` | None | Not established for a child: selected child ID and its local reference must come from configuration/mapping |
| Get | GET `work/processes/{processId}/workitemtypes/{witRefName}` | None | Conditional: possible with destination context and a known local reference; no write body needed |
| List | GET `work/processes/{processId}/workitemtypes` | None | Request-addressable from organization and selected child ID; event-specific data is unnecessary |
| Update | PATCH `work/processes/{processId}/workitemtypes/{witRefName}` | description, color, icon, isDisabled | Not established: exact new values and child-local reference are not supplied by the normalized audit field set |

Get/List optionally accept `$expand`; omitting it does not leave a required
parameter missing. These reads retrieve types; they do not themselves apply a
Create/Update/Delete audit action.

## Create field detail

| Field | Type | Can current audit evidence supply it? |
| --- | --- | --- |
| name | string | Only when `data.WorkItemTypeName` is supplied; not guaranteed for every event |
| description | string | Not retained in normalized evidence; raw live value uninspected |
| color | string | Not retained in normalized evidence; raw live value uninspected |
| icon | string | Not retained in normalized evidence; raw live value uninspected |
| isDisabled | boolean | Not retained in normalized evidence; extractor retains identifier strings, not this boolean |
| inheritsFrom | string | Not retained in normalized evidence; a source reference is not automatically this parent reference |

The response's `referenceName` is generated for the created type and belongs to
the addressed process. `referenceName`, `url`, and `customization` are not Create
body fields. The GET response property `inherits` and the Create body property
`inheritsFrom` have different names; copying a complete GET object is not request
preparation.

The request can only reproduce values that are actually available. Omitting
unknown fields or choosing defaults is not proof that the Universal change was
reproduced exactly. Microsoft documents a successful Create response and shows
HTTP 201 in the example; this assessment has not executed it.

## Update field detail

| Field | Type | Can current audit evidence supply its exact new value? |
| --- | --- | --- |
| description | string | Not from normalized evidence |
| color | string | Not from normalized evidence |
| icon | string | Not from normalized evidence |
| isDisabled | boolean | Not from normalized evidence |

An Update action ID indicates the operation family, not which property changed or
its new value. The documented Update body has no `name`, `referenceName`, or
`inheritsFrom`; an audit rename or inheritance change is not automatically an
equivalent PATCH through this endpoint. Explicit `null` values and omitted
properties are different request representations; missing audit values do not
establish that a null-valued write was requested.

## Delete, Get, and List detail

Delete/Get need a mapped reference name for the addressed child. A source-only
`ProcessId` plus `WorkItemTypeReferenceName` can address the source, not establish
an independently customized child's reference. An earlier child Create response
or a supplied mapping can provide the missing reference without another read.

Delete has no body. A deletion event also may no longer correspond to a source
type that can be retrieved. Delete being a documented endpoint does not imply
that the existing app or gateway permits it: both currently prohibit DELETE.

List requires no work item type name or reference. With organization, selected
child ID, and API version, its request parameters are available from application
context, independently of audit-row contents. Server permissions and response
success have not been tested against the live organization.

Get/List document the read scope `vso.work`. Create/Update/Delete document
`vso.work_write`; identity permissions and organization policies still apply.

## Conclusion

All five endpoint schemas were inspected. The available repository evidence does
not establish complete audit-only input for child Create or Update, or universal
availability of child-local references for Get/Delete. List is addressable with
existing application configuration. Get/Delete become addressable when the
child-local reference mapping is supplied. Create/Update need the actual body
values for the intended change from raw audit data that demonstrably contains
them, a supplied definition, or another data source.

A record-by-record assessment of the user's live Universal events remains
unverified because those rows were not supplied. Disabling comparison and
approval stages does not change this data-availability result.

## Official sources

- [Work Item Types overview](https://learn.microsoft.com/en-us/rest/api/azure/devops/processes/work-item-types?view=azure-devops-rest-7.1)
- [Create](https://learn.microsoft.com/en-us/rest/api/azure/devops/processes/work-item-types/create?view=azure-devops-rest-7.1)
- [Delete](https://learn.microsoft.com/en-us/rest/api/azure/devops/processes/work-item-types/delete?view=azure-devops-rest-7.1)
- [Get](https://learn.microsoft.com/en-us/rest/api/azure/devops/processes/work-item-types/get?view=azure-devops-rest-7.1)
- [List](https://learn.microsoft.com/en-us/rest/api/azure/devops/processes/work-item-types/list?view=azure-devops-rest-7.1)
- [Update](https://learn.microsoft.com/en-us/rest/api/azure/devops/processes/work-item-types/update?view=azure-devops-rest-7.1)