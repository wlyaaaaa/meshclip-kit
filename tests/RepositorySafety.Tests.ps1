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
        foreach ($name in @('install-windows.ps1', 'configure-peer.ps1', 'uninstall.ps1', 'watch-kdeconnect.ps1')) {
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
            'Register-ScheduledTask',
            'Unregister-ScheduledTask',
            'Start-ScheduledTask',
            'Start-Process',
            'Save-MeshClipState',
            'Write-MeshClipKdeConfigChange'
        )) {
            $doctor | Should -Not -Match ([regex]::Escape($pattern))
        }
    }

    It 'treats broad unmanaged KDE inbound rules as a failing diagnostic' {
        $doctor = Get-Content -LiteralPath (Join-Path $script:repoRoot 'scripts\doctor.ps1') -Raw

        $doctor | Should -Match "Add-Check 'Unmanaged KDE firewall' 'FAIL'"
        $doctor | Should -Not -Match "Add-Check 'Unmanaged KDE firewall' 'WARN'"
    }

    It 'requires explicit broad-rule hardening before peer configuration can proceed' {
        $configure = Get-Content -LiteralPath (Join-Path $script:repoRoot 'scripts\configure-peer.ps1') -Raw

        $configure | Should -Match '\$DisableBroadKdeFirewallRules'
        $configure | Should -Match 'Disable-MeshClipBroadKdeFirewallRules'
        $configure | Should -Not -Match 'AllowOfflinePeer'
    }

    It 'preserves rollback ownership when uninstall actions are declined or changed' {
        $uninstall = Get-Content -LiteralPath (Join-Path $script:repoRoot 'scripts\uninstall.ps1') -Raw

        $uninstall | Should -Match 'OwnedAndUnchanged'
        $uninstall | Should -Match 'RestoreDisabledBroadKdeFirewallRules'
        $uninstall | Should -Not -Match '\$state\.addedPeers\s*=\s*@\(\)'
    }

    It 'uses a silent, project-owned KDE Connect watchdog lifecycle' {
        $module = Get-Content -LiteralPath (Join-Path $script:repoRoot 'scripts\MeshClip.Common.psm1') -Raw
        $install = Get-Content -LiteralPath (Join-Path $script:repoRoot 'scripts\install-windows.ps1') -Raw
        $doctor = Get-Content -LiteralPath (Join-Path $script:repoRoot 'scripts\doctor.ps1') -Raw
        $uninstall = Get-Content -LiteralPath (Join-Path $script:repoRoot 'scripts\uninstall.ps1') -Raw
        $watchdogPath = Join-Path $script:repoRoot 'scripts\watch-kdeconnect.ps1'
        $wrapperPath = Join-Path $script:repoRoot 'scripts\watch-kdeconnect-hidden.vbs'

        Test-Path -LiteralPath $watchdogPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $wrapperPath -PathType Leaf | Should -BeTrue
        $module | Should -Match 'New-MeshClipWatchdogStartupShortcut'
        $module | Should -Match 'New-MeshClipWatchdogTask'
        $install | Should -Match 'Start-MeshClipWatchdog'
        $install | Should -Match 'watchdogTaskCreated'
        $doctor | Should -Match 'Get-MeshClipWatchdogStatus'
        $doctor | Should -Match 'Get-MeshClipWatchdogTaskInfo'
        $uninstall | Should -Match 'Stop-MeshClipWatchdogProcesses'
        $uninstall | Should -Match 'watchdogTask\.OwnedAndUnchanged'

        $wrapper = Get-Content -LiteralPath $wrapperPath -Raw
        $wrapper | Should -Match '%ProgramFiles%'
        $wrapper | Should -Match '%LOCALAPPDATA%.*Microsoft\\WindowsApps\\pwsh\.exe'
    }

    It 'keeps the watchdog out of clipboard, network, and firewall configuration' {
        $watchdog = Get-Content -LiteralPath (Join-Path $script:repoRoot 'scripts\watch-kdeconnect.ps1') -Raw

        foreach ($pattern in @('Set-Clipboard', 'Get-Clipboard', 'tailscale', 'NetFirewall', 'NetAdapter')) {
            $watchdog | Should -Not -Match ([regex]::Escape($pattern))
        }
        $watchdog | Should -Match 'Get-MeshClipKdeExecutable -Kind indicator'
        $watchdog | Should -Match 'Start-Process -FilePath \$indicator'
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
