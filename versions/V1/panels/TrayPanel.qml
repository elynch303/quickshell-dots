import Quickshell
import "../modules"
import Quickshell.Services.SystemTray
import Quickshell.Wayland
import QtQuick

PanelWindow {
    id: trayPanel
    required property var root

    screen: root.activePopupScreen

    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "omarchy-tray"
    // no mask → whole overlay is interactive (modal): click-outside + ESC work

    readonly property int barBottom: 35
    readonly property int gap: 8
    readonly property int popupW: 56

    visible: root.trayVisible
    WlrLayershell.keyboardFocus: root.trayVisible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    // auto-close when there are no hidden (unpinned) items left to show
    readonly property int hiddenCount: {
        var n = 0, vals = SystemTray.items.values
        for (var i = 0; i < vals.length; i++)
            if (root.trayPinned.indexOf(vals[i].id) < 0) n++
        return n
    }
    onHiddenCountChanged: if (root.trayVisible && hiddenCount === 0) root.trayVisible = false

    // click-outside-to-close: full-overlay dismiss area behind the card
    MouseArea { anchors.fill: parent; onClicked: root.trayVisible = false }

    Rectangle {
        id: card
        width: popupW
        height: col.implicitHeight + 24
        radius: root.trayVisible ? root.pillRadius : 0
        color: root.bg
        border.color: root.pillBorder
        border.width: root.pillBorderW
        PillShadow { theme: root }

        x: Math.round(Math.max(6, Math.min(root.trayBarX, parent.width - width - 6)))
        y: root.barPosition === "bottom" ? (parent.height - barBottom - gap - height) : (barBottom + gap)
        focus: root.trayVisible

        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
                root.trayVisible = false
                event.accepted = true
            }
        }

        MouseArea { anchors.fill: parent; onClicked: {} }

        Column {
            id: col
            anchors.fill: parent
            anchors.margins: 12
            spacing: 4

            Item {
                width: parent.width
                implicitHeight: 18
                height: 18
                anchors.horizontalCenter: parent.horizontalCenter
                UiText {
                    anchors.centerIn: parent
                    text: "✕"
                    color: closeMa.containsMouse ? root.seal : root.sumi
                    font.pixelSize: 12
                    Behavior on color { ColorAnimation { duration: 120 } }
                }
                MouseArea {
                    id: closeMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.trayVisible = false
                }
            }

            Rectangle { width: parent.width; height: 1; color: root.sep }

            Repeater {
                model: SystemTray.items

                delegate: Item {
                    required property SystemTrayItem modelData
                    required property int index

                    width: parent.width
                    height: 28
                    visible: root.trayPinned.indexOf(modelData.id) < 0

                    Rectangle {
                        anchors.fill: parent
                        radius: root.tileRadius
                        color: ma.containsMouse ? root.fillActive : "transparent"
                        border.color: ma.containsMouse ? root.seal : "transparent"
                        border.width: ma.containsMouse ? 1 : 0
                        Behavior on color { ColorAnimation { duration: 120 } }
                    }

                    Row {
                        anchors.centerIn: parent

                        Image {
                            source: modelData.icon
                            sourceSize.width: 16
                            sourceSize.height: 16
                            width: 16
                            height: 16
                            fillMode: Image.PreserveAspectFit
                            smooth: true
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    MouseArea {
                        id: ma
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: (e) => {
                            if (e.button === Qt.LeftButton) {
                                modelData.activate()
                            } else if (e.button === Qt.RightButton) {
                                root.trayToggleHide(modelData)
                            } else if (e.button === Qt.MiddleButton) {
                                if (modelData.hasMenu) {
                                    var gp = ma.mapToItem(null, 0, 0)
                                    root.openTrayMenu(modelData.menu, gp.x - 98)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
