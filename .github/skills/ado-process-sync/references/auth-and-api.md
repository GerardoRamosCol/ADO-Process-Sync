# Authentication, storage, and API reference

## Credential decision

Microsoft recommends Microsoft Entra tokens over PATs where available. A
production unattended implementation should use a narrowly authorized service
identity and short-lived tokens, not a long-lived personal administrator PAT.
This skill implements the selected local Windows PAT option, not Actions or
service-identity authentication.

Use two short-lived, organization-scoped PATs:

| Role | PAT scopes | Identity permissions |
| --- | --- | --- |
| Reader | `vso.auditlog`, `vso.work` | View audit log; permission to read source/target processes |
| Writer | `vso.work_write` | Read metadata and Edit process on the selected targets |

Audit availability requires an Entra-backed Services organization and enabled
auditing. Prefer delegated View audit log permission rather than collection
administrator membership. PAT creation policies may prevent these scopes;
do not work around the organization's policy.

## Local Windows DPAPI storage

Run setup directly in your own PowerShell 7 terminal, without transcription,
screen recording, or shell debugging. The setup prompt uses `Read-Host
-AsSecureString`, so the PAT is not a command argument or shell history entry.

Files are stored in
`%LOCALAPPDATA%\AdoProcessSync\credentials\<org>-reader.clixml` and
`<org>-writer.clixml`. The directory grants access only to the current Windows
user and SYSTEM. `Export-Clixml` encrypts the credential password with DPAPI,
bound to the same Windows account and computer. Never move these files into
the workspace, cloud sync, reports, attachments, or Git.

DPAPI is not protection from malicious code running as your Windows user,
administrator compromise, or a compromised agent allowed to run arbitrary code.
Instruction-based approval is not an OS security boundary. The gateway validates
scope/hash but cannot authenticate who approved a hash or interpret destructive
semantics. Use host tool approvals and a non-production target first.
Credentials will necessarily exist briefly in the HTTP client's process memory.

Do not pass a PAT via chat, `ask_user`, environment variables, CLI arguments,
URLs, plaintext JSON, `.env`, or generated authentication headers. Do not inspect
the encrypted files through agent tools. Never log HTTP headers or raw auth errors.
API responses themselves can contain sensitive organization metadata.

Use `-Replace` with the setup script to rotate a credential. Revoke the old PAT
in Azure DevOps first or immediately after successful rotation. Deleting the
specific local credential file does not revoke a PAT. Remove expired local
credential files explicitly; do not recursively clear a user directory.

The org slug and process IDs are non-secret. Keep them in a separate config
under `%LOCALAPPDATA%\AdoProcessSync\config.json`; share a sanitized example only.

## REST endpoints

All authenticated calls use HTTPS, fixed Microsoft hosts, no redirects.
No project-scoped URL is substituted for organization process APIs.

| Purpose | Host and route | Version |
| --- | --- | --- |
| Audit pages | `https://auditservice.dev.azure.com/{org}/_apis/audit/auditlog` | `7.1-preview.1` |
| Process inventory | `https://dev.azure.com/{org}/_apis/work/processes` | `7.1` |
| Process metadata | `.../work/processes/{processId}` | `7.1` |
| WITs | `.../work/processes/{processId}/workItemTypes` | `7.1` |
| Fields, states, rules, layout | `.../work/processes/{processId}/workItemTypes/{witRefName}/{resource}` | Check exact operation docs |
| Behaviors | `.../work/processes/{processId}/behaviors` | Check exact operation docs |
| WIT behavior associations | `.../work/processes/{processId}/workItemTypes/{witRefName}/behaviors` | Check exact operation docs |
| Global field metadata (GET only) | `.../wit/fields` | `7.1` |
| Picklist metadata (GET only) | `.../work/processes/lists` | `7.1` |

The gateway pins 7.1 for process APIs. If an operation is unavailable in that
version, report a blocker; do not silently use undocumented/private endpoints.
Check the documented operation method, body, response, and inherited limitations
before adding it to a plan. Backlog UI operations are not universally writable.

Audit retention is currently 90 days. The query sample uses a `value` wrapper;
handle that explicitly and validate `hasMore`/`continuationToken` on every page.
No server-side process-ID filter is documented on the audit query endpoint.

## Offline validation

From the workspace root on Windows:

```powershell
pwsh -NoLogo -NoProfile -File '.\tests\AdoProcessSync.Tests.ps1'
```

Tests use a temporary local store, a fake PAT, actual DPAPI encryption, and mocked
HTTP calls. They check parsing/frontmatter, ACL restrictions, credential rotation,
fixed API hosts, pagination encoding, audit response validation, plan hashes,
target/inheritance restrictions, blocked deletions, and sanitized failures.
They do not prove live permissions, audit-event coverage, or the semantic safety
of a proposed process change. Validate those read-only against your organization
and apply to a disposable inherited process before production use.

## Official sources

- [Authentication guidance](https://learn.microsoft.com/en-us/azure/devops/integrate/get-started/authentication/authentication-guidance?view=azure-devops)
- [PAT management](https://learn.microsoft.com/en-us/azure/devops/organizations/accounts/use-personal-access-tokens-to-authenticate?view=azure-devops)
- [Auditing availability, permissions, and retention](https://learn.microsoft.com/en-us/azure/devops/organizations/audit/azure-devops-auditing?view=azure-devops)
- [Audit query REST API](https://learn.microsoft.com/en-us/rest/api/azure/devops/audit/audit-log/query?view=azure-devops-rest-7.1)
- [Audit action catalog](https://learn.microsoft.com/en-us/azure/devops/organizations/audit/auditing-events?view=azure-devops)
- [Process inventory](https://learn.microsoft.com/en-us/rest/api/azure/devops/processes/processes/list?view=azure-devops-rest-7.1)
- [Process field add](https://learn.microsoft.com/en-us/rest/api/azure/devops/processes/fields/add?view=azure-devops-rest-7.1)
- [Process rule add](https://learn.microsoft.com/en-us/rest/api/azure/devops/processes/rules/add?view=azure-devops-rest-7.1)
- [Windows Export-Clixml and DPAPI](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/export-clixml)
