# Offline behavioral checks. No real credentials or external API requests.
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$collector = Join-Path $repoRoot 'scripts\collect_factcheck_sample.ps1'
$example = Get-Content -LiteralPath (Join-Path $repoRoot 'configs\factcheck.sample.example.json') -Raw -Encoding UTF8
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$testRoot = Join-Path $repoRoot ('outputs\collector-offline-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$utf8 = New-Object Text.UTF8Encoding($false)
$results = New-Object 'System.Collections.Generic.List[object]'
function Run-Case([string]$Name, [scriptblock]$Mutate, [bool]$ShouldPass, [string]$RunName = 'sample') {
    $caseRoot = Join-Path $testRoot $Name
    [void][IO.Directory]::CreateDirectory($caseRoot)
    $plan = $example | ConvertFrom-Json
    & $Mutate $plan $caseRoot
    $planPath = Join-Path $caseRoot 'plan.json'
    [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 8), $utf8)
    $childOutput = & $pwsh -NoProfile -File $collector -ProjectRoot $caseRoot -PlanPath $planPath -RunId $RunName -ValidateOnly 2>&1
    $childExit = $LASTEXITCODE
    $outputText = $childOutput | Out-String
    $passed = if ($ShouldPass) { $childExit -eq 0 } else { $childExit -ne 0 }
    if ($ShouldPass -and $passed) {
        $validation = $outputText | ConvertFrom-Json
        $passed = $validation.plan_valid -eq $true -and $validation.requests_sent -eq 0 -and $validation.query_count -eq 6 -and $validation.max_returned_claim_records -eq 60
        if (Test-Path -LiteralPath (Join-Path $caseRoot 'data')) { $passed = $false }
        if (Test-Path -LiteralPath (Join-Path $caseRoot 'outputs')) { $passed = $false }
    }
    $results.Add([pscustomobject]@{name = $Name; passed = $passed; process_exit = $childExit})
    if ($passed) { Write-Output ('PASS ' + $Name) } else { Write-Output ('FAIL ' + $Name + ': expected success=' + $ShouldPass + ', exit=' + $childExit) }
}
Run-Case 'valid-plan-without-key-has-no-side-effects' {param($p,$r)} $true
Run-Case 'reject-request-cap-above-six' {param($p,$r) $p.max_requests = 7} $false
Run-Case 'reject-zero-page-size' {param($p,$r) $p.page_size = 0} $false
Run-Case 'reject-pagination' {param($p,$r) $p.follow_pagination = $true} $false
Run-Case 'reject-duplicate-query-files' {param($p,$r) $p.queries[1].query_id = 'Q01'} $false
Run-Case 'reject-query-path-traversal' {param($p,$r) $p.queries[0].query_id = '../.env'} $false
Run-Case 'reject-windows-device-query-file' {param($p,$r) $p.queries[0].query_id = 'NUL'} $false
Run-Case 'reject-windows-device-run-directory' {param($p,$r)} $false 'CON'
Run-Case 'reject-credential-forwarding-to-other-host' {param($p,$r) $p.endpoint = 'https://example.invalid/claims:search'} $false
Run-Case 'reject-existing-run-before-reading-key' {param($p,$r) [void][IO.Directory]::CreateDirectory((Join-Path $r 'outputs\sample'))} $false
$failures = @($results | Where-Object { -not $_.passed }).Count
$summary = [ordered]@{total = $results.Count; passed = $results.Count - $failures; failed = $failures; external_api_requests = 0; results = $results.ToArray()}
[IO.File]::WriteAllText((Join-Path $testRoot 'summary.json'), ($summary | ConvertTo-Json -Depth 5), $utf8)
Write-Output ('Tests: {0} passed, {1} failed; external API requests: 0' -f ($results.Count - $failures), $failures)
if ($failures -gt 0) { exit 1 }
