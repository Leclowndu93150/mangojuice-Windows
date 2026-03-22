/* game_manager.vala // Licence: GPL-v3.0 */
/* Overlay manager: pick a running process, launch MangoHud.exe targeting it. */

using Gtk;
using Adw;
using Gee;

/**
 * Get full path to reg.exe
 */
private static string get_reg_exe () {
    string? sysroot = Environment.get_variable ("SystemRoot");
    if (sysroot == null)
        sysroot = "C:\\Windows";
    return Path.build_filename (sysroot, "System32", "reg.exe");
}

private static bool run_reg (string[] args) {
    string[] real_args = args.copy ();
    real_args[0] = get_reg_exe ();

    try {
        int exit_status;
        string std_out;
        string std_err;
        Process.spawn_sync (null, real_args, null, (SpawnFlags) 0, null,
            out std_out, out std_err, out exit_status);
        return (exit_status == 0);
    } catch (Error e) {
        stderr.printf ("reg command failed: %s\n", e.message);
        return false;
    }
}

private static string? find_layer_json () {
    string exe_dir = Environment.get_current_dir ();
    string? appdir = Environment.get_variable ("APPDIR");
    if (appdir != null && appdir != "")
        exe_dir = appdir;

    string json_path = Path.build_filename (exe_dir, "MangoHud.x86_64.json");
    if (FileUtils.test (json_path, FileTest.EXISTS))
        return json_path;
    json_path = Path.build_filename (exe_dir, "MangoHud.json");
    if (FileUtils.test (json_path, FileTest.EXISTS))
        return json_path;
    return null;
}

public static bool register_vulkan_layer () {
    string? json_path = find_layer_json ();
    if (json_path == null) return false;
    string reg_path = json_path.replace ("/", "\\");

    bool ok = run_reg ({ "reg", "add",
        "HKLM\\SOFTWARE\\Khronos\\Vulkan\\ImplicitLayers",
        "/v", reg_path, "/t", "REG_DWORD", "/d", "0", "/f" });
    if (!ok) return false;

    run_reg ({ "reg", "add",
        "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment",
        "/v", "MANGOHUD", "/t", "REG_SZ", "/d", "1", "/f" });
    return true;
}

public static bool is_vulkan_layer_registered () {
    try {
        int exit_status;
        string std_out;
        string std_err;
        Process.spawn_sync (null,
            { get_reg_exe (), "query", "HKLM\\SOFTWARE\\Khronos\\Vulkan\\ImplicitLayers" },
            null, (SpawnFlags) 0, null, out std_out, out std_err, out exit_status);
        return (exit_status == 0 && std_out.contains ("MangoHud"));
    } catch (Error e) {
        return false;
    }
}

public class GameManager : Box {
    private ListBox process_list_box;
    private Button start_btn;
    private Button stop_btn;
    private Button refresh_btn;
    private Label status_label;
    private Pid? overlay_pid = null;
    private string? current_target = null;

    public GameManager () {
        Object (orientation: Orientation.VERTICAL, spacing: 8);
        set_margin_start (12);
        set_margin_end (12);
        set_margin_top (12);
        set_margin_bottom (12);
        setup_ui ();
        refresh_processes ();
    }

    private string get_exe_directory () {
        string? appdir = Environment.get_variable ("APPDIR");
        if (appdir != null && appdir != "")
            return appdir;
        return Environment.get_current_dir ();
    }

    /* ---- UI ---- */

    private void setup_ui () {
        // Header
        var header = new Label (_("Overlay"));
        header.add_css_class ("title-2");
        header.set_halign (Align.START);
        append (header);

        var desc = new Label (_("Select a running game process and start the overlay. MangoHud will track the game window automatically."));
        desc.add_css_class ("dim-label");
        desc.set_halign (Align.START);
        desc.set_wrap (true);
        append (desc);

        // Process list
        var scrolled = new ScrolledWindow ();
        scrolled.vexpand = true;
        scrolled.min_content_height = 250;

        process_list_box = new ListBox ();
        process_list_box.set_selection_mode (SelectionMode.SINGLE);
        process_list_box.add_css_class ("boxed-list");
        scrolled.child = process_list_box;
        append (scrolled);

        // Buttons
        var btn_box = new Box (Orientation.HORIZONTAL, 8);
        btn_box.set_halign (Align.CENTER);
        btn_box.set_margin_top (8);

        refresh_btn = new Button.with_label (_("Refresh"));
        refresh_btn.add_css_class ("flat");
        refresh_btn.clicked.connect (refresh_processes);
        btn_box.append (refresh_btn);

        start_btn = new Button.with_label (_("Start Overlay"));
        start_btn.add_css_class ("suggested-action");
        start_btn.add_css_class ("pill");
        start_btn.clicked.connect (on_start);
        btn_box.append (start_btn);

        stop_btn = new Button.with_label (_("Stop Overlay"));
        stop_btn.add_css_class ("destructive-action");
        stop_btn.sensitive = false;
        stop_btn.clicked.connect (on_stop);
        btn_box.append (stop_btn);

        append (btn_box);

        // Status
        status_label = new Label (_("No overlay running."));
        status_label.add_css_class ("dim-label");
        status_label.set_margin_top (4);
        append (status_label);

        // Vulkan layer section
        var sep = new Separator (Orientation.HORIZONTAL);
        sep.set_margin_top (12);
        append (sep);

        var vk_header = new Label (_("Vulkan Games"));
        vk_header.add_css_class ("title-4");
        vk_header.set_halign (Align.START);
        vk_header.set_margin_top (6);
        append (vk_header);

        var vk_desc = new Label (_("Register the Vulkan layer for games like CS2, Doom, etc. Requires admin. The overlay still needs to be started above."));
        vk_desc.add_css_class ("dim-label");
        vk_desc.set_halign (Align.START);
        vk_desc.set_wrap (true);
        append (vk_desc);

        var vk_status = new Label ("");
        vk_status.set_halign (Align.START);
        vk_status.set_margin_top (4);

        var vk_btn = new Button.with_label (_("Register Vulkan Layer"));
        vk_btn.set_margin_top (4);

        if (is_vulkan_layer_registered ()) {
            vk_status.label = _("Registered");
            vk_status.add_css_class ("success");
            vk_btn.label = _("Re-register");
        } else {
            vk_status.label = _("Not registered");
            vk_status.add_css_class ("warning");
        }

        vk_btn.clicked.connect (() => {
            vk_btn.sensitive = false;
            vk_status.label = _("Registering...");
            new Thread<void> ("vk-reg", () => {
                bool ok = register_vulkan_layer ();
                bool reg = is_vulkan_layer_registered ();
                Idle.add (() => {
                    vk_btn.sensitive = true;
                    if (ok && reg) {
                        vk_status.label = _("Registered");
                        vk_status.remove_css_class ("warning");
                        vk_status.add_css_class ("success");
                    } else {
                        vk_status.label = _("Failed (need admin)");
                        vk_status.add_css_class ("error");
                    }
                    return false;
                });
            });
        });

        append (vk_status);
        append (vk_btn);
    }

    /* ---- Process enumeration ---- */

    private void refresh_processes () {
        // Clear
        var child = process_list_box.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            process_list_box.remove (child);
            child = next;
        }

        // Get running processes via tasklist (simple, no extra deps)
        try {
            string tasklist = Path.build_filename (
                Environment.get_variable ("SystemRoot") ?? "C:\\Windows",
                "System32", "tasklist.exe"
            );

            int exit_status;
            string std_out;
            string std_err;
            Process.spawn_sync (null,
                { tasklist, "/FO", "CSV", "/NH" },
                null, (SpawnFlags) 0, null,
                out std_out, out std_err, out exit_status);

            if (exit_status != 0) return;

            // Known non-game processes to filter out
            string[] skip = {
                "System", "svchost.exe", "csrss.exe", "wininit.exe",
                "services.exe", "lsass.exe", "smss.exe", "dwm.exe",
                "explorer.exe", "SearchHost.exe", "RuntimeBroker.exe",
                "ShellExperienceHost.exe", "sihost.exe", "taskhostw.exe",
                "ctfmon.exe", "conhost.exe", "cmd.exe", "powershell.exe",
                "WindowsTerminal.exe", "SecurityHealthSystray.exe",
                "TextInputHost.exe", "SystemSettings.exe",
                "ApplicationFrameHost.exe", "fontdrvhost.exe",
                "WmiPrvSE.exe", "spoolsv.exe", "dllhost.exe",
                "tasklist.exe", "mangojuice.exe", "MangoJuice.exe",
                "MangoHud.exe", "Code.exe", "msedge.exe",
                "chrome.exe", "firefox.exe", "Widgets.exe",
                "StartMenuExperienceHost.exe",
                "CompPkgSrv.exe", "audiodg.exe",
                "NVDisplay.Container.exe", "nvcontainer.exe",
                "NVIDIA Web Helper.exe",
            };

            var seen = new HashSet<string> ();
            string[] lines = std_out.split ("\n");

            foreach (string line in lines) {
                string trimmed = line.strip ();
                if (trimmed == "") continue;

                // CSV: "name.exe","PID","Session Name","Session#","Mem Usage"
                string[] parts = trimmed.split ("\",\"");
                if (parts.length < 2) continue;

                string name = parts[0].replace ("\"", "").strip ();
                if (name == "" || name == "Image Name") continue;

                // Skip known system processes
                bool should_skip = false;
                foreach (string s in skip) {
                    if (name == s) { should_skip = true; break; }
                }
                if (should_skip) continue;

                // Skip duplicates
                if (seen.contains (name)) continue;
                seen.add (name);

                var row = new Adw.ActionRow ();
                row.title = name;
                process_list_box.append (row);
            }
        } catch (Error e) {
            stderr.printf ("Failed to list processes: %s\n", e.message);
        }
    }

    private string? get_selected_process () {
        var row = process_list_box.get_selected_row ();
        if (row == null) return null;

        // Walk to find the ActionRow
        var child = process_list_box.get_first_child ();
        int idx = 0;
        while (child != null) {
            if (child == row) {
                var action_row = child as Adw.ActionRow;
                if (action_row != null) return action_row.title;
            }
            child = child.get_next_sibling ();
        }
        return null;
    }

    /* ---- Start / Stop ---- */

    private void on_start () {
        string? proc = get_selected_process ();
        if (proc == null) {
            show_error_dialog (_("No process selected"), _("Select a game from the list first."));
            return;
        }

        string mangohud_exe = Path.build_filename (get_exe_directory (), "MangoHud.exe");
        if (!FileUtils.test (mangohud_exe, FileTest.EXISTS)) {
            show_error_dialog (_("MangoHud.exe not found"), _("Expected at: %s").printf (mangohud_exe));
            return;
        }

        // Save config before starting so the overlay picks up current settings
        // (MangoJuice saves to MangoHud.conf, MangoHud.exe reads it on startup)

        try {
            Process.spawn_command_line_async (mangohud_exe + " " + proc);
            current_target = proc;
            start_btn.sensitive = false;
            stop_btn.sensitive = true;
            status_label.label = _("Overlay running on: %s").printf (proc);
            status_label.remove_css_class ("dim-label");
            status_label.add_css_class ("success");
        } catch (Error e) {
            show_error_dialog (_("Failed to start overlay"), e.message);
        }
    }

    private void on_stop () {
        try {
            string taskkill = Path.build_filename (
                Environment.get_variable ("SystemRoot") ?? "C:\\Windows",
                "System32", "taskkill.exe"
            );
            Process.spawn_command_line_async (taskkill + " /IM MangoHud.exe /F");
        } catch (Error e) {
            stderr.printf ("Failed to stop overlay: %s\n", e.message);
        }

        current_target = null;
        start_btn.sensitive = true;
        stop_btn.sensitive = false;
        status_label.label = _("No overlay running.");
        status_label.remove_css_class ("success");
        status_label.add_css_class ("dim-label");
    }

    /* ---- Error dialog ---- */

    private void show_error_dialog (string title, string message) {
        var dlg = new Adw.AlertDialog (title, message);
        dlg.add_response ("ok", _("OK"));
        dlg.set_default_response ("ok");
        var root_window = this.get_root () as Gtk.Window;
        dlg.present (root_window);
    }
}
