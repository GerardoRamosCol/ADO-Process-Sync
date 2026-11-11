#requires -Version 7.5
[CmdletBinding()]
param(
    [ValidateRange(1024, 65500)][int]$Port = 8765,
    [switch]$NoBrowser,
    [string]$StoreRoot = (Join-Path $env:LOCALAPPDATA 'AdoProcessSync/web')
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Windows with PowerShell 7.5 or later is required.' }
$modulePath = Join-Path $PSScriptRoot 'process-sync/AdoProcessApp.psm1'
Import-Module $modulePath -Force
Import-Module (Join-Path $PSScriptRoot 'process-sync/AdoProcessApi.psm1')
Initialize-AdoStore $StoreRoot
$webRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'web/process-sync'
$listener = $null
for ($candidate = $Port; $candidate -lt $Port + 50; $candidate++) {
    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $candidate)
    try { $probe.Start(); $probe.Stop() } catch { $probe.Stop(); continue }
    $listener = [Net.HttpListener]::new()
    $listener.Prefixes.Add("http://127.0.0.1:$candidate/")
    try { $listener.Start(); $Port = $candidate; break }
    catch { $listener.Close(); $listener = $null }
}
if (-not $listener -or -not $listener.IsListening) { throw 'No available loopback listener. Check local HTTP listener permissions; do not run the app elevated.' }
$origin = "http://127.0.0.1:$Port"
$bootstrap = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
$cookieName = "AdoProcessSync$Port"
$sessionToken = ''
$csrf = ''
$session = [hashtable]::Synchronized(@{
    storeRoot = $StoreRoot; organization = ''; reader = $null; writer = $null; connected = $false; processes = @();
    state = 'ready'; error = $null; progress = ''; preview = $null; result = $null; scope = $null;
    recoveryNeeded = $false; consumedHash = ''; cancel = $false; rawAudit = $null; auditRead = $null; auditCache = $null; expiresAt = [DateTimeOffset]::UtcNow.AddMinutes(30)
})
$worker = $null
$workerResult = $null

function Send-AppResponse {
    param([Net.HttpListenerContext]$Context, [int]$Status, [object]$Value, [string]$ContentType = 'application/json; charset=utf-8')
    $response = $Context.Response
    $response.StatusCode = $Status
    $response.ContentType = $ContentType
    $response.Headers['Cache-Control'] = 'no-store'
    $response.Headers['X-Content-Type-Options'] = 'nosniff'
    $response.Headers['Referrer-Policy'] = 'no-referrer'
    $response.Headers['Content-Security-Policy'] = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
    $response.Headers['Cross-Origin-Resource-Policy'] = 'same-origin'
    $response.Headers['Permissions-Policy'] = 'camera=(), microphone=(), geolocation=()'
    $bytes = if ($Value -is [byte[]]) { $Value } elseif ($ContentType.StartsWith('application/json')) {
        [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 100 -Compress))
    } else { [Text.Encoding]::UTF8.GetBytes([string]$Value) }
    $response.ContentLength64 = $bytes.Length
    try { $response.OutputStream.Write($bytes, 0, $bytes.Length) } finally { $response.Close() }
}

function Read-AppBody {
    param([Net.HttpListenerRequest]$Request)
    if ($Request.ContentType -notmatch '^application/json(?:;\s*charset=utf-8)?$' -or $Request.ContentLength64 -lt 0 -or $Request.ContentLength64 -gt 65536) { throw 'Invalid request content type or body size.' }
    $reader = [IO.StreamReader]::new($Request.InputStream, [Text.UTF8Encoding]::new($false, $true))
    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    $body = ConvertFrom-Json -InputObject $text -AsHashtable -DateKind String -Depth 20
    $text = $null
    if ($body -isnot [hashtable]) { throw 'An object request is required.' }
    return $body
}

function Get-AppState {
    $preview = $session.preview
    return @{
        state = $session.state; connected = $session.connected; organization = $session.organization; processes = $session.processes;
        progress = $session.progress; error = $session.error; result = $session.result; recoveryNeeded = $session.recoveryNeeded; auditRead = $session.auditRead;
        expiresAt = $session.expiresAt.ToString('o'); rawAuditAvailable = ($null -ne $session.rawAudit -and $session.rawAudit.Count -gt 0);
        preview = $(if ($preview) { @{ hash = $preview.hash; runId = $preview.runId; plan = $preview.plan } } else { $null })
    }
}

function Clear-AppCredentials {
    $session.cancel = $true
    $session.reader = $null; $session.writer = $null
    $session.connected = $false; $session.processes = @(); $session.preview = $null
    $session.rawAudit = $null; $session.auditRead = $null; $session.auditCache = $null
}

Write-Output "ADO Process Sync: $origin/#key=$bootstrap"
Write-Output 'Loopback only. PATs stay in this process memory. Press Ctrl+C to stop.'
if (-not $NoBrowser) { Start-Process "$origin/#key=$bootstrap" }
try {
    $pending = $listener.GetContextAsync()
    while ($listener.IsListening) {
        if ([DateTimeOffset]::UtcNow -gt $session.expiresAt -and $session.reader) {
            Clear-AppCredentials
            $session.error = 'Session expired. Reconnect with a reader PAT.'
        }
        if (-not $pending.Wait(1000)) { continue }
        $context = $pending.GetAwaiter().GetResult()
        $pending = $listener.GetContextAsync()
        $request = $context.Request
        $body = $null
        try {
            if ($worker -and $workerResult.IsCompleted) {
                try { $null = $worker.EndInvoke($workerResult) } catch { $session.state = 'error'; $session.error = 'Background job stopped unexpectedly. Inspect live state before retrying writes.' }
                $worker.Dispose(); $worker = $null; $workerResult = $null
            }
            if ($request.Headers['Host'] -cne "127.0.0.1:$Port" -or $request.Url.Query -or -not [Net.IPAddress]::IsLoopback($request.RemoteEndPoint.Address)) {
                Send-AppResponse $context 403 @{ error = 'Loopback host required.' }; continue
            }
            $route = $request.Url.AbsolutePath
            $assets = @{
                '/' = @('index.html', 'text/html; charset=utf-8')
                '/app.css' = @('app.css', 'text/css; charset=utf-8')
                '/app.js' = @('app.js', 'text/javascript; charset=utf-8')
                '/icons/workflow.svg' = @('icons/workflow.svg', 'image/svg+xml')
                '/icons/refresh-cw.svg' = @('icons/refresh-cw.svg', 'image/svg+xml')
                '/icons/download.svg' = @('icons/download.svg', 'image/svg+xml')
                '/icons/log-out.svg' = @('icons/log-out.svg', 'image/svg+xml')
                '/icons/check.svg' = @('icons/check.svg', 'image/svg+xml')
                '/icons/arrow-right.svg' = @('icons/arrow-right.svg', 'image/svg+xml')
            }
            if ($request.HttpMethod -eq 'GET' -and $assets.ContainsKey($route)) {
                $asset = $assets[$route]
                Send-AppResponse $context 200 ([IO.File]::ReadAllBytes((Join-Path $webRoot $asset[0]))) $asset[1]; continue
            }
            if ($route -notmatch '^/api/' -or $request.Headers['Origin'] -cne $origin) {
                Send-AppResponse $context 403 @{ error = 'Same-origin application request required.' }; continue
            }
            $cookie = $request.Cookies[$cookieName]
            $authenticated = $sessionToken -and $cookie -and $cookie.Value -ceq $sessionToken
            if ($route -eq '/api/session' -and $request.HttpMethod -eq 'POST') {
                if (-not $authenticated -and (-not $bootstrap -or $request.Headers['X-Bootstrap-Token'] -cne $bootstrap)) {
                    Send-AppResponse $context 403 @{ error = 'Open the one-time launch link printed by the server.' }; continue
                }
                if (-not $authenticated) {
                    $sessionToken = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
                    $bootstrap = ''
                    $context.Response.Headers['Set-Cookie'] = "$cookieName=$sessionToken; Path=/; HttpOnly; SameSite=Strict"
                }
                $csrf = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
                Send-AppResponse $context 200 @{ csrf = $csrf; app = 'ADO Process Sync' }; continue
            }
            if (-not $authenticated -or $request.Headers['X-CSRF-Token'] -cne $csrf) {
                Send-AppResponse $context 403 @{ error = 'Session or CSRF token is invalid. Reload the local application.' }; continue
            }
            if ($route -eq '/api/status' -and $request.HttpMethod -eq 'POST') { Send-AppResponse $context 200 (Get-AppState); continue }
            if ($route -eq '/api/audit-raw' -and $request.HttpMethod -eq 'POST') {
                if (-not $session.connected -or -not $session.reader) { Send-AppResponse $context 401 @{ error = 'Reconnect with a reader PAT.' }; continue }
                if ($session.state -eq 'running') { Send-AppResponse $context 409 @{ error = 'Wait for the current job to finish.' }; continue }
                if ($null -eq $session.rawAudit -or $session.rawAudit.Count -eq 0) { Send-AppResponse $context 404 @{ error = 'No audit response available. Read audit first.' }; continue }
                Send-AppResponse $context 200 ($session.rawAudit.ToArray()); continue
            }
            if ($route -eq '/api/logout' -and $request.HttpMethod -eq 'POST') {
                Clear-AppCredentials
                $session.error = $null; $session.result = $null
                Send-AppResponse $context 200 @{ status = 'disconnected' }; continue
            }
            if ($route -eq '/api/cancel' -and $request.HttpMethod -eq 'POST') {
                $session.cancel = $true
                Send-AppResponse $context 200 @{ status = 'stopping-after-current-operation' }; continue
            }
            if ($route -eq '/api/plan' -and $request.HttpMethod -eq 'POST' -and $session.preview) {
                $null = Assert-AdoApprovedPlan $session.preview $session.preview.hash -AllowBlocked
                $context.Response.Headers['Content-Disposition'] = 'attachment; filename="process-sync-plan.json"'
                Send-AppResponse $context 200 ([IO.File]::ReadAllBytes((Join-Path $session.preview.runPath 'plan.json'))); continue
            }
            if ($request.HttpMethod -ne 'POST' -or $route -notin @('/api/connect', '/api/read-audit', '/api/preview', '/api/apply', '/api/reconcile')) {
                Send-AppResponse $context 404 @{ error = 'Route not found.' }; continue
            }
            if ($worker) { Send-AppResponse $context 409 @{ error = 'A job is already running.' }; continue }
            $body = Read-AppBody $request
            $kind = ''
            if ($route -eq '/api/connect') {
                Assert-AdoOrganization ([string]$body.organization)
                if ($body.readerPat -isnot [string] -or $body.readerPat.Length -lt 1 -or $body.readerPat.Length -gt 512) { throw 'Invalid reader credential.' }
                Clear-AppCredentials
                $session.organization = $body.organization.ToLowerInvariant()
                $session.reader = [PSCredential]::new($session.organization, (ConvertTo-SecureString $body.readerPat -AsPlainText -Force))
                $body.readerPat = $null
                $session.expiresAt = [DateTimeOffset]::UtcNow.AddMinutes(30)
                $kind = 'Connect'
            }
            else {
                if (-not $session.connected -or -not $session.reader -or [DateTimeOffset]::UtcNow -gt $session.expiresAt) {
                    Send-AppResponse $context 401 @{ error = 'Reconnect with a reader PAT.' }; continue
                }
                switch ($route) {
                    '/api/read-audit' { $session.preview = $null; $session.rawAudit = $null; $session.auditRead = $null; $session.auditCache = $null; $kind = 'ReadAudit' }
                    '/api/preview' { $session.preview = $null; $kind = 'Preview' }
                    '/api/reconcile' { if (-not $session.scope) { throw 'Scan an explicit scope first.' }; $kind = 'Reconcile' }
                    '/api/apply' {
                        if ($body.confirmed -ne $true -or $body.mappingsConfirmed -ne $true) { throw 'Explicit confirmation required.' }
                        $plan = Assert-AdoApprovedPlan $session.preview $body.hash
                        if ($plan.mode -eq 'sync' -and $plan.operations.Count) {
                            if ($body.writerPat -isnot [string] -or $body.writerPat.Length -lt 1 -or $body.writerPat.Length -gt 512) { throw 'Writer credential required.' }
                            $session.writer = [PSCredential]::new($session.organization, (ConvertTo-SecureString $body.writerPat -AsPlainText -Force))
                        }
                        $body.writerPat = $null
                        $kind = 'Apply'
                    }
                }
            }
            $session.cancel = $false; $session.state = 'running'; $session.error = $null
            $worker = [PowerShell]::Create()
            $null = $worker.AddScript('param($modulePath, $session, $kind, $inputData) Import-Module $modulePath -Force; Invoke-AdoAppJob $session $kind $inputData').AddArgument($modulePath).AddArgument($session).AddArgument($kind).AddArgument($body)
            $workerResult = $worker.BeginInvoke()
            Send-AppResponse $context 202 @{ status = 'running' }
        }
        catch {
            $session.writer = $null
            try { Send-AppResponse $context 400 @{ error = 'Request rejected. Check inputs, exact plan approval, and session state.' } } catch { }
        }
        finally { if ($body) { $body.readerPat = $null; $body.writerPat = $null }; $body = $null }
    }
}
finally {
    Clear-AppCredentials
    $listener.Close()
    if ($worker) { $worker.Stop(); $worker.Dispose() }
}