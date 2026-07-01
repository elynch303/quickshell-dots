import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Widgets
import "ImagePickerModel.js" as Model

// Tanzaku filmstrip picker for theme & wallpaper.
// sumi-e language: lots of empty space (ma), the focused image centred & full,
// the rest as thin desaturated paper strips (tanzaku), and ONE seal brush-stroke
// gliding under the focus as the single confident accent line.
PanelWindow {
    id: panel
    required property var root

    screen: root.activePopupScreen

    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "omarchy-image-carousel"
    WlrLayershell.keyboardFocus: panel.visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    readonly property bool active: root.pickerStyle === "tanzaku" || root.pickerStyle === ""   // default
    readonly property bool isThemeMode: root.imagePickerMode === "theme"
    readonly property bool ready: root.imagePickerVisible && active && imagesLoaded && layoutSettled

    property bool imagesLoaded:  false
    property bool layoutSettled: false
    property bool scanDone:      false   // a scan finished (distinguishes "loading" from "nothing found")
    property var  imageArray:    []
    property int  selFilt:       0
    property string filterText:  ""
    property string currentImage: ""

    visible: root.imagePickerVisible && active

    // ── reveal (fade + subtle rise) ──
    property real reveal: 0
    Behavior on reveal { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
    onReadyChanged: reveal = ready ? 1 : 0

    // ── filtered list (each entry keeps its original index) ──
    readonly property var filtered: {
        var out = []
        for (var i = 0; i < imageArray.length; i++) {
            if (!Model.itemMatches(imageArray, i, filterText)) continue
            out.push({
                idx:      i,
                filePath: imageArray[i].filePath,
                thumb:    "file://" + imageArray[i].thumbnailPath,
                label:    Model.labelForPath(imageArray[i].filePath),
                dir:      imageArray[i].dir || "",
                current:  imageArray[i].filePath === panel.currentImage
            })
        }
        return out
    }
    onFilteredChanged: if (selFilt >= filtered.length) selFilt = Math.max(0, filtered.length - 1)

    readonly property string currentLabel:
        (filtered.length > 0 && selFilt >= 0 && selFilt < filtered.length)
            ? filtered[selFilt].label
            : (filterText ? "No matches" : "")

    // ── open / style gating ──
    function syncOpen() {
        if (root.imagePickerVisible && active) {
            if (!imagesLoaded) {
                panel.layoutSettled = false
                panel.filterText    = ""
                panel.imageArray    = []
                panel.selFilt       = 0
                panel.reveal        = 0
                currentProc.running = false; currentProc.running = true
            }
        } else {
            panel.imagesLoaded  = false; panel.scanDone = false
            panel.layoutSettled = false
            panel.reveal        = 0
        }
    }
    Connections {
        target: root
        function onImagePickerVisibleChanged() { panel.syncOpen() }
        function onPickerStyleChanged()         { panel.syncOpen() }
    }

    // step 1: current image
    Process {
        id: currentProc
        command: panel.isThemeMode
            ? ["bash", "-c",
               "CACHE=$HOME/.cache/quickshell-theme-picker; " +
               "name=$(cat ~/.config/omarchy/current/theme.name 2>/dev/null || true); " +
               "for ext in png jpg jpeg webp; do f=\"$CACHE/$name.$ext\"; [ -L \"$f\" ] && echo \"$f\" && exit 0; done; echo ''"]
            : ["bash", "-c", "readlink -f ~/.config/omarchy/current/background 2>/dev/null || true"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                panel.currentImage = this.text.trim()
                cacheProc.running = false; cacheProc.running = true   // instant from cache
                var cmd = panel.buildScanCmd()
                cmd[2] = cmd[2] + " | tee " + panel.shq(panel.scanCachePath)
                scanProc.command = cmd
                scanProc.running = false; scanProc.running = true
            }
        }
    }

    // step 2: scan images (live refresh; writes the cache via tee)
    Process {
        id: scanProc
        command: []
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: panel.applyScan(text, false)
        }
    }

    // scan-result cache → instant (re)open
    readonly property string scanCachePath: Quickshell.env("HOME") + "/.cache/quickshell-scan-" + (isThemeMode ? "theme" : "wallpaper")
    property string _lastScan: ""
    Process {
        id: cacheProc
        command: ["cat", panel.scanCachePath]
        stdout: StdioCollector { onStreamFinished: panel.applyScan(this.text, true) }
    }
    function applyScan(text, fromCache) {
        var t = String(text || "")
        if (fromCache && !t.trim()) return   // cache empty → wait for live scan; live empty → fall through to empty-state
        if (fromCache && imagesLoaded) return
        if (!fromCache && t.trim() === _lastScan.trim() && imagesLoaded) return
        _lastScan = t
        var images = Model.loadRows(t)
        panel.imageArray   = images
        panel.selFilt      = Model.indexForSelectedImage(images, panel.currentImage)
        panel.imagesLoaded = images.length > 0; panel.scanDone = true
        Qt.callLater(function() {
            if (root.imagePickerVisible && panel.active) {
                panel.layoutSettled = true
                if (panel.imageArray.length > 0) stage.forceActiveFocus()   // keep Esc-catcher focused when empty
                panel.fetchMeta()
                if (!fromCache) { panel.warmMeta(); warmTimer.restart() }
            }
        })
    }

    function buildScanCmd() {
        if (isThemeMode) {
            return ["bash", "-c", [
                "shopt -s nullglob nocaseglob;",
                "CACHE=$HOME/.cache/quickshell-theme-picker; mkdir -p \"$CACHE\";",
                "for d in ~/.local/share/omarchy/themes/* ~/.config/omarchy/themes/*; do",
                "  [ -d \"$d\" ] || continue;",
                "  name=$(basename \"$d\");",
                "  prev=\"\";",
                "  for c in \"$d\"/preview.png \"$d\"/preview.jpg \"$d\"/preview.jpeg; do [ -f \"$c\" ] && { prev=\"$c\"; break; }; done;",
                "  if [ -z \"$prev\" ]; then bgs=(\"$d\"/backgrounds/*.jpg \"$d\"/backgrounds/*.jpeg \"$d\"/backgrounds/*.png \"$d\"/backgrounds/*.webp); prev=\"${bgs[0]}\"; fi;",
                "  [ -z \"$prev\" ] && continue;",
                "  ext=\"${prev##*.}\"; link=\"$CACHE/$name.$ext\";",
                "  [ -L \"$link\" ] || ln -sf \"$prev\" \"$link\";",
                "  printf '%s\\t%s\\t%s\\n' \"$link\" \"$prev\" \"$d\";",
                "done | sort -u"
            ].join(" ")]
        } else {
            return ["bash", "-c",
                "find -L ~/.config/omarchy/current/theme/backgrounds -maxdepth 1 -type f " +
                "\\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \\) " +
                "2>/dev/null | sort | while read f; do printf '%s\\t%s\\n' \"$f\" \"$f\"; done"
            ]
        }
    }

    Process { id: applyThemeProc; command: [] }
    Process { id: applyBgProc;    command: [] }

    function applySelected() {
        if (!imagesLoaded || filtered.length === 0) return
        if (selFilt < 0 || selFilt >= filtered.length) return
        var path = filtered[selFilt].filePath; if (!path) return
        if (isThemeMode) {
            var name = Model.nameForPath(path)
            applyThemeProc.command = ["bash", "-c", "omarchy-theme-set '" + name.replace(/'/g, "'\\''") + "'"]
            applyThemeProc.running = false; applyThemeProc.running = true
        } else {
            applyBgProc.command = ["bash", "-c", "omarchy-theme-bg-set '" + path.replace(/'/g, "'\\''") + "'"]
            applyBgProc.running = false; applyBgProc.running = true
        }
        root.imagePickerVisible = false
    }

    function moveSel(delta) {
        if (filtered.length === 0) return
        selFilt = Math.max(0, Math.min(filtered.length - 1, selFilt + delta))
    }

    // the currently focused entry (or null)
    readonly property var sel: (filtered.length > 0 && selFilt >= 0 && selFilt < filtered.length)
                               ? filtered[selFilt] : null

    function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

    // ── background pre-warm: after the open settles, generate every missing
    // thumbnail at LOW priority (nice) so fast scrubbing finds cached thumbs
    // without the warm burst ever competing with the open animation / GUI ──
    Process { id: warmProc; command: [] }
    Timer { id: warmTimer; interval: 450; onTriggered: panel.warmAll() }
    function warmAll() {
        var srcs = []
        for (var i = 0; i < imageArray.length; i++)
            if (imageArray[i].filePath) srcs.push(imageArray[i].filePath)
        if (srcs.length === 0) return
        warmProc.command = ["bash", "-c",
            "D=$HOME/.cache/quickshell-img-thumbs; mkdir -p \"$D\"; command -v magick >/dev/null 2>&1 || exit 0; " +
            "for s in \"$@\"; do k=$(printf '%s' \"$s\" | md5sum | cut -d' ' -f1); m=$(stat -c %Y \"$s\" 2>/dev/null); " +
            "o=\"$D/$k-$m.jpg\"; [ -f \"$o\" ] && continue; printf '%s\\n%s\\n' \"$s\" \"$o\"; done | " +
            "nice -n 19 xargs -d '\\n' -P 3 -n 2 sh -c 'magick \"$0\" -auto-orient -strip -thumbnail 480x270^ -quality 82 \"$1\" >/dev/null 2>&1'",
            "warm"].concat(srcs)
        warmProc.running = false; warmProc.running = true
    }

    // ── lazy meta (author/repo/palette) for the FOCUSED theme only, cached by
    // dir — keeps the scan instant; enrichment lands ~110ms after the focus settles
    property var metaCache: ({})
    property string _metaDir: ""
    readonly property var selMeta: (sel && sel.dir && metaCache[sel.dir]) ? metaCache[sel.dir] : null

    Timer { id: metaTimer; interval: 60; onTriggered: panel.fetchMeta() }
    onSelChanged: if (isThemeMode && sel && sel.dir && !metaCache[sel.dir]) metaTimer.restart()

    function fetchMeta() {
        if (!isThemeMode || !sel || !sel.dir || metaCache[sel.dir]) return
        panel._metaDir = sel.dir
        metaProc.command = ["bash", "-c",
            "d=" + shq(sel.dir) + "; repo=''; author='';" +
            "if [ -f \"$d/.git/config\" ]; then " +
            "  repo=$(sed -nE 's#^[[:space:]]*url = (.*)$#\\1#p' \"$d/.git/config\" | head -1);" +
            "  author=$(printf '%s' \"$repo\" | sed -nE 's#.*github\\.com[:/]+([^/]+)/.*#\\1#p');" +
            "fi;" +
            "pal=$(awk -F'\"' '/^color[1-6][[:space:]]*=/{print $2}' \"$d/colors.toml\" 2>/dev/null | paste -sd,);" +
            "printf '%s\\t%s\\t%s\\n' \"$author\" \"$repo\" \"$pal\""]
        metaProc.running = false; metaProc.running = true
    }
    Process {
        id: metaProc
        command: []
        stdout: StdioCollector {
            onStreamFinished: {
                var parts = String(this.text || "").replace(/\n+$/, "").split("\t")
                var m = panel.metaCache
                m[panel._metaDir] = { author: parts[0] || "", repo: parts[1] || "", palette: parts[2] || "" }
                panel.metaCache = m   // reassign → bindings refresh
            }
        }
    }

    function openRepo() {
        if (!selMeta || !selMeta.repo) return
        var url = String(selMeta.repo)
            .replace(/^git@github\.com:/, "https://github.com/")
            .replace(/\.git$/, "")
        Quickshell.execDetached(["xdg-open", url])
    }

    // ── bulk meta pre-warm: author/repo/palette for ALL themes in one background
    // pass → info is instant for every theme (no lazy timing fragility) ──
    Process {
        id: metaWarmProc
        command: []
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = String(this.text || "").split("\n")
                var m = panel.metaCache
                for (var i = 0; i < lines.length; i++) {
                    if (!lines[i]) continue
                    var p = lines[i].split("\t")
                    if (p[0] && !m[p[0]]) m[p[0]] = { author: p[1] || "", repo: p[2] || "", palette: p[3] || "" }
                }
                panel.metaCache = m
            }
        }
    }
    function warmMeta() {
        if (!isThemeMode) return
        var dirs = []
        for (var i = 0; i < imageArray.length; i++)
            if (imageArray[i].dir) dirs.push(imageArray[i].dir)
        if (dirs.length === 0) return
        metaWarmProc.command = ["bash", "-c",
            "for d in \"$@\"; do repo=''; author='';" +
            "if [ -f \"$d/.git/config\" ]; then repo=$(sed -nE 's#^[[:space:]]*url = (.*)$#\\1#p' \"$d/.git/config\" | head -1);" +
            "author=$(printf '%s' \"$repo\" | sed -nE 's#.*github\\.com[:/]+([^/]+)/.*#\\1#p'); fi;" +
            "pal=$(awk -F'\"' '/^color[1-6][[:space:]]*=/{print $2}' \"$d/colors.toml\" 2>/dev/null | paste -sd,);" +
            "printf '%s\\t%s\\t%s\\t%s\\n' \"$d\" \"$author\" \"$repo\" \"$pal\"; done",
            "warm"].concat(dirs)
        metaWarmProc.running = false; metaWarmProc.running = true
    }

    // ── geometry ──
    readonly property int  focusedW:   460
    readonly property int  focusedH:   259      // 16:9
    readonly property int  peekW:      104      // ONLY the immediate neighbour — preview peek
    readonly property int  stripW:     24       // every other strip — thin tanzaku (unchanged)
    readonly property int  gap:        8
    readonly property int  maxVisible: 5

    // only the first neighbour on each side widens for a preview; the rest stay thin
    function stripWidthFor(d) {
        if (d <= 0) return focusedW
        if (d === 1) return peekW
        return stripW
    }

    // ── colors (bar materials) ──
    readonly property color scrim:   Qt.rgba(root.paper.r, root.paper.g, root.paper.b, 0.8)
    readonly property color frameBg: root.frameWeak
    readonly property color uiDim:   Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.45)

    // ── scrim ──
    Rectangle {
        anchors.fill: parent
        color: panel.scrim
        opacity: panel.reveal
    }
    MouseArea {
        anchors.fill: parent
        enabled: panel.visible
        onClicked: root.imagePickerVisible = false
        onWheel: function(wheel) {
            if (!panel.ready) return
            panel.moveSel(wheel.angleDelta.y < 0 ? 1 : -1)
        }
    }

    // ── empty/loading state — also catches Esc to close when the stage isn't focused ──
    Item {
        anchors.fill: parent
        focus: panel.visible && !(panel.ready && panel.filtered.length > 0)
        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
                if (panel.filterText) panel.filterText = ""
                else root.imagePickerVisible = false
                event.accepted = true
            } else if (event.key === Qt.Key_Backspace) {
                if (panel.filterText.length > 0) panel.filterText = panel.filterText.slice(0, -1)
                event.accepted = true
            } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32
                       && event.text.charCodeAt(0) !== 127
                       && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
                if (event.text !== " " || (panel.filterText.length > 0 && !panel.filterText.endsWith(" "))) panel.filterText += event.text;
                event.accepted = true
            }
        }
    }
    Text {
        visible: root.imagePickerVisible && panel.active && panel.ready && panel.filtered.length === 0
        anchors.centerIn: parent
        horizontalAlignment: Text.AlignHCenter
        text: "No matches: " + panel.filterText + "\n\nBackspace to edit, or Esc to clear"
        color: root.ink
        font.family: root.mono; font.pixelSize: 16; font.letterSpacing: 1
    }
    Text {
        visible: root.imagePickerVisible && panel.active && !panel.ready
        anchors.centerIn: parent
        horizontalAlignment: Text.AlignHCenter
        text: panel.scanDone
              ? (panel.isThemeMode ? "No themes found" : "No wallpapers found") + "\n\nEsc or click to close"
              : "Loading…"
        color: root.ink
        font.family: root.mono; font.pixelSize: 16; font.letterSpacing: 1
    }

    // ── header / filter (over the stage) ──
    Text {
        visible: panel.ready
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: stage.top
        anchors.bottomMargin: 22
        opacity: panel.reveal
        text: panel.isThemeMode ? "THEME" : "WALLPAPER"
        color: root.sumiHi
        font.family: root.mono; font.pixelSize: 12; font.letterSpacing: 3; font.weight: Font.Medium
        horizontalAlignment: Text.AlignHCenter
    }

    // ── position indicator (aligned to the right edge of the focused image) ──
    Text {
        visible: panel.ready && panel.filtered.length > 0
        anchors.bottom: stage.top
        anchors.bottomMargin: 23
        x: stage.cx + panel.focusedW / 2 - width
        opacity: panel.reveal
        text: (panel.selFilt + 1) + " / " + panel.filtered.length
        color: panel.uiDim
        font.family: root.mono; font.pixelSize: 11
    }

    // ── the stage (filmstrip) ──
    Item {
        id: stage
        visible: panel.ready && panel.filtered.length > 0
        focus: panel.ready && panel.filtered.length > 0
        opacity: panel.reveal
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -10 + (1 - panel.reveal) * 14
        width: parent.width
        height: panel.focusedH

        readonly property real cx:     width / 2
        readonly property real fLeft:  cx - panel.focusedW / 2
        readonly property real fRight: cx + panel.focusedW / 2

        // left edge x for an item at relIdx r, summing intervening (variable) widths
        function xForRel(r) {
            if (r === 0) return fLeft
            var x
            if (r < 0) {
                x = fLeft
                for (var k = -1; k >= r; k--) x = x - panel.gap - panel.stripWidthFor(-k)
                return x
            }
            x = fRight + panel.gap
            for (var j = 1; j < r; j++) x = x + panel.stripWidthFor(j) + panel.gap
            return x
        }

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
                if (panel.filterText) panel.filterText = ""
                else root.imagePickerVisible = false
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                panel.applySelected(); event.accepted = true
            } else if (event.key === Qt.Key_Backspace) {
                if (panel.filterText.length > 0) panel.filterText = panel.filterText.slice(0, -1)
                event.accepted = true
            } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Backtab
                       || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
                panel.moveSel(-1); event.accepted = true
            } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Tab) {
                panel.moveSel(1); event.accepted = true
            } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32
                       && event.text.charCodeAt(0) !== 127
                       && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
                if (event.text !== " " || (panel.filterText.length > 0 && !panel.filterText.endsWith(" "))) panel.filterText += event.text; event.accepted = true
            }
        }

        Repeater {
            model: panel.filtered.length

            delegate: Item {
                id: item
                required property int index
                readonly property var  entry:   panel.filtered[index] || null
                readonly property int  relIdx:  index - panel.selFilt
                readonly property bool focused: relIdx === 0
                readonly property bool near:    Math.abs(relIdx) <= panel.maxVisible

                // ── cached 480px thumbnails for ALL items (theme + wallpaper) ──
                // never decode the full source live → instant load, smooth scrubbing.
                property string thumbPath: ""
                Process {
                    id: thumbProc
                    command: []
                    stdout: StdioCollector {
                        onStreamFinished: { var p = this.text.trim(); if (p) item.thumbPath = "file://" + p }
                    }
                }
                function ensureThumb() {
                    if (thumbPath || !panel.ready || !near || !entry) return
                    thumbProc.command = ["bash", "-c",
                        "s=" + panel.shq(entry.filePath) + "; D=$HOME/.cache/quickshell-img-thumbs; mkdir -p \"$D\"; " +
                        "k=$(printf '%s' \"$s\" | md5sum | cut -d' ' -f1); m=$(stat -c %Y \"$s\" 2>/dev/null); o=\"$D/$k-$m.jpg\"; " +
                        "if command -v magick >/dev/null 2>&1; then [ -f \"$o\" ] || nice -n 10 magick \"$s\" -auto-orient -strip -thumbnail 480x270^ -quality 82 \"$o\" >/dev/null 2>&1; fi; " +
                        "[ -f \"$o\" ] && echo \"$o\" || echo \"$s\""]
                    thumbProc.running = false; thumbProc.running = true
                }
                onNearChanged: if (near) ensureThumb()
                Component.onCompleted: ensureThumb()
                Connections { target: panel; function onReadyChanged() { if (panel.ready) item.ensureThumb() } }

                width:  panel.stripWidthFor(Math.abs(relIdx))
                height: panel.focusedH
                y: 0
                x: stage.xForRel(relIdx)
                z: focused ? 100 : 50 - Math.abs(relIdx)
                visible: near
                opacity: near ? 1 : 0

                Behavior on x       { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                Behavior on width   { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                Behavior on opacity { NumberAnimation { duration: 200 } }

                // hairline frame; the photo is clipped to the rounded INNER shape
                // (ClippingRectangle = AA shader mask) so its corners round to match
                // the frame instead of poking out square. radius 5 = concentric (8 - 3px).
                Rectangle {
                    id: frame
                    anchors.fill: parent
                    radius: 8
                    color: panel.frameBg
                    border.width: 1
                    border.color: item.focused ? root.seal : root.sep
                    Behavior on border.color { ColorAnimation { duration: 180 } }

                    ClippingRectangle {
                        anchors.fill: parent
                        anchors.margins: 3
                        radius: 5
                        color: "transparent"

                        // image — clipped to the rounded shape above
                        Image {
                            anchors.fill: parent
                            // cached 480px thumb (theme + wallpaper); current-visibility
                            // bound so off-screen refs drop → bounded memory
                            source: (panel.ready && item.near && item.entry) ? item.thumbPath : ""
                            fillMode: Image.PreserveAspectCrop; asynchronous: true; cache: true; smooth: true
                            sourceSize.width:  panel.focusedW
                            sourceSize.height: panel.focusedH
                        }
                        // dim the unfocused strips (paper wash); the preview peek lighter
                        Rectangle {
                            anchors.fill: parent
                            color: root.paper
                            opacity: item.focused ? 0 : (Math.abs(item.relIdx) === 1 ? 0.28 : 0.5)
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                        }
                    }
                }

                // "current" marker — seal dot on the active theme/wallpaper
                Rectangle {
                    visible: item.entry && item.entry.current === true
                    width: 8; height: 8; radius: 4
                    x: 9; y: 9; z: 5
                    color: root.seal
                    border.color: Qt.rgba(0, 0, 0, 0.35); border.width: 1
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: item.focused ? panel.applySelected() : (panel.selFilt = index)
                }
            }
        }
    }

    // ── seal brush-stroke + label + hint (under the focused image, centred) ──
    Column {
        visible: panel.ready && panel.filtered.length > 0
        opacity: panel.reveal
        anchors.top: stage.bottom
        anchors.topMargin: 16
        anchors.horizontalCenter: stage.horizontalCenter
        spacing: 12

        // the single confident accent line — tapered like a brush stroke
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: panel.focusedW * 0.42
            height: 3; radius: 1.5
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0;  color: "transparent" }
                GradientStop { position: 0.5;  color: root.seal }
                GradientStop { position: 1.0;  color: "transparent" }
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: panel.focusedW + 120
            text: panel.currentLabel
            color: root.ink
            font.family: root.mono; font.pixelSize: 22; font.weight: Font.DemiBold
            horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
        }

        // palette swatch — the focused theme's vivid colours (lazy, theme mode)
        Row {
            visible: panel.isThemeMode && panel.selMeta && panel.selMeta.palette.length > 0
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 6
            Repeater {
                model: (panel.selMeta && panel.selMeta.palette.length > 0)
                       ? panel.selMeta.palette.split(",") : []
                delegate: Rectangle {
                    required property var modelData
                    width: 13; height: 13; radius: 6.5
                    color: modelData
                    border.color: Qt.rgba(1, 1, 1, 0.15); border.width: 1
                }
            }
        }

        // meta — current badge · author (click → open repo)
        Row {
            visible: (panel.sel && panel.sel.current)
                     || (panel.isThemeMode && panel.selMeta && panel.selMeta.author.length > 0)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 12
            Text {
                visible: panel.sel && panel.sel.current
                anchors.verticalCenter: parent.verticalCenter
                text: "● current"
                color: root.seal
                font.family: root.mono; font.pixelSize: 11
            }
            Text {
                visible: panel.isThemeMode && panel.selMeta && panel.selMeta.author.length > 0
                anchors.verticalCenter: parent.verticalCenter
                text: "by " + (panel.selMeta ? panel.selMeta.author : "") + "  ↗"
                color: authorMa.containsMouse ? root.seal : panel.uiDim
                font.family: root.mono; font.pixelSize: 11
                Behavior on color { ColorAnimation { duration: 120 } }
                MouseArea {
                    id: authorMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: panel.openRepo()
                }
            }
        }

        Text {
            visible: panel.filterText.length > 0
            anchors.horizontalCenter: parent.horizontalCenter
            text: panel.filterText
            color: root.seal; opacity: 0.95
            font.family: root.mono; font.pixelSize: 14
            horizontalAlignment: Text.AlignHCenter
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "← →  scroll navigate     Enter apply     Esc cancel     type to filter"
            color: panel.uiDim
            font.family: root.mono; font.pixelSize: 11
            horizontalAlignment: Text.AlignHCenter
        }
    }
}
