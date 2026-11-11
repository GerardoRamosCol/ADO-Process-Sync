Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$verifier = Join-Path $PSScriptRoot '..\.github\skills\ado-migration-verify\scripts\Verify-GitMigration.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ado-migration-tests-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot

function Invoke-TestGit {
    param([string[]] $GitArguments)
    $result = @(& git @GitArguments)
    if ($LASTEXITCODE -ne 0) { throw "Test Git command failed: $($GitArguments -join ' ')" }
    return $result
}

function Test-Verification {
    param(
        [string] $Name,
        [string] $Source,
        [string] $Destination,
        [bool] $ShouldPass
    )
    $path = Join-Path $testRoot $Name
    $failure = $null
    try {
        $null = & $verifier -SourceMirrorPath $Source -DestinationUrl $Destination -DestinationClonePath $path
    }
    catch {
        $failure = $_
    }
    if ($ShouldPass -and $null -ne $failure) { throw $failure }
    if (-not $ShouldPass -and $null -eq $failure) { throw "$Name should have failed." }
    $reportPath = Join-Path $path 'git-verification.json'
    if (-not (Test-Path -LiteralPath $reportPath)) { throw "$Name did not persist evidence." }
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    if ($report.passed -ne $ShouldPass) { throw "$Name report has an incorrect result." }
    Write-Host "PASS: $Name"
    return $report
}

try {
    $work = Join-Path $testRoot 'work'
    $source = Join-Path $testRoot 'source.git'
    $target = Join-Path $testRoot 'target.git'
    $null = Invoke-TestGit @('init', '--initial-branch=main', $work)
    $null = Invoke-TestGit @('-C', $work, 'config', 'user.name', 'Migration Test')
    $null = Invoke-TestGit @('-C', $work, 'config', 'user.email', 'migration-test@example.invalid')
    $null = Invoke-TestGit @('-C', $work, 'commit', '--allow-empty', '-m', 'Root')
    $null = Invoke-TestGit @('-C', $work, 'checkout', '-b', 'feature/nested')
    $null = Invoke-TestGit @('-C', $work, 'commit', '--allow-empty', '-m', 'Feature')
    $null = Invoke-TestGit @('-C', $work, 'checkout', 'main')
    $null = Invoke-TestGit @('-C', $work, 'commit', '--allow-empty', '-m', 'Main')
    $null = Invoke-TestGit @('-C', $work, 'merge', '--no-ff', 'feature/nested', '-m', 'Merge')
    $null = Invoke-TestGit @('-C', $work, 'tag', 'lightweight')
    $null = Invoke-TestGit @('-C', $work, 'tag', '-a', 'annotated', '-m', 'Original tag message')
    $null = Invoke-TestGit @('clone', '--mirror', '--', $work, $source)
    $null = Invoke-TestGit @('init', '--bare', $target)
    $null = Invoke-TestGit @(
        "--git-dir=$source", 'push', '--atomic', $target,
        'refs/heads/*:refs/heads/*', 'refs/tags/*:refs/tags/*'
    )
    $null = Invoke-TestGit @("--git-dir=$target", 'symbolic-ref', 'HEAD', 'refs/heads/main')
    $report = Test-Verification 'matching' $source $target $true
    if ($report.sourceBranchCount -ne 2 -or $report.sourceTagCount -ne 2 -or
        $report.sourceCommitCount -ne 4) { throw 'Unexpected inventory counts.' }

    $failure = $null
    try {
        & $verifier -SourceMirrorPath $source -DestinationUrl $target `
            -DestinationClonePath (Join-Path $testRoot 'matching')
    }
    catch { $failure = $_ }
    if ($null -eq $failure -or $failure.ToString() -notlike '*already exists*') {
        throw 'Existing verification directories must be rejected.'
    }
    Write-Output 'PASS: existing-path guard'

    $null = Invoke-TestGit @("--git-dir=$target", 'update-ref', '-d', 'refs/heads/feature/nested')
    $null = Test-Verification 'missing-branch' $source $target $false
    $feature = @(Invoke-TestGit @("--git-dir=$source", 'rev-parse', 'refs/heads/feature/nested'))[0]
    $null = Invoke-TestGit @("--git-dir=$target", 'update-ref', 'refs/heads/feature/nested', $feature)
    $null = Invoke-TestGit @("--git-dir=$target", 'update-ref', 'refs/heads/extra', $feature)
    $null = Test-Verification 'extra-branch' $source $target $false
    $null = Invoke-TestGit @("--git-dir=$target", 'update-ref', '-d', 'refs/heads/extra')

    $null = Invoke-TestGit @('-C', $work, 'tag', '-f', '-a', 'annotated', '-m', 'Changed tag message')
    $null = Invoke-TestGit @('-C', $work, 'push', $target, '+refs/tags/annotated:refs/tags/annotated')
    $report = Test-Verification 'changed-annotated-tag' $source $target $false
    if (@($report.commitDifferences).Count -ne 0 -or @($report.refDifferences).Count -eq 0) {
        throw 'Tag-object mismatch must fail even when the commit set is identical.'
    }

    $null = Invoke-TestGit @('-C', $work, 'commit', '--allow-empty', '-m', 'Destination-only history')
    $null = Invoke-TestGit @('-C', $work, 'push', $target, 'refs/heads/main:refs/heads/main')
    $report = Test-Verification 'changed-history' $source $target $false
    if (@($report.commitDifferences).Count -eq 0) { throw 'History mismatch was not detected.' }

    $emptySource = Join-Path $testRoot 'empty-source.git'
    $emptyTarget = Join-Path $testRoot 'empty-target.git'
    $null = Invoke-TestGit @('init', '--bare', $emptySource)
    $null = Invoke-TestGit @('init', '--bare', $emptyTarget)
    $null = Test-Verification 'empty-repositories' $emptySource $emptyTarget $true
    $null = Test-Verification 'empty-source-nonempty-target' $emptySource $target $false
    $null = Test-Verification 'nonempty-source-empty-target' $source $emptyTarget $false
}
finally {
    # Only this test's uniquely created directory is eligible for cleanup.
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
