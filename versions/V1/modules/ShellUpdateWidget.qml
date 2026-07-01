import QtQuick
import Quickshell
import Quickshell.Io

// Shell-update badge. Read-only mirror of the state file written by
// ~/.config/quickshell/bin/qs-shell-check-update.sh (driven by a systemd timer).
// Badge shows only when an update is pending; the tooltip lists the incoming
// commit subjects so the user sees what the update contains.
// (Smallest testable step: badge + tooltip only — the apply/popup comes later.)
Item {
    id: rootMod
    required property var root

    property int    behind: 0
    property var    summary: []
    property string version: ""

    readonly property bool updateAvailable: behind > 0
    visible: updateAvailable
    implicitWidth: updateAvailable ? 20 : 0
    implicitHeight: 28


    readonly property string tooltipText: {
        if (!updateAvailable) return ""
        var head = "Shell update available (" + behind + (behind === 1 ? " commit)" : " commits)")
        var lines = []
        for (var i = 0; i < summary.length; i++) lines.push("• " + summary[i])
        return lines.length ? head + "\n" + lines.join("\n") : head
    }

    FileView {
        id: stateFile
        path: Quickshell.env("HOME") + "/.cache/qs-shell/update-available.json"
        watchChanges: true
        onFileChanged: stateFile.reload()
        onLoaded: {
            try {
                var j = JSON.parse(stateFile.text())
                rootMod.behind  = j.behind  || 0
                rootMod.summary = j.summary || []
                rootMod.version = j.version || ""
            } catch (e) {
                rootMod.behind = 0; rootMod.summary = []
            }
            rootMod.publish()
        }
        onLoadFailed: {                                              // file never existed => up to date
            rootMod.behind = 0; rootMod.summary = []
            rootMod.publish()
        }
    }

    // share parsed state with the panel via root; close a stale panel once there
    // is nothing to update (new state contract: behind:0 arrives via onLoaded)
    function publish() {
        rootMod.root.shellUpdateBehind  = rootMod.behind
        rootMod.root.shellUpdateSummary = rootMod.summary
        rootMod.root.shellUpdateVersion = rootMod.version
        if (rootMod.behind === 0 && rootMod.root.shellUpdateVisible)
            rootMod.root.shellUpdateVisible = false
    }

    IconText {
        anchors.centerIn: parent
        text: "\uE5D5"   // refresh (distinct from omarchy's  sync sitting next to it)
        color: root.seal
        font.pixelSize: 14
    }

    TooltipMixin { id: tip; root: rootMod.root; owner: rootMod; text: rootMod.tooltipText }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true; cursorShape: Qt.PointingHandCursor
        onEntered: tip.show()
        onExited:  tip.hide()
        onClicked: {
            tip.hide()
            rootMod.publish()
            var p = rootMod.mapToItem(null, rootMod.width / 2, 0)   // badge centre, global X
            rootMod.root.setPanelAnchor("shellUpdate", p.x)
            rootMod.root.shellUpdateVisible = true
        }
    }
}
