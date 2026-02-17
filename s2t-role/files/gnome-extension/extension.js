const { GObject, GLib, St } = imports.gi;
const Clutter = imports.gi.Clutter;
const Main = imports.ui.main;
const PanelMenu = imports.ui.panelMenu;

let QuickSettings = null;
try {
    QuickSettings = imports.ui.quickSettings;
} catch (e) {
    QuickSettings = null;
}

// COMMANDS
const S2T_CONTROLLER = '/etc/s2t/result/bin/s2t-controller';

// Helper to run command
function runToggle() {
    try {
        GLib.spawn_async(
            null,
            [S2T_CONTROLLER, 'toggle'],
            null,
            GLib.SpawnFlags.SEARCH_PATH,
            null
        );
    } catch (e) {
        logError(e);
    }
}

function getPidFile() {
    const runtimeDir = GLib.getenv('XDG_RUNTIME_DIR') || '/tmp';
    return `${runtimeDir}/s2t/recording.pid`;
}

function isRecording() {
    return GLib.file_test(getPidFile(), GLib.FileTest.EXISTS);
}

let S2TToggle = null;
if (QuickSettings) {
    // Quick Settings Toggle Class (GNOME 43+)
    S2TToggle = GObject.registerClass(
    class S2TToggleImpl extends QuickSettings.QuickToggle {
        _init() {
            super._init({
                title: 'Mic S2T',
                iconName: 'microphone-sensitivity-high-symbolic',
                toggleMode: true,
            });

            this.checked = isRecording();

            this.connect('clicked', () => {
                runToggle();
                GLib.timeout_add(GLib.PRIORITY_DEFAULT, 250, () => {
                    this.checked = isRecording();
                    return GLib.SOURCE_REMOVE;
                });
            });
        }
    });
}

// Extension Logic
class Extension {
    constructor(uuid) {
        this._uuid = uuid;
        this._toggle = null;
        this._qsIndicator = null;
        this._indicator = null;
        this._syncId = null;
    }

    enable() {
        // detection of QuickSettings
        if (QuickSettings && Main.panel.statusArea.quickSettings) {
            this._qsIndicator = new QuickSettings.SystemIndicator();
            this._qsIndicator._indicator = this._qsIndicator._addIndicator();
            this._qsIndicator._indicator.icon_name = 'microphone-sensitivity-high-symbolic';

            this._toggle = new S2TToggle();
            this._qsIndicator.quickSettingsItems.push(this._toggle);

            Main.panel.statusArea.quickSettings.addExternalIndicator(this._qsIndicator);

            this._syncId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 1, () => {
                if (this._toggle)
                    this._toggle.checked = isRecording();
                return GLib.SOURCE_CONTINUE;
            });
        } else {
            // Fallback for Older GNOME or if QuickSettings missing
            this._indicator = new PanelMenu.Button(0.0, "S2T", false);
            let icon = new St.Icon({
                icon_name: 'microphone-sensitivity-high-symbolic',
                style_class: 'system-status-icon',
            });
            this._indicator.add_child(icon);
            this._indicator.connect('button-press-event', () => {
                runToggle();
                return Clutter.EVENT_PROPAGATE;
            });
            Main.panel.addToStatusArea('s2t-indicator', this._indicator);
        }
    }

    disable() {
        if (this._syncId) {
            GLib.Source.remove(this._syncId);
            this._syncId = null;
        }
        if (this._toggle) {
            this._toggle.destroy();
            this._toggle = null;
        }
        if (this._qsIndicator) {
            this._qsIndicator.destroy();
            this._qsIndicator = null;
        }
        if (this._indicator) {
            this._indicator.destroy();
            this._indicator = null;
        }
    }
}

function init(meta) {
    return new Extension(meta.uuid);
}
