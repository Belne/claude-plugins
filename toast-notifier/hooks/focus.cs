// Toast click activator: launched by Windows (DCOM LocalServer32) when the user
// clicks a Claude Code toast notification.
//
//   focus.exe                          -> global: focus the Claude Code terminal
//   focus.exe --session <session_id>   -> route back to the exact WT tab of that
//                                         Claude session (registered by toast.ps1
//                                         under HKCU\Software\ClaudeCode\Sessions)
//
// Session restore behavior:
//   - tab found + claude alive -> select that tab (UIA) and bring to foreground
//   - claude exited            -> new tab in same WT window: claude --resume <id>
//   - WT window gone           -> new WT window:            claude --resume <id>
//
// Claude Code sets the tab title to "<status glyph> <session name>" where the
// glyph changes dynamically (◐ ◑ ✳ ...), so tab matching compares the core
// session name after stripping the first short token.

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

static class FocusExe
{
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lp);
    delegate bool EnumProc(IntPtr h, IntPtr lp);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool f);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern void SwitchToThisWindow(IntPtr h, bool altTab);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll")] static extern bool FreeConsole();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern int GetConsoleTitle(StringBuilder sb, int max);
    const uint KEYEVENTF_KEYUP = 0x2;
    static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
    const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_SHOWWINDOW = 0x40;

    static IntPtr found = IntPtr.Zero;               // terminal window whose title contains "claude"
    static List<IntPtr> allTerminals = new List<IntPtr>(); // every Windows Terminal window (Z order)

    static void Log(string msg)
    {
        try
        {
            string path = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + "\\.claude\\toast-focus.log";
            System.IO.File.AppendAllText(path, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + msg + Environment.NewLine);
        }
        catch { }
    }

    static string RegValue(string key, string name)
    {
        try { object v = Microsoft.Win32.Registry.GetValue(key, name, null); return v == null ? null : v.ToString(); }
        catch { return null; }
    }

    static int RegInt(string key, string name)
    {
        try { return (int)Microsoft.Win32.Registry.GetValue(key, name, 0); }
        catch { return 0; }
    }

    // "◐ session name" -> "session name"; titles without a short status token pass through
    static string CoreName(string title)
    {
        if (string.IsNullOrEmpty(title)) return title;
        int sp = title.IndexOf(' ');
        if (sp > 0 && sp <= 3) return title.Substring(sp + 1).Trim();
        return title.Trim();
    }

    // Live tab title: attach to the claude process's console and read its title.
    // WT runs one ConPTY per tab and claude sets that console's title to the WT tab
    // title ("<status glyph> <session name>"), so this is the exact text UIA needs.
    // focus.exe is a GUI-subsystem process born without a console (DCOM launches it),
    // so AttachConsole is legal here — it fails from any process that already owns one.
    static string PeekConsoleTitle(uint pid)
    {
        try
        {
            if (!AttachConsole(pid)) { Log("attachconsole failed pid=" + pid); return null; }
            try
            {
                StringBuilder sb = new StringBuilder(1024);
                return GetConsoleTitle(sb, 1024) > 0 ? sb.ToString() : null;
            }
            finally { FreeConsole(); }
        }
        catch (Exception ex) { Log("peek title error: " + ex.Message); return null; }
    }

    static void FindWindows()
    {
        EnumWindows(delegate(IntPtr h, IntPtr lp)
        {
            if (!IsWindowVisible(h)) return true;
            StringBuilder sb = new StringBuilder(512);
            if (GetWindowText(h, sb, 512) == 0) return true;
            string title = sb.ToString();
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            string proc;
            try { proc = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName.ToLowerInvariant(); }
            catch { return true; }
            // Only terminal host processes, to avoid focusing a browser tab named "Claude"
            bool isTerminal = proc == "windowsterminal" || proc == "conhost" || proc == "openconsole" ||
                              proc == "wezterm-gui" || proc == "alacritty" || proc == "mintty";
            if (!isTerminal) return true;
            if (proc == "windowsterminal") allTerminals.Add(h);
            if (title.IndexOf("claude", StringComparison.OrdinalIgnoreCase) >= 0 && found == IntPtr.Zero)
                found = h; // keep scanning: session routing needs the full window list
            return true;
        }, IntPtr.Zero);
    }

    static void Activate(IntPtr h)
    {
        StringBuilder tb = new StringBuilder(256);
        GetWindowText(h, tb, 256);
        Log("activate hwnd=" + h + " title=" + tb.ToString());
        bool wasMin = IsIconic(h);
        if (wasMin) ShowWindow(h, 9); // SW_RESTORE
        uint pid;
        uint foreThread = GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        uint thisThread = GetCurrentThreadId();
        uint targetThread = GetWindowThreadProcessId(h, out pid);
        AttachThreadInput(thisThread, foreThread, true);
        AttachThreadInput(thisThread, targetThread, true);
        // Simulated Alt press/release defeats the foreground lock (classic hack)
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x12, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        bool ok = SetForegroundWindow(h);
        AttachThreadInput(thisThread, foreThread, false);
        AttachThreadInput(thisThread, targetThread, false);
        Log("SetForegroundWindow=" + ok + " wasMinimized=" + wasMin);
        if (!ok)
        {
            // TOPMOST 置顶再取消：强制把窗口推到 Z 序顶部（DCOM 进程无前台权限时的经典解法）
            SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE | SWP_SHOWWINDOW);
            SetWindowPos(h, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE | SWP_SHOWWINDOW);
            ok = SetForegroundWindow(h);
            Log("topmost-toggle SetForegroundWindow=" + ok);
        }
        if (!ok)
        {
            // 老牌强力 API：等效 Alt+Tab 切换
            SwitchToThisWindow(h, true);
            Log("SwitchToThisWindow applied");
        }
    }

    // Select the WT tab matching the recorded title. Match chain:
    // exact title -> core session name (status glyph stripped) -> contains "claude".
    // Returns false when this window has no matching tab.
    static bool TrySelectTab(IntPtr hwnd, string tabTitle)
    {
        try
        {
            var root = System.Windows.Automation.AutomationElement.FromHandle(hwnd);
            var tabCond = new System.Windows.Automation.PropertyCondition(
                System.Windows.Automation.AutomationElement.ControlTypeProperty,
                System.Windows.Automation.ControlType.Tab);
            var tab = root.FindFirst(System.Windows.Automation.TreeScope.Descendants, tabCond);
            if (tab == null) return false;
            var itemCond = new System.Windows.Automation.PropertyCondition(
                System.Windows.Automation.AutomationElement.ControlTypeProperty,
                System.Windows.Automation.ControlType.TabItem);
            var items = tab.FindAll(System.Windows.Automation.TreeScope.Descendants, itemCond);
            System.Windows.Automation.AutomationElement best = null;
            string core = CoreName(tabTitle);
            if (!string.IsNullOrEmpty(tabTitle))
                foreach (System.Windows.Automation.AutomationElement it in items)
                    if (it.Current.Name == tabTitle) { best = it; break; }
            if (best == null && !string.IsNullOrEmpty(core))
                foreach (System.Windows.Automation.AutomationElement it in items)
                {
                    string n = it.Current.Name;
                    if (!string.IsNullOrEmpty(n) && n.IndexOf(core, StringComparison.OrdinalIgnoreCase) >= 0)
                    { best = it; break; }
                }
            if (best == null)
                foreach (System.Windows.Automation.AutomationElement it in items)
                    if (!string.IsNullOrEmpty(it.Current.Name) &&
                        it.Current.Name.ToLowerInvariant().Contains("claude")) { best = it; break; }
            if (best == null) return false;
            var sel = (System.Windows.Automation.SelectionItemPattern)best.GetCurrentPattern(
                System.Windows.Automation.SelectionItemPattern.Pattern);
            sel.Select();
            Log("uia: selected tab '" + best.Current.Name + "' in hwnd=" + hwnd);
            return true;
        }
        catch (Exception ex) { Log("uia error: " + ex.Message); return false; }
    }

    static void ResumeNewTab(string wtSession, string cwd, string sessionId, bool sameWindow)
    {
        // 防抖：60 秒内同一会话只 resume 一次（通知被连点时避免开出多个重复标签）
        string lockPath = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) +
            "\\.claude\\toast-resume-" + sessionId + ".lock";
        try
        {
            if (System.IO.File.Exists(lockPath) &&
                (DateTime.Now - System.IO.File.GetLastWriteTime(lockPath)).TotalSeconds < 60)
            {
                Log("resume debounced (lock fresh): " + sessionId);
                return;
            }
            System.IO.File.WriteAllText(lockPath, DateTime.Now.ToString("s"));
        }
        catch { }
        try
        {
            var sb = new StringBuilder();
            if (sameWindow && !string.IsNullOrEmpty(wtSession))
                sb.Append("-s ").Append(wtSession).Append(' ');
            sb.Append("nt");
            if (!string.IsNullOrEmpty(cwd)) sb.Append(" -d \"").Append(cwd).Append("\"");
            sb.Append(" cmd /c claude --resume ").Append(sessionId);
            Log("resume: wt " + sb);
            System.Diagnostics.Process.Start("wt.exe", sb.ToString());
        }
        catch (Exception ex) { Log("resume failed: " + ex.Message); }
    }

    static void GlobalFocus()
    {
        IntPtr target = found;
        if (target == IntPtr.Zero && allTerminals.Count > 0) target = allTerminals[0];
        if (target != IntPtr.Zero)
        {
            Activate(target);
        }
        else
        {
            Log("no terminal window found, fallback to claude --resume");
            try { System.Diagnostics.Process.Start("wt.exe", "-d \"" +
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) +
                "\" powershell -NoExit -Command claude --resume"); }
            catch
            {
                try { System.Diagnostics.Process.Start("powershell.exe", "-NoExit -Command claude --resume"); }
                catch { }
            }
        }
    }

    static void SessionRestore(string sessionId)
    {
        string k = @"HKEY_CURRENT_USER\Software\ClaudeCode\Sessions\" + sessionId;
        string wtSession = RegValue(k, "wt_session");
        string tabTitle = RegValue(k, "tab_title");
        string cwd = RegValue(k, "cwd");
        int parentPid = RegInt(k, "parent_pid");
        Log("session=" + sessionId + " wt=" + wtSession + " title=" + tabTitle + " pid=" + parentPid + " cwd=" + cwd);

        // No session record (never registered by the new hook): degrade to global focus
        if (string.IsNullOrEmpty(wtSession) && string.IsNullOrEmpty(tabTitle) &&
            string.IsNullOrEmpty(cwd) && parentPid == 0)
        {
            Log("no session record, fallback to global focus");
            GlobalFocus();
            return;
        }

        bool claudeAlive = false;
        try { var p = System.Diagnostics.Process.GetProcessById(parentPid); claudeAlive = !p.HasExited; }
        catch { }
        Log("claudeAlive=" + claudeAlive + " windows=" + allTerminals.Count);

        // Live title beats the registry copy: the hook usually registers with an
        // empty tab_title (it runs in a detached pty and cannot read the real one),
        // and the title may also have changed since registration anyway.
        if (parentPid > 0)
        {
            string live = PeekConsoleTitle((uint)parentPid);
            if (!string.IsNullOrEmpty(live))
            {
                Log("live title='" + live + "' (registry='" + tabTitle + "')");
                tabTitle = live;
            }
        }

        // Locate the window that owns a tab matching the recorded session title
        IntPtr target = IntPtr.Zero;
        bool tabOk = false;
        foreach (IntPtr w in allTerminals)
        {
            if (TrySelectTab(w, tabTitle)) { target = w; tabOk = true; break; }
        }
        Log("tabSelect=" + tabOk);

        if (tabOk)
        {
            if (!claudeAlive) ResumeNewTab(wtSession, cwd, sessionId, true);
            Activate(target);
        }
        else if (found != IntPtr.Zero || allTerminals.Count > 0)
        {
            // Claude alive but tab title unmatched: just focus the window (user Ctrl+Tab)
            if (!claudeAlive) ResumeNewTab(wtSession, cwd, sessionId, true);
            GlobalFocus();
        }
        else
        {
            // WT window gone: open a new one and resume
            ResumeNewTab(wtSession, cwd, sessionId, false);
        }
    }

    static int Main(string[] args)
    {
        Log("focus.exe activated: " + string.Join(" ", args));

        string sessionId = null;
        for (int i = 0; i + 1 < args.Length; i++)
            if (args[i] == "--session") sessionId = args[i + 1];

        FindWindows();

        if (sessionId != null) SessionRestore(sessionId);
        else GlobalFocus();
        return 0;
    }
}
