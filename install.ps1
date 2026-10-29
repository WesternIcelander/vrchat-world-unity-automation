# Installs or updates the editor trigger in a Unity project:
#   - copies unity/ to Assets/VRChatWorldUnityAutomation/ (editor-only, with its own assembly definition) when it's
#     missing or older than the bundled one (VERSION.txt), or with -Force. Not an embedded package: registering one
#     rewrites Packages/packages-lock.json, which projects commit;
#   - lists it and its .meta in .git/info/exclude (git's own ignore list, which isn't committed), as the trigger is
#     this developer's tool;
#   - keeps TestingAutomation.md out of git where the developer chooses: -SettingsIgnore gitignore (the project's
#     .gitignore, a change to commit, so nobody commits their own) or -SettingsIgnore exclude (.git/info/exclude, this
#     clone only). Without either, when git doesn't already ignore it, it says so and leaves it uncreated;
#   - creates TestingAutomation.md from the template when the project has none.
#
#   & "$HOME\.claude\skills\vrchat-world-unity-automation\install.ps1" [-Project <path>]
#       [-SettingsIgnore gitignore|exclude] [-Force]
param(
    [string]$Project = (Get-Location).Path,
    [ValidateSet("", "gitignore", "exclude")][string]$SettingsIgnore = "",
    [switch]$Force
)
$ErrorActionPreference = "Stop"
$skill = $PSScriptRoot
$folderName = "VRChatWorldUnityAutomation"
$needsChoice = $false

if (-not (Test-Path (Join-Path $Project "Assets")) -or -not (Test-Path (Join-Path $Project "ProjectSettings"))) {
    throw "$Project isn't a Unity project (no Assets or ProjectSettings folder)"
}

function Get-InstalledVersion($folder) {
    $file = Join-Path $folder "VERSION.txt"
    if (-not (Test-Path $file)) { return [version]"0.0.0" }
    return [version]((Get-Content $file -Raw).Trim())
}

# The editor scripts.
$source = Join-Path $skill "unity"
$target = Join-Path $Project "Assets\$folderName"
$bundled = Get-InstalledVersion $source
$installed = Get-InstalledVersion $target
if ($Force -or $installed -lt $bundled) {
    New-Item -ItemType Directory -Force $target | Out-Null
    # Copies over the existing files; the .meta files Unity made for them stay, so their GUIDs don't change.
    Copy-Item -Path (Join-Path $source "*") -Destination $target -Recurse -Force
    Write-Output "editor scripts: installed $bundled (was $(if ($installed -eq [version]'0.0.0') { 'none' } else { $installed }))"
} else {
    Write-Output "editor scripts: $installed is up to date"
}

# Git's local exclude list. Outside a repository git writes to stderr, which "Stop" turns into an error in Windows
# PowerShell, so it's relaxed while git runs.
Push-Location $Project
$ErrorActionPreference = "Continue"
try {
    $exclude = (& git rev-parse --git-path info/exclude 2>$null)
} finally {
    $ErrorActionPreference = "Stop"
    Pop-Location
}
if ($LASTEXITCODE -eq 0 -and $exclude) {
    if (-not [IO.Path]::IsPathRooted($exclude)) { $exclude = Join-Path $Project $exclude }
    New-Item -ItemType Directory -Force (Split-Path $exclude) | Out-Null
    if (-not (Test-Path $exclude)) { New-Item -ItemType File $exclude | Out-Null }
    $lines = @(Get-Content $exclude)
    $added = @()
    foreach ($entry in @("/Assets/$folderName/", "/Assets/$folderName.meta")) {
        if ($lines -notcontains $entry) { $added += $entry }
    }
    if ($added.Count -gt 0) {
        Add-Content -Path $exclude -Value (@("", "# vrchat-world-unity-automation (Claude Code skill)") + $added)
        Write-Output "git: excluded $($added -join ', ')"
    } else {
        Write-Output "git: already excluded"
    }
    # TestingAutomation.md: kept out of git where the developer chose (-SettingsIgnore), unless git already ignores it.
    Push-Location $Project
    try {
        & git check-ignore -q TestingAutomation.md 2>$null
        $alreadyIgnored = ($LASTEXITCODE -eq 0)
    } finally {
        Pop-Location
    }
    $entry = "/TestingAutomation.md"
    $comment = "# Developer-specific test automation settings (vrchat-world-unity-automation Claude Code skill)"
    if ($alreadyIgnored) {
        Write-Output "TestingAutomation.md: already ignored by git"
    } elseif ($SettingsIgnore -eq "exclude") {
        Add-Content -Path $exclude -Value @("", $comment, $entry)
        Write-Output "TestingAutomation.md: excluded in .git/info/exclude"
    } elseif ($SettingsIgnore -eq "gitignore") {
        # The project's .gitignore, keeping the file's own line endings.
        $gitignore = Join-Path $Project ".gitignore"
        $text = if (Test-Path $gitignore) { [IO.File]::ReadAllText($gitignore) } else { "" }
        $newline = if ($text -match "\r\n") { "`r`n" } else { "`n" }
        $prefix = if ($text -eq "" -or $text.EndsWith("`n")) { "" } else { $newline }
        if ($text -ne "") { $prefix += $newline }
        [IO.File]::AppendAllText($gitignore, $prefix + $comment + $newline + $entry + $newline)
        Write-Output "TestingAutomation.md: added to .gitignore (commit it)"
    } else {
        $needsChoice = $true
        Write-Output ("TestingAutomation.md: not ignored by git yet. Ask the developer, then run again with " +
            "-SettingsIgnore gitignore (the project's .gitignore, committed) or -SettingsIgnore exclude " +
            "(.git/info/exclude, this clone only)")
    }
} else {
    Write-Output "git: not a git repository; nothing to exclude"
}

# The project's settings file, once git ignores it.
$settings = Join-Path $Project "TestingAutomation.md"
if (Test-Path $settings) {
    Write-Output "TestingAutomation.md: kept"
} elseif ($needsChoice) {
    Write-Output "TestingAutomation.md: not created until it's ignored"
} else {
    Copy-Item (Join-Path $skill "templates\TestingAutomation.md") $settings
    Write-Output "TestingAutomation.md: created from the template; fill it in"
}
