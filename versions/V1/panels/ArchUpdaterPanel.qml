import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

PanelWindow {
    id: archPanel
    required property var root

    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "omarchy-arch-updater"

    readonly property int barBottom: 35
    readonly property int gap: 8

    Process {
        id: panelUpdateRunner
        // No default command — it is built (gated, with --ignore) on click only,
        // so an accidental start can never run an ungated -Syu.
        command: []
    }

    property real reveal: root.archVisible ? 1 : 0
    Behavior on reveal {
        NumberAnimation {
            duration: root.archVisible ? 160 : 120
            easing.type: root.archVisible ? Easing.OutCubic : Easing.InCubic
        }
    }
    visible: reveal > 0.001
    WlrLayershell.keyboardFocus: root.archVisible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    MouseArea {
        anchors.fill: parent
        onClicked: root.archVisible = false
    }

    // A degraded verdict can be a transient (blacklist file mid-update at scan
    // time) — retry once each time the panel opens instead of letting it stick
    // until the next refresh.
    Connections {
        target: root
        function onArchVisibleChanged() {
            if (root.archVisible && root.archGateDegraded) root.archGateRescan()
        }
    }

    // pkg -> gate verdict, rebuilt once per gate run (avoids O(n²) per-row scans)
    readonly property var gateMap: {
        var m = ({})
        var r = root.archGateResults || []
        for (var i = 0; i < r.length; i++) m[r[i].pkg] = r[i]
        return m
    }

    Rectangle {
        id: card
        width: 520
        height: Math.min(col.implicitHeight + 24, 460)
        radius: 6
        color: root.bg
        border.color: root.sep
        border.width: 1

        x: Math.round(Math.max(6, Math.min(root.archBarX - width / 2, parent.width - width - 6)))
        y: barBottom + gap
        opacity: archPanel.reveal
        focus: root.archVisible

        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
                root.archVisible = false;
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
                    text: "Updates"
                    color: root.ink
                    font.family: root.mono
                    font.pixelSize: 13
                    font.letterSpacing: 2
                    font.weight: Font.Medium
                }
                Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "\u2715"
                    color: closeMa.containsMouse ? root.seal : root.sumi
                    font.pixelSize: 12
                    Behavior on color { ColorAnimation { duration: 120 } }
                    MouseArea {
                        id: closeMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.archVisible = false
                    }
                }
            }

            Rectangle { width: parent.width; height: 1; color: root.sep }

            // ── security-gate status ──
            Row {
                width: parent.width
                spacing: 12
                visible: root.archUpdates.length > 0
                Text {
                    text: "✓ " + root.archGateOk + " OK"
                    color: root.green
                    font.family: root.mono; font.pixelSize: 10; font.letterSpacing: 1
                }
                Text {
                    visible: root.archGateWarn > 0
                    text: "⚠ " + root.archGateWarn + " review"
                    color: root.inkDeep
                    font.family: root.mono; font.pixelSize: 10; font.letterSpacing: 1
                }
                Text {
                    visible: root.archGateFail > 0
                    text: "✗ " + root.archGateFail + " blocked"
                    color: root.seal
                    font.family: root.mono; font.pixelSize: 10; font.letterSpacing: 1
                }
                Item { width: 1; height: 1 }
                Text {
                    visible: root.archGateDegraded
                    text: "⚠ protection limited"
                    color: root.seal
                    font.family: root.mono; font.pixelSize: 10; font.letterSpacing: 1
                }
                Text {
                    visible: root.archGateListDate !== "" && root.archGateBlacklist > 0
                    text: "list " + root.archGateListDate
                    color: root.sumi
                    font.family: root.mono; font.pixelSize: 10; font.letterSpacing: 1
                }
            }

            // ── escalation: a FAIL means the INSTALLED copy is on the list, i.e.
            // possibly already compromised — --ignore only freezes that version ──
            Text {
                visible: root.archGateFail > 0
                width: parent.width
                text: "⚠ installed copy may be compromised — run the infection checker"
                color: root.seal
                font.family: root.mono; font.pixelSize: 10
                wrapMode: Text.WordWrap
            }

            // ── column headers ──
            Row {
                width: parent.width
                spacing: 4
                Text {
                    width: parent.width * 0.4
                    text: "Package"
                    color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.6)
                    font.family: root.mono; font.pixelSize: 10; font.letterSpacing: 1
                }
                Text {
                    width: parent.width * 0.3
                    text: "Installed"
                    color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.6)
                    font.family: root.mono; font.pixelSize: 10; font.letterSpacing: 1
                }
                Text {
                    width: parent.width * 0.3
                    text: "Available"
                    color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.6)
                    font.family: root.mono; font.pixelSize: 10; font.letterSpacing: 1
                }
            }

            // ── update list ──
            Flickable {
                width: parent.width
                height: Math.min(updatesCol.implicitHeight, 280)
                contentHeight: updatesCol.implicitHeight
                clip: true
                interactive: updatesCol.implicitHeight > 280

                Column {
                    id: updatesCol
                    width: parent.width
                    spacing: 2

                    Repeater {
                        model: root.archUpdates

                        delegate: Item {
                            required property var modelData
                            required property int index

                            readonly property color srcColor: {
                                if (modelData.source === "system") return root.seal;
                                if (modelData.source === "aur") return root.indigo;
                                return root.sumi;
                            }

                            readonly property var gv: archPanel.gateMap[modelData.name]
                            readonly property bool vBlocked: gv !== undefined && gv.verdict === "FAIL"
                            readonly property bool vReview:  gv !== undefined && gv.verdict === "WARN"
                            readonly property bool vOk:      gv !== undefined && gv.verdict === "OK"
                            readonly property string vReason: (gv !== undefined && gv.reason) ? gv.reason : ""
                            readonly property bool showReason: vReason !== "" && (vBlocked || vReview)

                            width: parent.width
                            height: showReason ? 34 : 22
                            opacity: vBlocked ? 0.55 : 1.0

                            Row {
                                id: rowTop
                                width: parent.width
                                height: 22
                                spacing: 4
                                Text {
                                    width: 14
                                    // neutral · until the gate has actually vouched —
                                    // unknown/scanning must NOT look like a green pass
                                    text: vBlocked ? "✗" : vReview ? "⚠" : vOk ? "✓" : "·"
                                    color: vBlocked ? root.seal : vReview ? root.inkDeep : vOk ? root.green : root.sumi
                                    font.family: root.mono; font.pixelSize: 11
                                    horizontalAlignment: Text.AlignHCenter
                                }
                                Text {
                                    width: parent.width * 0.4 - 18
                                    text: modelData.name
                                    color: vBlocked ? root.seal : srcColor
                                    font.family: root.mono; font.pixelSize: 11
                                    elide: Text.ElideRight
                                }
                                Text {
                                    width: parent.width * 0.3
                                    text: modelData.oldVer
                                    color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.7)
                                    font.family: root.mono; font.pixelSize: 11
                                    elide: Text.ElideRight
                                }
                                Text {
                                    width: parent.width * 0.3
                                    text: modelData.newVer
                                    color: srcColor
                                    font.family: root.mono; font.pixelSize: 11
                                    font.weight: Font.Medium
                                    elide: Text.ElideRight
                                }
                            }

                            Text {
                                visible: showReason
                                anchors.top: rowTop.bottom
                                x: 18
                                width: parent.width - 18
                                text: vReason
                                color: vBlocked ? root.seal : root.sumi
                                font.family: root.mono; font.pixelSize: 9
                                elide: Text.ElideRight
                            }

                            Rectangle {
                                anchors.bottom: parent.bottom
                                width: parent.width; height: 1
                                color: root.sep
                                visible: index < root.archUpdates.length - 1
                            }
                        }
                    }

                    Text {
                        width: parent.width
                        visible: root.archUpdates.length === 0
                        text: "No updates available"
                        color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.5)
                        font.family: root.mono; font.pixelSize: 11
                        horizontalAlignment: Text.AlignHCenter
                        topPadding: 20
                    }
                }
            }

            Rectangle { width: parent.width; height: 1; color: root.sep }

            // ── buttons ──
            Row {
                width: parent.width
                spacing: 8

                Rectangle {
                    width: (parent.width - 8) / 2
                    height: 28; radius: 4
                    color: refreshMa.containsMouse ? Qt.rgba(root.seal.r, root.seal.g, root.seal.b, 0.18) : root.sep
                    border.color: refreshMa.containsMouse ? root.seal : "transparent"
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Text {
                        anchors.centerIn: parent
                        text: "Refresh"
                        color: refreshMa.containsMouse ? root.seal : root.ink
                        font.family: root.mono; font.pixelSize: 11
                    }
                    MouseArea {
                        id: refreshMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.archRefreshTick++;
                        }
                    }
                }

                Rectangle {
                    width: (parent.width - 8) / 2
                    height: 28; radius: 4
                    color: updateMa.containsMouse ? Qt.lighter(root.seal, 1.15) : root.seal
                    border.color: "transparent"
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Text {
                        anchors.centerIn: parent
                        text: root.archGateFail > 0
                            ? "Update (" + root.archGateFail + " ignored)"
                            : "Update"
                        color: root.paper
                        font.family: root.mono; font.pixelSize: 11
                    }
                    MouseArea {
                        id: updateMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            // Block FAIL packages by --ignore — keeps the upgrade
                            // whole (no partial-upgrade risk), unlike a name allowlist.
                            var ignore = [];
                            var r = root.archGateResults || [];
                            for (var i = 0; i < r.length; i++) {
                                if (r[i].verdict === "FAIL" && /^[a-zA-Z0-9@._+-]+$/.test(r[i].pkg))
                                    ignore.push(r[i].pkg);
                            }
                            var ign = ignore.length ? " --ignore " + ignore.join(",") : "";
                            var prompt = root.archGateDegraded
                                ? "protection limited — blacklist unavailable. Continue?"
                                : "Update packages?";
                            panelUpdateRunner.command = ["bash", "-c",
                                "omarchy-launch-floating-terminal-with-presentation 'gum confirm \"" + prompt + "\" && { AUR=$(command -v paru || command -v yay); $AUR -Syu" + ign + "; }'"];
                            root.archVisible = false;
                            panelUpdateRunner.running = false;
                            panelUpdateRunner.running = true;
                        }
                    }
                }
            }
        }
    }
}
