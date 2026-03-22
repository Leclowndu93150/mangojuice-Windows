/* game_manager.vala // Licence: GPL-v3.0 */
/* Windows Game Manager for MangoHud -- deploy/remove proxy dxgi.dll per game.
 * Also handles Vulkan implicit layer registration (requires admin). */

using Gtk;
using Adw;
using Gee;

/**
 * Register the MangoHud Vulkan implicit layer in the Windows Registry.
 * This writes to HKLM so the application needs admin privileges.
 * After registration, all Vulkan games get the overlay when MANGOHUD=1 is set.
 */
public static void register_vulkan_layer () {
    string exe_dir = Environment.get_current_dir ();
    string? appdir = Environment.get_variable ("APPDIR");
    if (appdir != null && appdir != "")
        exe_dir = appdir;

    string json_path = Path.build_filename (exe_dir, "MangoHud.x86_64.json");

    // Also check for the JSON without arch suffix
    if (!FileUtils.test (json_path, FileTest.EXISTS)) {
        json_path = Path.build_filename (exe_dir, "MangoHud.json");
    }

    if (!FileUtils.test (json_path, FileTest.EXISTS)) {
        stderr.printf ("Vulkan layer JSON not found at: %s\n", json_path);
        return;
    }

    // Use reg.exe to write the registry key. This avoids needing Windows-specific
    // Vala bindings. The key is:
    //   HKLM\SOFTWARE\Khronos\Vulkan\ImplicitLayers
    //   <path_to_json> = REG_DWORD 0
    try {
        // Normalize path separators for the registry
        string reg_path = json_path.replace ("/", "\\");

        string cmd = "reg add \"HKLM\\SOFTWARE\\Khronos\\Vulkan\\ImplicitLayers\" /v \"%s\" /t REG_DWORD /d 0 /f".printf (reg_path);
        Process.spawn_command_line_sync (cmd);

        // Also set MANGOHUD=1 system-wide so Vulkan games see it
        string env_cmd = "reg add \"HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment\" /v MANGOHUD /t REG_SZ /d 1 /f";
        Process.spawn_command_line_sync (env_cmd);

        stdout.printf ("Vulkan layer registered: %s\n", reg_path);
        stdout.printf ("MANGOHUD=1 set system-wide.\n");
    } catch (Error e) {
        stderr.printf ("Failed to register Vulkan layer: %s\n", e.message);
        stderr.printf ("Make sure MangoJuice is running as administrator.\n");
    }
}

/**
 * Check if the Vulkan layer is already registered.
 */
public static bool is_vulkan_layer_registered () {
    try {
        string output;
        Process.spawn_command_line_sync (
            "reg query \"HKLM\\SOFTWARE\\Khronos\\Vulkan\\ImplicitLayers\"",
            out output
        );
        return output.contains ("MangoHud");
    } catch (Error e) {
        return false;
    }
}

public class GameEntry : Object {
    public string name { get; set; }
    public string exe_path { get; set; }
    public bool enabled { get; set; }

    public GameEntry (string name, string exe_path, bool enabled) {
        this.name = name;
        this.exe_path = exe_path;
        this.enabled = enabled;
    }
}

public class GameManager : Box {
    private ArrayList<GameEntry> games;
    private string games_file;
    private string proxy_dll_path;
    private ListBox list_box;
    private Label empty_label;

    public GameManager () {
        Object (orientation: Orientation.VERTICAL, spacing: 10);

        set_margin_start (12);
        set_margin_end (12);
        set_margin_top (12);
        set_margin_bottom (12);

        string appdata = Environment.get_variable ("APPDATA") ?? Environment.get_home_dir ();
        games_file = Path.build_filename (appdata, "MangoHud", "games.txt");

        // The proxy dxgi.dll is expected beside the running executable,
        // or in the application install directory.
        proxy_dll_path = Path.build_filename (get_exe_directory (), "dxgi.dll");

        games = new ArrayList<GameEntry> ();

        setup_ui ();
        load_games ();
        refresh_list ();
    }

    /* ------------------------------------------------------------------ */
    /*  Helpers                                                            */
    /* ------------------------------------------------------------------ */

    private string get_exe_directory () {
        // Try the directory of the running process first.
        // GLib doesn't expose GetModuleFileName on Windows, so fall back to
        // the working directory or APPDIR if set.
        string? appdir = Environment.get_variable ("APPDIR");
        if (appdir != null && appdir != "") {
            return appdir;
        }
        return Environment.get_current_dir ();
    }

    /* ------------------------------------------------------------------ */
    /*  UI                                                                 */
    /* ------------------------------------------------------------------ */

    private void setup_ui () {
        // Title
        var header = new Label (_("Game Manager"));
        header.add_css_class ("title-2");
        header.set_halign (Align.START);
        append (header);

        var subtitle = new Label (_("Deploy or remove the MangoHud proxy DLL (dxgi.dll) for each game."));
        subtitle.add_css_class ("dim-label");
        subtitle.set_halign (Align.START);
        subtitle.set_wrap (true);
        append (subtitle);

        // Scrolled list
        var scrolled = new ScrolledWindow ();
        scrolled.vexpand = true;
        scrolled.min_content_height = 200;

        list_box = new ListBox ();
        list_box.set_selection_mode (SelectionMode.SINGLE);
        list_box.add_css_class ("boxed-list");
        scrolled.child = list_box;
        append (scrolled);

        // Empty-state label (shown when no games configured)
        empty_label = new Label (_("No games added yet. Click \"Add Game\" to get started."));
        empty_label.add_css_class ("dim-label");
        empty_label.set_margin_top (24);
        empty_label.set_margin_bottom (24);

        // Buttons row
        var button_box = new Box (Orientation.HORIZONTAL, 6);
        button_box.set_halign (Align.CENTER);
        button_box.set_margin_top (6);

        var add_btn = new Button.with_label (_("Add Game"));
        add_btn.add_css_class ("suggested-action");
        add_btn.clicked.connect (on_add_game);
        button_box.append (add_btn);

        var remove_btn = new Button.with_label (_("Remove"));
        remove_btn.add_css_class ("destructive-action");
        remove_btn.clicked.connect (on_remove_game);
        button_box.append (remove_btn);

        var enable_btn = new Button.with_label (_("Enable"));
        enable_btn.clicked.connect (on_enable_game);
        button_box.append (enable_btn);

        var disable_btn = new Button.with_label (_("Disable"));
        disable_btn.clicked.connect (on_disable_game);
        button_box.append (disable_btn);

        append (button_box);

        // Proxy DLL status
        if (!FileUtils.test (proxy_dll_path, FileTest.EXISTS)) {
            var warn = new Label (_("Warning: proxy dxgi.dll not found at: %s").printf (proxy_dll_path));
            warn.add_css_class ("error");
            warn.set_wrap (true);
            warn.set_margin_top (8);
            append (warn);
        }

        // Vulkan layer section
        var vk_separator = new Separator (Orientation.HORIZONTAL);
        vk_separator.set_margin_top (12);
        append (vk_separator);

        var vk_header = new Label (_("Vulkan Overlay"));
        vk_header.add_css_class ("title-4");
        vk_header.set_halign (Align.START);
        vk_header.set_margin_top (6);
        append (vk_header);

        var vk_desc = new Label (_("Register the Vulkan layer so the overlay works in Vulkan games (CS2, Doom, etc). This requires admin privileges and sets the MANGOHUD=1 environment variable system-wide."));
        vk_desc.add_css_class ("dim-label");
        vk_desc.set_halign (Align.START);
        vk_desc.set_wrap (true);
        append (vk_desc);

        var vk_status_label = new Label ("");
        vk_status_label.set_halign (Align.START);
        vk_status_label.set_margin_top (4);

        var vk_btn = new Button.with_label (_("Register Vulkan Layer"));

        if (is_vulkan_layer_registered ()) {
            vk_status_label.label = _("Status: Registered");
            vk_status_label.add_css_class ("success");
            vk_btn.label = _("Re-register Vulkan Layer");
        } else {
            vk_status_label.label = _("Status: Not registered");
            vk_status_label.add_css_class ("warning");
        }

        vk_btn.set_margin_top (4);
        vk_btn.clicked.connect (() => {
            register_vulkan_layer ();
            if (is_vulkan_layer_registered ()) {
                vk_status_label.label = _("Status: Registered");
                vk_status_label.remove_css_class ("warning");
                vk_status_label.add_css_class ("success");
                vk_btn.label = _("Re-register Vulkan Layer");
            } else {
                show_error_dialog (
                    _("Registration failed"),
                    _("Could not write to the registry. Make sure MangoJuice is running as administrator.")
                );
            }
        });

        append (vk_status_label);
        append (vk_btn);
    }

    /* ------------------------------------------------------------------ */
    /*  List helpers                                                       */
    /* ------------------------------------------------------------------ */

    private void refresh_list () {
        // Remove all children
        var child = list_box.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            list_box.remove (child);
            child = next;
        }

        if (games.size == 0) {
            list_box.append (empty_label);
            return;
        }

        foreach (var game in games) {
            var row = new Adw.ActionRow ();
            row.title = game.name;
            row.subtitle = game.exe_path;

            // Status indicator
            var status = new Label (game.enabled ? _("Enabled") : _("Disabled"));
            if (game.enabled) {
                status.add_css_class ("success");
            } else {
                status.add_css_class ("dim-label");
            }
            status.set_valign (Align.CENTER);
            row.add_suffix (status);

            list_box.append (row);
        }
    }

    private int get_selected_index () {
        var selected_row = list_box.get_selected_row ();
        if (selected_row == null) return -1;

        int idx = 0;
        var child = list_box.get_first_child ();
        while (child != null) {
            if (child == selected_row) return idx;
            idx++;
            child = child.get_next_sibling ();
        }
        return -1;
    }

    /* ------------------------------------------------------------------ */
    /*  Game add / remove                                                  */
    /* ------------------------------------------------------------------ */

    private void on_add_game () {
        var dialog = new Gtk.FileDialog ();
        dialog.set_title (_("Select a game executable"));

        // Filter for .exe files
        var filter = new Gtk.FileFilter ();
        filter.set_filter_name (_("Executables"));
        filter.add_pattern ("*.exe");
        var filter_store = new GLib.ListStore (typeof (Gtk.FileFilter));
        filter_store.append (filter);
        dialog.set_filters (filter_store);
        dialog.set_default_filter (filter);

        var root_window = this.get_root () as Gtk.Window;
        dialog.open.begin (root_window, null, (obj, res) => {
            try {
                var file = dialog.open.end (res);
                string path = file.get_path ();
                string name = Path.get_basename (path);

                // Check for duplicates
                foreach (var g in games) {
                    if (g.exe_path == path) {
                        stderr.printf ("Game already in the list: %s\n", path);
                        return;
                    }
                }

                // Detect whether dxgi.dll already exists beside the game
                string game_dir = Path.get_dirname (path);
                string dll_in_game = Path.build_filename (game_dir, "dxgi.dll");
                bool already_enabled = FileUtils.test (dll_in_game, FileTest.EXISTS);

                var entry = new GameEntry (name, path, already_enabled);
                games.add (entry);
                save_games ();
                refresh_list ();
            } catch (Error e) {
                // User cancelled or error
                if (!(e is IOError.CANCELLED)) {
                    stderr.printf ("Error selecting game: %s\n", e.message);
                }
            }
        });
    }

    private void on_remove_game () {
        int idx = get_selected_index ();
        if (idx < 0 || idx >= games.size) return;

        games.remove_at (idx);
        save_games ();
        refresh_list ();
    }

    /* ------------------------------------------------------------------ */
    /*  Enable / Disable (deploy or remove dxgi.dll)                       */
    /* ------------------------------------------------------------------ */

    private void on_enable_game () {
        int idx = get_selected_index ();
        if (idx < 0 || idx >= games.size) return;

        var game = games[idx];
        if (game.enabled) return;

        if (!FileUtils.test (proxy_dll_path, FileTest.EXISTS)) {
            stderr.printf ("Proxy DLL not found at: %s\n", proxy_dll_path);
            show_error_dialog (_("Proxy dxgi.dll not found"), _("Expected at: %s").printf (proxy_dll_path));
            return;
        }

        string game_dir = Path.get_dirname (game.exe_path);
        string dest = Path.build_filename (game_dir, "dxgi.dll");

        try {
            var src_file = File.new_for_path (proxy_dll_path);
            var dst_file = File.new_for_path (dest);
            src_file.copy (dst_file, FileCopyFlags.OVERWRITE);

            game.enabled = true;
            save_games ();
            refresh_list ();
        } catch (Error e) {
            stderr.printf ("Error copying dxgi.dll: %s\n", e.message);
            show_error_dialog (_("Failed to enable MangoHud"), e.message);
        }
    }

    private void on_disable_game () {
        int idx = get_selected_index ();
        if (idx < 0 || idx >= games.size) return;

        var game = games[idx];
        if (!game.enabled) return;

        string game_dir = Path.get_dirname (game.exe_path);
        string dll_path = Path.build_filename (game_dir, "dxgi.dll");

        try {
            var dll_file = File.new_for_path (dll_path);
            if (dll_file.query_exists ()) {
                dll_file.delete ();
            }

            game.enabled = false;
            save_games ();
            refresh_list ();
        } catch (Error e) {
            stderr.printf ("Error removing dxgi.dll: %s\n", e.message);
            show_error_dialog (_("Failed to disable MangoHud"), e.message);
        }
    }

    /* ------------------------------------------------------------------ */
    /*  Persistence  (simple text file: name|path|enabled per line)        */
    /* ------------------------------------------------------------------ */

    private void load_games () {
        games.clear ();

        if (!FileUtils.test (games_file, FileTest.EXISTS)) {
            return;
        }

        try {
            string contents;
            FileUtils.get_contents (games_file, out contents);

            string[] lines = contents.split ("\n");
            foreach (string line in lines) {
                string trimmed = line.strip ();
                if (trimmed == "") continue;

                string[] parts = trimmed.split ("|", 3);
                if (parts.length < 3) continue;

                string name = parts[0];
                string path = parts[1];
                bool enabled = (parts[2] == "true");

                // Re-check actual state on disk
                string game_dir = Path.get_dirname (path);
                string dll_in_game = Path.build_filename (game_dir, "dxgi.dll");
                bool actual_enabled = FileUtils.test (dll_in_game, FileTest.EXISTS);

                games.add (new GameEntry (name, path, actual_enabled));
            }
        } catch (Error e) {
            stderr.printf ("Error loading games list: %s\n", e.message);
        }
    }

    private void save_games () {
        try {
            // Ensure directory exists
            string dir = Path.get_dirname (games_file);
            var dir_file = File.new_for_path (dir);
            if (!dir_file.query_exists ()) {
                dir_file.make_directory_with_parents ();
            }

            var sb = new StringBuilder ();
            foreach (var game in games) {
                sb.append ("%s|%s|%s\n".printf (game.name, game.exe_path, game.enabled ? "true" : "false"));
            }

            FileUtils.set_contents (games_file, sb.str);
        } catch (Error e) {
            stderr.printf ("Error saving games list: %s\n", e.message);
        }
    }

    /* ------------------------------------------------------------------ */
    /*  Error dialog                                                       */
    /* ------------------------------------------------------------------ */

    private void show_error_dialog (string title, string message) {
        var dlg = new Adw.AlertDialog (title, message);
        dlg.add_response ("ok", _("OK"));
        dlg.set_default_response ("ok");
        var root_window = this.get_root () as Gtk.Window;
        dlg.present (root_window);
    }
}
