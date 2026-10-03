# Keeps Windows from sleeping (including Modern Standby) while an experiment runs.
# It does NOT prevent sleep from closing the lid or pressing the power button.
#   powershell -File scripts/experiments/keep-awake.ps1 -Minutes 120
# Stop it with Ctrl+C; the request is released when the process exits.
param([int]$Minutes = 120)

Add-Type -Namespace StorefrontExperiments -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'

# ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED. Written in decimal because Windows PowerShell 5.1
# reads 0x80000003 as a negative Int32, which can't convert to uint (the call then silently never happens).
$flags = [uint32]2147483651

if ([StorefrontExperiments.Power]::SetThreadExecutionState($flags) -eq 0) {
    throw "SetThreadExecutionState failed; the machine may still sleep."
}
$end = (Get-Date).AddMinutes($Minutes)
"Keeping the machine awake until $($end.ToString('HH:mm')). Keep the lid open and the charger plugged in."
while ((Get-Date) -lt $end) {
    [StorefrontExperiments.Power]::SetThreadExecutionState($flags) | Out-Null
    Start-Sleep -Seconds 30
}
"keep-awake ended"
