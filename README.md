# vrchat-world-unity-automation

A Claude Code skill that lets Claude drive the open Unity editor and VRChat clients from the shell for a VRChat world project: compile after code changes, run Play Mode tests, run editor menu items, upload the world, and launch, list and close VRChat clients for several-client checks. Tests can run with nobody at the computer. Windows only (PowerShell, VRChat's Windows client).

## Installing

Clone this repository into `~/.claude/skills/vrchat-world-unity-automation/` (on Windows, `%USERPROFILE%\.claude\skills\…`). Claude Code then lists the skill in every project.

Ask Claude to create your `developer.md` (your VRChat accounts and profiles, VR headsets, how you want to be asked before uploads and launches). It's created from `templates/developer.md` next to `SKILL.md` and is ignored by git, so it stays yours.

## Using it in a project

Ask Claude to set up testing automation in the project. It runs `install.ps1`, which adds the editor trigger in `Assets/VRChatWorldUnityAutomation/` (listed in `.git/info/exclude`, so it stays out of the repository) and a `TestingAutomation.md` for your settings for that project, which it adds to the project's `.gitignore`: commit that one line. Click on Unity once so it compiles the trigger; after that it works with Unity in the background.

How it all works: `SKILL.md`.
