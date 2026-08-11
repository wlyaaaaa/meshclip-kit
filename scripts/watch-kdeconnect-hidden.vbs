Option Explicit

Dim shell, fso, scriptsRoot, pwshPath, scriptPath, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptsRoot = fso.GetParentFolderName(WScript.ScriptFullName)
pwshPath = shell.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe"
scriptPath = fso.BuildPath(scriptsRoot, "watch-kdeconnect.ps1")

If Not fso.FileExists(pwshPath) Or Not fso.FileExists(scriptPath) Then
    WScript.Quit 2
End If

command = """" & pwshPath & """ -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File """ & scriptPath & """"
shell.Run command, 0, False
