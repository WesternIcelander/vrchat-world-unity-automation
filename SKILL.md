---
name: vrchat-world-unity-automation
description: Drive the open Unity editor and VRChat clients from the shell for a VRChat world project, so tests run with nobody at the computer. Use in any project with a TestingAutomation.md in its root, and whenever work there needs Play Mode tests (including a plan step's verification), compiling after code changes, editor menu items, a VRChat world upload, or launching, listing or closing VRChat clients for several-client checks; also when setting up testing automation in a Unity project.
---

# VRChat world Unity automation

Everything lives in this skill's folder (`$HOME\.claude\skills\vrchat-world-unity-automation\`, "the skill folder" below). A project gets only these:

- `Assets/VRChatWorldUnityAutomation/` (and its `.meta`): the editor trigger, editor-only with its own assembly definition, copied from the skill's `unity/` by `install.ps1`. Not an embedded package: registering one rewrites `Packages/packages-lock.json`, which projects commit.
- `TestingAutomation.md`: that project's settings (test texts, test instance, reminders). **Read it before any testing work in the project**, and follow its reminders.

The trigger folder and its `.meta` are listed in `.git/info/exclude` (git's own ignore list, not committed): it's this developer's tool. `TestingAutomation.md` is listed in the project's `.gitignore`, the one change `install.ps1` makes to the repository: commit that line, so nobody commits their own settings. Never commit the files themselves.

## Setting up a project

1. Run `& "$HOME\.claude\skills\vrchat-world-unity-automation\install.ps1" -Project <project path>` with the PowerShell tool (from Bash, use `powershell -ExecutionPolicy Bypass -File <script> …`, since the execution policy blocks scripts there). It copies the editor scripts when they're missing or older than the bundled ones, adds the exclusions, adds `/TestingAutomation.md` to `.gitignore` if it isn't there (tell the developer to commit that), and creates `TestingAutomation.md` from the template if there's none. After changing the bundled scripts, bump `unity/VERSION.txt` and run it again in each project, then queue a `refresh`.
2. If no trigger was running in that editor yet, Unity has to compile the new scripts once, and its own auto-refresh doesn't compile while its window lacks focus: ask the developer to click on Unity once. Once `Temp/EditorTrigger/log.txt` answers a `refresh`, everything works with Unity in the background.
3. Fill in `TestingAutomation.md` with the developer: what the project's tests log when done, the test instance URL, which profiles (from `developer.md`) to launch.

## The editor trigger

Append commands to `Temp/EditorTrigger/queue.txt` in the project (one per line; several at once run in order) and read the outcome from `Temp/EditorTrigger/log.txt`. Remember the log's line count before queuing, and poll for the new lines.

- `refresh`: resolve packages, import changed files and compile, logging `refreshed` or `refresh: compile errors (see the Editor log)`. **Queue one after every code change**: it compiles even with Unity in the background, which Unity's own auto-refresh doesn't.
- `select <hierarchy path>`: select an object (for editor scripts acting on the selection).
- `menu <menu path>`: run a menu item, e.g. `menu Tools/My Tool/Build`.
- `save`: save the open scenes.
- `play <seconds> <text>|<text>…`: enter Play Mode and leave it once every text has been logged, or after `<seconds>`. The log gets the line holding each text (e.g. a test's pass/fail summary), the first 20 errors and exceptions, and `Play Mode ended, N errors logged`.
- `stop`: leave Play Mode.
- `upload`: build the open scene and upload it as a new version of its world (its `PipelineManager` world ID), through the VRChat SDK's builder API. Logs in from the SDK's saved credentials (the panel otherwise only logs in when drawn, which it isn't with Unity in the background). The project's build callbacks still run and can cancel it. It saves the scene as the SDK normalizes it (e.g. `AutoHold` on pickups): treat that as a Unity-generated change.

Full details: the Editor log, `%LOCALAPPDATA%\Unity\Editor\Editor.log`.

**Things that stop the queue.** A modal dialog waits until someone closes it, and the Editor log goes quiet meanwhile: an editor script's error dialog, or Unity's "The open scene(s) have been modified externally" (Reload / Ignore) after a git operation (reset, checkout, pull) rewrites the open scene, which appears at the next refresh. If the trigger's log stops answering and the Editor log hasn't been written for a while:

1. List the Unity process's visible top-level windows (PowerShell `Add-Type` with `EnumWindows`, `GetWindowThreadProcessId`, `GetWindowText`, `GetClassName`). A dialog is a `#32770` window besides the main `UnityContainerWndClass` one.
2. Read it with UI Automation (`AutomationElement.FromHandle(<dialog handle>)`, all descendants): its message and buttons (each a native `Button` with its own handle).
3. Press a button only when the right answer is clear from what the developer asked for (e.g. **Reload** after a git operation they asked for, since the file on disk is then the version they want), by posting `BM_CLICK` (0x00F5) to the button's handle: `PostMessage(button, 0xF5, 0, 0)`. This doesn't move the mouse or take focus. Check the button's class and text first. Otherwise say what the dialog asks and let the developer answer.

**When no trigger is loaded** (a new install, or after removing and reinstalling it), Unity doesn't even import new files until its window gains focus; posting `WM_ACTIVATEAPP` to it doesn't help. Ask the developer to click on Unity once (or, when they're away, say it's waiting for that). So when replacing the trigger, install the new one while the old one still runs, and let the old one's `refresh` compile it.

## VRChat clients (production)

`vrchat-clients.ps1` in the skill folder (PowerShell):

- `start -Profiles 0,2 -Url "<instance URL>" [-VrProfiles 0]`: launch each profile through VRChat's `launch.exe`, desktop (`--no-vr`) unless in `-VrProfiles`, a few seconds apart. The script assumes the default Steam install; pass `-Launcher <path to launch.exe>` for another (the path can be set in `developer.md`).
- `clients`: the running clients (pid, profile, account, log). Easy Anti-Cheat hides VRChat's command line, so the script pairs each process with the log created as it started and reads the profile and account from the log.
- `stop [-Profiles …]`: close them (`taskkill`, forced after 15 s). Without `-Profiles` it closes every client, the developer's own included: name the profiles you started.
- `logs [-Minutes 30]`: recent output logs with their profile and account.

Client logs: `%USERPROFILE%\AppData\LocalLow\VRChat\VRChat\output_log_*.txt`, one per client. Wait for `User Authenticated` and `Joining wrld_…`, then for the project's done texts.

An instance that's still open can keep the world version it opened with: after an upload, close every client first, and check from the client logs that the new version loaded.

## The developer

**Read `developer.md` in the skill folder before any testing work**: it holds the developer's own settings (VRChat accounts and profiles, VR headsets, whether they may be away, how they want to be asked), and it overrides the defaults below. It isn't shared with the skill. If it's missing, offer to create it with the developer from `templates/developer.md`.

Defaults, unless `developer.md` says otherwise:

- **Ask before every production run** (`upload`, starting or stopping VRChat clients): use the AskUserQuestion tool with two options, **Do it now** and **Later**. Skip asking only when the request for that run itself says to do it (e.g. "try upload", or "without asking"). Get everything ready first (code, `refresh`, Play Mode tests); on **Later**, stop and say what's ready and what to queue or run.
- **VR clients:** never plan more clients in VR at once than the developer has headsets (one if `developer.md` doesn't say); the rest run on desktop.
- **The developer may be away from the computer**, steering the session remotely. Then nothing can need a headset or hands at the PC (no VR client, no by-hand steps, no clicking on Unity): run what can go unattended and list what's left for when they're back. When it's unclear whether they're there and a run would need them, ask first.
- **Before closing clients, check `clients`:** the developer may be using some of them; stop only the profiles you started.

## Notes

- Claude Code's permission classifier has refused compiling C# with Unity's bundled `csc` outside Unity as a "production deploy". Compile through `refresh` instead.
- To check whether Unity has focus (for diagnosing compile waits): `GetForegroundWindow` through PowerShell `Add-Type`, compared against the Unity process.
