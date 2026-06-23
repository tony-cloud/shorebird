[CmdletBinding()]
param(
  [string] $UpdaterRevision = "main",
  [switch] $PrintPlan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$workspaceRoot = Split-Path -Parent $repoRoot
$updaterUrl = "https://github.com/shorebirdtech/updater.git"
$updaterPath = Join-Path $workspaceRoot "flutter\engine\src\flutter\third_party\updater"
$updaterHeader = Join-Path $updaterPath "library\include\updater_engine.h"

function Write-Step([string] $message) {
  Write-Host "[open-source-sync] $message"
}

Write-Step "Shorebird updater source: $updaterUrl"
Write-Step "Target path: $updaterPath"
Write-Step "Revision: $UpdaterRevision"

if ($PrintPlan) {
  Write-Step "PrintPlan only; no files will be changed."
  exit 0
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  throw "git is required to sync public Shorebird sources."
}

$parent = Split-Path -Parent $updaterPath
if (-not (Test-Path -LiteralPath $parent)) {
  New-Item -ItemType Directory -Path $parent | Out-Null
}

if (Test-Path -LiteralPath $updaterPath) {
  $gitDir = Join-Path $updaterPath ".git"
  if (-not (Test-Path -LiteralPath $gitDir)) {
    throw "Target exists but is not a git checkout: $updaterPath"
  }

  Write-Step "Updating existing public updater checkout."
  & git -C $updaterPath fetch --tags origin
  if ($LASTEXITCODE -ne 0) {
    throw "git fetch failed."
  }
  & git -C $updaterPath checkout $UpdaterRevision
  if ($LASTEXITCODE -ne 0) {
    throw "git checkout $UpdaterRevision failed."
  }
  if ($UpdaterRevision -eq "main") {
    & git -C $updaterPath pull --ff-only
    if ($LASTEXITCODE -ne 0) {
      throw "git pull --ff-only failed."
    }
  }
} else {
  Write-Step "Cloning public updater checkout."
  & git clone $updaterUrl $updaterPath
  if ($LASTEXITCODE -ne 0) {
    throw "git clone failed."
  }
  & git -C $updaterPath checkout $UpdaterRevision
  if ($LASTEXITCODE -ne 0) {
    throw "git checkout $UpdaterRevision failed."
  }
}

if (-not (Test-Path -LiteralPath $updaterHeader)) {
  throw "Updater checkout is missing expected C API header: $updaterHeader"
}

Write-Step "Public Shorebird updater is available for the engine build."
