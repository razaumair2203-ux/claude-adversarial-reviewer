[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$BundlePath,
  [Parameter(Mandatory)][string]$ResultPath,
  [string]$Model = "",
  [int]$MaxTurns = 8,
  [decimal]$MaxBudgetUsd = 3.00,
  [int]$TimeoutSeconds = 600,
  [Parameter(DontShow)][string]$MockOutputPath = "",
  [Parameter(DontShow)][int]$MockExitCode = 0
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SkillDir = Split-Path -Parent $ScriptDir
$SchemaPath = Join-Path $SkillDir "references\review-schema.json"
$PromptPath = Join-Path $SkillDir "references\reviewer-prompt.md"

function Write-Envelope($Value) {
  $parent = Split-Path -Parent $ResultPath
  if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ResultPath -Encoding utf8
}

if (-not (Test-Path -LiteralPath $BundlePath) -or (Get-Item $BundlePath).Length -eq 0) {
  Write-Envelope @{ result="invalid_output"; verdict=$null; review_quality="unknown"; review=$null; errors="Bundle is missing or empty."; session_id=$null }
  exit 2
}
foreach ($required in @($SchemaPath, $PromptPath)) {
  if (-not (Test-Path -LiteralPath $required)) {
    Write-Envelope @{ result="setup_needed"; verdict=$null; review_quality="unknown"; review=$null; errors="Missing skill resource: $required"; session_id=$null }
    exit 2
  }
}
if (-not $MockOutputPath -and -not (Get-Command claude -ErrorAction SilentlyContinue)) {
  Write-Envelope @{ result="setup_needed"; verdict=$null; review_quality="degraded_environmental"; review=$null; errors="Claude Code CLI is not installed or not on PATH."; session_id=$null }
  exit 2
}

$schema = Get-Content -Raw -LiteralPath $SchemaPath | ConvertFrom-Json | ConvertTo-Json -Compress -Depth 20
# Start-Process joins ArgumentList into one Windows command line. Escape JSON quotes
# so the child process receives the schema as one literal argument.
$schemaArgument = $schema.Replace('"', '\"')
$settings = '{"disableAllHooks":true,"autoMemoryEnabled":false}'
$settingsArgument = $settings.Replace('"', '\"')
$stdout = [IO.Path]::GetTempFileName()
$stderr = [IO.Path]::GetTempFileName()
$reviewCwd = Join-Path ([IO.Path]::GetTempPath()) ("claude-review-cwd-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $reviewCwd | Out-Null
try {
  $args = @("-p", "--permission-mode", "dontAsk", "--tools=", "--disable-slash-commands", "--setting-sources=", "--strict-mcp-config", "--mcp-config", "{}", "--settings", $settingsArgument, "--output-format", "json", "--json-schema", $schemaArgument, "--system-prompt-file", $PromptPath, "--max-turns", "$MaxTurns", "--max-budget-usd", "$MaxBudgetUsd", "--no-session-persistence")
  if ($Model) { $args += @("--model", $Model) }
  if ($MockOutputPath) {
    Copy-Item -LiteralPath $MockOutputPath -Destination $stdout -Force
    $exitCode = $MockExitCode
  } else {
    $process = Start-Process -FilePath "claude" -ArgumentList $args -WorkingDirectory $reviewCwd -RedirectStandardInput $BundlePath -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -WindowStyle Hidden
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      try { $process.Kill($true) } catch { $process.Kill() }
      Write-Envelope @{ result="timeout"; verdict=$null; review_quality="degraded_environmental"; review=$null; errors="Claude review exceeded ${TimeoutSeconds}s."; session_id=$null }
      exit 3
    }
    $exitCode = $process.ExitCode
  }
  $err = Get-Content -Raw -LiteralPath $stderr -ErrorAction SilentlyContinue
  if ($null -eq $err) { $err = "" } else { $err = $err.Trim() }
  if ($exitCode -ne 0) {
    if ($err.Length -gt 1000) { $err = $err.Substring(0,1000) }
    Write-Envelope @{ result="launch_failure"; verdict=$null; review_quality="degraded_environmental"; review=$null; errors=$err; session_id=$null }
    exit 3
  }
  try { $outer = Get-Content -Raw -LiteralPath $stdout | ConvertFrom-Json } catch {
    Write-Envelope @{ result="invalid_output"; verdict=$null; review_quality="unknown"; review=$null; errors="Claude returned malformed outer JSON."; session_id=$null }
    exit 4
  }
  $review = $outer.structured_output
  if (-not $review -or -not $review.verdict -or -not $review.review_quality) {
    Write-Envelope @{ result="invalid_output"; verdict=$null; review_quality="unknown"; review=$null; errors="Claude response lacks structured_output or required fields."; session_id=$outer.session_id }
    exit 4
  }
  $count = @($review.findings).Count
  if (($review.verdict -eq "approved" -and $count -ne 0) -or ($review.verdict -eq "revise" -and $count -eq 0)) {
    Write-Envelope @{ result="invalid_output"; verdict=$review.verdict; review_quality=$review.review_quality; review=$review; errors="Verdict and finding count are inconsistent."; session_id=$outer.session_id }
    exit 4
  }
  Write-Envelope @{ result="success"; verdict=$review.verdict; review_quality=$review.review_quality; review=$review; errors=$null; session_id=$outer.session_id }
} finally {
  Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $reviewCwd -Recurse -Force -ErrorAction SilentlyContinue
}
