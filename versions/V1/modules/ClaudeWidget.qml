import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io

// Combined AI-usage pill (Claude Code + OpenAI Codex). The bar shows ONE tool
// (root.aiTool) as a themed-tinted SVG with a bottom-up usage fill; the tooltip
// shows BOTH; clicking opens the AiUsagePanel where the tool can be switched.
// Gating is unchanged: root.modClaude is the on/off toggle for the whole pill.
Item {
    id: rootMod
    required property var root

    // ── which tool the bar pill displays ──
    readonly property bool isCodex: root.aiTool === "codex"

    // ── Claude: process detection is local (drives the pill's visibility); all
    //    usage data comes from root.ai* — the single shared parse in Theme.qml that
    //    AiUsagePanel renders from too, so the two views can't drift apart. ──
    property bool clActive: false
    readonly property bool   clFresh:     root.aiClFresh
    readonly property int    clPct5h:     root.aiClPct5h
    readonly property int    clPct7d:     root.aiClPct7d
    readonly property bool   clBlocked:   root.aiClBlocked
    readonly property string clTokens:    root.aiClTokens
    readonly property string clRate:      root.aiClRate
    readonly property int    clReset5hTs: root.aiClReset5hTs
    readonly property bool   clHas:       root.aiClHas

    // ── Codex ──
    property bool cxActive: false
    readonly property bool   cxFresh:     root.aiCxFresh
    readonly property int    cxPct5h:     root.aiCxPct5h
    readonly property int    cxPct7d:     root.aiCxPct7d    // weekly
    readonly property string cxPlan:      root.aiCxPlan
    readonly property string cxTokens:    root.aiCxTokens
    readonly property string cxRate:      root.aiCxRate
    readonly property int    cxReset5hTs: root.aiCxReset5hTs
    readonly property int    cxReset7dTs: root.aiCxReset7dTs
    readonly property bool   cxHas:       root.aiCxHas

    // ── per-tool signal (active OR fresh non-zero usage) ──
    readonly property bool clSignal: clActive || (clPct5h > 0 && clFresh)
    readonly property bool cxSignal: cxActive || (cxPct5h > 0 && cxFresh)

    // ── selected-tool display values ──
    readonly property int  pct5h:   isCodex ? cxPct5h : clPct5h
    readonly property int  pct5hStep: Math.round(pct5h / 5) * 5
    readonly property bool selFresh: isCodex ? cxFresh : clFresh
    readonly property bool selSignal: isCodex ? cxSignal : clSignal
    readonly property bool blocked:  isCodex ? false : clBlocked

    // show whenever the gate is on AND either tool has a signal — the pill stays
    // reachable (to open the panel + switch) even if the selected tool is idle
    readonly property bool shown: (clSignal || cxSignal) && root.modClaude

    readonly property string tooltipText: {
        var lines = []
        if (clHas || clActive) {
            lines.push("Claude Code")
            var cr = root.aiFmtReset(clReset5hTs)
            lines.push("5h: " + clPct5h + "%" + (cr ? "  (reset in " + cr + ")" : ""))
            if (clPct7d > 0) lines.push("7d: " + clPct7d + "%")
            if (clTokens)    lines.push(clTokens + " tokens" + (clRate ? "  · " + clRate : ""))
        }
        if (cxHas || cxActive) {
            if (lines.length) lines.push("")
            lines.push("OpenAI Codex" + (cxPlan ? "  (" + cxPlan + ")" : ""))
            var x5 = root.aiFmtReset(cxReset5hTs)
            lines.push("5h: " + cxPct5h + "%" + (x5 ? "  (reset in " + x5 + ")" : ""))
            var x7 = root.aiFmtReset(cxReset7dTs)
            lines.push("7d: " + cxPct7d + "%" + (x7 ? "  (reset in " + x7 + ")" : ""))
            if (cxTokens) lines.push(cxTokens + " tokens" + (cxRate ? "  · " + cxRate : ""))
        }
        return lines.length ? lines.join("\n") : "AI usage"
    }

    // keep rendered until the collapse animation finishes
    visible: implicitWidth > 0.5
    implicitWidth: shown ? row.implicitWidth + 18 : 0
    implicitHeight: 28
    opacity: shown ? 1 : 0

    Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

    // ── process detection ──
    Process {
        id: detectClaude
        command: ["bash", "-c", "pgrep -x claude >/dev/null 2>&1 && echo 1 || echo 0"]
        stdout: StdioCollector { onStreamFinished: { rootMod.clActive = (this.text.trim() === "1") } }
    }
    Process {
        id: detectCodex
        // exact process-name match (comm == "codex") so the cache readers / poller
        // (python codex-usage, bash on codex-usage.json) never count as "active";
        // drop the short-lived `codex … app-server` our own backend spawns
        command: ["bash", "-c", "pgrep -xa codex 2>/dev/null | grep -vq app-server && echo 1 || echo 0"]
        stdout: StdioCollector { onStreamFinished: { rootMod.cxActive = (this.text.trim() === "1") } }
    }
    Timer {
        interval: 5000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: {
            detectClaude.running = false; detectClaude.running = true
            detectCodex.running = false;  detectCodex.running = true
        }
    }

    // ── background pill ──
    Rectangle {
        x: 0; anchors.verticalCenter: parent.verticalCenter
        width: Math.round(row.width) + 18
        height: root.pillH; radius: root.pillRadius
        color: root.pill
        border.color: root.pillBorder
        border.width: root.pillBorderW
        PillShadow { theme: root }
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 5

        // icon with bottom-to-top usage fill. Claude keeps its nerd-font glyph;
        // Codex uses its logo SVG (no glyph exists) themed via the shared logo-tint
        // shader (keeps alpha, recolors to a flat color). Both fill bottom→top.
        Item {
            id: iconItem
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: 15; implicitHeight: 15

            // ── Claude: nerd-font glyph (original look) ──
            Item {
                anchors.centerIn: parent
                visible: !rootMod.isCodex
                implicitWidth: glyphBase.implicitWidth
                implicitHeight: glyphBase.implicitHeight

                UiText {
                    id: glyphBase
                    text: String.fromCodePoint(0xF167A)
                    renderType: Text.QtRendering
                    color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.25)
                    font.family: root.mono
                    font.pixelSize: 14
                }
                Item {
                    clip: true
                    width: parent.width
                    anchors.bottom: parent.bottom
                    height: rootMod.pct5hStep > 0
                        ? Math.min(parent.height, Math.max(parent.height * rootMod.pct5hStep / 100, parent.height * 0.25))
                        : 0
                    Behavior on height { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
                    UiText {
                        anchors.bottom: parent.bottom
                        text: String.fromCodePoint(0xF167A)
                        renderType: Text.QtRendering
                        color: root.seal
                        font.family: root.mono
                        font.pixelSize: 14
                        Behavior on color { ColorAnimation { duration: 200 } }
                    }
                }
            }

            // ── Codex: tinted SVG ──
            Item {
                anchors.fill: parent
                visible: rootMod.isCodex

                Image {
                    id: codexBase
                    anchors.fill: parent
                    source: Qt.resolvedUrl("../assets/codex.svg")
                    sourceSize: Qt.size(48, 48)
                    fillMode: Image.PreserveAspectFit
                    smooth: true; mipmap: true
                    // thinner-stroked than the Claude glyph → needs more presence
                    // than the glyph's 0.25 faint base to stay recognizable
                    opacity: 0.5
                    layer.enabled: true
                    layer.smooth: true
                    layer.effect: ShaderEffect {
                        property color tintColor: root.ink
                        fragmentShader: Qt.resolvedUrl("../shaders/logo-tint.frag.qsb")
                    }
                }
                Item {
                    clip: true
                    width: parent.width
                    anchors.bottom: parent.bottom
                    height: rootMod.pct5hStep > 0
                        ? Math.min(parent.height, Math.max(parent.height * rootMod.pct5hStep / 100, parent.height * 0.22))
                        : 0
                    Behavior on height { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
                    Image {
                        width: iconItem.width; height: iconItem.height
                        anchors.bottom: parent.bottom
                        source: Qt.resolvedUrl("../assets/codex.svg")
                        sourceSize: Qt.size(48, 48)
                        fillMode: Image.PreserveAspectFit
                        smooth: true; mipmap: true
                        layer.enabled: true
                        layer.smooth: true
                        layer.effect: ShaderEffect {
                            property color tintColor: root.seal
                            fragmentShader: Qt.resolvedUrl("../shaders/logo-tint.frag.qsb")
                        }
                    }
                }
            }
        }

        UiText {
            anchors.verticalCenter: parent.verticalCenter
            text: rootMod.blocked
                ? "BLK"
                : (rootMod.selSignal ? String(rootMod.pct5h).padStart(2, "0") + "%" : "··")
            color: rootMod.blocked
                ? root.seal
                : Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.85)
            font.family: root.mono
            font.pixelSize: 12
            Behavior on color { ColorAnimation { duration: 200 } }
        }
    }

    TooltipMixin { id: tip; root: rootMod.root; owner: rootMod; text: rootMod.tooltipText }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true; cursorShape: Qt.PointingHandCursor
        onEntered: if (shown) tip.show()
        onExited: { tip.hide() }
        onClicked: { tip.hide(); root.aiUsageVisible = !root.aiUsageVisible }
    }
}
