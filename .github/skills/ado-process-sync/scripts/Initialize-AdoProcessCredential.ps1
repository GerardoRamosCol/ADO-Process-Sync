#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,49}$')]
    [string]$Organization,
    [Parameter(Mandatory)]
    [ValidateSet('Reader', 'Writer')]
    [string]$Role,
    [switch]$Replace
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Windows DPAPI is required.' }

$directory = Join-Path $env:LOCALAPPDATA 'AdoProcessSync\credentials'
if (Test-Path -LiteralPath $directory) {
    if ((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Credential directory must not be a reparse point.'
    }
}
else {
    $null = New-Item -ItemType Directory -Path $directory
}

$acl = Get-Acl -LiteralPath $directory
$acl.SetAccessRuleProtection($true, $false)
foreach ($existingRule in @($acl.Access)) {
    $null = $acl.RemoveAccessRuleSpecific($existingRule)
}
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
foreach ($identity in @($sid, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $identity, 'FullControl', $inheritance, 'None', 'Allow'
    )
    $acl.AddAccessRule($rule)
}
[IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($directory), $acl)

$path = Join-Path $directory ("{0}-{1}.clixml" -f $Organization.ToLowerInvariant(), $Role.ToLowerInvariant())
if (Test-Path -LiteralPath $path) {
    if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Credential file must not be a reparse point.'
    }
    if (-not $Replace) { throw 'Credential already exists. Use -Replace for intentional rotation.' }
}

$secret = Read-Host "Enter the $Role PAT for $Organization (never paste it in chat)" -AsSecureString
try {
    if ($secret.Length -eq 0) { throw 'PAT cannot be empty.' }
    $credential = [PSCredential]::new($Organization.ToLowerInvariant(), $secret)
    $credential | Export-Clixml -LiteralPath $path -Force
    # Reset explicit file permissions as well when replacing an older credential.
    $fileAcl = Get-Acl -LiteralPath $path
    $fileAcl.SetAccessRuleProtection($true, $false)
    foreach ($existingRule in @($fileAcl.Access)) {
        $null = $fileAcl.RemoveAccessRuleSpecific($existingRule)
    }
    foreach ($identity in @($sid, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $fileAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'Allow'))
    }
    [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($path), $fileAcl)
    Write-Output "Stored encrypted $Role credential locally for $Organization."
}
finally {
    $credential = $null
    $secret.Dispose()
}
