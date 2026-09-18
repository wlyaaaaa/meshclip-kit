#Requires -Version 7.0
[CmdletBinding()]
param([switch]$AsJson,[switch]$SelfTest)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'MeshClip.Common.psm1') -Force
function Get-ControlSnapshot {
    $control=Get-MeshClipWatchdogControl
    $heartbeat=Get-MeshClipWatchdogStatus
    [pscustomobject]@{schema='meshclip.control.v1'; observedUtc=[DateTimeOffset]::UtcNow.ToString('O')
        watchdog_intent=$control.mode; resume_at=$control.resumeAt; heartbeat=$heartbeat
        watchdog_process=Get-MeshClipWatchdogProcessInfo; recovery=Get-MeshClipRecoverySummary
        clipboard_acceptance='not_tested'; file_transfer_acceptance='not_tested'
        note='暂停只停止自动拉起，不关闭现有 KDE Connect；恢复在下次检查生效。'}
}
if($AsJson){Get-ControlSnapshot|ConvertTo-Json -Depth 8;return}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$form=[Windows.Forms.Form]::new();$form.Text='MeshClip Kit 控制中心';$form.Width=830;$form.Height=650
$form.StartPosition='CenterScreen';$form.Font=[Drawing.Font]::new('Microsoft YaHei UI',10)
$layout=[Windows.Forms.TableLayoutPanel]::new();$layout.Dock='Fill';$layout.RowCount=3;$layout.ColumnCount=1
$layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute',72))|Out-Null
$layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute',90))|Out-Null
$layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent',100))|Out-Null
$intro=[Windows.Forms.Label]::new();$intro.Dock='Fill';$intro.Padding='12,10,12,0'
$intro.Text="控制自动恢复，不改网络或剪贴板。`n关闭此窗口不会停止守护；暂停不会关闭现有 KDE Connect。"
$buttons=[Windows.Forms.FlowLayoutPanel]::new();$buttons.Dock='Fill';$buttons.Padding='10,4,10,4'
$view=[Windows.Forms.TextBox]::new();$view.Multiline=$true;$view.ReadOnly=$true;$view.ScrollBars='Both';$view.Dock='Fill';$view.Font=[Drawing.Font]::new('Consolas',10)
$layout.Controls.Add($intro,0,0);$layout.Controls.Add($buttons,0,1);$layout.Controls.Add($view,0,2);$form.Controls.Add($layout)
$refresh={try{$view.Text=Get-ControlSnapshot|ConvertTo-Json -Depth 8}catch{$view.Text='状态无法完整读取；未执行任何自动修复。请打开诊断查看。'}}
foreach($spec in @(@('暂停一小时','pause-hour'),@('暂停直到恢复','pause'),@('恢复守护','resume'),@('刷新状态','refresh'),@('完整诊断','doctor.ps1'),@('恢复预览','recover.ps1'),@('双机验收向导','acceptance.ps1'))){
    $button=[Windows.Forms.Button]::new();$button.Text=$spec[0];$button.Tag=$spec[1];$button.AutoSize=$true;$button.Height=33
    $button.Add_Click({
        param($sender,$eventArgs)
        try {
            switch([string]$sender.Tag){
                'pause-hour'{Set-MeshClipWatchdogControl -Mode Pause -Minutes 60 -Confirm:$false|Out-Null}
                'pause'{Set-MeshClipWatchdogControl -Mode Pause -Confirm:$false|Out-Null}
                'resume'{Set-MeshClipWatchdogControl -Mode Resume -Confirm:$false|Out-Null;if(-not(Get-MeshClipWatchdogProcessInfo).Running){Start-MeshClipWatchdog|Out-Null}}
                'refresh'{}
                default {
                    $script=Join-Path $PSScriptRoot ([string]$sender.Tag)
                    Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList ('-NoLogo -NoProfile -NoExit -File "'+$script+'"')
                }
            }
            & $refresh
        }catch{[void][Windows.Forms.MessageBox]::Show('操作未完成；已有设置未被批量重置。请打开诊断或恢复预览。','MeshClip Kit')}
    });$buttons.Controls.Add($button)
}
$timer=[Windows.Forms.Timer]::new();$timer.Interval=10000;$timer.Add_Tick($refresh)
try {
    if($SelfTest){[pscustomobject]@{schema='meshclip.ui-test.v1';buttons=$buttons.Controls.Count;layout_rows=$layout.RowCount;status='constructed';shown=$false}|ConvertTo-Json;return}
    & $refresh;$timer.Start();[void]$form.ShowDialog()
}finally{$timer.Stop();$timer.Dispose();$form.Dispose()}
