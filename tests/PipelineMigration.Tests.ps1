Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$initializer = Join-Path $PSScriptRoot '..\.github\skills\ado-pipeline-inventory\scripts\New-PipelineMigrationRun.ps1'
$reporter = Join-Path $PSScriptRoot '..\.github\skills\ado-pipeline-report\scripts\Write-PipelineMigrationReports.ps1'
$example = Join-Path $PSScriptRoot '..\.github\skills\ado-pipeline-report\assets\assessment.example.json'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('pipeline-migration-tests-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Write-Fixture {
    param([string] $Run, $Data)
    ConvertTo-Json -InputObject @($Data.pipelines | Select-Object id, name, type) -Depth 10 |
        Set-Content -LiteralPath (Join-Path $Run 'inventory.json') -Encoding UTF8
    $Data | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath (Join-Path $Run 'assessment.json') -Encoding UTF8
}

function Assert-Rejected {
    param([string] $Name, [string] $Run, [string] $MessagePattern)
    $failure = $null
    try { $null = & $reporter -RunPath $Run }
    catch { $failure = $_ }
    Assert-True ($null -ne $failure) "$Name should fail."
    Assert-True ($failure.ToString() -like $MessagePattern) "$Name failed unexpectedly: $failure"
    Write-Host "PASS: $Name"
}

function New-Fixture {
    $run = & $initializer -WorkspacePath $testRoot
    $data = Get-Content -LiteralPath $example -Raw | ConvertFrom-Json
    'name: Example draft (not executed)' | Set-Content -LiteralPath (Join-Path $run 'workflows\sample-release-42.yml')
    return [pscustomobject]@{ run = $run; data = $data }
}

try {
    $first = & $initializer -WorkspacePath $testRoot
    $second = & $initializer -WorkspacePath $testRoot
    Assert-True ($first -ne $second) 'Invocations must create unique folders.'
    foreach ($run in @($first, $second)) {
        foreach ($path in @('run.json', 'inventory.json', 'summary.md', 'sources',
                'workflows', 'reports', 'evidence', 'importer')) {
            Assert-True (Test-Path -LiteralPath (Join-Path $run $path)) "Missing initialized artifact: $path"
        }
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot '.github\workflows'))) 'Must not create active workflows.'
    $sentinel = Join-Path $first 'sources\preserved.txt'
    'preserve prior runs' | Set-Content -LiteralPath $sentinel
    $null = & $initializer -WorkspacePath $testRoot
    Assert-True ((Get-Content -LiteralPath $sentinel -Raw).Trim() -eq 'preserve prior runs') 'Prior run was changed.'
    Write-Host 'PASS: unique run layout and prior-run preservation'

    $fixture = New-Fixture
    Write-Fixture $fixture.run $fixture.data
    $null = & $reporter -RunPath $fixture.run
    $coverage = Get-Content -LiteralPath (Join-Path $fixture.run 'coverage.json') -Raw | ConvertFrom-Json
    Assert-True ($coverage.overallPercentage -eq 12.5) 'Partial/manual example must score 12.5%.'
    $report = Get-Content -LiteralPath (Join-Path $fixture.run 'reports\sample-release-42.md') -Raw
    foreach ($text in @('12.5%', 'Manual steps', 'Cloud administrator', 'Acceptance test',
            '../workflows/sample-release-42.yml', 'not run')) {
        Assert-True ($report.Contains($text)) "Missing report content: $text"
    }
    $manifest = Get-Content -LiteralPath (Join-Path $fixture.run 'run.json') -Raw | ConvertFrom-Json
    Assert-True ($manifest.status -eq 'reported') 'Manifest must distinguish reporting from deployment.'
    Write-Host 'PASS: report contents, credit formula and manifest status'

    foreach ($type in @('yaml', 'classic-build', 'classic-release')) {
        $fixture = New-Fixture
        $pipeline = $fixture.data.pipelines[0]
        $pipeline.type = $type
        $pipeline.name = 'Name | with table separator'
        $pipeline.requirements = @($pipeline.requirements[0])
        $pipeline.requirements[0].status = 'migrated'
        $pipeline.requirements[0].manualAction = ''
        $pipeline.requirements[0].owner = ''
        $pipeline.requirements[0].verification = ''
        Write-Fixture $fixture.run $fixture.data
        $null = & $reporter -RunPath $fixture.run
        $coverage = Get-Content -LiteralPath (Join-Path $fixture.run 'coverage.json') -Raw | ConvertFrom-Json
        Assert-True ($coverage.overallPercentage -eq 100) "Fully mapped $type must score 100%."
        $summary = Get-Content -LiteralPath (Join-Path $fixture.run 'summary.md') -Raw
        Assert-True ($summary.Contains('Name \| with table separator')) 'Markdown tables must escape pipes.'
    }
    Write-Host 'PASS: all three pipeline types and Markdown escaping'

    $fixture = New-Fixture
    $pipeline = $fixture.data.pipelines[0]
    $pipeline.workflows = @()
    $pipeline.inventoryComplete = $false
    $pipeline.requirements = @($pipeline.requirements[0])
    $pipeline.requirements[0].status = 'unknown'
    Write-Fixture $fixture.run $fixture.data
    $null = & $reporter -RunPath $fixture.run
    $coverage = Get-Content -LiteralPath (Join-Path $fixture.run 'coverage.json') -Raw | ConvertFrom-Json
    Assert-True ($coverage.overallPercentage -eq 0) 'Unassessed pipeline must score zero.'
    Write-Host 'PASS: inaccessible pipeline retained at zero coverage'

    $fixture = New-Fixture
    $fixture.data.pipelines[0].requirements[1].status = 'unsupported'
    Write-Fixture $fixture.run $fixture.data
    Assert-Rejected 'unknown status' $fixture.run '*Invalid requirement status*'

    $fixture = New-Fixture
    $fixture.data.pipelines[0].requirements[1].manualAction = ''
    Write-Fixture $fixture.run $fixture.data
    Assert-Rejected 'missing manual completion action' $fixture.run '*manualAction must be nonempty*'

    $fixture = New-Fixture
    $fixture.data.pipelines[0].inventoryComplete = $false
    Write-Fixture $fixture.run $fixture.data
    Assert-Rejected 'missing unknown for incomplete inventory' $fixture.run '*requires an unknown*'

    $fixture = New-Fixture
    $fixture.data.pipelines[0].workflows = @('workflows/../../escape.yml')
    Write-Fixture $fixture.run $fixture.data
    Assert-Rejected 'workflow traversal' $fixture.run '*flat, run-relative*'

    $fixture = New-Fixture
    $fixture.data.pipelines[0].id = '../escape'
    Write-Fixture $fixture.run $fixture.data
    Assert-Rejected 'report traversal' $fixture.run '*Unsafe ID*'

    $fixture = New-Fixture
    $fixture.data.pipelines[0].workflows = @('workflows/missing.yml')
    Write-Fixture $fixture.run $fixture.data
    Assert-Rejected 'missing workflow artifact' $fixture.run '*does not exist*'

    $fixture = New-Fixture
    $fixture.data.pipelines[0].workflows = @()
    Write-Fixture $fixture.run $fixture.data
    Assert-Rejected 'credit without a draft' $fixture.run '*require a local workflow*'

    $fixture = New-Fixture
    Write-Fixture $fixture.run $fixture.data
    '[]' | Set-Content -LiteralPath (Join-Path $fixture.run 'inventory.json')
    Assert-Rejected 'omitted inventory entry' $fixture.run '*pipeline counts differ*'

    $fixture = New-Fixture
    $fixture.data.pipelines += $fixture.data.pipelines[0]
    Write-Fixture $fixture.run $fixture.data
    Assert-Rejected 'duplicate pipeline IDs' $fixture.run '*Duplicate inventory ID*'

    $fixture = New-Fixture
    $fixture.data.pipelines[0].categoryReview.identity = 'not-applicable: skipped'
    Write-Fixture $fixture.run $fixture.data
    Assert-Rejected 'hiding an applicable category' $fixture.run '*not-applicable category*'

    $fixture = New-Fixture
    $fixture.data.pipelines = @()
    Write-Fixture $fixture.run $fixture.data
    $null = & $reporter -RunPath $fixture.run
    $coverage = Get-Content -LiteralPath (Join-Path $fixture.run 'coverage.json') -Raw | ConvertFrom-Json
    Assert-True ($null -eq $coverage.overallPercentage) 'Empty inventory is N/A, not 100%.'
    Write-Host 'PASS: empty inventory is N/A'

    $fixture = New-Fixture
    $secondPipeline = (Get-Content -LiteralPath $example -Raw | ConvertFrom-Json).pipelines[0]
    $secondPipeline.id = 'second-build-1'
    $secondPipeline.type = 'classic-build'
    $secondPipeline.workflows = @('workflows/second-build-1.yml')
    'name: Second draft' | Set-Content -LiteralPath (Join-Path $fixture.run 'workflows\second-build-1.yml')
    $secondPipeline.requirements = @($secondPipeline.requirements[0])
    $secondPipeline.requirements[0].status = 'migrated'
    $secondPipeline.requirements[0].manualAction = ''
    $secondPipeline.requirements[0].owner = ''
    $secondPipeline.requirements[0].verification = ''
    $fixture.data.pipelines += $secondPipeline
    Write-Fixture $fixture.run $fixture.data
    $null = & $reporter -RunPath $fixture.run
    $coverage = Get-Content -LiteralPath (Join-Path $fixture.run 'coverage.json') -Raw | ConvertFrom-Json
    Assert-True ($coverage.overallPercentage -eq 30) 'Overall score must use requirement totals: 1.5/5 = 30%.'
    Write-Host 'PASS: requirement-weighted batch coverage'

    $result = @(& $reporter -RunPath $fixture.run)
    Assert-True ($result.Count -eq 1) 'Reporter should return only the summary path.'
    Write-Host 'PASS: regeneration is local and returns summary'

    $fixture = New-Fixture
    $prototype = $fixture.data.pipelines[0].requirements[0] | ConvertTo-Json
    $requirements = @()
    for ($index = 0; $index -lt 1000; $index++) {
        $requirement = $prototype | ConvertFrom-Json
        $requirement.id = "requirement-$index"
        $requirement.status = 'migrated'
        $requirement.manualAction = ''
        $requirement.owner = ''
        $requirement.verification = ''
        $requirements += $requirement
    }
    $partial = $prototype | ConvertFrom-Json
    $partial.id = 'still-partial'
    $requirements += $partial
    $fixture.data.pipelines[0].requirements = $requirements
    Write-Fixture $fixture.run $fixture.data
    $null = & $reporter -RunPath $fixture.run
    $coverage = Get-Content -LiteralPath (Join-Path $fixture.run 'coverage.json') -Raw | ConvertFrom-Json
    Assert-True ($coverage.overallPercentage -eq 99.9) 'Incomplete coverage must never round up to 100%.'
    Write-Host 'PASS: near-complete coverage stays below 100%'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
