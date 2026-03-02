param(
    [Parameter(Mandatory=$true)][string]$SpExe,
    [Parameter(Mandatory=$true)][string]$SpId
)
$resultFile = "C:\SWSetup\${SpId}_result.txt"
try {
    # HP SoftPaqs handle extract+install internally with /s (silent)
    $p = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$SpExe`" /s" -Wait -PassThru -NoNewWindow
    "EXITCODE=$($p.ExitCode)" | Set-Content $resultFile
} catch {
    "EXITCODE=-4 $_" | Set-Content $resultFile
}
