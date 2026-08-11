Option Explicit

Dim shell, fso, scriptsRoot, programFilesPwsh, windowsAppsPwsh, pwshPath, scriptPath, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptsRoot = fso.GetParentFolderName(WScript.ScriptFullName)
programFilesPwsh = shell.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe"
windowsAppsPwsh = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\Microsoft\WindowsApps\pwsh.exe"
scriptPath = fso.BuildPath(scriptsRoot, "watch-kdeconnect.ps1")

If fso.FileExists(programFilesPwsh) Then
    pwshPath = programFilesPwsh
ElseIf fso.FileExists(windowsAppsPwsh) Then
    pwshPath = windowsAppsPwsh
Else
    WScript.Quit 2
End If

If Not fso.FileExists(scriptPath) Then
    WScript.Quit 2
End If

command = """" & pwshPath & """ -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File """ & scriptPath & """"
shell.Run command, 0, False
