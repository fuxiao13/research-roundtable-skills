[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Plan', 'Experiment')]
    [string]$ReviewType,

    [Parameter(Mandatory)]
    [string]$ReviewPacketPath,

    [Parameter(Mandatory)]
    [string]$CodexAdvicePath,

    [string]$UserIdeasPath,

    [string]$OutputDirectory = (Join-Path (Get-Location).Path '.roundtable\reviews'),

    [string]$DataRoot = (Join-Path $HOME '.research-roundtable'),

    [string]$KimiHome,

    [ValidateSet('Lean', 'Standard')]
    [string]$Mode = 'Lean',

    [ValidateRange(0, 1000000)]
    [int]$MaximumInputCharacters = 0,

    [ValidateRange(0, 100000)]
    [int]$MaximumReviewCharacters = 0,

    [switch]$SkipKimi,

    [switch]$SkipDeepSeek,

    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$skillRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ($SkipKimi -and $SkipDeepSeek) {
    throw 'Both reviewers cannot be skipped.'
}

$modeSettings = @{
    Lean = @{
        OutputLimit = 100000
        ReviewInstruction = 'LEAN MODE: Report only MUST_FIX findings. A finding is MUST_FIX only when leaving it unresolved would invalidate the objective, evidence, feasibility, safety, or claimed conclusion. Omit recommendations and optional improvements. If there is no MUST_FIX finding, output only NO_MATERIAL_CHANGE.'
    }
    Standard = @{
        OutputLimit = 100000
        ReviewInstruction = 'STANDARD MODE: Report all MUST_FIX findings and all RECOMMENDED improvements that materially strengthen rigor, clarity, efficiency, or reproducibility. Label every finding as MUST_FIX or RECOMMENDED. Do not omit substance for brevity.'
    }
}
$settings = $modeSettings[$Mode]
$inputLimits = @{
    Plan = @{
        Lean = 8000
        Standard = 16000
    }
    Experiment = @{
        Lean = 10000
        Standard = 18000
    }
}
if ($MaximumInputCharacters -eq 0) {
    $MaximumInputCharacters = $inputLimits[$ReviewType][$Mode]
}
if ($MaximumReviewCharacters -eq 0) {
    $MaximumReviewCharacters = $settings.OutputLimit
}

$typeInstruction = if ($ReviewType -eq 'Plan') {
    'PLAN REVIEW: Recheck Codex suggestions against the research objective, constraints, internal logic, feasibility, and required evidence. Review every cited [CX#] item and add only high-value omissions as NEW. Do not rewrite the full plan.'
} else {
    'EXPERIMENT REVIEW: Recheck whether the observed evidence supports Codex diagnosis and whether each [CX#] next step is justified by the research plan and acceptance criteria. Check reproducibility, leakage, metric validity, failure causes, and verification design. Add omissions as NEW.'
}

function Read-Utf8File {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "$Label is not a valid file: $resolved"
    }
    return Get-Content -LiteralPath $resolved -Raw -Encoding UTF8
}

function Invoke-IsolatedReviewer {
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
    if (-not $process.Start()) {
        throw "$Name could not be started."
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.Write($InputText)
    $process.StandardInput.Close()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    if ($process.ExitCode -ne 0) {
        $safeError = if ($stderr.Length -gt 2000) { $stderr.Substring(0, 2000) } else { $stderr }
        throw "$Name review failed with exit code $($process.ExitCode): $safeError"
    }
    if ([string]::IsNullOrWhiteSpace($stdout)) {
        throw "$Name returned no review."
    }

    return $stdout.Trim()
}

function ConvertTo-WindowsArgument {
    param([Parameter(Mandatory)][string]$Value)

    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
        } else {
            [void]$builder.Append(('\' * $backslashes))
            [void]$builder.Append($character)
        }
        $backslashes = 0
    }
    [void]$builder.Append(('\' * ($backslashes * 2)))
    [void]$builder.Append('"')
    return $builder.ToString()
}

$packet = Read-Utf8File -Path $ReviewPacketPath -Label 'Review packet'
$codexAdvice = Read-Utf8File -Path $CodexAdvicePath -Label 'Codex advice'
$ideas = if ($UserIdeasPath) {
    Read-Utf8File -Path $UserIdeasPath -Label 'User ideas'
} else {
    '(No separate user-ideas file was provided.)'
}

$kimiPrompt = Read-Utf8File -Path (Join-Path $skillRoot 'references\kimi-reviewer.txt') -Label 'Kimi reviewer prompt'
$deepseekPrompt = Read-Utf8File -Path (Join-Path $skillRoot 'references\deepseek-reviewer.txt') -Label 'DeepSeek reviewer prompt'
$reviewInstruction = $settings.ReviewInstruction

$material = @"
===== REVIEW TYPE =====
$ReviewType

===== REVIEW PACKET =====
$packet

===== USER IDEAS =====
$ideas

===== CODEX FIRST-PASS ASSESSMENT =====
$codexAdvice
"@

if ($material.Length -gt $MaximumInputCharacters) {
    throw "Review input has $($material.Length) characters, exceeding the $MaximumInputCharacters limit."
}

$kimiCommand = if (-not $SkipKimi) {
    (Get-Command kimi -ErrorAction Stop).Source
} else {
    '(skipped)'
}
$claudeCommand = if (-not $SkipDeepSeek) {
    $claudeWrapper = (Get-Command claude.cmd -ErrorAction Stop).Source
    $native = Join-Path (Split-Path $claudeWrapper -Parent) 'node_modules\@anthropic-ai\claude-code\bin\claude.exe'
    if (-not (Test-Path -LiteralPath $native -PathType Leaf)) {
        throw "Claude Code native executable was not found: $native"
    }
    $native
} else {
    '(skipped)'
}
$dataRootFull = [IO.Path]::GetFullPath($DataRoot)
$outputRootFull = [IO.Path]::GetFullPath($OutputDirectory)
$kimiHome = if ($KimiHome) {
    [IO.Path]::GetFullPath($KimiHome)
} else {
    Join-Path $dataRootFull 'kimi'
}
$sandboxRoot = Join-Path $dataRootFull 'sandbox'

if ($ValidateOnly) {
    Write-Output 'Roundtable validation passed.'
    Write-Output "Review type: $ReviewType"
    Write-Output "Mode: $Mode"
    Write-Output "Input characters: $($material.Length)"
    Write-Output "Input limit: $MaximumInputCharacters"
    Write-Output "Kimi command: $kimiCommand"
    Write-Output "Claude Code command: $claudeCommand"
    Write-Output "Data root: $dataRootFull"
    Write-Output "Kimi home: $kimiHome"
    Write-Output "Output root: $outputRootFull"
    return
}

New-Item -ItemType Directory -Path $kimiHome -Force | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reviewDirectory = Join-Path $outputRootFull $timestamp
New-Item -ItemType Directory -Path $reviewDirectory -Force | Out-Null

$kimiInput = $kimiPrompt + "`r`n`r`n" + $typeInstruction + "`r`n" + $reviewInstruction + "`r`n`r`n" + $material
$deepseekInput = $deepseekPrompt + "`r`n`r`n" + $typeInstruction + "`r`n" + $reviewInstruction + "`r`n`r`n" + $material

$kimiReview = if (-not $SkipKimi) {
    Write-Host 'Running the isolated Kimi Code review...'
    $kimiArgument = ConvertTo-WindowsArgument -Value $kimiInput
    Invoke-IsolatedReviewer `
        -Name 'Kimi Code' `
        -Executable $kimiCommand `
        -Arguments "--prompt $kimiArgument --output-format text" `
        -InputText '' `
        -WorkingDirectory (Join-Path $sandboxRoot 'kimi') `
        -Environment @{
            KIMI_CODE_HOME = $kimiHome
            KIMI_CLI_NO_AUTO_UPDATE = '1'
        }
}

$deepseekReview = if (-not $SkipDeepSeek) {
    Write-Host 'Running the isolated DeepSeek review through Claude Code...'
    Invoke-IsolatedReviewer `
        -Name 'DeepSeek via Claude Code' `
        -Executable $claudeCommand `
        -Arguments '-p --permission-mode plan --tools "" --no-session-persistence --output-format text' `
        -InputText $deepseekInput `
        -WorkingDirectory (Join-Path $sandboxRoot 'deepseek')
}

if ($kimiReview -and $kimiReview.Length -gt $MaximumReviewCharacters) {
    $kimiReview = $kimiReview.Substring(0, $MaximumReviewCharacters) + "`r`n`r`n[Output truncated at the local length limit.]"
}
if ($deepseekReview -and $deepseekReview.Length -gt $MaximumReviewCharacters) {
    $deepseekReview = $deepseekReview.Substring(0, $MaximumReviewCharacters) + "`r`n`r`n[Output truncated at the local length limit.]"
}

$kimiOutput = if ($kimiReview) {
    $path = Join-Path $reviewDirectory 'kimi-review.md'
    [IO.File]::WriteAllText($path, "# Kimi Code Review`r`n`r`n$kimiReview`r`n", [Text.UTF8Encoding]::new($false))
    $path
}
$deepseekOutput = if ($deepseekReview) {
    $path = Join-Path $reviewDirectory 'deepseek-review.md'
    [IO.File]::WriteAllText($path, "# DeepSeek Review (via Claude Code)`r`n`r`n$deepseekReview`r`n", [Text.UTF8Encoding]::new($false))
    $path
}

Write-Host 'Reviews completed.'
if ($kimiOutput) {
    Write-Output "Kimi: $kimiOutput"
}
if ($deepseekOutput) {
    Write-Output "DeepSeek via Claude Code: $deepseekOutput"
}
