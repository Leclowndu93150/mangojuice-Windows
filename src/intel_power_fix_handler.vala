/* intel_power_fix_handler.vala // Licence: GPL-v3.0 */
/* Stubbed out for Windows -- Intel powercap is Linux-only. */

using Gtk;
using GLib;
using Adw;

public async void on_intel_power_fix_button_clicked(Button button) {
    // No-op on Windows: Intel powercap permissions are a Linux concept.
}

public async void check_file_permissions_async(Button button) {
    // No-op on Windows.
    Idle.add(() => {
        button.sensitive = false;
        button.set_tooltip_text("Not available on Windows");
        return false;
    });
}
