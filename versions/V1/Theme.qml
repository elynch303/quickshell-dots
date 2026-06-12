import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "Palette.js" as Palette

Item {
    id: theme

    readonly property string colorsPath: Quickshell.env("HOME") + "/.config/omarchy/current/theme/colors.toml"

    property color paper:   "#181616"
    property color ink:     "#c5c9c5"
    property color inkDeep: "#c8c093"
    property color sumi:    "#a6a69c"
    property color indigo:  "#658594"
    property color green:   "#8a9a73"   // gate "OK" verdict
    property color sealRaw:    "#c4746e"
    property color accentHint: sealRaw    // filled by palette; default = same as red
    property bool  useThemeAccent: false

    readonly property color seal: useThemeAccent ? accentHint : sealRaw

    readonly property string mono:  "JetBrainsMono Nerd Font"

    // ── transparency knobs (0.0 = fully transparent, 1.0 = opaque) ──
    property real barOpacity:  0.94   // große Insel / Split-Sektionen
    property real pillOpacity: 0.45   // einzelne Widget-Pillen (workspace, mem, cpu, …)

    readonly property color bg:     Qt.rgba(paper.r, paper.g, paper.b, barOpacity)
    readonly property color pill:   Qt.rgba(paper.r, paper.g, paper.b, pillOpacity)
    readonly property color fg:     ink
    readonly property color muted:  sumi
    readonly property color accent: seal
    readonly property color warn:   seal
    readonly property color sep:    Qt.rgba(ink.r, ink.g, ink.b, 0.18)

    property string lastAppliedName: ""

    // ── Tooltip state ──
    property string tooltipText: ""
    property real tooltipX: 0
    property real tooltipY: 0
    property bool tooltipShown: false
    property var tooltipOwner: null   // the widget currently owning the tooltip

    function showTooltip(text, x, y, owner) {
        if (!text) return;
        tooltipText = text;
        tooltipX = x;
        tooltipY = y;
        tooltipOwner = owner !== undefined ? owner : null;
        tooltipShown = true;
    }

    // hide only if the caller owns the current tooltip (owner match is stable
    // even when the tooltip text changes, e.g. a live timer). A null/undefined
    // owner force-hides. Legacy string args fall back to a text match.
    function hideTooltip(owner) {
        if (owner === undefined || owner === null) {
            tooltipShown = false; tooltipOwner = null;
        } else if (typeof owner === "object") {
            if (tooltipOwner === owner) { tooltipShown = false; tooltipOwner = null; }
        } else if (tooltipText === owner) {
            tooltipShown = false; tooltipOwner = null;
        }
    }

    // safety net: if the owning widget disappears while its tooltip is shown
    // (e.g. ScreenRecord stops mid-hover, or a slot widget gets disabled), force-hide.
    // Via Connections — NOT a `_visible` property whose change-handler writes
    // tooltipOwner (that property read tooltipOwner → binding loop).
    Connections {
        target: theme.tooltipOwner
        ignoreUnknownSignals: true
        function onVisibleChanged() {
            if (theme.tooltipOwner && !theme.tooltipOwner.visible) {
                theme.tooltipShown = false; theme.tooltipOwner = null;
            }
        }
    }

    // ── Calendar state ──
    property bool calendarVisible: false
    property int calendarMonthOffset: 0
    property int calendarTick: 0
    property int selectedDay: 0

    readonly property var calendarCells: {
        calendarTick;
        const now = new Date();
        const first = new Date(now.getFullYear(), now.getMonth() + calendarMonthOffset, 1);
        const year = first.getFullYear();
        const month = first.getMonth();
        const lastDay = new Date(year, month + 1, 0).getDate();
        const startDay = (first.getDay() + 6) % 7;
        const today = new Date();
        const isCurrentMonth = year === today.getFullYear() && month === today.getMonth();
        const cells = [];
        for (let i = 0; i < startDay; i++) cells.push({day: 0, today: false});
        for (let d = 1; d <= lastDay; d++) {
            cells.push({day: d, today: isCurrentMonth && d === today.getDate()});
        }
        while (cells.length < 42) cells.push({day: 0, today: false});
        return cells;
    }

    readonly property string calendarMonthName: {
        const months = ["JANUARY","FEBRUARY","MARCH","APRIL","MAY","JUNE",
                        "JULY","AUGUST","SEPTEMBER","OCTOBER","NOVEMBER","DECEMBER"];
        const now = new Date();
        return months[(now.getMonth() + calendarMonthOffset + 12000) % 12];
    }

    readonly property string calendarYear: {
        const now = new Date();
        const d = new Date(now.getFullYear(), now.getMonth() + calendarMonthOffset, 1);
        return String(d.getFullYear());
    }

    function openCalendar() {
        calendarMonthOffset = 0;
        calendarTick++;
        selectedDay = (new Date()).getDate();
        calendarVisible = true;
    }

    // ── CPU panel state ──
    property bool cpuVisible: false

    // ── Memory panel state ──
    property bool memVisible: false

    // ── Volume panel state ──
    property bool volVisible: false

    // ── Control center state ──
    property bool controlVisible: false

    // ── Split state (controlled by Bar + ControlPanel) ──
    property bool splitLeft:   false
    property bool splitRight:  false
    property bool splitArch:   false
    property bool splitMon:    false
    property bool splitNet:    false
    property bool splitMprisL: false
    property int barAnim: 0   // 0=off, 1=stream, 2=surge, 3=bolt

    // ── Bar layout / unlock (drag&drop reorder). barUnlocked is transient. ──
    property bool barUnlocked: false
    // split-control hooks — assigned by BarSlot, called by the ControlPanel split
    // sub-panel (same engine → shared root, no IPC needed).
    property var  fnSplitAll:      null
    property var  fnMergeAll:      null
    property var  fnDefaultLayout: null
    property bool splitsSubVisible: false
    onControlVisibleChanged: if (!controlVisible) splitsSubVisible = false   // don't reopen with the panel

    readonly property bool anySplit: splitLeft || splitRight || splitArch
                                  || splitMon  || splitNet  || splitMprisL
    onAnySplitChanged: if (!anySplit) barAnim = 0

    // splitLeft/splitRight kept as constant-false (toggles removed); the clean
    // content-edge cuts are splitMon (Left) and splitMprisL (Right).
    function mergeAllSplits() {
        splitLeft = false; splitRight = false; splitArch = false;
        splitMon = false; splitNet = false; splitMprisL = false;
    }

    // ── Control-panel state persistence (splits / anim / accent) ──
    // Survives bar restarts via a tiny cache file; no extra deps (same Process+cat
    // pattern used elsewhere). _splitsLoaded gates saving so the initial restore
    // doesn't immediately write back over itself.
    readonly property string splitsCachePath: Quickshell.env("HOME") + "/.cache/quickshell_splits"
    property bool _splitsLoaded: false

    onSplitArchChanged:      if (_splitsLoaded) saveSplits()
    onSplitMonChanged:       if (_splitsLoaded) saveSplits()
    onSplitNetChanged:       if (_splitsLoaded) saveSplits()
    onSplitMprisLChanged:    if (_splitsLoaded) saveSplits()
    onBarAnimChanged:        if (_splitsLoaded) saveSplits()
    onUseThemeAccentChanged: if (_splitsLoaded) saveSplits()

    // Build the command imperatively (not as a binding): a bound `command` can
    // still hold the pre-toggle value when the Process runs, saving stale state.
    function saveSplits() {
        var line = (splitArch   ? "1" : "0") + " "
                 + (splitMon     ? "1" : "0") + " "
                 + (splitMprisL  ? "1" : "0") + " "
                 + (splitNet     ? "1" : "0") + " "
                 + barAnim + " "
                 + (useThemeAccent ? "1" : "0")
        splitSaveProc.command = ["bash", "-c",
            "mkdir -p \"$(dirname '" + splitsCachePath + "')\" && echo '" + line + "' > '" + splitsCachePath + "'"]
        splitSaveProc.running = false
        splitSaveProc.running = true
    }

    Process {
        id: splitLoadProc
        command: ["cat", theme.splitsCachePath]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                var parts = this.text.trim().split(" ")
                if (parts.length >= 5) {
                    theme.splitArch      = parts[0] === "1"
                    theme.splitMon       = parts[1] === "1"
                    theme.splitMprisL    = parts[2] === "1"
                    theme.splitNet       = parts[3] === "1"
                    var ba = parseInt(parts[4]); theme.barAnim = (ba >= 0 && ba <= 4) ? ba : 0
                    theme.useThemeAccent = parts.length >= 6 && parts[5] === "1"
                }
                theme._splitsLoaded = true
            }
        }
    }

    Process { id: splitSaveProc }   // command is set imperatively in saveSplits()

    // ── module enable flags (controlled by ControlPanel) ──
    property bool modWorkspace:  true
    property bool modStatus:     true
    property bool modMemory:     true
    property bool modCpu:        true
    property bool modVolume:     true
    property bool modWeather:    true
    property bool modNetwork:    true
    property string networkMode: "none"   // mirrored from NetworkWidget: wifi/ethernet/none
    // NetworkManager active (Omarchy 4.0) → the panel's iwctl scan/connect won't work,
    // so it shows an "open nmtui" button instead of an empty list
    property bool useNM: false
    Process {
        command: ["bash", "-c", "systemctl is-active --quiet NetworkManager && echo 1 || echo 0"]
        running: true
        stdout: StdioCollector { onStreamFinished: theme.useNM = this.text.trim() === "1" }
    }

    // ── wifi/bluetooth settings launchers (Omarchy way, via uwsm-app) ──
    // iwd (Omarchy 3.8.x) → impala/bluetui through omarchy-launch-*; if NetworkManager
    // is the active backend (Omarchy 4.0) → nmtui instead.
    readonly property string launchWifiCmd: "if systemctl is-active --quiet NetworkManager 2>/dev/null; then omarchy-launch-or-focus-tui nmtui; else omarchy-launch-wifi; fi"
    readonly property string launchBtCmd:   "omarchy-launch-bluetooth"
    property bool modPower:      false   // default off (toggle in ControlPanel)
    property bool modBluetooth:  false   // default off (toggle in ControlPanel)
    property bool modBattery:    true
    property bool modBrightness: true
    property bool modMedia:      true
    property bool modClaude:     false   // default off (toggle in ControlPanel)

    // backlight presence — set by BrightnessWidget once it probes /sys/class/backlight.
    // ControlPanel uses this to hide the Brightness toggle on desktops without one.
    property bool hasBacklight:  false

    // ── workspace display mode ──
    property string workspaceMode: "10"   // "10", "5", "active"

    // ── picker visual style (theme/wallpaper/screenshot/video pickers) ──
    property string pickerStyle: "tanzaku"   // "tanzaku", "hearthstone", "carousel"
    property bool   weatherImperial: false   // false = °C / km·h, true = °F / mph
    property bool   clock12h:        false   // false = 24h, true = 12h (AM/PM)

    // ── widget/workspace state persistence ──
    readonly property string widgetsCachePath: Quickshell.env("HOME") + "/.cache/quickshell_widgets"
    property bool _widgetsLoaded: false

    onModMemoryChanged:     if (_widgetsLoaded) saveWidgets()
    onModBrightnessChanged: if (_widgetsLoaded) saveWidgets()
    onModClaudeChanged:     if (_widgetsLoaded) saveWidgets()
    onModPowerChanged:      if (_widgetsLoaded) saveWidgets()
    onModBluetoothChanged:  if (_widgetsLoaded) saveWidgets()
    onModNetworkChanged:    if (_widgetsLoaded) saveWidgets()
    onWorkspaceModeChanged: if (_widgetsLoaded) saveWidgets()
    onPickerStyleChanged:   if (_widgetsLoaded) saveWidgets()
    onWeatherImperialChanged: if (_widgetsLoaded) saveWidgets()
    onClock12hChanged:        if (_widgetsLoaded) saveWidgets()

    function saveWidgets() {
        var line = (modMemory    ? "1" : "0") + " "
                 + (modBrightness ? "1" : "0") + " "
                 + (modClaude    ? "1" : "0") + " "
                 + (modPower     ? "1" : "0") + " "
                 + (modBluetooth ? "1" : "0") + " "
                 + workspaceMode + " "
                 + pickerStyle + " "
                 + (weatherImperial ? "1" : "0") + " "
                 + (clock12h        ? "1" : "0") + " "
                 + (modNetwork      ? "1" : "0")   // appended → old caches just keep the default
        widgetSaveProc.command = ["bash", "-c",
            "echo '" + line + "' > '" + widgetsCachePath + "'"]
        widgetSaveProc.running = false
        widgetSaveProc.running = true
    }

    Process {
        id: widgetLoadProc
        command: ["cat", theme.widgetsCachePath]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                var parts = this.text.trim().split(" ")
                if (parts.length >= 4) {
                    theme.modMemory    = parts[0] !== "0"
                    theme.modBrightness = parts[1] !== "0"
                    theme.modClaude    = parts[2] !== "0"
                    theme.modPower     = parts[3] !== "0"
                }
                // parts[4] is the bluetooth flag in the new format, but in the OLD
                // format it was the workspace mode ("10"/"5"/"active") — detect which.
                var wsField = -1
                if (parts.length >= 5) {
                    if (parts[4] === "5" || parts[4] === "active" || parts[4] === "10") {
                        wsField = 4                         // old format: no bluetooth field
                    } else {
                        theme.modBluetooth = parts[4] !== "0"
                        wsField = 5
                    }
                }
                if (wsField >= 0 && parts.length > wsField) {
                    var m = parts[wsField]
                    theme.workspaceMode = (m === "5" || m === "active") ? m : "10"
                    // pickerStyle is the field right after the workspace mode
                    if (parts.length > wsField + 1) {
                        var ps = parts[wsField + 1]
                        if (ps === "hearthstone" || ps === "carousel" || ps === "tanzaku")
                            theme.pickerStyle = ps
                    }
                    // weatherImperial / clock12h follow pickerStyle
                    if (parts.length > wsField + 2) theme.weatherImperial = parts[wsField + 2] === "1"
                    if (parts.length > wsField + 3) theme.clock12h        = parts[wsField + 3] === "1"
                    if (parts.length > wsField + 4) theme.modNetwork      = parts[wsField + 4] === "1"
                }
                theme._widgetsLoaded = true
            }
        }
    }

    Process { id: widgetSaveProc }

    // ── New widget panel states ──
    property bool networkVisible:   false
    property bool bluetoothVisible: false
    property bool batteryVisible:   false
    property bool brightnessVisible: false
    property bool mprisVisible:     false
    property bool weatherVisible:   false
    property bool workspaceVisible: false

    // ── Image picker state (theme/wallpaper carousel) ──
    property bool   imagePickerVisible:  false
    property string imagePickerMode:     "wallpaper"   // "theme" or "wallpaper"
    property real   quickActionsBarX:    0
    // ── Media browser state (screenshots/videos carousel) ──
    property bool   mediaBrowserVisible: false
    property string mediaBrowserMode:    "screenshots"  // "screenshots" or "videos"
    // ── Idle inhibitor (Wayland idle-inhibit protocol) ──
    property bool   idleInhibited:       false
    // ── Notification state ──
    property bool notifVisible: false
    property int  notifCount:   0
    property real notifBarX:    0

    // ── Power Profile state ──
    property bool powerProfileVisible: false
    property string powerProfileCurrent: ""

    Process {
        id: initPowerProfile
        command: ["bash", "-c", "powerprofilesctl get 2>/dev/null || echo balanced"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                var p = this.text.trim()
                if (p) theme.powerProfileCurrent = p
            }
        }
    }

    // ── Hyprland workspace dispatch (config-mode-aware) ──
    // Hyprland 0.55 added Lua configs but still supports classic hyprlang, and
    // BOTH ship the same version number — so the dispatch form depends on which
    // config is ACTIVE, not the version: classic wants "workspace N", Lua wants
    // hl.dsp.focus({ workspace = N }). Probe the mode once with a harmless token:
    // "hl.dsp" alone yields the Lua error "hl.dispatch: expected a dispatcher"
    // under Lua, or "Invalid dispatcher" under classic — neither switches.
    property bool hyprUsesLua: false
    Process {
        id: hyprDispatchProbe
        command: ["bash", "-c", "hyprctl dispatch 'hl.dsp' 2>&1 | grep -qi 'hl\\.dispatch' && echo lua || echo classic"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: { theme.hyprUsesLua = (this.text.trim() === "lua") }
        }
    }
    function gotoWorkspace(id) {
        if (hyprUsesLua)
            Hyprland.dispatch("hl.dsp.focus({ workspace = " + id + " })")
        else
            Hyprland.dispatch("workspace " + id)
    }

    // ── Arch Updater state ──
    property bool archVisible: false
    property var archUpdates: []
    property int archRefreshTick: 0

    // ── Arch security gate (pre-install verdict per package) ──
    // idle | scanning | clean | warn | blocked | degraded
    property string archGateState: "idle"
    property var    archGateResults: []   // [{pkg,repo,old,new,verdict,reason}]
    property int    archGateOk: 0
    property int    archGateWarn: 0
    property int    archGateFail: 0
    property int    archGateBlacklist: 0
    property bool   archGateDegraded: false
    property string archGateListDate: ""   // mtime of the freshest blacklist source

    // Manual retry, e.g. on panel open: a degraded verdict can be a transient
    // (blacklist file mid-update at scan time) and must not stick until the
    // next refresh.
    function archGateRescan() { archGate.rerun() }

    Process {
        id: archGate
        // Hang on the DATA, not the refresh trigger: archRefreshTick fires the
        // refresh, but archUpdates is only filled when the refresh finishes — so
        // watching the tick would scan the PREVIOUS list. Watch archUpdates.
        property var watched: theme.archUpdates
        onWatchedChanged: rerun()
        function rerun() {
            running = false   // restart even if a previous scan is still running
            theme.archGateResults = []
            theme.archGateOk = 0; theme.archGateWarn = 0; theme.archGateFail = 0
            theme.archGateBlacklist = 0; theme.archGateDegraded = false
            if (!theme.archUpdates || theme.archUpdates.length === 0) {
                theme.archGateState = "clean"; return
            }
            theme.archGateState = "scanning"
            running = true
        }
        command: ["bash", Quickshell.env("HOME") + "/.local/bin/qs-arch-security-gate.sh"]
        stdinEnabled: true
        onStarted: {
            // Feed "pkg|repo|old|new" — exactly the gate's stdin format.
            for (var i = 0; i < theme.archUpdates.length; i++) {
                var u = theme.archUpdates[i]
                var repo = (u.source === "aur") ? "aur" : "system"
                write(u.name + "|" + repo + "|" + (u.oldVer || "") + "|" + (u.newVer || "") + "\n")
            }
            stdinEnabled = false   // EOF → gate finishes
        }
        stdout: StdioCollector {
            onStreamFinished: {
                var results = [], ok = 0, warn = 0, fail = 0, sawMeta = false
                var lines = this.text.trim().split("\n")
                for (var i = 0; i < lines.length; i++) {
                    var s = lines[i].trim(); if (!s) continue
                    var o; try { o = JSON.parse(s) } catch (e) { continue }
                    if (o.meta === "gate") {
                        sawMeta = true
                        theme.archGateBlacklist = o.blacklist || 0
                        if (o.degraded) theme.archGateDegraded = true
                        if (o.list_date) theme.archGateListDate = o.list_date
                        continue
                    }
                    results.push(o)
                    if (o.verdict === "FAIL") fail++
                    else if (o.verdict === "WARN") warn++
                    else ok++
                }
                theme.archGateResults = results
                theme.archGateOk = ok; theme.archGateWarn = warn; theme.archGateFail = fail
                // Fail-CLOSED: if the gate didn't fully respond (no meta line, or a
                // package has no verdict — gate missing/crashed/partial), do NOT
                // claim "clean". An empty/short answer means "unverified", not "safe".
                if (!sawMeta || results.length !== theme.archUpdates.length)
                    theme.archGateDegraded = true
                theme.archGateState =
                    fail > 0 ? "blocked"
                    : theme.archGateDegraded ? "degraded"
                    : warn > 0 ? "warn" : "clean"
            }
        }
        onExited: (exitCode) => {
            // Gate exited nonzero (missing script, crash) and produced no findings
            // => force degraded so the panel never shows a false all-clear.
            if (exitCode !== 0) {
                theme.archGateDegraded = true
                if (theme.archGateFail === 0 && theme.archGateWarn === 0)
                    theme.archGateState = "degraded"
            }
        }
    }

    // ── Shell Updater state (badge ⇄ panel; fed by ShellUpdateWidget's FileView) ──
    property bool shellUpdateVisible: false
    property int  shellUpdateBehind: 0
    property var  shellUpdateSummary: []
    property string shellUpdateVersion: ""
    property real shellUpdateBarX: 0

    // ── Tray state ──
    property bool trayVisible: false
    property var trayPinned: []
    property real trayBarX: 10

    // ── slot-aware panel X anchors (center-X of each group; set by BarSlot) ──
    property real volumeBarX:     0
    property real networkBarX:    0
    property real batteryBarX:    0
    property real memoryBarX:     0
    property real cpuBarX:        0
    property real workspaceBarX:  0
    property real archBarX:       0
    property real bluetoothBarX:  0
    property real brightnessBarX: 0
    property real powerBarX:      0
    property real mprisBarX:      0
    property real weatherBarX:    0
    property real launcherBarX:   6   // ControlPanel follows the Launcher/Control group

    // ── Tray context-menu state (themed menu, rendered by TrayMenu.qml) ──
    property bool trayMenuVisible: false
    property var  trayMenuHandle: null   // the QsMenuHandle of the clicked item
    property real trayMenuX: 0           // global x to anchor the menu under the icon
    function openTrayMenu(handle, x) {
        trayMenuHandle = handle
        trayMenuX = x
        trayMenuVisible = true
    }

    function trayIsHidden(item) {
        return trayPinned.indexOf(item.id) < 0
    }

    // toggle: hidden items get pinned (shown in bar); pinned items get unpinned (back to panel)
    function trayToggleHide(item) {
        var key = item.id
        if (!key) return
        var i = trayPinned.indexOf(key)
        if (i >= 0) {
            var a = trayPinned.slice(0, i)
            var b = trayPinned.slice(i + 1)
            trayPinned = a.concat(b)
            trayVisible = false
        } else {
            trayPinned = trayPinned.concat([key])
        }
    }

    Process {
        id: paletteReader
        command: ["cat", theme.colorsPath]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                Palette.apply(theme, Palette.parse(this.text));
            }
        }
    }

    IpcHandler {
        target: "theme"
        function apply(payload: string): void {
            let p;
            try { p = JSON.parse(payload); }
            catch (e) { console.warn("theme.apply: bad payload —", e); return; }
            if (!p || !p.colors) return;
            Palette.apply(theme, Palette.mapKeys(p.colors));
            theme.lastAppliedName = p.name || "";
        }
        function reload(): void {
            paletteReader.running = false;
            paletteReader.running = true;
        }
    }

    // entry point for keybinds: `qs -c bar ipc call picker theme|wallpaper|...`
    // (unqualified access → resolves to the Theme root's properties; avoids the
    //  function name `theme` shadowing the `id: theme`)
    IpcHandler {
        target: "picker"
        function theme(): void       { mediaBrowserVisible = false; imagePickerMode = "theme";     imagePickerVisible = true }
        function wallpaper(): void   { mediaBrowserVisible = false; imagePickerMode = "wallpaper"; imagePickerVisible = true }
        function screenshots(): void { imagePickerVisible = false;  mediaBrowserMode = "screenshots"; mediaBrowserVisible = true }
        function videos(): void      { imagePickerVisible = false;  mediaBrowserMode = "videos";      mediaBrowserVisible = true }
    }
}
