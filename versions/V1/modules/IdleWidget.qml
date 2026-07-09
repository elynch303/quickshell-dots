import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: rootMod
    required property var root

    // "stay awake" mode active when hypridle is NOT running
    readonly property bool awake: root.hypridleAwake

    visible: awake
    implicitWidth: awake ? 20 : 0
    implicitHeight: 28


    readonly property string tooltipText: "Idle lock disabled"

    Text {
        anchors.centerIn: parent
        text: "\uDB86\uDED6"   // coffee (Nerd Font / JetBrainsMono)
        color: root.seal
        font.family: root.mono
        font.pixelSize: 13
    }

    Process {
        id: toggleProc
        command: ["bash", "-c", "omarchy-toggle-idle"]
        onExited: root.refreshStatusIndicators()
    }

    TooltipMixin { id: tip; root: rootMod.root; owner: rootMod; text: rootMod.tooltipText }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true; cursorShape: Qt.PointingHandCursor
        onEntered: tip.show()
        onExited:  { tip.hide() }
        onClicked: {
            tip.hide()
            toggleProc.running = false; toggleProc.running = true
        }
    }
}
