using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Threading.Tasks;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;
#if VRC_WORLDS_SDK && UDON
using VRC.Core;
using VRC.SDK3.Editor;
using VRC.SDKBase.Editor.Api;
#endif

// Lets the shell drive the open editor with nobody at it. Installed in Assets/VRChatWorldUnityAutomation/ by the
// vrchat-world-unity-automation Claude Code skill. Commands appended to Temp/EditorTrigger/queue.txt run one at a
// time, and what happened is appended to Temp/EditorTrigger/log.txt (and logged with [EditorTrigger]). Commands, one
// per line:
//   refresh                          resolve packages, import changed files and wait for the scripts to compile
//   select <hierarchy path>          select an object in the open scenes, e.g. "World/Table 2"
//   menu <menu path>                 run a menu item, e.g. "Tools/My Tool/Build"
//   save                             save the open scenes
//   play <seconds> [<text>|<text>…]  enter Play Mode; leave it once every text has been logged, or after <seconds>
//   stop                             leave Play Mode
//   upload                           build the open scene and upload it as a new version of its world (the one in
//                                    its PipelineManager), as the VRChat SDK control panel's Build and Upload does
// A modal dialog (e.g. an editor script's error dialog) stops the editor, and so the queue, until someone closes it.
// Entering Play Mode reloads the domain, so the state of a command in progress is kept in SessionState. `upload` is
// compiled only with the VRChat Worlds SDK (VRC_WORLDS_SDK, set by the assembly definition) and when the UDON define
// is set: the SDK's VRC.SDK3.Editor assembly compiles only with it, and UDON is per platform, so it can be missing
// for a moment while the editor switches platform (e.g. a multi-platform upload switching to Android).
[InitializeOnLoad]
public static class EditorTrigger {
    const string Folder = "Temp/EditorTrigger";
    const string QueuePath = Folder + "/queue.txt";
    const string LogPath = Folder + "/log.txt";

    const string KeyState = "EditorTrigger.state"; // StateIdle, StateCompile, StatePlay or StateUpload
    const string KeyDeadline = "EditorTrigger.deadline"; // editor time the command gives up (or, compiling, settles)
    const string KeyStartDeadline = "EditorTrigger.startDeadline"; // editor time Play Mode must have started by
    const string KeyWaitFor = "EditorTrigger.waitFor"; // texts not logged yet, separated by '|'
    const string KeyWaitedAll = "EditorTrigger.waitedAll"; // every text given to play has been logged
    const string KeyPlayed = "EditorTrigger.played"; // Play Mode was seen running
    const string KeyExiting = "EditorTrigger.exiting"; // this has asked Play Mode to end
    const string KeyErrors = "EditorTrigger.errors"; // errors and exceptions logged in Play Mode

    const string StateIdle = "";
    const string StateCompile = "compile";
    const string StatePlay = "play";
    const string StateUpload = "upload";

    const double PollSeconds = 0.5;
    const double SettleSeconds = 2; // quiet time after a refresh before it counts as done
    const double StartSeconds = 60; // Play Mode must start within this (it won't with compile errors)
    const int LoginSeconds = 60; // the SDK must be logged in within this of opening its control panel
    const int MaxErrorsLogged = 20;
    const string Prefix = "[EditorTrigger] ";

    static double nextPoll;
    static bool uploading; // an upload runs in this domain (a domain reload would have ended it)

    static EditorTrigger() {
        EditorApplication.update += Update;
        Application.logMessageReceived += OnLog;
    }

    static void Update() {
        double now = EditorApplication.timeSinceStartup;
        string state = SessionState.GetString(KeyState, StateIdle);
        if (state == StateCompile) {
            StepCompile(now);
            return;
        }
        if (state == StatePlay) {
            StepPlay(now);
            return;
        }
        if (state == StateUpload) {
            if (!uploading) {
                Log("upload: interrupted by a domain reload");
                Finish();
            }
            return;
        }
        if (now < nextPoll) return;
        nextPoll = now + PollSeconds;
        if (EditorApplication.isCompiling || EditorApplication.isUpdating) return;
        string command = PopCommand();
        if (command != null) Run(command, now);
    }

    // The queue's first non-empty line, removed from the file; null when there's none (or the file is busy).
    static string PopCommand() {
        try {
            if (!File.Exists(QueuePath)) return null;
            string[] lines = File.ReadAllLines(QueuePath);
            int first = 0;
            while (first < lines.Length && lines[first].Trim() == "") first++;
            if (first == lines.Length) {
                File.Delete(QueuePath);
                return null;
            }
            List<string> rest = new List<string>();
            for (int i = first + 1; i < lines.Length; i++) rest.Add(lines[i]);
            File.WriteAllLines(QueuePath, rest.ToArray());
            return lines[first].Trim();
        } catch (IOException) {
            return null;
        }
    }

    static void Run(string command, double now) {
        Log("> " + command);
        int space = command.IndexOf(' ');
        string verb = space < 0 ? command : command.Substring(0, space);
        string arg = space < 0 ? "" : command.Substring(space + 1).Trim();
        switch (verb) {
            case "refresh":
                // Resolving picks up a package added to or removed from Packages/, which an asset refresh doesn't.
                UnityEditor.PackageManager.Client.Resolve();
                AssetDatabase.Refresh();
                SessionState.SetString(KeyDeadline, (now + SettleSeconds).ToString("R", CultureInfo.InvariantCulture));
                SessionState.SetString(KeyState, StateCompile);
                break;
            case "select":
                GameObject found = FindObject(arg);
                if (found == null) {
                    Log("select: no object at " + arg);
                } else {
                    Selection.activeGameObject = found;
                    Log("selected " + arg);
                }
                break;
            case "menu":
                Log(EditorApplication.ExecuteMenuItem(arg) ? "ran " + arg : "menu: no item " + arg);
                break;
            case "save":
                Log(EditorSceneManager.SaveOpenScenes() ? "saved the open scenes" : "save failed");
                break;
            case "play":
                StartPlay(arg, now);
                break;
            case "stop":
                if (EditorApplication.isPlaying) EditorApplication.ExitPlaymode();
                Log(EditorApplication.isPlaying ? "leaving Play Mode" : "stop: not in Play Mode");
                break;
            case "upload":
#if VRC_WORLDS_SDK && UDON
                Upload();
#else
                Log("upload: needs the VRChat Worlds SDK (com.vrchat.worlds) and the UDON define for this platform");
#endif
                break;
            default:
                Log("unknown command: " + command);
                break;
        }
    }

    static void StartPlay(string arg, double now) {
        if (EditorApplication.isPlayingOrWillChangePlaymode) {
            Log("play: already in Play Mode");
            return;
        }
        int space = arg.IndexOf(' ');
        string secondsText = space < 0 ? arg : arg.Substring(0, space);
        double seconds = GetNumber(secondsText);
        if (seconds <= 0) {
            Log("play: give the most seconds to wait first, e.g. play 600 [ArchiveTest] done");
            return;
        }
        SessionState.SetString(KeyWaitFor, space < 0 ? "" : arg.Substring(space + 1).Trim());
        SessionState.SetString(KeyStartDeadline, (now + StartSeconds).ToString("R", CultureInfo.InvariantCulture));
        SessionState.SetString(KeyDeadline, (now + StartSeconds + seconds).ToString("R", CultureInfo.InvariantCulture));
        SessionState.SetBool(KeyPlayed, false);
        SessionState.SetBool(KeyWaitedAll, false);
        SessionState.SetBool(KeyExiting, false);
        SessionState.SetInt(KeyErrors, 0);
        SessionState.SetString(KeyState, StatePlay);
        EditorApplication.EnterPlaymode();
    }

#if VRC_WORLDS_SDK && UDON
    // Opens the SDK control panel if needed, waits for it to log in, then builds and uploads through its public
    // builder API. The SDK's build checks (the project's own IVRCSDKBuildRequestedCallbacks too) can still cancel it.
    static async void Upload() {
        uploading = true;
        SessionState.SetString(KeyState, StateUpload);
        try {
            PipelineManager pipeline = UnityEngine.Object.FindObjectOfType<PipelineManager>();
            if (pipeline == null || string.IsNullOrEmpty(pipeline.blueprintId)) {
                Log("upload: the scene has no world ID yet; upload it once from the control panel");
                return;
            }
            // The panel logs in from its drawing code, which doesn't run while Unity is in the background, so this
            // starts the login (from the saved credentials) itself and keeps the panel repainting until it's done.
            EditorApplication.ExecuteMenuItem("VRChat SDK/Show Control Panel");
            for (int i = 0; i < LoginSeconds * 2 && !APIUser.IsLoggedIn; i++) {
                if (VRCSdkControlPanel.window != null) {
                    VRCSdkControlPanel.InitAccount();
                    VRCSdkControlPanel.window.Repaint();
                }
                await Task.Delay(500);
            }
            if (!APIUser.IsLoggedIn) {
                Log("upload: the SDK isn't logged in; log in on the control panel");
                return;
            }
            IVRCSdkWorldBuilderApi builder;
            if (!VRCSdkControlPanel.TryGetBuilder(out builder)) {
                Log("upload: the control panel has no world builder");
                return;
            }
            VRCWorld world = await VRCApi.GetWorld(pipeline.blueprintId, true);
            Log("upload: building and uploading " + world.Name + " (" + pipeline.blueprintId + ")");
            // The SDK asks for its copyright ownership agreement once per Unity session per world, as a modal in the
            // control panel's Build section that waits for OK. It's the developer's own certification, so it's left
            // for them; this only says the upload is waiting on it. The SDK keeps the worlds agreed to this session in
            // this SessionState key (VRCCopyrightAgreement, not public API: if it moves, the note just shows anyway).
            string agreed = SessionState.GetString("VRCSdkControlPanel.CopyrightAgreement.ContentList", "");
            if (Array.IndexOf(agreed.Split(';'), world.ID) < 0) {
                Log("upload: waiting for the developer to accept VRChat's \"Copyright ownership agreement\" (OK in the "
                    + "control panel's Build section; asked once per Unity session per world)");
            }
            await builder.BuildAndUpload(world);
            Log("upload: done");
        } catch (Exception e) {
            Log("upload failed: " + e.GetType().Name + ": " + FirstLine(e.Message));
        } finally {
            uploading = false;
            Finish();
        }
    }
#endif

    static void StepCompile(double now) {
        if (EditorApplication.isCompiling || EditorApplication.isUpdating) {
            SessionState.SetString(KeyDeadline, (now + SettleSeconds).ToString("R", CultureInfo.InvariantCulture));
            return;
        }
        if (now < GetTime(KeyDeadline)) return;
        Log(EditorUtility.scriptCompilationFailed ? "refresh: compile errors (see the Editor log)" : "refreshed");
        Finish();
    }

    static void StepPlay(double now) {
        bool played = SessionState.GetBool(KeyPlayed, false);
        if (!played) {
            if (EditorApplication.isPlaying) {
                SessionState.SetBool(KeyPlayed, true);
                Log("Play Mode started");
            } else if (!EditorApplication.isPlayingOrWillChangePlaymode && now > GetTime(KeyStartDeadline)) {
                Log("play: Play Mode didn't start (compile errors?)");
                Finish();
            }
            return;
        }
        if (!EditorApplication.isPlaying) {
            if (EditorApplication.isPlayingOrWillChangePlaymode) return;
            Log("Play Mode ended, " + SessionState.GetInt(KeyErrors, 0) + " errors logged");
            Finish();
            return;
        }
        if (SessionState.GetBool(KeyExiting, false)) return;
        string waitFor = SessionState.GetString(KeyWaitFor, "");
        bool waited = SessionState.GetBool(KeyWaitedAll, false);
        if (waited) {
            Log("every text was logged; leaving Play Mode");
        } else if (now > GetTime(KeyDeadline)) {
            Log(waitFor == "" ? "time up; leaving Play Mode" : "timed out waiting for: " + waitFor);
        } else {
            return;
        }
        SessionState.SetBool(KeyExiting, true);
        EditorApplication.ExitPlaymode();
    }

    // In Play Mode: counts errors (logging the first few) and crosses off the texts being waited for, logging the line
    // that held each.
    static void OnLog(string message, string stackTrace, LogType type) {
        if (SessionState.GetString(KeyState, StateIdle) != StatePlay) return;
        if (message.StartsWith(Prefix)) return;
        if (type == LogType.Error || type == LogType.Exception || type == LogType.Assert) {
            int errors = SessionState.GetInt(KeyErrors, 0) + 1;
            SessionState.SetInt(KeyErrors, errors);
            if (errors <= MaxErrorsLogged) Log("error: " + FirstLine(message));
        }
        string waitFor = SessionState.GetString(KeyWaitFor, "");
        if (waitFor == "") return;
        string[] texts = waitFor.Split('|');
        bool changed = false;
        for (int i = 0; i < texts.Length; i++) {
            if (texts[i] == "" || !message.Contains(texts[i])) continue;
            Log("logged: " + FirstLine(message));
            texts[i] = "";
            changed = true;
        }
        if (!changed) return;
        string left = string.Join("|", texts);
        SessionState.SetString(KeyWaitFor, left);
        // A single crossed-off text leaves "", the same as no texts given, so record it separately.
        if (left.Replace("|", "") == "") SessionState.SetBool(KeyWaitedAll, true);
    }

    static void Finish() {
        SessionState.SetString(KeyState, StateIdle);
        SessionState.EraseString(KeyWaitFor);
        SessionState.EraseString(KeyDeadline);
        SessionState.EraseString(KeyStartDeadline);
        SessionState.EraseBool(KeyPlayed);
        SessionState.EraseBool(KeyWaitedAll);
        SessionState.EraseBool(KeyExiting);
        SessionState.EraseInt(KeyErrors);
    }

    // An object in the open scenes by its hierarchy path ("Parent/Child"), inactive ones included.
    static GameObject FindObject(string path) {
        string[] names = path.Split('/');
        for (int s = 0; s < SceneManager.sceneCount; s++) {
            Scene scene = SceneManager.GetSceneAt(s);
            if (!scene.isLoaded) continue;
            foreach (GameObject root in scene.GetRootGameObjects()) {
                if (root.name != names[0]) continue;
                Transform t = root.transform;
                for (int i = 1; i < names.Length && t != null; i++) t = t.Find(names[i]);
                if (t != null) return t.gameObject;
            }
        }
        return null;
    }

    static double GetTime(string key) {
        return GetNumber(SessionState.GetString(key, ""));
    }

    // A number written in the invariant culture (the editor's own may use a decimal comma), 0 if it isn't one.
    static double GetNumber(string text) {
        double number;
        return double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out number) ? number : 0;
    }

    static string FirstLine(string text) {
        int end = text.IndexOf('\n');
        return end < 0 ? text : text.Substring(0, end).TrimEnd('\r');
    }

    static void Log(string text) {
        try {
            Directory.CreateDirectory(Folder);
            File.AppendAllText(LogPath, DateTime.Now.ToString("HH:mm:ss") + " " + text + "\n");
        } catch (IOException) {
        }
        Debug.Log(Prefix + text);
    }
}
