$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $root "skills\claude-adversarial-reviewer\scripts\invoke-claude-review.ps1"
$temp = Join-Path ([IO.Path]::GetTempPath()) ("claude-review-stress-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $temp | Out-Null
try {
  $bundle = Join-Path $temp "bundle.md"
  "# Synthetic bundle`nNo repository content." | Set-Content $bundle
  $cases = @(
    @{ name="approved"; fixture="approved.json"; exit="0"; expected="success"; code=0 },
    @{ name="revise"; fixture="revise.json"; exit="0"; expected="success"; code=0 },
    @{ name="inconsistent"; fixture="inconsistent.json"; exit="0"; expected="invalid_output"; code=4 },
    @{ name="malformed"; fixture="malformed.txt"; exit="0"; expected="invalid_output"; code=4 },
    @{ name="cli-failure"; fixture="malformed.txt"; exit="7"; expected="launch_failure"; code=3 }
  )
  foreach ($case in $cases) {
    $fixture = Join-Path $PSScriptRoot ("fixtures\" + $case.fixture)
    $resultPath = Join-Path $temp ($case.name + ".json")
    & $runner -BundlePath $bundle -ResultPath $resultPath -TimeoutSeconds 10 -MockOutputPath $fixture -MockExitCode $case.exit
    $actualCode = $LASTEXITCODE
    if ($null -eq $actualCode) { $actualCode = 0 }
    $result = Get-Content -Raw $resultPath | ConvertFrom-Json
    if ($actualCode -ne $case.code -or $result.result -ne $case.expected) { throw "$($case.name): expected $($case.expected)/$($case.code), got $($result.result)/$actualCode" }
    Write-Host "PASS $($case.name)"
  }
  $empty = Join-Path $temp "empty.md"
  New-Item -ItemType File -Path $empty | Out-Null
  $emptyResult = Join-Path $temp "empty.json"
  & $runner -BundlePath $empty -ResultPath $emptyResult
  if ($LASTEXITCODE -ne 2 -or (Get-Content -Raw $emptyResult | ConvertFrom-Json).result -ne "invalid_output") { throw "empty-bundle case failed" }
  Write-Host "PASS empty-bundle"
  $snapshot = Join-Path $root "skills\claude-adversarial-reviewer\scripts\snapshot.ps1"
  $repo = Join-Path $temp "repo"
  New-Item -ItemType Directory -Path $repo | Out-Null
  & git -C $repo init -q
  "before" | Set-Content (Join-Path $repo "untracked.txt")
  $before = Join-Path $temp "snapshot-before"
  $after = Join-Path $temp "snapshot-after"
  & $snapshot -RepoRoot $repo -OutputPath $before
  "after" | Set-Content (Join-Path $repo "untracked.txt")
  & $snapshot -RepoRoot $repo -OutputPath $after
  if ((Get-FileHash $before).Hash -eq (Get-FileHash $after).Hash) { throw "untracked mutation was not detected" }
  Write-Host "PASS untracked-mutation"
  Write-Host "Stress suite passed: 7/7"
} finally {
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
