#Requires -Version 7.0

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$powerShellFiles = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File |
    Where-Object Extension -in @('.ps1', '.psm1'))

foreach ($file in $powerShellFiles) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null
    if (@($errors).Count -gt 0) {
        throw "PowerShell parse check failed for $($file.Name)."
    }
}

$scanFiles = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File | Where-Object {
    $_.FullName -notmatch '[\\/]\.git[\\/]' -and
    $_.FullName -notmatch '[\\/]TestResults[\\/]'
})
$secretPatterns = @(
    '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    'tskey-(?:auth|api|client)-[A-Za-z0-9_-]+',
    'gh[opusr]_[A-Za-z0-9]{20,}'
)
foreach ($file in $scanFiles) {
    if ($file.Extension -in @('.png', '.jpg', '.jpeg', '.gif', '.ico', '.zip')) {
        continue
    }
    $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
    foreach ($pattern in $secretPatterns) {
        if ($content -match $pattern) {
            throw "Potential secret material was found in $($file.Name)."
        }
    }
}

Import-Module Pester -MinimumVersion 5.7.1 -Force
$resultDirectory = Join-Path $repoRoot 'TestResults'
New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null
$configuration = [PesterConfiguration]::Default
$configuration.Run.Path = Join-Path $repoRoot 'tests'
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Detailed'
$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputFormat = 'NUnitXml'
$configuration.TestResult.OutputPath = Join-Path $resultDirectory 'pester.xml'
$result = Invoke-Pester -Configuration $configuration
if ($result.FailedCount -gt 0) {
    throw "$($result.FailedCount) Pester test(s) failed."
}

Write-Host "[PASS] $($result.PassedCount) Pester tests passed."
