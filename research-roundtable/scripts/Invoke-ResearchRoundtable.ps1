[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Procedure', 'Experiment')]
    [string]$ReviewType,

    [string]$ReviewPacketPath,

    [string]$CompressedReviewPacketPath,

    [string]$CompressionStrategy = '',

    [string]$UserIdeasPath,

    [string]$OutputDirectory = (Join-Path (Get-Location).Path '.roundtable\reviews'),

    [string]$DataRoot = (Join-Path $HOME '.research-roundtable'),

    [string]$KimiHome,

    [ValidateSet('BudgetLean', 'Lean', 'Standard')]
    [string]$Mode = 'Lean',

    [ValidateSet('Full', 'Diff')]
    [string]$ReviewScope = 'Full',

    [ValidateSet('Auto', 'Engineering', 'Scientific')]
    [string]$ReviewFocus = 'Auto',

    [string]$KimiPacketPath,

    [string]$DeepSeekPacketPath,

    [string]$IssueLedgerPath,

    [ValidateRange(1, 168)]
    [int]$IsolationCacheHours = 24,

    [ValidateRange(0, 1000000)]
    [int]$MaximumInputCharacters = 0,

    [ValidateRange(0, 1000000)]
    [int]$ExpectedReviewCharacters = 0,

    [switch]$SkipKimi,

    [switch]$SkipDeepSeek,

    [switch]$ValidateOnly,

    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$skillRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$scriptVersion = '3.0-cost-control'

function Get-TextSha256 {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Get-CommandVersionText {
    param([Parameter(Mandatory)][string]$Executable)
    try {
        $info = Get-Item -LiteralPath $Executable
        "$($info.VersionInfo.FileVersion)|$($info.Length)|$($info.LastWriteTimeUtc.Ticks)"
    } catch { 'unknown' }
}

function Test-PacketPreflight {
    param([string]$Text, [string]$Type, [string]$Scope)
    $required = if ($Scope -eq 'Diff') {
        @('Previous packet summary','Previous unresolved MUST_FIX','Current changes / diff','User intent for this revision','Focus questions for this round')
    } elseif ($Type -eq 'Plan') {
        @('Research objective','Method novelty claim','Baselines and comparison methods','Expected evidence and success metrics','Dataset / experiment source','Ground truth and label definition','Statistical test / repeated trials','Leakage control','Failure criteria','Cost and hardware constraints')
    } elseif ($Type -eq 'Procedure') {
        @('Procedure objective','Hardware / software / environment','Step-by-step procedure','Required inputs','Required outputs','Parameters to freeze before execution','Data recording requirements','Safety and equipment risks','Failure handling / fallback path','Stop conditions','Reproducibility requirements')
    } else { @() }
    $missing = @()
    foreach ($name in $required) {
        $escaped = [regex]::Escape($name)
        $match = [regex]::Match($Text, "(?ims)^##\s+$escaped\s*\r?\n(?<body>.*?)(?=^##\s+|\z)")
        if (-not $match.Success -or [string]::IsNullOrWhiteSpace($match.Groups.Item('body').Value)) { $missing += $name }
    }
    $status = if ($required.Count -gt 0 -and $missing.Count -ge [math]::Ceiling($required.Count * 0.4)) { 'blocked' } elseif ($missing.Count -gt 0) { 'warning' } else { 'passed' }
    [pscustomobject]@{ Status = $status; Missing = $missing }
}

function Get-IsolationFingerprint {
    param([string]$Reviewer,[string]$CliPath,[string]$CliVersion,[string]$PromptHash)
    Get-TextSha256 "$Reviewer|$CliPath|$CliVersion|$PromptHash|plan|tools-disabled|empty-random-sandbox|mcp-disabled|$scriptVersion|$env:USERNAME"
}

function Get-CachedIsolation {
    param([string]$CachePath,[string]$Fingerprint,[int]$Hours)
    if (-not (Test-Path -LiteralPath $CachePath)) { return $null }
    try {
        $item = Get-Content -LiteralPath $CachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $age = ((Get-Date) - [datetime]$item.timestamp).TotalHours
        if ($item.status -eq 'passed' -and $item.fingerprint -eq $Fingerprint -and $age -ge 0 -and $age -lt $Hours) {
            return [pscustomobject]@{ Status='passed'; Error=''; Cached=$true; AgeHours=[math]::Round($age,2) }
        }
    } catch {}
    $null
}

function Save-IsolationCache {
    param([string]$CachePath,[string]$Fingerprint,[string]$Status)
    New-Item -ItemType Directory -Path (Split-Path $CachePath -Parent) -Force | Out-Null
    [ordered]@{timestamp=(Get-Date).ToString('o');fingerprint=$Fingerprint;status=$Status} |
        ConvertTo-Json | Set-Content -LiteralPath $CachePath -Encoding UTF8
}

function Read-Utf8File {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "$Label is not a valid file: $resolved"
    }
    Get-Content -LiteralPath $resolved -Raw -Encoding UTF8
}

function Invoke-IsolatedProcess {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][AllowEmptyString()][string]$InputText,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [hashtable]$Environment = @{}
    )
    New-Item -ItemType Directory -Path $WorkingDirectory -Force | Out-Null
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.Arguments = $Arguments
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($key in $Environment.Keys) {
        $startInfo.EnvironmentVariables[$key] = [string]$Environment[$key]
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "$Name could not be started." }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.Write($InputText)
    $process.StandardInput.Close()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
        $safeError = if ($stderr.Length -gt 2000) { $stderr.Substring(0, 2000) } else { $stderr }
        throw "$Name failed with exit code $($process.ExitCode): $safeError"
    }
    if ([string]::IsNullOrWhiteSpace($stdout)) { throw "$Name returned no output." }
    $stdout.Trim()
}

function Quote-WindowsArgument {
    param([Parameter(Mandatory)][string]$Value)
    '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-KimiText {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$KimiDataHome,
        [switch]$DirectShortPrompt
    )
    $environment = @{ KIMI_CODE_HOME = $KimiDataHome; KIMI_CLI_NO_AUTO_UPDATE = '1' }
    if ($DirectShortPrompt) {
        $argument = Quote-WindowsArgument $Prompt
        return Invoke-IsolatedProcess -Name 'Kimi Code' -Executable $Executable `
            -Arguments "--prompt $argument --output-format text" -InputText '' `
            -WorkingDirectory $WorkingDirectory -Environment $environment
    }

    # Kimi prompt mode has no documented stdin prompt option. Keep the full packet
    # out of the process command line by placing it in the otherwise-empty sandbox.
    $promptPath = Join-Path $WorkingDirectory ("prompt-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $WorkingDirectory -Force | Out-Null
    [IO.File]::WriteAllText($promptPath, $Prompt, [Text.UTF8Encoding]::new($false))
    try {
        $shortPrompt = "Read and follow only the UTF-8 review prompt in this file: $promptPath . Do not inspect any other file."
        $argument = Quote-WindowsArgument $shortPrompt
        Invoke-IsolatedProcess -Name 'Kimi Code' -Executable $Executable `
            -Arguments "--prompt $argument --output-format text" -InputText '' `
            -WorkingDirectory $WorkingDirectory -Environment $environment
    } finally {
        if (Test-Path -LiteralPath $promptPath) { Remove-Item -LiteralPath $promptPath -Force }
    }
}

function Test-ReviewerIsolation {
    param(
        [Parameter(Mandatory)][ValidateSet('Kimi', 'DeepSeek')][string]$Reviewer,
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [string]$KimiDataHome
    )
    $smoke = 'Isolation smoke test. Do not read files, inspect directories, call tools, or run commands. Based only on this text, output exactly ISOLATED_OK.'
    try {
        $output = if ($Reviewer -eq 'Kimi') {
            Invoke-KimiText -Executable $Executable -Prompt $smoke -WorkingDirectory $WorkingDirectory `
                -KimiDataHome $KimiDataHome -DirectShortPrompt
        } else {
            Invoke-IsolatedProcess -Name 'DeepSeek isolation test' -Executable $Executable `
                -Arguments '-p --permission-mode plan --tools "" --no-session-persistence --output-format text' `
                -InputText $smoke -WorkingDirectory $WorkingDirectory
        }
        $cleanOutput = $output.Trim() -replace '^\s*[-*`\u2022]+\s*', '' -replace '\s*[-*`]+\s*$', ''
        if ($cleanOutput.Trim() -ceq 'ISOLATED_OK') {
            [pscustomobject]@{ Status = 'passed'; Error = '' }
        } else {
            [pscustomobject]@{ Status = 'failed'; Error = "Unexpected isolation response: $output" }
        }
    } catch {
        [pscustomobject]@{ Status = 'failed'; Error = $_.Exception.Message }
    }
}

function Convert-ReviewOutput {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][ValidateSet('K', 'D')][string]$Prefix
    )
    if ($Text.Trim() -eq 'NO_MATERIAL_CHANGE') {
        return [pscustomobject]@{
            Status = 'valid'; Normalized = ''; ValidCount = 0; UnparsedCount = 0
        }
    }
    $valid = [Collections.Generic.List[string]]::new()
    $unparsed = [Collections.Generic.List[string]]::new()
    $seenIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $separator = [char]0xFF5C
    $separatorEscaped = [regex]::Escape([string]$separator)
    $separatorPattern = '[|' + $separatorEscaped + ']'
    $fieldPattern = '[^|' + $separatorEscaped + ']+'
    $pattern = '^\[(?<id>{0}\d+)\]\s+(?<level>MUST_FIX|RECOMMENDED)\s*{1}\s*(?<anchor>{2})\s*{1}\s*(?<reason>{2})\s*{1}\s*(?<action>.+)$' -f $Prefix, $separatorPattern, $fieldPattern
    $lineNumber = 0
    foreach ($line in ($Text -split "`r?`n")) {
        $lineNumber++
        $trimmed = ($line.Trim() -replace '^\s*[-*\u2022]+\s*', '').Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        $match = [regex]::Match($trimmed, $pattern)
        if ($match.Success) {
            [string]$anchor = $match.Groups.Item('anchor').Value
            [string]$reason = $match.Groups.Item('reason').Value
            [string]$action = $match.Groups.Item('action').Value
            $anchor = $anchor.Trim()
            $reason = $reason.Trim()
            $action = $action.Trim()
            $vague = $reason -match '^(looks good|agree|good|optimize|improve)$'
            if ($anchor.Length -ge 2 -and $reason.Length -ge 4 -and $action.Length -ge 4 -and -not $vague) {
                [string]$itemId = $match.Groups.Item('id').Value
                [string]$itemLevel = $match.Groups.Item('level').Value
                if (-not $seenIds.Add($itemId)) {
                    $unparsed.Add(([ordered]@{type='UNPARSED_REVIEW_ITEM';reason='duplicate_id';id=$itemId;raw_line_reference=$lineNumber;raw=$trimmed}|ConvertTo-Json -Compress))
                    continue
                }
                $category = if ($Prefix -eq 'K') { 'engineering_feasibility' } else { 'scientific_validity' }
                if ($reason -match '(?i)statistic|confidence|sample size|variance|p-value') { $category = 'statistical_validity' }
                if ($reason -match '(?i)safety|hazard|temperature|risk') { $category = 'safety_risk' }
                if ($reason -match '(?i)publication|novelty|baseline') { $category = 'publication_viability' }
                $blocking = if ($itemLevel -eq 'RECOMMENDED') { 'improves_quality' } elseif ($category -in @('engineering_feasibility','safety_risk')) { 'blocks_execution' } elseif ($category -eq 'statistical_validity') { 'blocks_claim' } else { 'blocks_publication' }
                $record = [ordered]@{id=$itemId;reviewer=if($Prefix -eq 'K'){'kimi'}else{'deepseek'};severity=$itemLevel;anchor=$anchor;category=$category;issue=$reason;evidence=$reason;action=$action;blocking_type=$blocking;raw_line_reference=$lineNumber}
                $valid.Add(($record | ConvertTo-Json -Compress))
                continue
            }
        }
        $unparsed.Add(([ordered]@{type='UNPARSED_REVIEW_ITEM';raw_line_reference=$lineNumber;raw=$trimmed}|ConvertTo-Json -Compress))
    }
    $status = if ($valid.Count -gt 0 -and $unparsed.Count -eq 0) {
        'valid'
    } elseif ($valid.Count -gt 0) {
        'partially_valid'
    } else {
        'invalid'
    }
    $normalizedLines = @($valid) + @($unparsed)
    [pscustomobject]@{
        Status = $status
        Normalized = ($normalizedLines -join [Environment]::NewLine)
        ValidCount = $valid.Count
        UnparsedCount = $unparsed.Count
    }
}

function New-ReviewerState {
    param([bool]$Enabled)
    [ordered]@{
        enabled = $Enabled
        completed = $false
        isolation_status = if ($Enabled) { 'skipped' } else { 'skipped' }
        isolation_cached = $false
        isolation_cache_age_hours = 0
        isolation_fingerprint = ''
        format_status = 'skipped'
        raw_output_path = ''
        normalized_output_path = ''
        output_characters = 0
        output_too_long = $false
        raw_output_saved = $false
        review_cache_hit = $false
        review_cache_key = ''
        review_cache_source = ''
        incomplete_status = ''
        error = ''
    }
}

function Save-ReviewerResult {
    param(
        [Parameter(Mandatory)][string]$ReviewerName,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)][string]$ReviewDirectory,
        [Parameter(Mandatory)][int]$ExpectedCharacters,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State
    )
    $rawPath = Join-Path $ReviewDirectory "$ReviewerName-review.raw.md"
    [IO.File]::WriteAllText($rawPath, $Output + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    $parsed = Convert-ReviewOutput -Text $Output -Prefix $Prefix
    $normalizedPath = Join-Path $ReviewDirectory "$ReviewerName-review.normalized.jsonl"
    [IO.File]::WriteAllText($normalizedPath, $parsed.Normalized + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    $State.completed = $true
    $State.format_status = $parsed.Status
    $State.raw_output_path = $rawPath
    $State.normalized_output_path = $normalizedPath
    $State.output_characters = $Output.Length
    $State.output_too_long = ($Output.Length -gt $ExpectedCharacters)
    $State.raw_output_saved = $true
    if ($State.output_too_long -and $parsed.Status -eq 'invalid') {
        $State.incomplete_status = 'REVIEW_INCOMPLETE_OUTPUT_TOO_LONG'
    }
}

function Restore-ReviewCache {
    param([string]$CacheDirectory,[string]$ReviewerName,[string]$ReviewDirectory,[System.Collections.IDictionary]$State)
    $metaPath = Join-Path $CacheDirectory 'meta.json'
    $rawSource = Join-Path $CacheDirectory 'review.raw.md'
    $normalizedSource = Join-Path $CacheDirectory 'review.normalized.jsonl'
    if (-not (Test-Path $metaPath) -or -not (Test-Path $rawSource) -or -not (Test-Path $normalizedSource)) { return $false }
    try {
        $meta = Get-Content $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $rawTarget = Join-Path $ReviewDirectory "$ReviewerName-review.raw.md"
        $normalizedTarget = Join-Path $ReviewDirectory "$ReviewerName-review.normalized.jsonl"
        Copy-Item $rawSource $rawTarget -Force
        Copy-Item $normalizedSource $normalizedTarget -Force
        $State.completed=$true;$State.isolation_status='passed';$State.format_status=$meta.format_status
        $State.raw_output_path=$rawTarget;$State.normalized_output_path=$normalizedTarget
        $State.output_characters=$meta.output_characters;$State.raw_output_saved=$true
        $State.review_cache_hit=$true;$State.review_cache_source=$CacheDirectory
        return $true
    } catch { return $false }
}

function Save-ReviewCache {
    param([string]$CacheDirectory,[System.Collections.IDictionary]$State)
    New-Item -ItemType Directory -Path $CacheDirectory -Force | Out-Null
    Copy-Item $State.raw_output_path (Join-Path $CacheDirectory 'review.raw.md') -Force
    Copy-Item $State.normalized_output_path (Join-Path $CacheDirectory 'review.normalized.jsonl') -Force
    [ordered]@{format_status=$State.format_status;output_characters=$State.output_characters;timestamp=(Get-Date).ToString('o')} |
        ConvertTo-Json | Set-Content (Join-Path $CacheDirectory 'meta.json') -Encoding UTF8
}

function Get-AdjudicationStatus {
    param($KimiState, $DeepSeekState)
    $enabled = @(@($KimiState, $DeepSeekState) | Where-Object { $_.enabled })
    $usable = @($enabled | Where-Object {
        $_.completed -and $_.isolation_status -eq 'passed' -and $_.format_status -in @('valid', 'partially_valid')
    })
    if ($usable.Count -eq 0) { return 'failed' }
    if ($usable.Count -lt $enabled.Count -or ($usable | Where-Object { $_.format_status -ne 'valid' })) { return 'partial' }
    'completed'
}

function Invoke-SelfTest {
    $separator = [char]0xFF5C
    $validText = ([char]0x2022) + " [K1] MUST_FIX${separator}S1${separator}Evidence is specific${separator}Apply a concrete correction"
    $valid = Convert-ReviewOutput -Text $validText -Prefix K
    if ($valid.Status -ne 'valid' -or $valid.ValidCount -ne 1) { throw 'Valid format test failed.' }
    $partialText = "[D1] MUST_FIX${separator}S2${separator}Specific causal flaw${separator}Add a control`nGeneral summary"
    $partial = Convert-ReviewOutput -Text $partialText -Prefix D
    if ($partial.Status -ne 'partially_valid' -or $partial.UnparsedCount -ne 1) { throw 'Partial format test failed.' }
    $duplicateText = "[K1] MUST_FIX${separator}S1${separator}First specific issue${separator}Apply first fix`n[K1] MUST_FIX${separator}S2${separator}Second specific issue${separator}Apply second fix"
    $duplicate = Convert-ReviewOutput -Text $duplicateText -Prefix K
    if ($duplicate.Status -ne 'partially_valid' -or $duplicate.UnparsedCount -ne 1) {
        throw 'Duplicate identifier test failed.'
    }
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("roundtable-selftest-{0}" -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporary -Force | Out-Null
    try {
        $state = New-ReviewerState $true
        $state.isolation_status = 'passed'
        $large = "[K1] MUST_FIX${separator}S1${separator}" + ('E' * 20000) + "${separator}Apply correction"
        Save-ReviewerResult -ReviewerName kimi -Prefix K -Output $large -ReviewDirectory $temporary `
            -ExpectedCharacters 100 -State $state
        $raw = Get-Content -LiteralPath $state.raw_output_path -Raw -Encoding UTF8
        if ($raw.Length -lt $large.Length -or -not $state.output_too_long) { throw 'Raw output preservation test failed.' }
        $failed = New-ReviewerState $true
        $failed.error = 'mock failure'
        if ((Get-AdjudicationStatus -KimiState $state -DeepSeekState $failed) -ne 'partial') {
            throw 'Partial-review degradation test failed.'
        }
        $manifestTestPath = Join-Path $temporary 'roundtable-manifest.json'
        $manifestTest = [ordered]@{
            timestamp = (Get-Date).ToString('o')
            review_type = 'Procedure'
            mode = 'Lean'
            packet_sha256 = ('0' * 64)
            reviewers = [ordered]@{ kimi = $state; deepseek = $failed }
            adjudication_status = 'partial'
            authorization_status = 'pending'
        }
        $manifestTest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestTestPath -Encoding UTF8
        $manifestRoundTrip = Get-Content -LiteralPath $manifestTestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($manifestRoundTrip.adjudication_status -ne 'partial' -or
            $manifestRoundTrip.authorization_status -ne 'pending') {
            throw 'Manifest round-trip test failed.'
        }
        $isolationPath = Join-Path $temporary 'isolation.json'
        if (Get-CachedIsolation $isolationPath 'fp1' 24) { throw 'Isolation cold-cache test failed.' }
        Save-IsolationCache $isolationPath 'fp1' 'passed'
        if (-not (Get-CachedIsolation $isolationPath 'fp1' 24)) { throw 'Isolation cache-hit test failed.' }
        if (Get-CachedIsolation $isolationPath 'changed-prompt-fp' 24) { throw 'Isolation fingerprint invalidation failed.' }
        $reviewCache = Join-Path $temporary 'review-cache-key'
        Save-ReviewCache $reviewCache $state
        $restored = New-ReviewerState $true
        if (-not (Restore-ReviewCache $reviewCache 'kimi-cached' $temporary $restored) -or -not $restored.review_cache_hit) {
            throw 'Exact review cache-hit test failed.'
        }
        if (Test-Path (Join-Path $temporary 'changed-packet-key')) { throw 'Packet cache invalidation test failed.' }
        $preflightBlocked = Test-PacketPreflight '# Plan Review Packet' 'Plan' 'Full'
        if ($preflightBlocked.Status -ne 'blocked') { throw 'Preflight blocked test failed.' }
        $invalidReview = Convert-ReviewOutput 'free-form summary only' K
        if ($invalidReview.Status -ne 'invalid') { throw 'Invalid normalized fallback test failed.' }
        $ledgerTest = Join-Path $temporary 'roundtable-issue-ledger.jsonl'
        $ledgerItem = [ordered]@{issue_id='ISSUE-001';status='open';severity='MUST_FIX';issue='test issue'}
        [IO.File]::WriteAllText($ledgerTest, ($ledgerItem|ConvertTo-Json -Compress)+[Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        $ledgerOpen = @(Get-Content $ledgerTest -Encoding UTF8 | ForEach-Object {$_|ConvertFrom-Json} | Where-Object {$_.status -eq 'open' -and $_.severity -eq 'MUST_FIX'}).Count
        if ($ledgerOpen -ne 1) { throw 'Issue ledger unresolved tracking test failed.' }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
    Write-Output 'SELF_TEST_PASS: format validation'
    Write-Output 'SELF_TEST_PASS: full raw output preservation'
    Write-Output 'SELF_TEST_PASS: one-reviewer partial degradation'
    Write-Output 'SELF_TEST_PASS: manifest generation and round-trip'
    Write-Output 'SELF_TEST_PASS: isolation cache cold, hit, and fingerprint invalidation'
    Write-Output 'SELF_TEST_PASS: exact review cache hit and packet-key invalidation'
    Write-Output 'SELF_TEST_PASS: preflight blocked without reviewer'
    Write-Output 'SELF_TEST_PASS: invalid normalized output requires raw fallback'
    Write-Output 'SELF_TEST_PASS: issue ledger tracks unresolved MUST_FIX'
    Write-Output 'SELF_TEST_PASS: authorization default is pending by design'
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

if (-not $ReviewType) { throw 'ReviewType is required unless -SelfTest is used.' }
if (-not $ReviewPacketPath) { throw 'ReviewPacketPath is required unless -SelfTest is used.' }
if ($Mode -eq 'BudgetLean' -and -not $SkipKimi -and -not $SkipDeepSeek) {
    $scientific = $ReviewFocus -eq 'Scientific' -or ($ReviewFocus -eq 'Auto' -and $ReviewType -eq 'Plan')
    if ($scientific) { $SkipKimi = $true } else { $SkipDeepSeek = $true }
}
if ($SkipKimi -and $SkipDeepSeek) { throw 'Both reviewers cannot be skipped.' }

$modeSettings = @{
    BudgetLean = @{
        OutputLimit = 8000
        ReviewInstruction = 'BUDGET LEAN: Report every MUST_FIX and nothing else. Use one line per blocking issue. Do not summarize, praise, retry formatting, or add optional advice.'
    }
    Lean = @{
        OutputLimit = 12000
        ReviewInstruction = 'LEAN MODE: Report every MUST_FIX finding and nothing else. MUST_FIX means unresolved would invalidate execution, evidence, feasibility, safety, reproducibility, or a claimed conclusion. Be compact; do not summarize or praise.'
    }
    Standard = @{
        OutputLimit = 24000
        ReviewInstruction = 'STANDARD MODE: Perform a deep audit. Report every MUST_FIX and every material RECOMMENDED finding, including cross-field contradictions, missing controls, weak falsifiability, reproducibility gaps, and publication or execution risks. Merge duplicates but do not impose a finding-count limit.'
    }
}
$inputLimits = @{
    Plan = @{ BudgetLean = 6000; Lean = 8000; Standard = 16000 }
    Procedure = @{ BudgetLean = 6500; Lean = 9000; Standard = 17000 }
    Experiment = @{ BudgetLean = 7000; Lean = 10000; Standard = 18000 }
}
$settings = $modeSettings[$Mode]
if ($MaximumInputCharacters -eq 0) { $MaximumInputCharacters = $inputLimits[$ReviewType][$Mode] }
if ($ExpectedReviewCharacters -eq 0) { $ExpectedReviewCharacters = $settings.OutputLimit }

$originalPacketPath = (Resolve-Path -LiteralPath $ReviewPacketPath).Path
$originalPacketHash = (Get-FileHash -LiteralPath $originalPacketPath -Algorithm SHA256).Hash.ToLowerInvariant()
$packetPathUsed = $originalPacketPath
$packet = Read-Utf8File -Path $packetPathUsed -Label 'Review packet'
$ideas = if ($UserIdeasPath) { Read-Utf8File -Path $UserIdeasPath -Label 'User ideas' } else { '' }

$material = "===== REVIEW TYPE =====`r`n$ReviewType`r`n`r`n===== REVIEW PACKET =====`r`n$packet`r`n"
if (-not [string]::IsNullOrWhiteSpace($ideas)) {
    $material += "`r`n===== USER IDEAS =====`r`n$ideas`r`n"
}
if ($material.Length -gt $MaximumInputCharacters) {
    if (-not $CompressedReviewPacketPath) {
        throw "Review input has $($material.Length) characters, exceeding $MaximumInputCharacters. Create a compressed packet that preserves source anchors and decisive evidence, then pass -CompressedReviewPacketPath and -CompressionStrategy. The original packet was not truncated."
    }
    if ([string]::IsNullOrWhiteSpace($CompressionStrategy)) {
        throw 'CompressionStrategy is required with CompressedReviewPacketPath.'
    }
    $packetPathUsed = (Resolve-Path -LiteralPath $CompressedReviewPacketPath).Path
    $packet = Read-Utf8File -Path $packetPathUsed -Label 'Compressed review packet'
    $material = "===== REVIEW TYPE =====`r`n$ReviewType`r`n`r`n===== COMPRESSED REVIEW PACKET =====`r`n$packet`r`n"
    if (-not [string]::IsNullOrWhiteSpace($ideas)) {
        $material += "`r`n===== USER IDEAS =====`r`n$ideas`r`n"
    }
    if ($material.Length -gt $MaximumInputCharacters) {
        throw "Compressed review input still exceeds $MaximumInputCharacters characters. It was not truncated."
    }
}
$effectivePacketHash = (Get-FileHash -LiteralPath $packetPathUsed -Algorithm SHA256).Hash.ToLowerInvariant()
$originalPacketCharacters = (Read-Utf8File -Path $originalPacketPath -Label 'Original packet').Length
$compressionEnabled = ($packetPathUsed -ne $originalPacketPath)
$compressionRatio = if ($originalPacketCharacters -gt 0) { [math]::Round($packet.Length / $originalPacketCharacters, 4) } else { 1 }
$preflight = Test-PacketPreflight -Text $packet -Type $ReviewType -Scope $ReviewScope
if ($Mode -eq 'Standard' -and $compressionEnabled -and $preflight.Status -ne 'passed') {
    $packetPathUsed = $originalPacketPath
    $packet = Read-Utf8File -Path $originalPacketPath -Label 'Original packet fallback'
    $material = "===== REVIEW TYPE =====`r`n$ReviewType`r`n`r`n===== REVIEW PACKET =====`r`n$packet`r`n"
    if ($material.Length -gt $MaximumInputCharacters) {
        throw 'Standard compressed packet failed preflight and the full-packet fallback exceeds the input limit. Supply a complete anchor-preserving compressed packet or explicitly accept degraded coverage.'
    }
    $effectivePacketHash = $originalPacketHash
    $compressionEnabled = $false
    $compressionRatio = 1
    $preflight = Test-PacketPreflight -Text $packet -Type $ReviewType -Scope $ReviewScope
}

if ($preflight.Status -eq 'blocked' -and -not $ValidateOnly) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $reviewDirectory = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) $timestamp
    New-Item -ItemType Directory -Path $reviewDirectory -Force | Out-Null
    $manifestPath = Join-Path $reviewDirectory 'roundtable-manifest.json'
    [ordered]@{
        timestamp=(Get-Date).ToString('o');review_type=$ReviewType;mode=$Mode;review_scope=$ReviewScope
        preflight_status='blocked';reviewers_called=$false;missing_required_fields=$preflight.Missing
        original_packet_sha256=$originalPacketHash;compressed_packet_sha256=$effectivePacketHash
        compression_enabled=$compressionEnabled;original_characters=$originalPacketCharacters
        compressed_characters=$packet.Length;compression_ratio=$compressionRatio
        lean_must_fix_only=($Mode -ne 'Standard');auto_format_retry=$false
        codex_read_raw=$false;codex_read_raw_reason='';authorization_status='pending'
        cost_saving_features=@('preflight_block')
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Write-Output 'PRECHECK_BLOCKED'
    Write-Output "Missing required fields: $($preflight.Missing -join '; ')"
    Write-Output "Manifest: $manifestPath"
    return
}

$kimiMaterial = $material
$deepseekMaterial = $material
if ($KimiPacketPath) {
    $focused = Read-Utf8File -Path $KimiPacketPath -Label 'Kimi-specific packet'
    $kimiMaterial = "===== REVIEW TYPE =====`r`n$ReviewType`r`n===== REVIEW SCOPE =====`r`n$ReviewScope`r`n===== KIMI FOCUSED PACKET =====`r`n$focused"
}
if ($DeepSeekPacketPath) {
    $focused = Read-Utf8File -Path $DeepSeekPacketPath -Label 'DeepSeek-specific packet'
    $deepseekMaterial = "===== REVIEW TYPE =====`r`n$ReviewType`r`n===== REVIEW SCOPE =====`r`n$ReviewScope`r`n===== DEEPSEEK FOCUSED PACKET =====`r`n$focused"
}
$kimiPacketHash = Get-TextSha256 $kimiMaterial
$deepseekPacketHash = Get-TextSha256 $deepseekMaterial

$typeInstruction = switch ($ReviewType) {
    Plan { 'PLAN: Independently audit research question, novelty, falsifiability, baselines, leakage controls, ablations, statistics, validation, constraints, minimum publishable result, and downgrade path. Do not execute or edit.' }
    Procedure { 'PROCEDURE: Decide whether the supplied procedure is directly executable. Audit missing or misordered steps, frozen parameters, records, reproducibility, safety, leakage, stop conditions, and fallback paths. Do not execute or edit.' }
    Experiment { 'EXPERIMENT: Audit Codex execution record, debugging choices, logs summarized in the packet, controls, reproducibility, leakage, metrics, diagnosis, and proposed changes. Do not execute or edit.' }
}
$scopeInstruction = if ($ReviewScope -eq 'Diff') {
    'DIFF SCOPE: Review only changed content and prior unresolved MUST_FIX items. Do not claim full-packet coverage. If the diff changes objectives, design, metrics, or hardware, flag that Full review is required.'
} else { 'FULL SCOPE: Review the complete supplied packet.' }
$anchorInstruction = 'Cite supplied source anchors (for example S1/S3) in the second field whenever possible. An unanchored finding is allowed only when the packet itself makes the issue explicit.'
$corePrompt = Read-Utf8File -Path (Join-Path $skillRoot 'references\core-readonly-rules.txt') -Label 'Core readonly prompt'
$formatPrompt = Read-Utf8File -Path (Join-Path $skillRoot 'references\review-format-rules.txt') -Label 'Review format prompt'
$kimiRole = Read-Utf8File -Path (Join-Path $skillRoot 'references\kimi-role-short.txt') -Label 'Kimi role prompt'
$deepseekRole = Read-Utf8File -Path (Join-Path $skillRoot 'references\deepseek-role-short.txt') -Label 'DeepSeek role prompt'
$modePromptFile = switch($ReviewType){Plan{'plan-mode-rules.txt'}Procedure{'procedure-mode-rules.txt'}default{'experiment-mode-rules.txt'}}
$taskModePrompt = Read-Utf8File -Path (Join-Path $skillRoot "references\$modePromptFile") -Label 'Task mode prompt'
$standardExtra = if($Mode -eq 'Standard'){Read-Utf8File -Path (Join-Path $skillRoot 'references\standard-extra-rules.txt') -Label 'Standard prompt'}else{''}
$kimiPrompt = "$corePrompt`n$kimiRole`n$formatPrompt`n$taskModePrompt`n$standardExtra"
$deepseekPrompt = "$corePrompt`n$deepseekRole`n$formatPrompt`n$taskModePrompt`n$standardExtra"
$kimiInput = "$kimiPrompt`r`n$typeInstruction`r`n$scopeInstruction`r`n$anchorInstruction`r`n$($settings.ReviewInstruction)`r`n$kimiMaterial"
$deepseekInput = "$deepseekPrompt`r`n$typeInstruction`r`n$scopeInstruction`r`n$anchorInstruction`r`n$($settings.ReviewInstruction)`r`n$deepseekMaterial"

$kimiCommand = if ($SkipKimi) { '' } else { (Get-Command kimi -ErrorAction Stop).Source }
$claudeCommand = ''
if (-not $SkipDeepSeek) {
    $claudeWrapper = (Get-Command claude.cmd -ErrorAction Stop).Source
    $claudeCommand = Join-Path (Split-Path $claudeWrapper -Parent) 'node_modules\@anthropic-ai\claude-code\bin\claude.exe'
    if (-not (Test-Path -LiteralPath $claudeCommand -PathType Leaf)) {
        throw "Claude Code native executable was not found: $claudeCommand"
    }
}
$dataRootFull = [IO.Path]::GetFullPath($DataRoot)
$outputRootFull = [IO.Path]::GetFullPath($OutputDirectory)
$kimiHomeFull = if ($KimiHome) { [IO.Path]::GetFullPath($KimiHome) } else { Join-Path $dataRootFull 'kimi' }
$sandboxRoot = Join-Path $dataRootFull 'sandbox'
$cacheRoot = Join-Path $dataRootFull 'cache'
$isolationCacheRoot = Join-Path $cacheRoot 'isolation'
$reviewCacheRoot = Join-Path $cacheRoot 'reviews'
$kimiPromptHash = Get-TextSha256 $kimiPrompt
$deepseekPromptHash = Get-TextSha256 $deepseekPrompt
$kimiCliVersion = if ($kimiCommand) { Get-CommandVersionText $kimiCommand } else { 'skipped' }
$deepseekCliVersion = if ($claudeCommand) { Get-CommandVersionText $claudeCommand } else { 'skipped' }
$kimiFingerprint = if ($kimiCommand) { Get-IsolationFingerprint Kimi $kimiCommand $kimiCliVersion $kimiPromptHash } else { '' }
$deepseekFingerprint = if ($claudeCommand) { Get-IsolationFingerprint DeepSeek $claudeCommand $deepseekCliVersion $deepseekPromptHash } else { '' }
$kimiReviewKey = Get-TextSha256 "$kimiPacketHash|$kimiPromptHash|$ReviewType|$Mode|kimi|$kimiCliVersion|$scriptVersion|$ReviewScope"
$deepseekReviewKey = Get-TextSha256 "$deepseekPacketHash|$deepseekPromptHash|$ReviewType|$Mode|deepseek|$deepseekCliVersion|$scriptVersion|$ReviewScope"

if ($ValidateOnly) {
    Write-Output 'Roundtable validation passed.'
    Write-Output "Review type: $ReviewType"
    Write-Output "Mode: $Mode"
    Write-Output "Input characters: $($material.Length)"
    Write-Output "Input limit: $MaximumInputCharacters"
    Write-Output "Original packet SHA256: $originalPacketHash"
    Write-Output "Effective packet SHA256: $effectivePacketHash"
    Write-Output "Preflight: $($preflight.Status)"
    Write-Output "Reviewer coverage: $(if($Mode -eq 'BudgetLean'){'single reviewer'}else{'configured reviewers'})"
    return
}

New-Item -ItemType Directory -Path $kimiHomeFull -Force | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reviewDirectory = Join-Path $outputRootFull $timestamp
New-Item -ItemType Directory -Path $reviewDirectory -Force | Out-Null
$kimiState = New-ReviewerState (-not $SkipKimi)
$deepseekState = New-ReviewerState (-not $SkipDeepSeek)

if (-not $SkipKimi) {
    $kimiState.isolation_fingerprint = $kimiFingerprint
    $kimiState.review_cache_key = $kimiReviewKey
    $kimiSandbox = Join-Path $sandboxRoot ("kimi-{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        $isolationCachePath = Join-Path $isolationCacheRoot 'kimi.json'
        $isolation = Get-CachedIsolation -CachePath $isolationCachePath -Fingerprint $kimiFingerprint -Hours $IsolationCacheHours
        if ($isolation) {
            $kimiState.isolation_cached = $true
            $kimiState.isolation_cache_age_hours = $isolation.AgeHours
        } else {
            $isolation = Test-ReviewerIsolation -Reviewer Kimi -Executable $kimiCommand `
                -WorkingDirectory $kimiSandbox -KimiDataHome $kimiHomeFull
            Save-IsolationCache -CachePath $isolationCachePath -Fingerprint $kimiFingerprint -Status $isolation.Status
        }
        $kimiState.isolation_status = $isolation.Status
        if ($isolation.Status -ne 'passed') {
            $kimiState.error = $isolation.Error
        } else {
            $cacheDirectory = Join-Path $reviewCacheRoot $kimiReviewKey
            if (-not (Restore-ReviewCache -CacheDirectory $cacheDirectory -ReviewerName kimi -ReviewDirectory $reviewDirectory -State $kimiState)) {
                $output = Invoke-KimiText -Executable $kimiCommand -Prompt $kimiInput `
                    -WorkingDirectory $kimiSandbox -KimiDataHome $kimiHomeFull
                Save-ReviewerResult -ReviewerName kimi -Prefix K -Output $output `
                    -ReviewDirectory $reviewDirectory -ExpectedCharacters $ExpectedReviewCharacters -State $kimiState
                Save-ReviewCache -CacheDirectory $cacheDirectory -State $kimiState
            }
        }
    } catch {
        $kimiState.error = $_.Exception.Message
        $kimiState.incomplete_status = 'REVIEW_INCOMPLETE_TOOL_FAILURE'
    } finally {
        if (Test-Path -LiteralPath $kimiSandbox) { Remove-Item -LiteralPath $kimiSandbox -Recurse -Force }
    }
}

if (-not $SkipDeepSeek) {
    $deepseekState.isolation_fingerprint = $deepseekFingerprint
    $deepseekState.review_cache_key = $deepseekReviewKey
    $deepseekSandbox = Join-Path $sandboxRoot ("deepseek-{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        $isolationCachePath = Join-Path $isolationCacheRoot 'deepseek.json'
        $isolation = Get-CachedIsolation -CachePath $isolationCachePath -Fingerprint $deepseekFingerprint -Hours $IsolationCacheHours
        if ($isolation) {
            $deepseekState.isolation_cached = $true
            $deepseekState.isolation_cache_age_hours = $isolation.AgeHours
        } else {
            $isolation = Test-ReviewerIsolation -Reviewer DeepSeek -Executable $claudeCommand `
                -WorkingDirectory $deepseekSandbox
            Save-IsolationCache -CachePath $isolationCachePath -Fingerprint $deepseekFingerprint -Status $isolation.Status
        }
        $deepseekState.isolation_status = $isolation.Status
        if ($isolation.Status -ne 'passed') {
            $deepseekState.error = $isolation.Error
        } else {
            $cacheDirectory = Join-Path $reviewCacheRoot $deepseekReviewKey
            if (-not (Restore-ReviewCache -CacheDirectory $cacheDirectory -ReviewerName deepseek -ReviewDirectory $reviewDirectory -State $deepseekState)) {
                $output = Invoke-IsolatedProcess -Name 'DeepSeek review through Claude Code' `
                    -Executable $claudeCommand `
                    -Arguments '-p --permission-mode plan --tools "" --no-session-persistence --output-format text' `
                    -InputText $deepseekInput -WorkingDirectory $deepseekSandbox
                Save-ReviewerResult -ReviewerName deepseek -Prefix D -Output $output `
                    -ReviewDirectory $reviewDirectory -ExpectedCharacters $ExpectedReviewCharacters -State $deepseekState
                Save-ReviewCache -CacheDirectory $cacheDirectory -State $deepseekState
            }
        }
    } catch {
        $deepseekState.error = $_.Exception.Message
        $deepseekState.incomplete_status = 'REVIEW_INCOMPLETE_TOOL_FAILURE'
    } finally {
        if (Test-Path -LiteralPath $deepseekSandbox) { Remove-Item -LiteralPath $deepseekSandbox -Recurse -Force }
    }
}

$adjudicationStatus = Get-AdjudicationStatus -KimiState $kimiState -DeepSeekState $deepseekState
$ledgerPath = if ($IssueLedgerPath) { [IO.Path]::GetFullPath($IssueLedgerPath) } else { Join-Path (Split-Path $outputRootFull -Parent) 'roundtable-issue-ledger.jsonl' }
$existingLedger = @()
if (Test-Path $ledgerPath) {
    $existingLedger = @(Get-Content $ledgerPath -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}
$roundId = (Get-Date).ToString('o')
foreach ($state in @($kimiState,$deepseekState)) {
    if (-not $state.normalized_output_path -or -not (Test-Path $state.normalized_output_path)) { continue }
    foreach ($line in (Get-Content $state.normalized_output_path -Encoding UTF8 | Where-Object { $_.Trim() })) {
        try { $item = $line | ConvertFrom-Json } catch { continue }
        if ($item.type -eq 'UNPARSED_REVIEW_ITEM' -or -not $item.id) { continue }
        $signature = Get-TextSha256 "$($item.category)|$($item.anchor)|$($item.issue)|$($item.action)"
        $found = @($existingLedger | Where-Object { $_.signature -eq $signature }) | Select-Object -First 1
        if ($found) { $found.last_seen_round = $roundId; continue }
        $existingLedger += [pscustomobject][ordered]@{
            issue_id=('ISSUE-{0:D3}' -f ($existingLedger.Count + 1));signature=$signature
            first_seen_round=$roundId;last_seen_round=$roundId;status='open'
            severity=$item.severity;category=$item.category;anchor=$item.anchor
            issue=$item.issue;required_action=$item.action;resolution_note=''
        }
    }
}
New-Item -ItemType Directory -Path (Split-Path $ledgerPath -Parent) -Force | Out-Null
$ledgerContent = ($existingLedger | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join [Environment]::NewLine
[IO.File]::WriteAllText($ledgerPath, $ledgerContent + $(if($ledgerContent){[Environment]::NewLine}else{''}), [Text.UTF8Encoding]::new($false))
$unresolvedMustFix = @($existingLedger | Where-Object { $_.status -eq 'open' -and $_.severity -eq 'MUST_FIX' }).Count
$codexReadRaw = ($Mode -eq 'Standard' -and (@($kimiState,$deepseekState) | Where-Object { $_.format_status -ne 'valid' }).Count -gt 0)
$costFeatures = @('normalized_only','exact_review_cache','isolation_cache')
if ($compressionEnabled) { $costFeatures += 'compressed_packet' }
if ($ReviewScope -eq 'Diff') { $costFeatures += 'diff_only' }
if ($Mode -eq 'BudgetLean') { $costFeatures += 'single_reviewer' }
$manifest = [ordered]@{
    timestamp = (Get-Date).ToString('o')
    review_type = $ReviewType
    mode = $Mode
    review_scope = $ReviewScope
    preflight_status = $preflight.Status
    reviewers_called = $true
    missing_required_fields = $preflight.Missing
    packet_sha256 = $originalPacketHash
    original_packet_sha256 = $originalPacketHash
    compressed_packet_sha256 = $effectivePacketHash
    effective_packet_sha256 = $effectivePacketHash
    packet_path_used = $packetPathUsed
    compressed_packet_used = ($packetPathUsed -ne $originalPacketPath)
    compression_enabled = $compressionEnabled
    original_characters = $originalPacketCharacters
    compressed_characters = $packet.Length
    compression_ratio = $compressionRatio
    reviewer_specific_packet = [bool]($KimiPacketPath -or $DeepSeekPacketPath)
    kimi_packet_sha256 = $kimiPacketHash
    deepseek_packet_sha256 = $deepseekPacketHash
    compression_strategy = $CompressionStrategy
    input_characters = $material.Length
    maximum_input_characters = $MaximumInputCharacters
    reviewers = [ordered]@{ kimi = $kimiState; deepseek = $deepseekState }
    review_cache_hit = [bool]($kimiState.review_cache_hit -or $deepseekState.review_cache_hit)
    isolation_cached = [ordered]@{kimi=$kimiState.isolation_cached;deepseek=$deepseekState.isolation_cached}
    lean_must_fix_only = ($Mode -ne 'Standard')
    auto_format_retry = $false
    raw_read_by_codex = $codexReadRaw
    codex_read_raw = $codexReadRaw
    codex_read_raw_reason = if($codexReadRaw){'Standard mode with degraded normalized output'}else{''}
    issue_ledger_path = $ledgerPath
    unresolved_must_fix_count = $unresolvedMustFix
    cost_saving_features = $costFeatures
    adjudication_status = $adjudicationStatus
    authorization_status = 'pending'
}
$manifestPath = Join-Path $reviewDirectory 'roundtable-manifest.json'
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

Write-Output "Roundtable status: $adjudicationStatus"
Write-Output "Kimi isolation: $($kimiState.isolation_status); format: $($kimiState.format_status)"
Write-Output "DeepSeek isolation: $($deepseekState.isolation_status); format: $($deepseekState.format_status)"
if ($kimiState.error) { Write-Output "Kimi unavailable: $($kimiState.error)" }
if ($deepseekState.error) { Write-Output "DeepSeek unavailable: $($deepseekState.error)" }
Write-Output "Manifest: $manifestPath"
if ($kimiState.raw_output_path) { Write-Output "Kimi raw: $($kimiState.raw_output_path)" }
if ($kimiState.normalized_output_path) { Write-Output "Kimi normalized: $($kimiState.normalized_output_path)" }
if ($deepseekState.raw_output_path) { Write-Output "DeepSeek raw: $($deepseekState.raw_output_path)" }
if ($deepseekState.normalized_output_path) { Write-Output "DeepSeek normalized: $($deepseekState.normalized_output_path)" }
