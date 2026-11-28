Option Explicit
Dim shell, fso, root, scriptPath, psPath, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(root, "scripts\STOP-STUDIO.ps1")
psPath = shell.ExpandEnvironmentStrings("%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe")
If Not fso.FileExists(psPath) Then psPath = "powershell.exe"
command = Chr(34) & psPath & Chr(34) & " -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & scriptPath & Chr(34)
shell.Run command, 0, False
