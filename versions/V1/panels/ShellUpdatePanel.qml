import QtQuick
import "../modules"
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Confirmation panel for the shell-update badge. Mirrors ArchUpdaterPanel.
// Lists the incoming commits and runs the apply script on confirm. The apply
// script restarts the bar, so it is launched DETACHED (setsid) — see
// ~/.config/quickshell/bin/qs-shell-apply-update.sh.
PanelWindow {
    id: panel
    required property var root

    screen: root.activePopupScreen

    readonly property string applyScript: Quickshell.env("HOME") + "/.config/quickshell/bin/qs-shell-apply-update.sh"

    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-shell-updater"

    readonly property int barBottom: 35
    readonly property int gap: 8

    Process {
        id: applyRunner
        // setsid detaches the apply from this (soon-to-be-killed) bar process.
        // argv form (no `bash -c` string) — nothing interpolated into a shell.
        command: ["setsid", "-f", "bash", panel.applyScript]
    }

    property real reveal: root.shellUpdateVisible ? 1 : 0
    Behavior on reveal {
        NumberAnimation {
            duration: root.shellUpdateVisible ? 160 : 120
            easing.type: root.shellUpdateVisible ? Easing.OutCubic : Easing.InCubic
        }
    }
    visible: reveal > 0.001
    WlrLayershell.keyboardFocus: root.shellUpdateVisible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    MouseArea {
        anchors.fill: parent
        onClicked: root.shellUpdateVisible = false
    }

    Rectangle {
        id: card
        width: 480
        height: Math.min(col.implicitHeight + 24, 420)
        radius: reveal > 0.001 ? root.pillRadius : 0
        color: root.bg
        border.color: root.pillBorder
        border.width: root.pillBorderW
        PillShadow { theme: root }

        x: Math.round(Math.max(6, Math.min(root.shellUpdateBarX - width / 2, parent.width - width - 6)))
        y: root.barPosition === "bottom" ? (parent.height - barBottom - gap - height) : (barBottom + gap)
        opacity: panel.reveal
        focus: root.shellUpdateVisible

        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
                root.shellUpdateVisible = false;
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
                UiText {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Shell update"
                    color: root.ink
                    font.family: root.mono
                    font.pixelSize: 13
                    font.letterSpacing: 2
                    font.weight: Font.Medium
                }
                UiText {
                    anchors.right: closeBtn.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.shellUpdateBehind + (root.shellUpdateBehind === 1 ? " commit" : " commits")
                          + (root.shellUpdateVersion ? " · " + root.shellUpdateVersion : "")
                    color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.55)
                    font.family: root.mono
                    font.pixelSize: 10
                    font.letterSpacing: 1
                }
                UiText {
                    id: closeBtn
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
                        onClicked: root.shellUpdateVisible = false
                    }
                }
            }

            Rectangle { width: parent.width; height: 1; color: root.sep }

            // ── commit list ──
            Flickable {
                width: parent.width
                height: Math.min(commitsCol.implicitHeight, 260)
                contentHeight: commitsCol.implicitHeight
                clip: true
                interactive: commitsCol.implicitHeight > 260

                Column {
                    id: commitsCol
                    width: parent.width
                    spacing: 4

                    Repeater {
                        model: root.shellUpdateSummary

                        delegate: Row {
                            required property var modelData
                            width: commitsCol.width
                            spacing: 6
                            UiText {
                                text: "•"
                                color: root.seal
                                font.family: root.mono; font.pixelSize: 11
                            }
                            UiText {
                                width: commitsCol.width - 14
                                text: modelData
                                color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.85)
                                font.family: root.mono; font.pixelSize: 11
                                wrapMode: Text.Wrap
                            }
                        }
                    }

                    UiText {
                        width: parent.width
                        visible: root.shellUpdateSummary.length === 0
                        text: "No changelog available"
                        color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.5)
                        font.family: root.mono; font.pixelSize: 11
                        horizontalAlignment: Text.AlignHCenter
                        topPadding: 12
                    }
                }
            }

            // ── note: settings are safe ──
            UiText {
                width: parent.width
                text: "Your layout & settings (slot order, splits) are kept."
                color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.45)
                font.family: root.mono; font.pixelSize: 9; font.letterSpacing: 0.5
                wrapMode: Text.Wrap
            }

            Rectangle { width: parent.width; height: 1; color: root.sep }

            // ── buttons ──
            Row {
                width: parent.width
                spacing: 8

                Rectangle {
                    width: root.evenW((parent.width - 8) / 2)
                    height: 28; radius: root.tileRadius
                    color: laterMa.containsMouse ? root.fillHover : root.fillIdle
                    border.color: laterMa.containsMouse ? root.seal : root.sep
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: 120 } }
                    UiText {
                        anchors.centerIn: parent
                        text: "Later"
                        color: laterMa.containsMouse ? root.seal : root.ink
                        font.family: root.mono; font.pixelSize: 11
                    }
                    MouseArea {
                        id: laterMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.shellUpdateVisible = false
                    }
                }

                Rectangle {
                    width: root.evenW((parent.width - 8) / 2)
                    height: 28; radius: root.tileRadius
                    color: updateMa.containsMouse ? root.fillPrimaryHover : root.seal
                    border.color: "transparent"
                    Behavior on color { ColorAnimation { duration: 120 } }
                    UiText {
                        anchors.centerIn: parent
                        text: "Update & restart"
                        color: root.paper
                        font.family: root.mono; font.pixelSize: 11
                    }
                    MouseArea {
                        id: updateMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.shellUpdateVisible = false;
                            applyRunner.running = false;
                            applyRunner.running = true;
                        }
                    }
                }
            }
        }
    }
}
