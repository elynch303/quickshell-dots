import QtQuick
import "../modules"
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// AI usage panel: shows BOTH Claude Code + OpenAI Codex usage and lets the user
// switch which tool's icon the bar pill displays (root.aiTool). Opened from the
// combined AI pill (ClaudeWidget). Reads the same caches the bar widget reads.
PanelWindow {
    id: aiPanel
    required property var root

    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "omarchy-ai-usage"

    readonly property int barBottom: 35
    readonly property int gap: 8

    // ── usage data: rendered from root.ai* — the single shared parse in Theme.qml
    //    that the bar pill uses too, so the two views can never drift apart. ──
    readonly property int    clPct5h:     root.aiClPct5h
    readonly property int    clPct7d:     root.aiClPct7d
    readonly property int    clReset5hTs: root.aiClReset5hTs
    readonly property string clTokens:    root.aiClTokens
    readonly property string clRate:      root.aiClRate
    readonly property bool   clFresh:     root.aiClFresh
    readonly property bool   clHas:       root.aiClHas

    readonly property int    cxPct5h:     root.aiCxPct5h
    readonly property int    cxPct7d:     root.aiCxPct7d
    readonly property int    cxReset5hTs: root.aiCxReset5hTs
    readonly property int    cxReset7dTs: root.aiCxReset7dTs
    readonly property string cxPlan:      root.aiCxPlan
    readonly property string cxTokens:    root.aiCxTokens
    readonly property string cxRate:      root.aiCxRate
    readonly property int    cxToday:     root.aiCxToday
    readonly property bool   cxFresh:     root.aiCxFresh
    readonly property bool   cxHas:       root.aiCxHas

    property real reveal: root.aiUsageVisible ? 1 : 0
    Behavior on reveal {
        NumberAnimation {
            duration: root.aiUsageVisible ? 160 : 120
            easing.type: root.aiUsageVisible ? Easing.OutCubic : Easing.InCubic
        }
    }
    visible: reveal > 0.001
    WlrLayershell.keyboardFocus: root.aiUsageVisible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    MouseArea {
        anchors.fill: parent
        onClicked: root.aiUsageVisible = false
    }

    // ── reusable label · bar · % row ──
    component UsageRow: Item {
        property string label: ""
        property int pct: 0
        property bool dim: false
        width: parent ? parent.width : 0
        height: 16
        Text {
            id: rowLbl
            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
            text: label; color: aiPanel.root.sumi
            font.family: aiPanel.root.mono; font.pixelSize: 11; font.letterSpacing: 1
        }
        Text {
            id: rowVal
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            text: pct + "%"
            color: dim ? aiPanel.root.sumi : aiPanel.root.seal
            font.family: aiPanel.root.mono; font.pixelSize: 11; font.weight: Font.Medium
        }
        Rectangle {
            anchors.left: rowLbl.right; anchors.leftMargin: 8
            anchors.right: rowVal.left; anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            height: 8; radius: 4
            color: Qt.rgba(aiPanel.root.seal.r, aiPanel.root.seal.g, aiPanel.root.seal.b, 0.15)
            Rectangle {
                width: parent.width * Math.min(100, parent ? pct : 0) / 100
                height: parent.height; radius: 4
                color: pct >= 90 ? aiPanel.root.sealRaw : aiPanel.root.seal
                Behavior on width { NumberAnimation { duration: 300 } }
            }
        }
    }

    // ── reusable key/value detail row ──
    component DetailRow: Row {
        property string k: ""
        property string v: ""
        width: parent ? parent.width : 0
        Text {
            text: k; color: aiPanel.root.sumi
            font.family: aiPanel.root.mono; font.pixelSize: 11
            width: parent.width * 0.45
        }
        Text {
            text: v; color: aiPanel.root.ink
            font.family: aiPanel.root.mono; font.pixelSize: 11
            width: parent.width * 0.55; horizontalAlignment: Text.AlignRight
        }
    }

    Rectangle {
        id: card
        width: 320
        height: col.implicitHeight + 24
        radius: reveal > 0.001 ? root.pillRadius : 0
        color: root.bg
        border.color: root.pillBorder
        border.width: root.pillBorderW
        PillShadow { theme: root }

        x: Math.round(Math.max(6, Math.min(root.aiBarX - width / 2, parent.width - width - 6)))
        y: root.barPosition === "bottom" ? (parent.height - barBottom - gap - height) : (barBottom + gap)
        opacity: aiPanel.reveal
        focus: root.aiUsageVisible

        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
                root.aiUsageVisible = false;
                event.accepted = true;
            }
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
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "AI USAGE"
                    color: root.ink
                    font.family: root.mono
                    font.pixelSize: 13
                    font.letterSpacing: 2
                    font.weight: Font.Medium
                }
                Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "✕"
                    color: closeMa.containsMouse ? root.seal : root.sumi
                    font.pixelSize: 12
                    Behavior on color { ColorAnimation { duration: 120 } }
                    MouseArea {
                        id: closeMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.aiUsageVisible = false
                    }
                }
            }

            // ── segmented switch: which tool the bar shows ──
            Row {
                width: parent.width
                height: 28
                spacing: 6
                Repeater {
                    model: [ { id: "claude", label: "Claude" }, { id: "codex", label: "Codex" } ]
                    Rectangle {
                        required property var modelData
                        width: (parent.width - 6) / 2
                        height: 28; radius: root.tileRadius
                        readonly property bool active: root.aiTool === modelData.id
                        color: active ? root.seal
                              : segMa.containsMouse ? Qt.rgba(root.seal.r, root.seal.g, root.seal.b, 0.18)
                              : Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.08)
                        Behavior on color { ColorAnimation { duration: 120 } }
                        Text {
                            anchors.centerIn: parent
                            text: modelData.label
                            color: parent.active ? root.paper : root.ink
                            font.family: root.mono; font.pixelSize: 11
                            font.weight: parent.active ? Font.Medium : Font.Normal
                        }
                        MouseArea {
                            id: segMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.aiTool = parent.modelData.id
                        }
                    }
                }
            }

            Rectangle { width: parent.width; height: 1; color: root.sep }

            // ── Claude Code ──
            Item {
                width: parent.width; height: 16
                Text {
                    anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                    text: "Claude Code"; color: root.ink
                    font.family: root.mono; font.pixelSize: 12; font.weight: Font.Medium
                }
                Text {
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    text: aiPanel.clFresh ? "live" : "stale"
                    color: aiPanel.clFresh ? root.sumi : root.sealRaw
                    font.family: root.mono; font.pixelSize: 10
                }
            }
            Text {
                visible: !aiPanel.clHas
                width: parent.width
                text: "no data — run claude"
                color: root.sumi; font.family: root.mono; font.pixelSize: 11
            }
            UsageRow { visible: aiPanel.clHas; label: "5h"; pct: aiPanel.clPct5h; dim: !aiPanel.clFresh }
            UsageRow { visible: aiPanel.clHas; label: "7d"; pct: aiPanel.clPct7d; dim: !aiPanel.clFresh }
            DetailRow { visible: aiPanel.clHas; k: "Resets in"; v: root.aiFmtReset(aiPanel.clReset5hTs) || "—" }
            DetailRow { visible: aiPanel.clHas && aiPanel.clTokens !== ""; k: "Tokens"; v: aiPanel.clTokens }
            DetailRow { visible: aiPanel.clHas && aiPanel.clRate !== "";   k: "Rate"; v: aiPanel.clRate }

            Rectangle { width: parent.width; height: 1; color: root.sep }

            // ── OpenAI Codex ──
            Item {
                width: parent.width; height: 16
                Text {
                    anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                    text: "OpenAI Codex" + (aiPanel.cxPlan ? "  · " + aiPanel.cxPlan : "")
                    color: root.ink
                    font.family: root.mono; font.pixelSize: 12; font.weight: Font.Medium
                }
                Text {
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    text: aiPanel.cxFresh ? "live" : "stale"
                    color: aiPanel.cxFresh ? root.sumi : root.sealRaw
                    font.family: root.mono; font.pixelSize: 10
                }
            }
            Text {
                visible: !aiPanel.cxHas
                width: parent.width
                text: "no data — run codex"
                color: root.sumi; font.family: root.mono; font.pixelSize: 11
            }
            UsageRow { visible: aiPanel.cxHas; label: "5h"; pct: aiPanel.cxPct5h; dim: !aiPanel.cxFresh }
            UsageRow { visible: aiPanel.cxHas; label: "7d"; pct: aiPanel.cxPct7d; dim: !aiPanel.cxFresh }
            DetailRow { visible: aiPanel.cxHas; k: "5h resets in"; v: root.aiFmtReset(aiPanel.cxReset5hTs) || "—" }
            DetailRow { visible: aiPanel.cxHas; k: "7d resets in"; v: root.aiFmtReset(aiPanel.cxReset7dTs) || "—" }
            DetailRow { visible: aiPanel.cxHas && aiPanel.cxTokens !== ""; k: "Tokens"; v: aiPanel.cxTokens }
            DetailRow { visible: aiPanel.cxHas && aiPanel.cxRate !== "";   k: "Rate"; v: aiPanel.cxRate }
            DetailRow { visible: aiPanel.cxHas && aiPanel.cxToday > 0; k: "Today"; v: (aiPanel.cxToday / 1e6).toFixed(2) + "M tok" }
        }
    }

    // Usage data + polling live in Theme.qml (shared with the bar pill); this panel
    // only renders from root.ai* and bumps the refresh cadence via root.aiUsageVisible.
}
