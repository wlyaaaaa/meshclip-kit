#Requires -Version 7.0

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\scripts\MeshClip.Common.psm1') -Force
}

Describe 'Address redaction' {
    It 'redacts an IPv4 address without retaining peer-identifying octets' {
        ConvertTo-MeshClipRedactedAddress -Address '192.0.2.41' |
            Should -Be '192.x.x.x'
    }

    It 'redacts invalid input completely' {
        ConvertTo-MeshClipRedactedAddress -Address 'not-an-address' |
            Should -Be '<redacted>'
    }
}

Describe 'KDE customDevices editing' {
    It 'reads a multi-line UTF-8 config as distinct lines' {
        $path = Join-Path $TestDrive 'config'
        [IO.File]::WriteAllText(
            $path,
            "[General]`r`nkeyAlgorithm=EC`r`n",
            [Text.UTF8Encoding]::new($false)
        )

        $document = Read-MeshClipTextDocument -Path $path

        @($document.Lines) | Should -HaveCount 2
        $document.Lines[0] | Should -Be '[General]'
        $document.Lines[1] | Should -Be 'keyAlgorithm=EC'
        $document.NewLine | Should -Be "`r`n"
        $document.EndsNewLine | Should -BeTrue
    }

    It 'creates a General section for an empty document' {
        $result = Add-MeshClipCustomDeviceToLines -Lines @() -Address '192.0.2.10'

        $result.Changed | Should -BeTrue
        $result.Lines | Should -Be @('[General]', 'customDevices=192.0.2.10')
    }

    It 'preserves comments and unrelated sections' {
        $inputLines = @(
            '# user comment',
            '[General]',
            'keyAlgorithm=EC',
            '',
            '[Unrelated]',
            'enabled=true'
        )

        $result = Add-MeshClipCustomDeviceToLines -Lines $inputLines -Address '192.0.2.11'

        $result.Lines | Should -Contain '# user comment'
        $result.Lines | Should -Contain 'keyAlgorithm=EC'
        $result.Lines | Should -Contain '[Unrelated]'
        $result.Lines | Should -Contain 'enabled=true'
        ($result.Lines -join "`n") | Should -Match '(?m)^customDevices=192\.0\.2\.11$'
    }

    It 'is idempotent when adding an existing address' {
        $inputLines = @('[General]', 'customDevices=192.0.2.12')
        $result = Add-MeshClipCustomDeviceToLines -Lines $inputLines -Address '192.0.2.12'

        $result.Changed | Should -BeFalse
        $result.Lines | Should -Be $inputLines
    }

    It 'removes only the selected address' {
        $inputLines = @('[General]', 'customDevices=192.0.2.13,192.0.2.14', 'keyAlgorithm=EC')
        $result = Remove-MeshClipCustomDeviceFromLines -Lines $inputLines -Address '192.0.2.13'

        $result.Changed | Should -BeTrue
        $result.Lines | Should -Contain 'customDevices=192.0.2.14'
        $result.Lines | Should -Contain 'keyAlgorithm=EC'
    }

    It 'removes the key when the last project address is removed' {
        $inputLines = @('[General]', 'customDevices=192.0.2.15', 'keyAlgorithm=EC')
        $result = Remove-MeshClipCustomDeviceFromLines -Lines $inputLines -Address '192.0.2.15'

        $result.Changed | Should -BeTrue
        $result.Lines | Should -Not -Contain 'customDevices=192.0.2.15'
        $result.Lines | Should -Contain 'keyAlgorithm=EC'
    }

    It 'rejects duplicate General sections' {
        {
            Add-MeshClipCustomDeviceToLines -Lines @('[General]', '[General]') -Address '192.0.2.16'
        } | Should -Throw '*duplicate*General*'
    }

    It 'rejects duplicate customDevices keys' {
        {
            Add-MeshClipCustomDeviceToLines -Lines @(
                '[General]',
                'customDevices=192.0.2.17',
                'customDevices=192.0.2.18'
            ) -Address '192.0.2.19'
        } | Should -Throw '*duplicate customDevices*'
    }

    It 'rejects a non-IP custom device value' {
        {
            Add-MeshClipCustomDeviceToLines -Lines @() -Address 'peer.example.invalid'
        } | Should -Throw '*not a valid IP address*'
    }

    It 'repairs only the legacy duplicate General shape created by version 0.1' {
        $inputLines = @(
            '[General]',
            'keyAlgorithm=EC',
            '',
            '[General]',
            'customDevices=192.0.2.19'
        )

        $result = Repair-MeshClipLegacyDuplicateGeneralLines -Lines $inputLines -Address '192.0.2.19'
        $parsed = Get-MeshClipCustomDevicesFromLines -Lines $result.Lines

        $result.Changed | Should -BeTrue
        @($result.Lines | Where-Object { $_ -eq '[General]' }) | Should -HaveCount 1
        $parsed.Devices | Should -Be @('192.0.2.19')
        $result.Lines | Should -Contain 'keyAlgorithm=EC'
    }

    It 'refuses to repair an unrelated duplicate General shape' {
        $inputLines = @(
            '[General]',
            'keyAlgorithm=EC',
            '[General]',
            'customDevices=192.0.2.19',
            'unrelated=true'
        )

        $result = Repair-MeshClipLegacyDuplicateGeneralLines -Lines $inputLines -Address '192.0.2.19'

        $result.Changed | Should -BeFalse
        $result.Lines | Should -Be $inputLines
    }
}

Describe 'Exact Tailnet peer resolution' {
    BeforeEach {
        $script:status = [pscustomobject]@{
            Peers = @(
                [pscustomobject]@{
                    StableId = 'stable-a'
                    HostName = 'desktop-a'
                    DnsName = 'desktop-a.meshclip.example.invalid.'
                    OS = 'windows'
                    Online = $true
                    TailscaleIPs = @('192.0.2.20', '2001:db8::20')
                },
                [pscustomobject]@{
                    StableId = 'stable-b'
                    HostName = 'desktop-b'
                    DnsName = 'desktop-b.meshclip.example.invalid.'
                    OS = 'windows'
                    Online = $false
                    TailscaleIPs = @('192.0.2.21')
                },
                [pscustomobject]@{
                    StableId = 'stable-c'
                    HostName = 'linux-c'
                    DnsName = 'linux-c.meshclip.example.invalid.'
                    OS = 'linux'
                    Online = $true
                    TailscaleIPs = @('192.0.2.22')
                }
            )
        }
    }

    It 'resolves an exact short DNS label' {
        $peer = Resolve-MeshClipPeer -Status $script:status -Peer 'desktop-a'

        $peer.StableId | Should -Be 'stable-a'
        $peer.Address | Should -Be '192.0.2.20'
    }

    It 'resolves an exact full DNS name case-insensitively' {
        $peer = Resolve-MeshClipPeer -Status $script:status -Peer 'DESKTOP-B.MESHCLIP.EXAMPLE.INVALID'

        $peer.StableId | Should -Be 'stable-b'
    }

    It 'rejects a partial peer name' {
        { Resolve-MeshClipPeer -Status $script:status -Peer 'desktop' } |
            Should -Throw '*No exact peer match*'
    }

    It 'rejects delimiter injection' {
        { Resolve-MeshClipPeer -Status $script:status -Peer "desktop-a`nother" } |
            Should -Throw '*must not contain*'
    }

    It 'automatically selects the only online Windows peer' {
        $peer = Resolve-MeshClipApprovedWindowsPeer -Status $script:status

        $peer.StableId | Should -Be 'stable-a'
    }

    It 'rejects an explicitly selected offline Windows peer' {
        { Resolve-MeshClipApprovedWindowsPeer -Status $script:status -Peer 'desktop-b' } |
            Should -Throw '*online Windows peer*'
    }

    It 'rejects an explicitly selected non-Windows peer' {
        { Resolve-MeshClipApprovedWindowsPeer -Status $script:status -Peer 'linux-c' } |
            Should -Throw '*online Windows peer*'
    }

    It 'rejects automatic selection when more than one online Windows peer exists' {
        $script:status.Peers += [pscustomobject]@{
            StableId = 'stable-d'
            HostName = 'desktop-d'
            DnsName = 'desktop-d.meshclip.example.invalid.'
            OS = 'windows'
            Online = $true
            TailscaleIPs = @('192.0.2.23')
        }

        { Resolve-MeshClipApprovedWindowsPeer -Status $script:status } |
            Should -Throw '*exactly one online Windows peer*'
    }
}

Describe 'Firewall rule naming' {
    It 'is deterministic while excluding the clear address' {
        $first = @(Get-MeshClipFirewallRuleNames -Address '192.0.2.22')
        $second = @(Get-MeshClipFirewallRuleNames -Address '192.0.2.22')

        $first | Should -Be $second
        $first | Should -HaveCount 2
        ($first -join ',') | Should -Not -Match '192\.0\.2\.22'
        $first[0] | Should -Match '^MeshClipKit-[0-9A-F]{12}-TCP$'
        $first[1] | Should -Match '^MeshClipKit-[0-9A-F]{12}-UDP$'
    }
}

Describe 'Exact firewall filter equality' {
    It 'accepts only the exact expected scalar set' {
        Test-MeshClipExactStringSet -Actual @('1714-1764') -Expected @('1714-1764') |
            Should -BeTrue
    }

    It 'rejects a filter that contains the expected value plus a broad value' {
        Test-MeshClipExactStringSet -Actual @('1714-1764', 'Any') -Expected @('1714-1764') |
            Should -BeFalse
    }

    It 'rejects a filter whose only value is broad' {
        Test-MeshClipExactStringSet -Actual @('Any') -Expected @('1714-1764') |
            Should -BeFalse
    }
}

Describe 'Firewall filter contract' {
    BeforeEach {
        $script:filter = @{
            ActualProtocol = 'TCP'
            ExpectedProtocol = 'TCP'
            ActualLocalPorts = @('1714-1764')
            ExpectedLocalPorts = @('1714-1764')
            ActualRemoteAddresses = @('192.0.2.24')
            ExpectedRemoteAddresses = @('192.0.2.24')
            ActualPrograms = @('C:\\Program Files\\KDE Connect\\bin\\kdeconnectd.exe')
            ExpectedPrograms = @('C:\\Program Files\\KDE Connect\\bin\\kdeconnectd.exe')
            ActualInterfaceAliases = @('Tailscale')
            ExpectedInterfaceAliases = @('Tailscale')
        }
    }

    It 'accepts an exact protocol, port, peer, program, and interface contract' {
        Test-MeshClipFirewallFilterContract @script:filter | Should -BeTrue
    }

    It 'rejects an additional remote address' {
        $script:filter.ActualRemoteAddresses = @('192.0.2.24', 'Any')

        Test-MeshClipFirewallFilterContract @script:filter | Should -BeFalse
    }

    It 'rejects an additional interface alias' {
        $script:filter.ActualInterfaceAliases = @('Tailscale', 'Any')

        Test-MeshClipFirewallFilterContract @script:filter | Should -BeFalse
    }
}
