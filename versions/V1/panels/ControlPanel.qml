import QtQuick
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: ctrlPanel
    required property var root

    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "omarchy-control"
    // no mask → whole overlay is interactive (modal): click-outside + ESC work

    readonly property int barBottom: 35
    readonly property int gap: 8

    // power sub-menu starts CLOSED — no destructive tile is ever pre-shown
    property bool powerOpen: false
    property bool widgetsOpen: false

    property real reveal: root.controlVisible ? 1 : 0
    Behavior on reveal {
        NumberAnimation {
            duration: root.controlVisible ? 160 : 120
            easing.type: root.controlVisible ? Easing.OutCubic : Easing.InCubic
        }
    }
    visible: reveal > 0.001
    onRevealChanged: if (reveal < 0.01) { powerOpen = false; widgetsOpen = false }  // reset when closed
    WlrLayershell.keyboardFocus: root.controlVisible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    // ── reusable tile: neutral by default, highlights only on hover ──
    component Tile: Rectangle {
        property string label
        property color accent: root.seal
        property bool active: false
        signal activated()
        height: 25
        radius: 4
        opacity: enabled ? 1.0 : 0.4          // built-in `enabled` also blocks input
        color: (active || _ma.containsMouse) ? Qt.rgba(accent.r, accent.g, accent.b, 0.18)
                                             : Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.06)
        border.color: (active || _ma.containsMouse) ? accent : root.sep
        border.width: 1
        Behavior on color { ColorAnimation { duration: 120 } }
        Text {
            anchors.centerIn: parent
            text: parent.label
            color: (parent.active || _ma.containsMouse) ? parent.accent : root.ink
            font.family: root.mono; font.pixelSize: 11
        }
        MouseArea {
            id: _ma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: parent.activated()
        }
    }

    MouseArea { anchors.fill: parent; onClicked: root.controlVisible = false }

    Rectangle {
        id: card
        width: 240
        height: col.implicitHeight + 24
        radius: 6
        color: root.bg
        border.color: root.sep
        border.width: 1

        x: Math.round(Math.max(6, Math.min(root.launcherBarX - width / 2, parent.width - width - 6)))
        y: barBottom + gap
        opacity: ctrlPanel.reveal
        focus: root.controlVisible

        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) { root.controlVisible = false; event.accepted = true }
        }

        MouseArea { anchors.fill: parent; onClicked: {} }

        Column {
            id: col
            anchors.fill: parent
            anchors.margins: 12
            spacing: 8

            // ── header ──
            Item {
                width: parent.width
                height: 24
                Text {
                    anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                    text: "Control"
                    color: root.ink; font.family: root.mono; font.pixelSize: 13
                    font.letterSpacing: 2; font.weight: Font.Medium
                }
                Text {
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    text: "✕"; color: closeMa.containsMouse ? root.seal : root.sumi; font.pixelSize: 12
                    Behavior on color { ColorAnimation { duration: 120 } }
                    MouseArea { id: closeMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.controlVisible = false }
                }
            }

            Rectangle { width: parent.width; height: 1; color: root.sep }

            // ── ACTIONS ──
            Text {
                text: "ACTIONS"
                color: root.sumi; font.family: root.mono; font.pixelSize: 10; font.letterSpacing: 1
            }
            Tile {
                width: parent.width
                label: "Reload QS-Config"
                onActivated: { root.controlVisible = false; Quickshell.reload(false) }
            }

            // ── POWER (collapsed sub-menu; nothing destructive pre-shown) ──
            Tile {
                width: parent.width
                label: ctrlPanel.powerOpen ? "Power  ▾" : "Power  ▸"
                accent: root.seal
                onActivated: ctrlPanel.powerOpen = !ctrlPanel.powerOpen
            }
            Grid {
                width: parent.width
                columns: 2
                columnSpacing: 8
                rowSpacing: 8
                visible: ctrlPanel.powerOpen
                Tile {
                    width: (col.width - 8) / 2
                    label: "Lock"
                    onActivated: { root.controlVisible = false; Quickshell.execDetached(["hyprlock"]) }
                }
                Tile {
                    width: (col.width - 8) / 2
                    label: "Suspend"
                    onActivated: { root.controlVisible = false; Quickshell.execDetached(["systemctl", "suspend"]) }
                }
                Tile {
                    width: (col.width - 8) / 2
                    label: "Reboot"
                    accent: root.indigo
                    onActivated: { root.controlVisible = false; Quickshell.execDetached(["systemctl", "reboot"]) }
                }
                Tile {
                    width: (col.width - 8) / 2
                    label: "Shutdown"
                    accent: root.seal
                    onActivated: { root.controlVisible = false; Quickshell.execDetached(["systemctl", "poweroff"]) }
                }
            }

            Rectangle { width: parent.width; height: 1; color: root.sep }

            // ── BAR-COLOR: seal color source ──
            Text {
                text: "BAR-COLOR"
                color: root.sumi; font.family: root.mono; font.pixelSize: 10; font.letterSpacing: 1
            }
            Grid {
                width: parent.width; columns: 2; columnSpacing: 8
                Repeater {
                    model: [
                        { label: "Red",    accent: false },
                        { label: "Accent", accent: true  }
                    ]
                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool on:      root.useThemeAccent === modelData.accent
                        readonly property bool hovered: _cma.containsMouse
                        width: (col.width - 8) / 2; height: 25; radius: 4
                        color: on     ? Qt.rgba(root.seal.r, root.seal.g, root.seal.b, 0.18)
                             : hovered ? Qt.rgba(root.ink.r,  root.ink.g,  root.ink.b,  0.12)
                                       : Qt.rgba(root.ink.r,  root.ink.g,  root.ink.b,  0.06)
                        border.color: (on || hovered) ? root.seal : root.sep
                        border.width: 1
                        Behavior on color { ColorAnimation { duration: 120 } }
                        Text {
                            anchors.centerIn: parent
                            text: modelData.label
                            color: (parent.on || parent.hovered) ? root.seal : root.ink
                            font.family: root.mono; font.pixelSize: 11
                            font.weight: parent.on ? Font.Medium : Font.Normal
                        }
                        MouseArea {
                            id: _cma
                            anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.useThemeAccent = modelData.accent
                        }
                    }
                }
            }

            Rectangle { width: parent.width; height: 1; color: root.sep }

            // ── SPLITS (opens the fly-out sub-panel) ──
            Text {
                text: "SPLITS"
                color: root.sumi; font.family: root.mono; font.pixelSize: 10; font.letterSpacing: 1
            }
            Tile {
                width: parent.width
                label: root.splitsSubVisible ? "Splits  ◂" : "Splits  ▸"
                accent: root.seal
                onActivated: root.splitsSubVisible = !root.splitsSubVisible
            }

            Rectangle { width: parent.width; height: 1; color: root.sep }

            // ── WIDGETS (collapsed toggle group) ──
            Text {
                text: "WIDGETS"
                color: root.sumi; font.family: root.mono; font.pixelSize: 10; font.letterSpacing: 1
            }
            Tile {
                width: parent.width
                label: ctrlPanel.widgetsOpen ? "Widgets  ▾" : "Widgets  ▸"
                onActivated: ctrlPanel.widgetsOpen = !ctrlPanel.widgetsOpen
            }
            Grid {
                width: parent.width
                columns: 2
                columnSpacing: 8
                rowSpacing: 8
                visible: ctrlPanel.widgetsOpen

                Tile {
                    width: (col.width - 8) / 2
                    label: "Memory"
                    active: root.modMemory
                    onActivated: root.modMemory = !root.modMemory
                }
                Tile {
                    width: (col.width - 8) / 2
                    label: "Brightness"
                    visible: root.hasBacklight
                    active: root.modBrightness
                    onActivated: root.modBrightness = !root.modBrightness
                }
                Tile {
                    width: (col.width - 8) / 2
                    label: "Claude"
                    active: root.modClaude
                    onActivated: root.modClaude = !root.modClaude
                }
                Tile {
                    width: (col.width - 8) / 2
                    label: "Power Prof."
                    active: root.modPower
                    onActivated: root.modPower = !root.modPower
                }
                Tile {
                    width: (col.width - 8) / 2
                    label: "Bluetooth"
                    active: root.modBluetooth
                    onActivated: root.modBluetooth = !root.modBluetooth
                }
                Tile {
                    width: (col.width - 8) / 2
                    label: "Network"
                    active: root.modNetwork
                    enabled: root.networkMode !== "wifi"   // can't hide while on WiFi
                    onActivated: root.modNetwork = !root.modNetwork
                }
            }

            Rectangle { width: parent.width; height: 1; color: root.sep }

            // ── WORKSPACE display mode ──
            Text {
                text: "WORKSPACE"
                color: root.sumi; font.family: root.mono; font.pixelSize: 10; font.letterSpacing: 1
            }
            Row {
                id: wsRow
                width: parent.width
                spacing: 4
                readonly property var opts: [
                    { label: "Persist 10", mode: "10"     },
                    { label: "Persist 5",  mode: "5"      },
                    { label: "Active",     mode: "active" }
                ]
                Repeater {
                    model: wsRow.opts
                    delegate: Rectangle {
                        id: wsTile
                        required property var modelData
                        readonly property bool on:      root.workspaceMode === modelData.mode
                        readonly property bool hovered: wsMa.containsMouse
                        width: (wsRow.width - wsRow.spacing * (wsRow.opts.length - 1)) / wsRow.opts.length
                        height: 25; radius: 4
                        color: on ? Qt.rgba(root.seal.r, root.seal.g, root.seal.b, 0.18)
                                  : hovered ? Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.12)
                                            : Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.06)
                        border.color: (on || hovered) ? root.seal : root.sep
                        border.width: 1
                        Behavior on color { ColorAnimation { duration: 120 } }
                        Text {
                            anchors.centerIn: parent
                            text: wsTile.modelData.label
                            color: (wsTile.on || wsTile.hovered) ? root.seal : root.ink
                            font.family: root.mono; font.pixelSize: 10
                            font.weight: wsTile.on ? Font.Medium : Font.Normal
                        }
                        MouseArea {
                            id: wsMa
                            anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.workspaceMode = wsTile.modelData.mode
                        }
                    }
                }
            }

            Rectangle { width: parent.width; height: 1; color: root.sep }

            // ── PICKER style (theme/wallpaper/screenshot/video picker visual) ──
            Text {
                text: "PICKER-STIL"
                color: root.sumi; font.family: root.mono; font.pixelSize: 10; font.letterSpacing: 1
            }
            Row {
                id: pickerRow
                width: parent.width
                spacing: 4
                readonly property var opts: [
                    { label: "Tanzaku",     mode: "tanzaku"     },
                    { label: "Hearthstone", mode: "hearthstone" },
                    { label: "Carousel",    mode: "carousel"    }
                ]
                Repeater {
                    model: pickerRow.opts
                    delegate: Rectangle {
                        id: pickTile
                        required property var modelData
                        readonly property bool on:      root.pickerStyle === modelData.mode
                        readonly property bool hovered: pickMa.containsMouse
                        width: (pickerRow.width - pickerRow.spacing * (pickerRow.opts.length - 1)) / pickerRow.opts.length
                        height: 25; radius: 4
                        color: on ? Qt.rgba(root.seal.r, root.seal.g, root.seal.b, 0.18)
                                  : hovered ? Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.12)
                                            : Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.06)
                        border.color: (on || hovered) ? root.seal : root.sep
                        border.width: 1
                        Behavior on color { ColorAnimation { duration: 120 } }
                        Text {
                            anchors.centerIn: parent
                            text: pickTile.modelData.label
                            color: (pickTile.on || pickTile.hovered) ? root.seal : root.ink
                            font.family: root.mono; font.pixelSize: 10
                            font.weight: pickTile.on ? Font.Medium : Font.Normal
                        }
                        MouseArea {
                            id: pickMa
                            anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.pickerStyle = pickTile.modelData.mode
                        }
                    }
                }
            }

        }
    }

    // ── SPLITS sub-panel (fly-out right of the ControlPanel) ──
    Rectangle {
        id: splitCard
        visible: root.controlVisible && root.splitsSubVisible
        width: 180
        height: splitCol.implicitHeight + 24
        radius: 6
        color: root.bg
        border.color: root.sep
        border.width: 1
        // open to the right of the card, or to the left if there's no room
        x: (card.x + card.width + ctrlPanel.gap + width <= parent.width - 6)
           ? card.x + card.width + ctrlPanel.gap
           : card.x - ctrlPanel.gap - width
        y: card.y
        opacity: ctrlPanel.reveal

        MouseArea { anchors.fill: parent; onClicked: {} }

        Column {
            id: splitCol
            anchors.fill: parent
            anchors.margins: 12
            spacing: 8
            Text {
                text: "SPLITS"
                color: root.sumi; font.family: root.mono; font.pixelSize: 10; font.letterSpacing: 1
            }
            Tile { width: parent.width; label: "Split all";      accent: root.seal;   onActivated: { if (root.fnSplitAll) root.fnSplitAll() } }
            Tile { width: parent.width; label: "Merge all";                            onActivated: { if (root.fnMergeAll) root.fnMergeAll() } }
            Tile { width: parent.width; label: "Default layout"; accent: root.indigo; onActivated: { if (root.fnDefaultLayout) root.fnDefaultLayout() } }

            Rectangle { width: parent.width; height: 1; color: root.sep }
            Text {
                text: "GAP ANIM"
                color: root.sumi; font.family: root.mono; font.pixelSize: 10; font.letterSpacing: 1
            }
            Row {
                id: animRow
                width: parent.width
                spacing: 4
                readonly property var opts: [
                    { label: "Stream", mode: 1 },
                    { label: "Surge",  mode: 2 },
                    { label: "Bolt",   mode: 3, cycle: true }   // click cycles Bolt → Bolt 2 → off
                ]
                Repeater {
                    model: animRow.opts
                    delegate: Rectangle {
                        id: animTile
                        required property var modelData
                        readonly property bool on:      modelData.cycle ? (root.barAnim === 3 || root.barAnim === 4)
                                                                         : (root.barAnim === modelData.mode)
                        readonly property bool hovered: animMa.containsMouse
                        width: (animRow.width - animRow.spacing * (animRow.opts.length - 1)) / animRow.opts.length
                        height: 25; radius: 4
                        color: on ? Qt.rgba(root.seal.r, root.seal.g, root.seal.b, 0.18)
                                  : hovered ? Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.12)
                                            : Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.06)
                        border.color: (on || hovered) ? root.seal : root.sep
                        border.width: 1
                        Behavior on color { ColorAnimation { duration: 120 } }
                        Text {
                            anchors.centerIn: parent
                            text: !animTile.modelData.cycle ? animTile.modelData.label
                                  : root.barAnim === 4 ? "Bolt 2" : "Bolt"
                            color: (animTile.on || animTile.hovered) ? root.seal : root.ink
                            font.family: root.mono; font.pixelSize: 11
                            font.weight: animTile.on ? Font.Medium : Font.Normal
                        }
                        MouseArea {
                            id: animMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (animTile.modelData.cycle) {
                                    var n = root.barAnim                       // Bolt → Bolt 2 → off
                                    root.barAnim = (n === 3 ? 4 : (n === 4 ? 0 : 3))
                                } else {
                                    root.barAnim = (root.barAnim === animTile.modelData.mode ? 0 : animTile.modelData.mode)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
