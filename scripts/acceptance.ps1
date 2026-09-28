#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess = $true)]
param([ValidateSet('Plan','Prepare','VerifyFile','RecordClipboard','RecordCheck','Summary','Clean')][string]$Action='Plan',
    [string]$RunDirectory,[ValidateRange(1,1024)][int[]]$SizesMiB=@(1),[string]$ReceivedPath,[string]$FixtureName,
    [ValidateSet('Forward','Reverse')][string]$Direction='Forward',[ValidateRange(0,99)][int]$SequenceIndex=0,
    [string]$ObservedMarker,[ValidateRange(0,3600000)][Nullable[int]]$LatencyMilliseconds=$null,
    [ValidateSet('pairing','reboot-recovery','no-echo-loop')][string]$Check,[switch]$Observed,[switch]$AsJson)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'MeshClip.Common.psm1') -Force
if($Action -eq 'Plan'){
    [pscustomobject]@{schema='meshclip.acceptance-plan.v1';status='not_tested';steps=@(
        '在两台设备上确认相同配对身份。',
        'Prepare 生成专用测试标记与文件；不使用真实剪贴板历史、密码或个人文件。',
        '两个方向分别复制 100 个标记，观察延迟与回环；RecordClipboard 只记录明确提供的观察。',
        '用 KDE Connect 两个方向传输生成文件，再用 VerifyFile 校验实际收到的副本。',
        '重启后检查服务、用户登录启动与真实传输；RecordCheck 明确记录人工观察。',
        'Summary 区分文件校验、人工观察与尚未测试；Clean 只删除未被改动的本次生成文件。')
        commands=@('.\acceptance.ps1 -Action Prepare -SizesMiB 1,100,1024','.\acceptance.ps1 -Action VerifyFile -RunDirectory <run> -ReceivedPath <copy> -Direction Forward','.\acceptance.ps1 -Action Summary -RunDirectory <run>')
        automatic_claim='No command here proves that two remote devices actually transferred data.'}|ConvertTo-Json -Depth 5
    return
}
if(-not $RunDirectory){
    if($Action -ne 'Prepare'){throw 'RunDirectory is required.'}
    $RunDirectory=Join-Path (Get-MeshClipPaths).StateRoot ('acceptance\'+[Guid]::NewGuid().ToString('N'))
}
$RunDirectory=[IO.Path]::GetFullPath($RunDirectory)
$manifestPath=Join-Path $RunDirectory 'manifest.json'
if($Action -eq 'Prepare'){
    if(Test-Path -LiteralPath $RunDirectory){throw 'Choose a new run directory; existing content is never overwritten.'}
    if(-not $PSCmdlet.ShouldProcess('Generated MeshClip test fixtures', 'Create a new bounded acceptance run')){return}
    [IO.Directory]::CreateDirectory($RunDirectory)|Out-Null
    $id=[Guid]::NewGuid().ToString('N')
    $markers=@(0..99|ForEach-Object{'MESHCLIP-TEST-'+$id+'-'+$_.ToString('D3')})
    $manifest=[pscustomobject]@{schema='meshclip.acceptance.v1';run_id=$id;createdUtc=[DateTimeOffset]::UtcNow.ToString('O');files=@();markers=$markers;clipboard=@();file_checks=@();manual_checks=@();status='preparing'}
    Write-MeshClipAtomicJson -Path $manifestPath -Value $manifest
    try{
        foreach($size in @($SizesMiB|Select-Object -Unique)){
            $name="meshclip-$($size)MiB.bin";$path=Join-Path $RunDirectory $name
            $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try{
                [byte[]]$block=New-Object byte[] (1MB);[Security.Cryptography.RandomNumberGenerator]::Fill($block)
                for($i=0;$i -lt $size;$i++){$stream.Write($block)};$stream.Flush($true)
            }finally{$stream.Dispose()}
            $manifest.files+=@([pscustomobject]@{name=$name;bytes=[long]$size*1MB;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash})
            Write-MeshClipAtomicJson -Path $manifestPath -Value $manifest
        }
        $manifest.status='prepared';Write-MeshClipAtomicJson -Path $manifestPath -Value $manifest
    }catch{throw 'Fixture creation did not complete. The partial run remains identifiable by its manifest; no acceptance was recorded.'}
    [pscustomobject]@{status='prepared';run_directory=$RunDirectory;file_count=$manifest.files.Count;sequence_samples=100;business_acceptance='not_tested'}|ConvertTo-Json
    return
}
$manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json -Depth 30
if($manifest.schema -ne 'meshclip.acceptance.v1' -or $manifest.run_id -notmatch '\A[0-9a-f]{32}\z'){throw 'Unsupported acceptance manifest.'}
foreach($file in @($manifest.files)){if($file.name -notmatch '\Ameshclip-(?:[1-9][0-9]{0,3})MiB\.bin\z' -or $file.sha256 -notmatch '\A[0-9a-fA-F]{64}\z'){throw 'Invalid fixture entry.'}}
switch($Action){
    'VerifyFile'{
        if(-not $ReceivedPath){throw 'ReceivedPath is required.'}
        if(-not $FixtureName){$FixtureName=Split-Path -Leaf $ReceivedPath}
        $expected=@($manifest.files|Where-Object name -eq $FixtureName)
        if($expected.Count -ne 1){throw 'The fixture name must match exactly one generated file.'}
        if([IO.Path]::GetFullPath($ReceivedPath) -eq (Join-Path $RunDirectory $FixtureName)){throw 'Select the received copy, not the original generated file.'}
        $match=(Get-FileHash -LiteralPath $ReceivedPath -Algorithm SHA256).Hash -eq $expected[0].sha256 -and (Get-Item -LiteralPath $ReceivedPath).Length -eq $expected[0].bytes
        $result=[pscustomobject]@{fixture=$FixtureName;direction=$Direction;hash_matches=$match;evidence='local_copy_hash_checked; remote_transfer_not_observed';observedUtc=[DateTimeOffset]::UtcNow.ToString('O')}
        if($PSCmdlet.ShouldProcess('Acceptance run','Record received-file checksum result')){$manifest.file_checks=@($manifest.file_checks|Where-Object { $_.fixture -ne $FixtureName -or $_.direction -ne $Direction })+$result;Write-MeshClipAtomicJson -Path $manifestPath -Value $manifest}
        $result|ConvertTo-Json
        if(-not $match){exit 1}
    }
    'RecordClipboard'{
        if(-not $ObservedMarker -or $ObservedMarker -cne $manifest.markers[$SequenceIndex]){throw 'Only the exact generated marker can be recorded; never submit personal clipboard content.'}
        if($PSCmdlet.ShouldProcess('Acceptance run','Record an operator-supplied clipboard observation')){
            $item=[pscustomobject]@{direction=$Direction;index=$SequenceIndex;latency_ms=$LatencyMilliseconds;evidence='operator_supplied_observation';observedUtc=[DateTimeOffset]::UtcNow.ToString('O')}
            $manifest.clipboard=@($manifest.clipboard|Where-Object { $_.direction -ne $Direction -or $_.index -ne $SequenceIndex })+$item
            Write-MeshClipAtomicJson -Path $manifestPath -Value $manifest
        }
    }
    'RecordCheck'{
        if(-not $Check -or -not $Observed){throw 'Check and explicit Observed are required; this is an operator attestation, not an automatic test.'}
        if($PSCmdlet.ShouldProcess('Acceptance run','Record explicit operator attestation')){
            $manifest.manual_checks=@($manifest.manual_checks|Where-Object check -ne $Check)+[pscustomobject]@{check=$Check;evidence='operator_attested';observedUtc=[DateTimeOffset]::UtcNow.ToString('O')}
            Write-MeshClipAtomicJson -Path $manifestPath -Value $manifest
        }
    }
    'Summary'{
        [pscustomobject]@{schema='meshclip.acceptance-summary.v1';fixture_count=@($manifest.files).Count
            forward_clipboard_samples=@($manifest.clipboard|Where-Object direction -eq 'Forward').Count
            reverse_clipboard_samples=@($manifest.clipboard|Where-Object direction -eq 'Reverse').Count
            clipboard_evidence='operator_supplied_not_independently_observed';file_checks=@($manifest.file_checks)
            manual_checks=@($manifest.manual_checks);business_acceptance='requires_two_device_review';automatic_pass=$false}|ConvertTo-Json -Depth 8
    }
    'Clean'{
        $retained=[Collections.Generic.List[string]]::new()
        foreach($file in @($manifest.files)){
            $path=Join-Path $RunDirectory $file.name
            if(Test-Path -LiteralPath $path){
                if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.sha256){$retained.Add($file.name);continue}
                if($PSCmdlet.ShouldProcess($file.name,'Remove unchanged generated fixture')){Remove-Item -LiteralPath $path -Force}
            }
        }
        $other=@(Get-ChildItem -LiteralPath $RunDirectory -Force|Where-Object Name -ne 'manifest.json')
        if(-not $other.Count -and -not $retained.Count -and $PSCmdlet.ShouldProcess('Empty acceptance run','Remove generated manifest and empty run folder')){Remove-Item -LiteralPath $manifestPath -Force;Remove-Item -LiteralPath $RunDirectory}
        [pscustomobject]@{status=if(Test-Path -LiteralPath $RunDirectory){'retained_or_preview'}else{'cleaned'};changed_or_foreign_files_preserved=$true}|ConvertTo-Json
    }
}
