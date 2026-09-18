#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param([switch]$Apply, [switch]$AsJson)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'MeshClip.Common.psm1') -Force
$lock=Enter-MeshClipOperationLock
try {
    $summary=Get-MeshClipRecoverySummary
    if ($Apply -and $summary.pending -and $PSCmdlet.ShouldProcess('Recorded MeshClip integration changes', 'Recover only unchanged resources using saved preimages')) {
        $result=Repair-MeshClipTransaction -State (Get-MeshClipState)
    } else { $result=[pscustomobject]@{status=if($summary.pending){'preview'}else{'nothing_to_recover'}; plan=$summary} }
    if($AsJson){$result|ConvertTo-Json -Depth 8}else{$result|Format-List;Write-Host 'Preview does not change settings. Apply with -Apply only after reviewing the scope. Changed resources are preserved, never overwritten.'}
    if($result.status -eq 'recovery_required'){exit 1}
} finally {Exit-MeshClipOperationLock -Lock $lock}
