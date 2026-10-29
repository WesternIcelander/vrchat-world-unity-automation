# Queues editor trigger commands in a Unity project and waits for each one's outcome
# (vrchat-world-unity-automation skill). Prints the trigger's new log lines as they come, then exits:
#   0  every command ended with its "done" line;
#   1  a command ended with its "failed or stopped" line (see SKILL.md's table);
#   2  no outcome in time: says what the trigger last wrote, when the Editor log was last written, and any dialog
#      open in that project's Unity editor.
#
#   $script = "$HOME\.claude\skills\vrchat-world-unity-automation\trigger.ps1"
#   & $script -Project <path> refresh "menu Tools/My Tool/Build" "play 420 [Test] done|passed"
#   powershell -ExecutionPolicy Bypass -File <script> -Project <path> refresh save     # from Bash
#
# Each command gets -TimeoutSeconds (default 300) to end; a play also gets its own seconds, and an upload 1800 s, so
# it can wait for the developer to accept VRChat's copyright agreement. Unity clears Temp/ when it opens a project,
# which deletes a queue written before then: commands that vanish from the queue unanswered are queued again.
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $true)][string]$Project,
    [int]$TimeoutSeconds = 300,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Commands
)
$ErrorActionPreference = "Stop"
$Commands = @($Commands | Where-Object { $_ -and $_.Trim() -ne "" } | ForEach-Object { $_.Trim() })
if ($Commands.Count -eq 0) { throw "give at least one command, e.g. refresh" }
$Project = (Resolve-Path $Project).Path
$folder = Join-Path $Project "Temp\EditorTrigger"
$queuePath = Join-Path $folder "queue.txt"
$logPath = Join-Path $folder "log.txt"
$editorLog = Join-Path $env:LOCALAPPDATA "Unity\Editor\Editor.log"

# Each log line starts with the time ("12:43:51 refreshed"); the outcome texts match what follows it. $null when the
# file is busy. The leading commas keep an empty or one-line array from being unrolled into $null or a string.
function Get-LogLines {
    if (-not (Test-Path $logPath)) { return , @() }
    try {
        return , @(Get-Content $logPath -Encoding UTF8 | ForEach-Object { $_ -replace '^\d\d:\d\d:\d\d ', '' })
    } catch { return $null }
}

# The command's outcome for a log line: "done", "failed", or $null while it's still running.
function Get-Outcome($verb, $line) {
    if ($line -like "unknown command: *") { return "failed" }
    switch ($verb) {
        "refresh" { if ($line -eq "refreshed") { "done" } elseif ($line -like "refresh: *") { "failed" } }
        "select" { if ($line -like "selected *") { "done" } elseif ($line -like "select: *") { "failed" } }
        "menu" { if ($line -like "ran *") { "done" } elseif ($line -like "menu: *") { "failed" } }
        "save" { if ($line -eq "saved the open scenes") { "done" } elseif ($line -eq "save failed") { "failed" } }
        "play" { if ($line -like "Play Mode ended, *") { "done" } elseif ($line -like "play: *") { "failed" } }
        "stop" { if ($line -like "Play Mode ended, *") { "done" } elseif ($line -like "stop: *") { "failed" } }
        "upload" {
            if ($line -eq "upload: done") { "done" }
            elseif ($line -like "upload failed*") { "failed" }
            elseif ($line -like "upload: *" -and $line -notlike "upload: building and uploading*" -and
                $line -notlike "upload: waiting for the developer*") { "failed" }
        }
    }
}

function Get-Timeout($command) {
    $parts = $command -split ' ', 3
    if ($parts[0] -eq "upload") { return 1800 }
    if ($parts[0] -eq "play" -and $parts.Count -gt 1 -and $parts[1] -match '^\d+(\.\d+)?$') {
        return $TimeoutSeconds + [double]$parts[1]
    }
    $TimeoutSeconds
}

# The visible dialogs (#32770 windows) of the Unity editor that has this project open.
function Get-Dialogs {
    if (-not ("TriggerWindows" -as [type])) {
        Add-Type @"
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class TriggerWindows {
    delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    public static List<string> Dialogs(uint processId) {
        List<string> found = new List<string>();
        EnumWindows((h, l) => {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid != processId || !IsWindowVisible(h)) return true;
            StringBuilder cls = new StringBuilder(256); GetClassName(h, cls, 256);
            if (cls.ToString() != "#32770") return true;
            StringBuilder title = new StringBuilder(512); GetWindowText(h, title, 512);
            found.Add("0x" + h.ToString("X") + " \"" + title + "\"");
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
"@
    }
    $unity = Get-CimInstance Win32_Process -Filter "Name='Unity.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Replace('/', '\') -like "*$Project*" }
    if (-not $unity) { return "no Unity editor has $Project open" }
    @($unity | ForEach-Object { [TriggerWindows]::Dialogs([uint32]$_.ProcessId) }) | ForEach-Object { "dialog $_" }
}

$unityOpen = Get-CimInstance Win32_Process -Filter "Name='Unity.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine.Replace('/', '\') -like "*$Project*" }
if (-not $unityOpen) {
    Write-Output "note: no Unity editor shows $Project on its command line; the commands wait for one to open it"
}

$lines = Get-LogLines
$seen = if ($null -ne $lines) { $lines.Count } else { 0 }
New-Item -ItemType Directory -Force $folder | Out-Null
Add-Content -Path $queuePath -Value $Commands -Encoding UTF8

$exitCode = 0
$index = 0               # the command being waited for
$echoed = $false         # whether its "> command" line has been logged
$deadline = (Get-Date).AddSeconds((Get-Timeout $Commands[0]))
$lostPolls = 0
while ($index -lt $Commands.Count) {
    Start-Sleep -Milliseconds 500
    $queueText = if (Test-Path $queuePath) { try { Get-Content $queuePath -Raw } catch { $null } } else { "" }
    $lines = Get-LogLines
    if ($null -eq $lines) { continue }
    if ($lines.Count -lt $seen) { $seen = 0 }   # Temp/ was cleared: a new log
    for ($i = $seen; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        Write-Output $line
        if ($index -ge $Commands.Count) { continue }
        $command = $Commands[$index]
        if (-not $echoed) {
            if ($line -eq "> $command") { $echoed = $true }
            continue
        }
        $outcome = Get-Outcome (($command -split ' ', 2)[0]) $line
        if ($null -eq $outcome) { continue }
        if ($outcome -eq "failed") { $exitCode = 1 }
        $index++
        $echoed = $false
        if ($index -lt $Commands.Count) { $deadline = (Get-Date).AddSeconds((Get-Timeout $Commands[$index])) }
    }
    $seen = $lines.Count
    if ($index -ge $Commands.Count) { break }

    # Commands gone from the queue but never logged were lost (Temp/ cleared as Unity opened the project): queue them
    # again. Two polls in a row, so a command the trigger has just taken but not logged yet isn't queued twice.
    $pending = @($Commands[$index..($Commands.Count - 1)])
    if (-not $echoed -and $null -ne $queueText -and -not ($pending | Where-Object { $queueText.Contains($_) })) {
        $lostPolls++
        if ($lostPolls -ge 2) {
            New-Item -ItemType Directory -Force $folder | Out-Null
            Add-Content -Path $queuePath -Value $pending -Encoding UTF8
            Write-Output "note: the queue was cleared before the trigger read it; queued again: $($pending -join ' / ')"
            $lostPolls = 0
        }
    } else {
        $lostPolls = 0
    }

    if ((Get-Date) -gt $deadline) {
        $last = if ($lines.Count -gt 0) { $lines[-1] } else { "(the trigger's log is empty)" }
        Write-Output "timed out waiting for: $($Commands[$index])$(if (-not $echoed) { ' (not started)' })"
        Write-Output "trigger's last line: $last"
        if (Test-Path $editorLog) {
            $age = [int]((Get-Date) - (Get-Item $editorLog).LastWriteTime).TotalSeconds
            Write-Output "Editor log last written $age s ago"
        }
        Get-Dialogs | ForEach-Object { Write-Output $_ }
        exit 2
    }
}
exit $exitCode
