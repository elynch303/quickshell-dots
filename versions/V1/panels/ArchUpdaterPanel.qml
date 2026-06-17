import QtQuick
import "../modules"
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

    // On open: show the blacklist/protection status instantly (the gate only reads
    // a local file — no need to wait for the slow package check), and kick a package
    // check if there is no data yet (e.g. right after a bar restart). The widget
    // ignores the trigger while a refresh is already in flight. Re-running the gate
    // here also clears a transient degraded verdict (blacklist mid-update at scan).
    Connections {
        target: root
        function onArchVisibleChanged() {
            if (!root.archVisible) return
            root.archGateRescan()
            if (root.archUpdates.length === 0) root.archRefreshTick++
        }
    }

    // pkg -> gate verdict, rebuilt once per gate run (avoids O(n²) per-row scans)
    readonly property var gateMap: {
        var m = ({})
        var r = root.archGateResults || []
        for (var i = 0; i < r.length; i++) m[r[i].pkg] = r[i]
        return m
    }

    // ── OK-only update policy ──
    // The main button installs ONLY verified repo/system OK packages, via pacman.
    // AUR packages are never part of a pacman transaction, so WARN/AUR is skipped
    // automatically; system packages that are not OK are held back with --ignore
    // (keeps the upgrade whole — no partial-upgrade risk, unlike a name allowlist).
    readonly property int repoOkPackages: {
        var n = 0, r = root.archGateResults || []
        for (var i = 0; i < r.length; i++)
            if (r[i].repo !== "aur" && r[i].verdict === "OK") n++
        return n
    }
    readonly property int aurReviewPackages: {
        var n = 0, r = root.archGateResults || []
        for (var i = 0; i < r.length; i++)
            if (r[i].repo === "aur" && r[i].verdict === "WARN") n++
        return n
    }
    readonly property int btnCount: aurReviewPackages > 0 ? 3 : 2
    // NOT gated on degraded: repo updates are trusted via pacman/GPG independently
    // of the AUR blacklist, so a degraded AUR feed must not block repo upgrades.
    readonly property bool canUpdate: repoOkPackages > 0 && root.archGateState !== "scanning"
    function systemIgnoreList() {
        var out = [], r = root.archGateResults || []
        for (var i = 0; i < r.length; i++)
            if (r[i].repo !== "aur" && r[i].verdict !== "OK"
                && /^[a-zA-Z0-9@._+-]+$/.test(r[i].pkg))
                out.push(r[i].pkg)
        return out
    }

    Rectangle {
        id: card
        width: 520
        height: Math.min(col.implicitHeight + 24, 460)
        radius: reveal > 0.001 ? root.pillRadius : 0
        color: root.bg
        border.color: root.pillBorder
        border.width: root.pillBorderW
        PillShadow { theme: root }

        x: Math.round(Math.max(6, Math.min(root.archBarX - width / 2, parent.width - width - 6)))
        y: root.barPosition === "bottom" ? (parent.height - barBottom - gap - height) : (barBottom + gap)
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

            // ── one status line: counts + protection, COLORED segments joined by "·",
            //    shown even at 0 updates. The blacklist segment opens its source. ──
            Row {
                id: statusRow
                width: parent.width
                spacing: 0
                visible: segs.length > 0
                readonly property var segs: {
                    var s = []
                    if (root.archUpdates.length > 0) {
                        s.push({ t: "✓ " + root.archGateOk + " OK", c: root.green, link: false })
                        if (root.archGateWarn > 0) s.push({ t: "⚠ " + root.archGateWarn + " review", c: root.inkDeep, link: false })
                        if (root.archGateFail > 0) s.push({ t: "✗ " + root.archGateFail + " blocked", c: root.seal, link: false })
                    }
                    if (root.archGateDegraded) s.push({ t: "⚠ protection limited", c: root.seal, link: false })
                    if (root.archGateStale) s.push({ t: "⚠ source stale", c: root.seal, link: false })
                    if (root.archGateMirrorsAgree && !root.archGateDegraded) s.push({ t: "mirrors ✓", c: root.green, link: false })
                    if (root.archGateBlacklist > 0) {
                        var b = "blacklist " + root.archGateBlacklist
                        if (root.archGateListDate !== "") b += " · " + root.archGateListDate
                        s.push({ t: b, c: root.ink, link: true })
                    }
                    return s
                }
                Repeater {
                    model: statusRow.segs
                    delegate: Row {
                        required property var modelData
                        required property int index
                        spacing: 0
                        Text {
                            visible: index > 0
                            text: " · "
                            color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.4)
                            font.family: root.mono; font.pixelSize: 10; font.letterSpacing: 1
                        }
                        Text {
                            text: modelData.t
                            color: (modelData.link && segMa.containsMouse) ? root.seal : modelData.c
                            font.family: root.mono; font.pixelSize: 10; font.letterSpacing: 1
                            font.underline: modelData.link && segMa.containsMouse
                            Behavior on color { ColorAnimation { duration: 120 } }
                            MouseArea {
                                id: segMa
                                anchors.fill: parent
                                enabled: !!modelData.link
                                hoverEnabled: true
                                cursorShape: modelData.link ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: if (modelData.link) Quickshell.execDetached(
                                    ["xdg-open", "https://gist.github.com/quantenProjects/3f768dce7331618310f016d975bf8547"])
                            }
                        }
                    }
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
                                color: vBlocked ? root.seal : root.ink
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

                // Refresh
                Rectangle {
                    width: (parent.width - 8 * (archPanel.btnCount - 1)) / archPanel.btnCount
                    height: 28; radius: root.tileRadius
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
                        onClicked: root.archRefreshTick++
                    }
                }

                // Update — OK-only repo/system via pacman; AUR is never installed here.
                Rectangle {
                    width: (parent.width - 8 * (archPanel.btnCount - 1)) / archPanel.btnCount
                    height: 28; radius: root.tileRadius
                    opacity: archPanel.canUpdate ? 1.0 : 0.45
                    color: (updateMa.containsMouse && archPanel.canUpdate) ? Qt.lighter(root.seal, 1.15) : root.seal
                    border.color: "transparent"
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Text {
                        anchors.centerIn: parent
                        text: archPanel.repoOkPackages === 0
                            ? "No repo updates"
                            : (archPanel.aurReviewPackages > 0 || root.archGateFail > 0)
                                ? "Update " + archPanel.repoOkPackages + " OK only"
                                : "Update " + archPanel.repoOkPackages
                        color: root.paper
                        font.family: root.mono; font.pixelSize: 11
                    }
                    MouseArea {
                        id: updateMa
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: archPanel.canUpdate
                        cursorShape: archPanel.canUpdate ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: {
                            // OK-only: pacman never touches AUR, so WARN/AUR is skipped
                            // automatically; non-OK SYSTEM packages are held back with
                            // --ignore (whole upgrade, no partial-upgrade risk). Names
                            // are regex-validated before interpolation.
                            var ig = archPanel.systemIgnoreList();
                            var ign = ig.length ? " --ignore " + ig.join(",") : "";
                            var prompt = "Update " + archPanel.repoOkPackages + " verified repo packages only?";
                            if (archPanel.aurReviewPackages > 0)
                                prompt += " " + archPanel.aurReviewPackages + " AUR review packages will be skipped.";
                            if (root.archGateDegraded)
                                prompt += " (security feed degraded)";
                            panelUpdateRunner.command = ["bash", "-c",
                                "omarchy-launch-floating-terminal-with-presentation 'gum confirm \"" + prompt + "\" && sudo pacman -Syu" + ign + "'"];
                            root.archVisible = false;
                            panelUpdateRunner.running = false;
                            panelUpdateRunner.running = true;
                        }
                    }
                }

                // Review — AUR needs a manual PKGBUILD look; this view installs nothing.
                Rectangle {
                    visible: archPanel.aurReviewPackages > 0
                    width: (parent.width - 8 * (archPanel.btnCount - 1)) / archPanel.btnCount
                    height: 28; radius: root.tileRadius
                    color: reviewMa.containsMouse ? Qt.rgba(root.seal.r, root.seal.g, root.seal.b, 0.18) : root.sep
                    border.color: reviewMa.containsMouse ? root.seal : "transparent"
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Text {
                        anchors.centerIn: parent
                        text: "Review " + archPanel.aurReviewPackages + " AUR"
                        color: reviewMa.containsMouse ? root.seal : root.ink
                        font.family: root.mono; font.pixelSize: 11
                    }
                    MouseArea {
                        id: reviewMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            // Display-only: list AUR updates, install nothing.
                            panelUpdateRunner.command = ["bash", "-c",
                                "omarchy-launch-floating-terminal-with-presentation 'echo \"AUR review — no packages are installed by this view.\"; echo; yay -Qum; echo; echo \"Inspect:  yay -G <pkg> && less <pkg>/PKGBUILD\"'"];
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
