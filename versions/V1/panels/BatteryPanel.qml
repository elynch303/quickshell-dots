import QtQuick
import "../modules"
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.UPower

PanelWindow {
    id: batPanel
    required property var root

    screen: root.activePopupScreen

    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "omarchy-battery"

    readonly property int barBottom: 35
    readonly property int gap: 8

    property int    percent: 0
    property string status:  "Unknown"
    property string capacity: ""
    property string sizeText: ""        // total energy capacity in Wh (from sysfs)
    property int    cycles:   0          // charge cycles (from sysfs)
    readonly property bool charging: status === "Charging"

    // live time estimates from UPower (seconds); 0 when unknown / not applicable
    readonly property var  dev:         UPower.displayDevice
    readonly property real timeToEmpty: dev ? dev.timeToEmpty : 0
    readonly property real timeToFull:  dev ? dev.timeToFull  : 0
    readonly property real changeRate:  dev ? Math.abs(dev.changeRate) : 0   // live W (charge/discharge)
    readonly property string timeLabel: charging ? "Time to full" : "Time left"
    readonly property string timeText:  charging ? fmtDuration(timeToFull) : fmtDuration(timeToEmpty)
    function fmtDuration(s) {
        if (!s || s <= 0) return ""
        var h = Math.floor(s / 3600)
        var m = Math.floor((s % 3600) / 60)
        return h > 0 ? (h + "h " + m + "m") : (m + "m")
    }

    property real reveal: root.batteryVisible ? 1 : 0
    Behavior on reveal {
        NumberAnimation {
            duration: root.batteryVisible ? 160 : 120
            easing.type: root.batteryVisible ? Easing.OutCubic : Easing.InCubic
        }
    }
    visible: reveal > 0.001
    WlrLayershell.keyboardFocus: root.batteryVisible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    MouseArea { anchors.fill: parent; onClicked: root.batteryVisible = false }

    Rectangle {
        id: card
        width: 300
        height: col.implicitHeight + 24
        radius: reveal > 0.001 ? root.pillRadius : 0
        color: root.bg
        border.color: root.pillBorder
        border.width: root.pillBorderW
        PillShadow { theme: root }

        x: Math.round(Math.max(6, Math.min(root.batteryBarX - width / 2, parent.width - width - 6)))
        y: root.barPosition === "bottom" ? (parent.height - barBottom - gap - height) : (barBottom + gap)
        opacity: batPanel.reveal
        focus: root.batteryVisible

        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) { root.batteryVisible = false; event.accepted = true }
        }

        MouseArea { anchors.fill: parent; onClicked: {} }

        Column {
            id: col
            anchors.fill: parent
            anchors.margins: 12
            spacing: 8

            Item {
                width: parent.width
                height: 24
                UiText {
                    anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                    text: "Battery"
                    color: root.ink; font.family: root.mono; font.pixelSize: 13
                    font.letterSpacing: 2; font.weight: Font.Medium
                }
                UiText {
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    text: "✕"; color: closeMa.containsMouse ? root.seal : root.sumi; font.pixelSize: 12
                    Behavior on color { ColorAnimation { duration: 120 } }
                    MouseArea { id: closeMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.batteryVisible = false }
                }
            }

            Rectangle { width: parent.width; height: 1; color: root.sep }

            Item {
                width: parent.width
                height: 30
                UiText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                    text: batPanel.percent + "%"
                    color: batPanel.charging ? root.indigo : root.seal
                    font.family: root.mono; font.pixelSize: 11; font.weight: Font.Medium
                }
                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width; height: 8; radius: 4
                    color: root.fillActive
                    Rectangle {
                        width: parent.width * batPanel.percent / 100
                        height: parent.height; radius: 4
                        color: batPanel.charging ? root.indigo : root.seal
                        Behavior on width { NumberAnimation { duration: 300 } }
                    }
                }
            }

            Column {
                width: parent.width
                spacing: 4
                Row {
                    width: parent.width
                    UiText { text: "Status"; color: root.sumiHi; font.family: root.mono; font.pixelSize: 11; width: parent.width * 0.4 }
                    UiText {
                        text: batPanel.status
                        color: batPanel.charging ? root.indigo : root.ink
                        font.family: root.mono; font.pixelSize: 11
                    }
                }
                Row {
                    width: parent.width
                    visible: batPanel.timeText !== ""
                    UiText { text: batPanel.timeLabel; color: root.sumiHi; font.family: root.mono; font.pixelSize: 11; width: parent.width * 0.4 }
                    UiText { text: batPanel.timeText; color: root.ink; font.family: root.mono; font.pixelSize: 11 }
                }
                Row {
                    width: parent.width
                    visible: batPanel.capacity !== ""
                    UiText { text: "Health"; color: root.sumiHi; font.family: root.mono; font.pixelSize: 11; width: parent.width * 0.4 }
                    UiText { text: batPanel.capacity; color: root.ink; font.family: root.mono; font.pixelSize: 11 }
                }
                Row {
                    width: parent.width
                    visible: batPanel.changeRate > 0.05
                    UiText { text: "Power draw"; color: root.sumiHi; font.family: root.mono; font.pixelSize: 11; width: parent.width * 0.4 }
                    UiText { text: batPanel.changeRate.toFixed(1) + " W"; color: root.ink; font.family: root.mono; font.pixelSize: 11 }
                }
                Row {
                    width: parent.width
                    visible: batPanel.sizeText !== ""
                    UiText { text: "Battery size"; color: root.sumiHi; font.family: root.mono; font.pixelSize: 11; width: parent.width * 0.4 }
                    UiText { text: batPanel.sizeText; color: root.ink; font.family: root.mono; font.pixelSize: 11 }
                }
                Row {
                    width: parent.width
                    visible: batPanel.cycles > 0
                    UiText { text: "Charge cycles"; color: root.sumiHi; font.family: root.mono; font.pixelSize: 11; width: parent.width * 0.4 }
                    UiText { text: String(batPanel.cycles); color: root.ink; font.family: root.mono; font.pixelSize: 11 }
                }
            }

            Rectangle { width: parent.width; height: 1; color: root.sep }

            Rectangle {
                width: parent.width
                height: 28; radius: root.tileRadius
                color: btopMa.containsMouse ? root.fillPrimaryHover : root.seal
                Behavior on color { ColorAnimation { duration: 120 } }
                UiText { anchors.centerIn: parent; text: "Open btop"; color: root.paper; font.family: root.mono; font.pixelSize: 11 }
                MouseArea {
                    id: btopMa
                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: { root.batteryVisible = false; btopRunner.running = false; btopRunner.running = true }
                }
            }
        }
    }

    Process {
        id: batData
        command: ["bash", "-c",
            "BAT=$(ls /sys/class/power_supply/ 2>/dev/null | grep -m1 '^BAT'); [ -z \"$BAT\" ] && exit; " +
            "CAP=$(cat /sys/class/power_supply/$BAT/capacity 2>/dev/null || echo 0); " +
            "STA=$(cat /sys/class/power_supply/$BAT/status 2>/dev/null || echo Unknown); " +
            "FULL=$(cat /sys/class/power_supply/$BAT/charge_full 2>/dev/null || cat /sys/class/power_supply/$BAT/energy_full 2>/dev/null || echo 0); " +
            "DESIGN=$(cat /sys/class/power_supply/$BAT/charge_full_design 2>/dev/null || cat /sys/class/power_supply/$BAT/energy_full_design 2>/dev/null || echo 0); " +
            "HEALTH=$(awk -v f=\"$FULL\" -v d=\"$DESIGN\" 'BEGIN{ if(d>0){ h=f*100/d; if(h>100) h=100; printf \"%d%%\", h } else print \"\" }'); " +
            "CYC=$(cat /sys/class/power_supply/$BAT/cycle_count 2>/dev/null || echo 0); " +
            "EFD=$(cat /sys/class/power_supply/$BAT/energy_full_design 2>/dev/null || echo 0); " +
            "CFD=$(cat /sys/class/power_supply/$BAT/charge_full_design 2>/dev/null || echo 0); " +
            "VMD=$(cat /sys/class/power_supply/$BAT/voltage_min_design 2>/dev/null || cat /sys/class/power_supply/$BAT/voltage_now 2>/dev/null || echo 0); " +
            "SIZE=$(awk -v e=\"$EFD\" -v c=\"$CFD\" -v v=\"$VMD\" 'BEGIN{ if(e>0) printf \"%.0f Wh\", e/1000000; else if(c>0&&v>0) printf \"%.0f Wh\", c*v/1000000000000; else print \"\" }'); " +
            "echo \"$CAP|$STA|$HEALTH|$CYC|$SIZE\""
        ]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                var parts = this.text.trim().split("|")
                if (parts.length >= 2) {
                    batPanel.percent = parseInt(parts[0]) || 0
                    batPanel.status = parts[1] || "Unknown"
                    batPanel.capacity = parts[2] || ""
                    batPanel.cycles = parts.length > 3 ? (parseInt(parts[3]) || 0) : 0
                    batPanel.sizeText = parts.length > 4 ? (parts[4] || "") : ""
                }
            }
        }
    }

    Process { id: btopRunner; command: ["bash", "-c", "omarchy-launch-floating-terminal-with-presentation 'btop'"] }

    onVisibleChanged: { if (visible) { batData.running = false; batData.running = true } }
}
