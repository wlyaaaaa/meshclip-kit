Option Explicit
Dim sh, fs, root, pwsh, target
Set sh = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
root = fs.GetParentFolderName(WScript.ScriptFullName)
pwsh = sh.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe"
target = fs.BuildPath(root, "scripts\control-center.ps1")
If Not fs.FileExists(pwsh) Then
  MsgBox "PowerShell 7 is required.", 48, "MeshClip Kit"
  WScript.Quit 2
End If
sh.Run """" & pwsh & """ -NoProfile -STA -WindowStyle Hidden -File """ & target & """", 0, False
