#Requires -Version 7.0

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:scriptFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:repoRoot 'scripts') -File |
        Where-Object Extension -in @('.ps1', '.psm1'))
}

Describe 'PowerShell source integrity' {
    It 'parses every PowerShell file without syntax errors' {
        foreach ($file in $script:scriptFiles) {
            $tokens = $null
            $errors = $null
            [Management.Automation.Language.Parser]::ParseFile(
                $file.FullName,
                [ref]$tokens,
                [ref]$errors
            ) | Out-Null
            @($errors) | Should -HaveCount 0 -Because $file.Name
        }
    }

    It 'marks each mutating entry point as SupportsShouldProcess' {
        foreach ($name in @('install-windows.ps1', 'configure-peer.ps1', 'uninstall.ps1')) {
            $content = Get-Content -LiteralPath (Join-Path $script:repoRoot "scripts\$name") -Raw
            $content | Should -Match '(?s)\[CmdletBinding\(SupportsShouldProcess\s*=\s*\$true'
        }
    }

    It 'keeps doctor read-only' {
        $doctor = Get-Content -LiteralPath (Join-Path $script:repoRoot 'scripts\doctor.ps1') -Raw
        foreach ($pattern in @(
            'New-NetFirewallRule',
            'Remove-NetFirewallRule',
            'Set-NetFirewallRule',
            'Remove-Item',
            'Start-Process',
            'Save-MeshClipState',
            'Write-MeshClipKdeConfigChange'
        )) {
            $doctor | Should -Not -Match ([regex]::Escape($pattern))
        }
    }
}

Describe 'Repository safety policy' {
    It 'does not contain prohibited command patterns in executable scripts' {
        $allScripts = ($script:scriptFiles | ForEach-Object {
            Get-Content -LiteralPath $_.FullName -Raw
        }) -join "`n"

        foreach ($pattern in @(
            '(?i)Invoke-Expression',
            '(?i)ExecutionPolicy\s+Bypass',
            '(?i)-EncodedCommand',
            '(?i)--auth-key',
            '(?i)@\(\s*[''"]down[''"]',
            '(?i)@\(\s*[''"]logout[''"]',
            '(?i)@\(\s*[''"]up[''"]\s*,\s*[''"]--reset[''"]',
            '(?i)netsh\s+advfirewall\s+reset',
            '(?i)Remove-Item[^\r\n]*-Recurse',
            '(?i)-RemoteAddress\s+[''"]?Any'
        )) {
            $allScripts | Should -Not -Match $pattern
        }
    }

    It 'documents the best-effort consistency boundary' {
        $product = Get-Content -LiteralPath (Join-Path $script:repoRoot 'docs\PRODUCT.md') -Raw

        $product | Should -Match '(?i)does not provide a strongly consistent'
        $product | Should -Match '(?i)best-effort'
    }

    It 'ignores local state, backups, environment files, and key material' {
        $ignore = Get-Content -LiteralPath (Join-Path $script:repoRoot '.gitignore') -Raw

        foreach ($pattern in @('state', 'backups', '.env', '*.pem', '*.key')) {
            $ignore | Should -Match ([regex]::Escape($pattern))
        }
    }
}
