#requires -Version 7.0
param(
    [string]$ProjectRoot = '',
    [string]$PlanPath = 'configs/factcheck.sample.example.json',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,95}$')]
    [string]$RunId = ('factcheck-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)),
    [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'
$reservedDevicePattern = '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$'
if ($RunId -match $reservedDevicePattern) { throw 'RunId cannot be a Windows reserved device name.' }
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Join-Path $PSScriptRoot '..' }
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
if (-not [IO.Path]::IsPathRooted($PlanPath)) { $PlanPath = Join-Path $ProjectRoot $PlanPath }
$sourcePlan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($sourcePlan.endpoint -cne 'https://factchecktools.googleapis.com/v1alpha1/claims:search') {
    throw 'Only the official Fact Check Tools claims.search endpoint is allowed.'
}
foreach ($constraint in @(@('max_requests', 1, 6), @('page_size', 1, 10), @('delay_between_requests_ms', 0, 10000))) {
    $value = $sourcePlan.($constraint[0])
    if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt $constraint[1] -or $value -gt $constraint[2]) {
        throw ('Invalid bounded integer setting: ' + $constraint[0])
    }
}
if ($sourcePlan.follow_pagination -ne $false -or $sourcePlan.automatic_retries -ne 0) {
    throw 'This sample collector does not allow pagination or automatic retries.'
}
$querySpecs = @($sourcePlan.queries)
if ($querySpecs.Count -lt 1 -or $querySpecs.Count -gt $sourcePlan.max_requests) {
    throw 'Query count must be between one and max_requests.'
}
$queryIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($querySpec in $querySpecs) {
    if ([string]$querySpec.query_id -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' -or [string]$querySpec.query_id -match $reservedDevicePattern -or -not $queryIds.Add([string]$querySpec.query_id)) {
        throw 'Query IDs must be safe, unique file names (case-insensitive).'
    }
    if ([string]::IsNullOrWhiteSpace([string]$querySpec.query) -and [string]::IsNullOrWhiteSpace([string]$querySpec.reviewPublisherSiteFilter)) {
        throw 'Each query needs query or reviewPublisherSiteFilter.'
    }
}
$outputDirectory = Join-Path $ProjectRoot ('outputs/' + $RunId)
$rawDirectory = Join-Path $ProjectRoot ('data/raw/' + $RunId)
if ((Test-Path -LiteralPath $outputDirectory) -or (Test-Path -LiteralPath $rawDirectory)) {
    throw 'Run directory already exists; choose a new RunId instead of overwriting data.'
}
if ($ValidateOnly) {
    [ordered]@{
        plan_valid = $true; requests_sent = 0; query_count = $querySpecs.Count
        max_returned_claim_records = $querySpecs.Count * $sourcePlan.page_size
        run_id = $RunId; output_directory = $outputDirectory
    } | ConvertTo-Json
    return
}
$envPath = Join-Path $ProjectRoot '.env'
if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) { throw 'Create a local .env file from .env.example before collecting.' }
$envText = [IO.File]::ReadAllText($envPath, [Text.Encoding]::UTF8)
$keyEntries = [regex]::Matches($envText, '(?m)^\s*(?:export\s+)?GOOGLE_FACTCHECK_API_KEY\s*=\s*(.*?)\s*$')
if ($keyEntries.Count -ne 1) { throw 'Expected exactly one local GOOGLE_FACTCHECK_API_KEY entry.' }
$secret = $keyEntries[0].Groups[1].Value.Trim().Trim([char]34).Trim([char]39)
if ([string]::IsNullOrWhiteSpace($secret) -or $secret -eq 'replace_with_your_google_factcheck_api_key') { throw 'Configure a real API key in the local .env file.' }
$envText = $null
$keyEntries = $null
$utf8 = New-Object Text.UTF8Encoding($false)
[void][IO.Directory]::CreateDirectory($outputDirectory)
$guard = [IO.File]::Open((Join-Path $outputDirectory '.started'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
$guard.Dispose()
[void][IO.Directory]::CreateDirectory($rawDirectory)
$plan = [pscustomobject][ordered]@{
    run_id = $RunId; endpoint = $sourcePlan.endpoint; max_requests = $sourcePlan.max_requests
    page_size = $sourcePlan.page_size; follow_pagination = $false; automatic_retries = 0
    delay_between_requests_ms = $sourcePlan.delay_between_requests_ms
    queries = $querySpecs; raw_directory = ('data/raw/' + $RunId)
}
[IO.File]::WriteAllText((Join-Path $outputDirectory 'run-plan.json'), ($plan | ConvertTo-Json -Depth 8), $utf8)
$logPath = Join-Path $outputDirectory 'requests.jsonl'

Add-Type -AssemblyName System.Net.Http
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds(35)
$client.MaxResponseContentBufferSize = 2097152
$requestResults = New-Object 'System.Collections.Generic.List[object]'
$scriptHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
$startedAt = [DateTimeOffset]::UtcNow.ToString('o')
try {
    foreach ($querySpec in $plan.queries) {
        $parameters = [ordered]@{ pageSize = $plan.page_size }
        if ($querySpec.languageCode) { $parameters.languageCode = $querySpec.languageCode }
        if ($querySpec.query) { $parameters.query = $querySpec.query }
        if ($querySpec.reviewPublisherSiteFilter) { $parameters.reviewPublisherSiteFilter = $querySpec.reviewPublisherSiteFilter }
        $queryString = ($parameters.GetEnumerator() | ForEach-Object {
            [Uri]::EscapeDataString([string]$_.Key) + '=' + [Uri]::EscapeDataString([string]$_.Value)
        }) -join '&'
        $requestUri = $plan.endpoint + '?' + $queryString
        $rawPath = Join-Path $ProjectRoot ($plan.raw_directory + '/' + $querySpec.query_id + '.json')
        $entry = [ordered]@{
            run_id = $RunId; query_id = $querySpec.query_id; parameters = $parameters
            requested_at_utc = [DateTimeOffset]::UtcNow.ToString('o'); http_status = $null
            success = $false; returned_claims = 0; has_next_page = $false
            raw_response_path = $rawPath; collector_sha256 = $scriptHash
        }
        $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $requestUri)
        $request.Headers.Add('X-Goog-Api-Key', $secret)
        $response = $null
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $response = $client.SendAsync($request).GetAwaiter().GetResult()
            $responseText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $safeResponse = $responseText.Replace($secret, '[REDACTED]')
            [System.IO.File]::WriteAllText($rawPath, $safeResponse, $utf8)
            $entry.http_status = [int]$response.StatusCode
            $entry.response_sha256 = (Get-FileHash -LiteralPath $rawPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $entry.response_bytes = [System.Text.Encoding]::UTF8.GetByteCount($safeResponse)
            $payload = $safeResponse | ConvertFrom-Json
            $entry.success = [bool]$response.IsSuccessStatusCode
            if ($entry.success) {
                $entry.returned_claims = @($payload.claims | Where-Object { $null -ne $_ }).Count
                $entry.has_next_page = [bool]$payload.nextPageToken
                if ($entry.returned_claims -gt $plan.page_size) { throw 'The server returned more records than the page-size cap.' }
            } else {
                $entry.error_status = $payload.error.status
                $entry.error_message = ([string]$payload.error.message).Replace($secret, '[REDACTED]')
            }
        } catch {
            $entry.success = $false
            $entry.failure_type = $_.Exception.GetType().FullName
            $safeMessage = ([string]$_.Exception.Message).Replace($secret, '[REDACTED]')
            $entry.error_message = $safeMessage.Substring(0, [Math]::Min(700, $safeMessage.Length))
        } finally {
            $watch.Stop()
            $entry.elapsed_seconds = [Math]::Round($watch.Elapsed.TotalSeconds, 3)
            if ($null -ne $response) { $response.Dispose() }
            $request.Dispose()
        }
        [System.IO.File]::AppendAllText($logPath, ($entry | ConvertTo-Json -Depth 8 -Compress) + "`n", $utf8)
        $requestResults.Add([pscustomobject]$entry)
        Write-Output ('{0}: HTTP {1}; records={2}; success={3}' -f $entry.query_id, $entry.http_status, $entry.returned_claims, $entry.success)
        if ($null -eq $entry.http_status -or $entry.http_status -in @(401, 403, 429)) { break }
        if ($requestResults.Count -lt $plan.queries.Count) { Start-Sleep -Milliseconds $plan.delay_between_requests_ms }
    }
} finally {
    $client.Dispose()
    $secret = $null
}
$successCount = @($requestResults | Where-Object success).Count
$collectionSummary = [ordered]@{
    run_id = $RunId; started_at_utc = $startedAt; finished_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    planned_requests = $plan.queries.Count; requests_sent = $requestResults.Count
    successful_requests = $successCount; failed_requests = $requestResults.Count - $successCount
    raw_claim_occurrences = ($requestResults | Measure-Object returned_claims -Sum).Sum
    pagination_followed = $false; automatic_retries = 0
    status = if ($successCount -eq $plan.queries.Count) { 'completed' } else { 'partial_or_failed' }
}
[System.IO.File]::WriteAllText((Join-Path $outputDirectory 'collection-summary.json'), ($collectionSummary | ConvertTo-Json -Depth 6), $utf8)
$collectionSummary | ConvertTo-Json -Depth 6
if ($collectionSummary.failed_requests -gt 0 -or $collectionSummary.requests_sent -ne $plan.queries.Count) { exit 1 }
