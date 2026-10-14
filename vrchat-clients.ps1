# Starts and stops VRChat clients for several-client checks in production, and finds their logs
# (vrchat-world-unity-automation skill). Each client is a VRChat profile logged in to its own account.
#
#   $script = "$HOME\.claude\skills\vrchat-world-unity-automation\vrchat-clients.ps1"
#   & $script start -Profiles 0,2 -Url "vrchat://launch?id=wrld_...:12345~private(usr_...)"
#   & $script stop [-Profiles 2]       # all VRChat clients when no profile is given
#   & $script clients                  # the running clients: pid, profile, account, log
#   & $script logs [-Minutes 30]       # each recent output log, its profile and account
#
# Clients start on desktop (--no-vr) unless their profile is in -VrProfiles. Stopping asks each client to close
# (taskkill without /F) and forces it after -WaitSeconds.
param(
    [Parameter(Mandatory = $true, Position = 0)][ValidateSet("start", "stop", "clients", "logs")][string]$Action,
    [int[]]$Profiles = @(),
    [int[]]$VrProfiles = @(),
    [string]$Url = "",
    [int]$Minutes = 30,
    [int]$WaitSeconds = 15,
    [string]$Launcher = "C:\Program Files (x86)\Steam\steamapps\common\VRChat\launch.exe",
    [string]$LogFolder = "$env:USERPROFILE\AppData\LocalLow\VRChat\VRChat"
)

# The profile a client was started with (0 when its log names none) and the account it's logged in as.
function Read-Log($path) {
    $profileNumber = 0
    $arg = Select-String -Path $path -Pattern 'Arg: --profile=(\d+)' | Select-Object -First 1
    if ($arg) { $profileNumber = [int]$arg.Matches[0].Groups[1].Value }
    $account = "(not logged in yet)"
    $auth = Select-String -Path $path -Pattern 'User Authenticated: (.+) \(usr_' | Select-Object -First 1
    if ($auth) { $account = $auth.Matches[0].Groups[1].Value }
    [pscustomobject]@{ Profile = $profileNumber; Account = $account }
}

# The running VRChat clients with their logs. Easy Anti-Cheat hides a client's command line, so each process is
# matched to the log created within a few seconds of its start, and the profile is read from that log.
function Get-Clients {
    $logs = @(Get-ChildItem -Path $LogFolder -Filter "output_log_*.txt")
    Get-Process -Name VRChat -ErrorAction SilentlyContinue | ForEach-Object {
        $start = $_.StartTime
        $log = $logs | Where-Object {
            $_.CreationTime -ge $start.AddSeconds(-2) -and $_.CreationTime -le $start.AddSeconds(30)
        } | Sort-Object CreationTime | Select-Object -First 1
        $info = [pscustomobject]@{ Profile = -1; Account = "(no log found)" }
        if ($log) { $info = Read-Log $log.FullName }
        [pscustomobject]@{
            Id = $_.Id; Profile = $info.Profile; Account = $info.Account
            Log = $(if ($log) { $log.FullName } else { "" })
        }
    }
}

switch ($Action) {
    "start" {
        if ($Url -eq "" -or $Profiles.Count -eq 0) { throw "start needs -Profiles and -Url" }
        foreach ($p in $Profiles) {
            $arguments = @("--profile=$p")
            if ($VrProfiles -notcontains $p) { $arguments += "--no-vr" }
            $arguments += "`"$Url`""
            Start-Process -FilePath $Launcher -ArgumentList $arguments
            Write-Output "started profile $p"
            # The clients log in one after another more reliably than all at once.
            Start-Sleep -Seconds 5
        }
    }
    "stop" {
        $clients = @(Get-Clients | Where-Object { $Profiles.Count -eq 0 -or $Profiles -contains $_.Profile })
        if ($clients.Count -eq 0) { Write-Output "no client to stop"; break }
        foreach ($c in $clients) { & taskkill.exe /PID $c.Id | Out-Null }
        $deadline = (Get-Date).AddSeconds($WaitSeconds)
        while ((Get-Date) -lt $deadline) {
            $left = @($clients | Where-Object { Get-Process -Id $_.Id -ErrorAction SilentlyContinue })
            if ($left.Count -eq 0) { break }
            Start-Sleep -Milliseconds 500
        }
        foreach ($c in $clients) {
            if (Get-Process -Id $c.Id -ErrorAction SilentlyContinue) {
                & taskkill.exe /F /PID $c.Id | Out-Null
                Write-Output "forced profile $($c.Profile) (pid $($c.Id)) to close"
            } else {
                Write-Output "closed profile $($c.Profile) (pid $($c.Id))"
            }
        }
    }
    "clients" {
        Get-Clients | ForEach-Object { Write-Output "pid $($_.Id)`tprofile $($_.Profile)`t$($_.Account)`t$($_.Log)" }
    }
    "logs" {
        $since = (Get-Date).AddMinutes(-$Minutes)
        Get-ChildItem -Path $LogFolder -Filter "output_log_*.txt" | Where-Object { $_.LastWriteTime -ge $since } |
            Sort-Object LastWriteTime | ForEach-Object {
                $info = Read-Log $_.FullName
                Write-Output ("$($_.FullName)`tprofile $($info.Profile)`t$($info.Account)`t" +
                    $_.LastWriteTime.ToString('HH:mm:ss'))
            }
    }
}
