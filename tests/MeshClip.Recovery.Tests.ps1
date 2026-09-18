#Requires -Version 7.0
BeforeAll {
    $script:repository=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repository 'scripts\MeshClip.Common.psm1') -Force
}
Describe 'Integration journal survives interruptions and partial recovery' {
    BeforeEach {
        InModuleScope MeshClip.Common -Parameters @{Root=$TestDrive;Repository=$script:repository} {
            param($Root,$Repository)
            $root=Join-Path $Root ([Guid]::NewGuid().ToString('N'))
            [IO.Directory]::CreateDirectory($root)|Out-Null
            $script:fixturePaths=[pscustomobject]@{StateRoot=$root;StatePath=Join-Path $root 'user-state.json';BackupsRoot=Join-Path $root 'backups';KdeRoot=$root;KdeConfigPath=Join-Path $root 'config';WatchdogStatusPath=Join-Path $root 'watchdog-status.json';StartupShortcut=Join-Path $root 'ordinary.lnk';WatchdogShortcut=Join-Path $root 'watchdog.lnk'}
            Mock Get-MeshClipPaths {$script:fixturePaths}
            Mock Enter-MeshClipOperationLock {[Threading.Mutex]::new($true)}
            $source=[IO.File]::ReadAllText((Join-Path $Repository 'scripts\install-windows.ps1'))
            $script:fixtureInstaller=[ScriptBlock]::Create([regex]::Replace($source,'(?m)^Import-Module[^\r\n]*(?:\r?\n)?',''))
            $source=[IO.File]::ReadAllText((Join-Path $Repository 'scripts\configure-peer.ps1'))
            $script:fixtureConfigure=[ScriptBlock]::Create([regex]::Replace($source,'(?m)^Import-Module[^\r\n]*(?:\r?\n)?',''))
            $script:fixtureUnattended=$false
            Mock Get-MeshClipTrustedCommand {'C:\fixture\trusted.exe'}
            Mock Get-MeshClipKdeInstallRoot {'C:\fixture\KDE'}
            Mock Get-MeshClipKdeExecutable {param($Kind) if($Kind -ne 'cli'){'C:\fixture\indicator.exe'}}
            Mock Get-MeshClipTailscaleStatus {[pscustomobject]@{BackendState='Running';SelfOnline=$true;Peers=@()}}
            Mock Resolve-MeshClipApprovedWindowsPeer {[pscustomobject]@{Address='100.64.0.12';OS='windows';Online=$true}}
            Mock Get-MeshClipTailscalePreferences {[pscustomobject]@{ForceDaemon=$script:fixtureUnattended}}
            Mock Test-MeshClipAdministrator {$true}
            Mock Invoke-MeshClipExternal {param($FilePath,$ArgumentList) if($ArgumentList[0] -eq 'set'){$script:fixtureUnattended=$ArgumentList[1] -eq '--unattended=true'};[pscustomobject]@{ExitCode=0;Output=@();StandardError=''}}
            Mock Get-MeshClipStartupInfo {$exists=Test-Path -LiteralPath $script:fixturePaths.StartupShortcut;[pscustomobject]@{Exists=$exists;Matches=$exists;OwnedAndUnchanged=$exists}}
            Mock Get-MeshClipWatchdogStartupInfo {$exists=Test-Path -LiteralPath $script:fixturePaths.WatchdogShortcut;[pscustomobject]@{Exists=$exists;OwnedAndUnchanged=$exists}}
            Mock New-MeshClipStartupShortcut {[IO.File]::WriteAllText($script:fixturePaths.StartupShortcut,'fixture');[pscustomobject]@{Created=$true}}
            Mock New-MeshClipWatchdogStartupShortcut {[IO.File]::WriteAllText($script:fixturePaths.WatchdogShortcut,'fixture');[pscustomobject]@{Created=$true}}
            Mock Get-MeshClipWatchdogTaskInfo {[pscustomobject]@{Exists=$false;Compliant=$false;OwnedAndUnchanged=$false}}
            Mock New-MeshClipWatchdogTask {throw 'Injected late task creation failure'}
            Mock Register-ScheduledTask {throw 'Real tasks are forbidden in this fixture'}
            Mock Unregister-ScheduledTask {throw 'Real tasks are forbidden in this fixture'}
            Mock New-NetFirewallRule {throw 'Real firewall changes are forbidden in this fixture'}
            Mock Remove-NetFirewallRule {throw 'Real firewall changes are forbidden in this fixture'}
        }
    }
    It 'blocks a second operation before overwriting a pending transaction' {
        InModuleScope MeshClip.Common {
            $state=Get-MeshClipState;Start-MeshClipTransaction $state 'fixture'
            $id=$state.pendingTransaction.id
            {Start-MeshClipTransaction (Get-MeshClipState) 'replacement'}|Should -Throw '*unfinished*'
            (Get-MeshClipState).pendingTransaction.id|Should -Be $id
        }
    }
    It 'recovers a prepared config effect after losing the in-memory state' {
        InModuleScope MeshClip.Common {
            [IO.File]::WriteAllText($script:fixturePaths.KdeConfigPath,"# original`n[General]`n",[Text.UTF8Encoding]::new($false))
            $original=(Get-FileHash $script:fixturePaths.KdeConfigPath).Hash
            $state=Get-MeshClipState;Start-MeshClipTransaction $state 'fixture'
            $plan=New-MeshClipConfigPlan -Action Add -Address '100.64.0.12'
            $step=Add-MeshClipTransactionStep $state KdeConfig $plan
            Set-MeshClipConfigPlan $plan|Out-Null
            # No CompleteStep: simulate interruption directly after the effect.
            $loaded=Get-MeshClipState
            $loaded.pendingTransaction.steps[0].phase|Should -Be 'prepared'
            (Repair-MeshClipTransaction $loaded).status|Should -Be 'recovered'
            (Get-FileHash $script:fixturePaths.KdeConfigPath).Hash|Should -Be $original
            (Get-MeshClipState).pendingTransaction|Should -BeNullOrEmpty
        }
    }
    It 'recovers intent persisted before a config write that never happened' {
        InModuleScope MeshClip.Common {
            $state=Get-MeshClipState;Start-MeshClipTransaction $state 'fixture'
            $plan=New-MeshClipConfigPlan -Action Add -Address '100.64.0.12'
            Add-MeshClipTransactionStep $state KdeConfig $plan|Out-Null
            (Repair-MeshClipTransaction (Get-MeshClipState)).status|Should -Be 'recovered'
            Test-Path -LiteralPath $script:fixturePaths.KdeConfigPath|Should -BeFalse
        }
    }
    It 'never clears the marker or overwrites a config changed by somebody else' {
        InModuleScope MeshClip.Common {
            $state=Get-MeshClipState;Start-MeshClipTransaction $state 'fixture'
            $plan=New-MeshClipConfigPlan -Action Add -Address '100.64.0.12'
            Add-MeshClipTransactionStep $state KdeConfig $plan|Out-Null
            Set-MeshClipConfigPlan $plan|Out-Null
            [IO.File]::AppendAllText($script:fixturePaths.KdeConfigPath,"# external edit`n")
            $externalHash=(Get-FileHash $script:fixturePaths.KdeConfigPath).Hash
            (Repair-MeshClipTransaction (Get-MeshClipState)).status|Should -Be 'recovery_required'
            (Get-MeshClipState).pendingTransaction.phase|Should -Be 'recovery_required'
            (Get-FileHash $script:fixturePaths.KdeConfigPath).Hash|Should -Be $externalHash
            {Assert-MeshClipNoPendingTransaction (Get-MeshClipState)}|Should -Throw
        }
    }
    It 'leaves legacy incomplete transactions visible instead of inventing preimages' {
        InModuleScope MeshClip.Common {
            $state=Get-MeshClipState;$state.pendingTransaction=[pscustomobject]@{operation='legacy';phase='started'};Save-MeshClipState $state
            {Repair-MeshClipTransaction (Get-MeshClipState)}|Should -Throw '*Legacy*'
            (Get-MeshClipState).pendingTransaction.operation|Should -Be 'legacy'
        }
    }
    It 'restores its pending marker in memory if commit persistence fails' {
        InModuleScope MeshClip.Common {
            $state=Get-MeshClipState;Start-MeshClipTransaction $state 'fixture'
            $handle=[IO.File]::Open($script:fixturePaths.StatePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            try{{Complete-MeshClipTransaction $state}|Should -Throw;$state.pendingTransaction|Should -Not -BeNullOrEmpty}
            finally{$handle.Dispose()}
            (Get-MeshClipState).pendingTransaction|Should -Not -BeNullOrEmpty
            @(Get-ChildItem -LiteralPath $script:fixturePaths.StateRoot -Filter '*.tmp')|Should -HaveCount 0
        }
    }
    It 'rolls back early installation changes when a later supervisor step fails' {
        InModuleScope MeshClip.Common {
            {& $script:fixtureInstaller -NoLaunchKdeConnect -Confirm:$false}|Should -Throw '*late task*'
            $script:fixtureUnattended|Should -BeFalse
            Test-Path -LiteralPath $script:fixturePaths.StartupShortcut|Should -BeFalse
            Test-Path -LiteralPath $script:fixturePaths.WatchdogShortcut|Should -BeFalse
            (Get-MeshClipState).pendingTransaction|Should -BeNullOrEmpty
            Should -Invoke Register-ScheduledTask -Times 0
            Should -Invoke Unregister-ScheduledTask -Times 0
        }
    }
    It 'detects an existing watchdog conflict before changing unattended mode or startup' {
        InModuleScope MeshClip.Common {
            Mock Get-MeshClipWatchdogStartupInfo {[pscustomobject]@{Exists=$true;OwnedAndUnchanged=$false}}
            {& $script:fixtureInstaller -NoLaunchKdeConnect -Confirm:$false}|Should -Throw '*different watchdog*'
            $script:fixtureUnattended|Should -BeFalse
            Should -Invoke New-MeshClipStartupShortcut -Times 0
            Should -Invoke Invoke-MeshClipExternal -Times 0
        }
    }
    It 'configure entry preserves a recovery-required marker after a failed inverse' {
        InModuleScope MeshClip.Common {
            Mock Complete-MeshClipTransaction {[IO.File]::AppendAllText($script:fixturePaths.KdeConfigPath,"# external edit`n");throw 'Injected commit failure'}
            {& $script:fixtureConfigure -Peer fixture -SkipFirewall -Confirm:$false}|Should -Throw '*incomplete recovery*'
            (Get-MeshClipState).pendingTransaction.phase|Should -Be 'recovery_required'
            [IO.File]::ReadAllText($script:fixturePaths.KdeConfigPath)|Should -Match 'external edit'
            Should -Invoke New-NetFirewallRule -Times 0
        }
    }
    It 'install WhatIf does not create integration state or shortcuts' {
        InModuleScope MeshClip.Common {
            & $script:fixtureInstaller -NoLaunchKdeConnect -WhatIf -AsJson|Out-Null
            Test-Path -LiteralPath $script:fixturePaths.StatePath|Should -BeFalse
            Should -Invoke New-MeshClipStartupShortcut -Times 0
            Should -Invoke New-MeshClipWatchdogTask -Times 0
        }
    }
}
Describe 'Visible watchdog control and heartbeat freshness' {
    BeforeEach {
        InModuleScope MeshClip.Common -Parameters @{Root=$TestDrive} {
            param($Root)
            $root=Join-Path $Root ([Guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($root)|Out-Null
            $script:controlPaths=[pscustomobject]@{StateRoot=$root;WatchdogStatusPath=Join-Path $root 'watchdog-status.json'}
            Mock Get-MeshClipPaths {$script:controlPaths}
        }
    }
    It 'pauses and resumes without touching the indicator or network' {
        InModuleScope MeshClip.Common {
            (Set-MeshClipWatchdogControl -Mode Pause -Minutes 60 -Confirm:$false).paused|Should -BeTrue
            (Set-MeshClipWatchdogControl -Mode Resume -Confirm:$false).paused|Should -BeFalse
        }
    }
    It 'does not create a control file for WhatIf' {
        InModuleScope MeshClip.Common {
            Set-MeshClipWatchdogControl -Mode Pause -WhatIf|Out-Null
            Test-Path (Join-Path $script:controlPaths.StateRoot 'watchdog-control.json')|Should -BeFalse
        }
    }
    It 'does not interpret corrupted pause state as permission to relaunch' {
        InModuleScope MeshClip.Common {
            [IO.File]::WriteAllText((Join-Path $script:controlPaths.StateRoot 'watchdog-control.json'),'invalid')
            {Get-MeshClipWatchdogControl}|Should -Throw '*suspended*'
        }
    }
    It 'evaluates a scheduled resume without rewriting the control file' {
        InModuleScope MeshClip.Common {
            $path=Join-Path $script:controlPaths.StateRoot 'watchdog-control.json'
            Write-MeshClipAtomicJson $path @{schemaVersion=1;mode='paused';resumeAt=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('O')}
            $hash=(Get-FileHash $path).Hash
            (Get-MeshClipWatchdogControl).paused|Should -BeFalse
            (Get-FileHash $path).Hash|Should -Be $hash
        }
    }
    It 'uses the real custom heartbeat interval rather than a fixed three minutes' {
        InModuleScope MeshClip.Common {
            Write-MeshClipAtomicJson $script:controlPaths.WatchdogStatusPath @{schemaVersion=1;status='Healthy';restartCount=0;observedUtc=[DateTimeOffset]::UtcNow.AddSeconds(-240).ToString('O');intervalSeconds=300}
            $status=Get-MeshClipWatchdogStatus
            $status.Fresh|Should -BeTrue;$status.IntervalSeconds|Should -Be 300
        }
    }
}
Describe 'Synthetic acceptance fixtures do not pretend to prove remote transfer' {
    It 'prepares, verifies a separate copy and preserves foreign files during cleanup' {
        $entry=Join-Path $script:repository 'scripts\acceptance.ps1'
        $run=Join-Path $TestDrive 'acceptance run'
        $pwsh=Join-Path $PSHOME 'pwsh.exe'
        $prepared=Invoke-MeshClipExternal -FilePath $pwsh -ArgumentList @('-NoProfile','-File',$entry,'-Action','Prepare','-RunDirectory',$run,'-SizesMiB','1') -TimeoutSeconds 30
        ($prepared.Output -join "`n"|ConvertFrom-Json).business_acceptance|Should -Be 'not_tested'
        $received=Join-Path $TestDrive 'received copy.bin'
        Copy-Item -LiteralPath (Join-Path $run 'meshclip-1MiB.bin') -Destination $received
        $verified=Invoke-MeshClipExternal -FilePath $pwsh -ArgumentList @('-NoProfile','-File',$entry,'-Action','VerifyFile','-RunDirectory',$run,'-ReceivedPath',$received,'-FixtureName','meshclip-1MiB.bin') -TimeoutSeconds 30
        $record=$verified.Output -join "`n"|ConvertFrom-Json
        $record.hash_matches|Should -BeTrue;$record.evidence|Should -Match 'remote_transfer_not_observed'
        [IO.File]::WriteAllText((Join-Path $run 'foreign.txt'),'must be preserved')
        Invoke-MeshClipExternal -FilePath $pwsh -ArgumentList @('-NoProfile','-File',$entry,'-Action','Clean','-RunDirectory',$run) -TimeoutSeconds 30|Out-Null
        Test-Path (Join-Path $run 'foreign.txt')|Should -BeTrue
        Test-Path (Join-Path $run 'meshclip-1MiB.bin')|Should -BeFalse
    }
}

Describe 'Stable firewall ownership and JSON-native state survive recovery' {
    It 'uses the immutable rule name for newly journaled firewall rules' {
        InModuleScope MeshClip.Common {
            $script:rules=@([pscustomobject]@{Name='MeshClipKit-fixture-TCP';DisplayName='Shared display';Group='MeshClip Kit'},[pscustomobject]@{Name='foreign-rule';DisplayName='Shared display';Group='other'})
            Mock Get-MeshClipKdeExecutable {'C:\fixture\kdeconnectd.exe'}
            Mock Get-MeshClipTailscaleAdapterAlias {'Tailscale'}
            Mock Get-NetFirewallRule {$script:rules}
            Mock Test-MeshClipFirewallRuleCompliant {$true}
            Mock Remove-NetFirewallRule {param($Name) $Name|Should -Be 'MeshClipKit-fixture-TCP';$script:rules=@($script:rules|Where-Object Name -ne $Name)}
            $step=[pscustomobject]@{kind='FirewallCreate';data=[pscustomobject]@{names=@('MeshClipKit-fixture-TCP');ruleNames=@('MeshClipKit-fixture-TCP');address='100.64.0.12'}}
            $script:rules[0].Name|Should -Be 'MeshClipKit-fixture-TCP'
            Undo-MeshClipTransactionStep $step
            Should -Invoke Remove-NetFirewallRule -Times 1
            $script:rules|Should -HaveCount 1;$script:rules[0].Name|Should -Be 'foreign-rule'
        }
    }
    It 'keeps dynamic state flags and Boolean values valid across JSON round-trip' {
        $state=[pscustomobject]@{flag=$false;count=2};$item=@{flag='flag'};$state.($item.flag)=$true
        $copy=$state|ConvertTo-Json|ConvertFrom-Json
        $copy.flag|Should -BeOfType ([bool]);$copy.flag|Should -BeTrue;$copy.count|Should -Be 2
    }
}

Describe 'Clipboard observation does not invent a measured latency' {
    It 'stores unknown latency as null when no measurement is supplied' {
        $entry=Join-Path $script:repository 'scripts\acceptance.ps1'
        $run=Join-Path $TestDrive 'latency run'
        & $entry -Action Prepare -RunDirectory $run -SizesMiB 1 -Confirm:$false|Out-Null
        $manifest=Get-Content (Join-Path $run 'manifest.json') -Raw|ConvertFrom-Json
        & $entry -Action RecordClipboard -RunDirectory $run -ObservedMarker $manifest.markers[0] -SequenceIndex 0 -Confirm:$false
        $manifest=Get-Content (Join-Path $run 'manifest.json') -Raw|ConvertFrom-Json
        $manifest.clipboard[0].latency_ms|Should -BeNullOrEmpty
        $manifest.clipboard[0].evidence|Should -Be 'operator_supplied_observation'
    }
}

Describe 'Runtime health distinguishes deliberate pause and configuration uncertainty' {
    It 'reports <expected> for fresh <heartbeat> with paused=<paused>' -ForEach @(
        @{heartbeat='Healthy';paused=$false;expected='PASS'},
        @{heartbeat='Paused';paused=$true;expected='WARN'},
        @{heartbeat='Healthy';paused=$true;expected='WARN'},
        @{heartbeat='Paused';paused=$false;expected='WARN'},
        @{heartbeat='Error';paused=$true;expected='FAIL'}
    ) {
        $r=Get-MeshClipWatchdogRuntimeCheck -ProcessInfo ([pscustomobject]@{Running=$true}) -Heartbeat ([pscustomobject]@{Available=$true;Fresh=$true;Status=$heartbeat}) -Control ([pscustomobject]@{paused=$paused})
        $r.Status|Should -Be $expected
    }
    It 'does not turn unreadable intent into enabled operation' {
        (Get-MeshClipWatchdogRuntimeCheck -ProcessInfo ([pscustomobject]@{Running=$true}) -Heartbeat ([pscustomobject]@{Available=$true;Fresh=$true;Status='Healthy'}) -Control $null).Status|Should -Be 'UNKNOWN'
    }
    It 'does not hide a dead watchdog just because restart is paused' {
        (Get-MeshClipWatchdogRuntimeCheck -ProcessInfo ([pscustomobject]@{Running=$false}) -Heartbeat ([pscustomobject]@{Available=$true;Fresh=$false;Status='Paused'}) -Control ([pscustomobject]@{paused=$true})).Status|Should -Be 'FAIL'
    }
}