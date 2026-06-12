import QtQuick

Item {
    id: root
    required property var   theme
    required property Item  layout   // island: exposes pillRuns, runRightEdge(), runLeftEdge()
    property bool active: false
    property int  mode:   1          // 1=stream, 2=surge, 3=bolt, 4=bolt2 (spark gap), 5=stream2 (transfer), 6=surge2 (collider)

    opacity: active ? 1.0 : 0.0
    Behavior on opacity { NumberAnimation { duration: 500; easing.type: Easing.InOutCubic } }

    Timer {
        interval: 16
        repeat: true
        running: root.active
        onTriggered: canvas.requestPaint()
    }

    Canvas {
        id: canvas
        anchors.fill: parent

        onPaint: {
            var ctx  = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            if (!root.active) return
            if (!root.layout || !root.layout.pillRuns) return

            var now  = Date.now()
            var cy   = height / 2
            var seal = root.theme.seal
            if (!seal) return
            var sr   = Math.round(seal.r * 255)
            var sg   = Math.round(seal.g * 255)
            var sb   = Math.round(seal.b * 255)

            function rgba(a) { return "rgba(" + sr + "," + sg + "," + sb + "," + a + ")" }
            // deterministic pseudo-random 0..1 (stable per seed; drives the bolt's jagged path)
            function hash(n) { var s = Math.sin(n * 127.1) * 43758.5453; return s - Math.floor(s) }

            var runs = root.layout.pillRuns

            for (var g = 0; g + 1 < runs.length; g++) {
                var x1 = root.layout.runRightEdge(runs[g].e)
                var x2 = root.layout.runLeftEdge(runs[g + 1].s)
                var gw = x2 - x1
                // guard against NaN/Infinity (would cause infinite loops below)
                if (gw < 10 || !isFinite(x1) || !isFinite(x2)) continue

                // clip drawing strictly to this gap
                ctx.save()
                ctx.beginPath()
                ctx.rect(x1, 0, gw, height)
                ctx.clip()

                if (root.mode === 1) {
                    // ══ STREAM: dots riding a glowing rail ══

                    // ── outer glow: diffuse aura around the track ──
                    var gh  = 8
                    var grd = ctx.createLinearGradient(0, cy - gh, 0, cy + gh)
                    grd.addColorStop(0.00, rgba(0.00))
                    grd.addColorStop(0.25, rgba(0.06))
                    grd.addColorStop(0.45, rgba(0.11))
                    grd.addColorStop(0.50, rgba(0.14))
                    grd.addColorStop(0.55, rgba(0.11))
                    grd.addColorStop(0.75, rgba(0.06))
                    grd.addColorStop(1.00, rgba(0.00))
                    ctx.globalAlpha = 1.0
                    ctx.fillStyle   = grd
                    ctx.fillRect(x1, cy - gh, gw, gh * 2)

                    // ── center line: the rail the dots ride on ──
                    ctx.globalAlpha = 0.55
                    ctx.strokeStyle = rgba(1.0)
                    ctx.lineWidth   = 1.5
                    ctx.beginPath(); ctx.moveTo(x1, cy); ctx.lineTo(x2, cy); ctx.stroke()
                    // white core of the rail
                    ctx.globalAlpha = 0.28
                    ctx.strokeStyle = "#ffffff"
                    ctx.lineWidth   = 0.75
                    ctx.beginPath(); ctx.moveTo(x1, cy); ctx.lineTo(x2, cy); ctx.stroke()

                    // ── global stream: fixed speed + spacing, gap is a viewport ──
                    var sp1  = 65   // px between fast dots
                    var sp2  = 110  // px between slow dots
                    var off1 = (now / 1000 * 70) % sp1
                    var off2 = (now / 1000 * 38) % sp2

                    // fast layer — cap at 60 iterations (60×65 = 3900 px)
                    var k1 = Math.ceil((x1 - off1) / sp1)
                    for (var di = 0; di < 60; di++) {
                        var fx = off1 + (k1 + di) * sp1
                        if (fx >= x2) break
                        var dotId   = (k1 + di + 100000)
                        var isPulse = (dotId % 5 === 0)
                        if (isPulse) {
                            var pulse = 0.5 + 0.5 * Math.sin(now / 700 + dotId * 2.4)
                            ctx.globalAlpha = 0.28 + pulse * 0.18
                            ctx.fillStyle   = seal
                            ctx.beginPath(); ctx.arc(fx, cy, 4.0 + pulse * 1.5, 0, Math.PI * 2); ctx.fill()
                            ctx.globalAlpha = 0.95
                            ctx.fillStyle   = "#ffffff"
                            ctx.beginPath(); ctx.arc(fx, cy, 1.6 + pulse * 0.4, 0, Math.PI * 2); ctx.fill()
                        } else {
                            ctx.globalAlpha = 0.30
                            ctx.fillStyle   = seal
                            ctx.beginPath(); ctx.arc(fx, cy, 4.5, 0, Math.PI * 2); ctx.fill()
                            ctx.globalAlpha = 0.90
                            ctx.fillStyle   = "#ffffff"
                            ctx.beginPath(); ctx.arc(fx, cy, 1.6, 0, Math.PI * 2); ctx.fill()
                        }
                    }

                    // slow layer
                    var k2 = Math.ceil((x1 - off2) / sp2)
                    for (var dj = 0; dj < 40; dj++) {
                        var sx = off2 + (k2 + dj) * sp2
                        if (sx >= x2) break
                        ctx.globalAlpha = 0.11
                        ctx.fillStyle   = seal
                        ctx.beginPath(); ctx.arc(sx, cy, 8.5, 0, Math.PI * 2); ctx.fill()
                        ctx.globalAlpha = 0.50
                        ctx.fillStyle   = "#ffffff"
                        ctx.beginPath(); ctx.arc(sx, cy, 2.3, 0, Math.PI * 2); ctx.fill()
                    }

                } else if (root.mode === 2) {
                    // ══ SURGE: current pulses race inward from both edges, meet, flash ══
                    var T     = 3900
                    // per-gap phase offset → the pulses ripple across the bar, gap by gap
                    var p     = (((now % T) / T) + g * 0.20) % 1   // 0..1 cycle
                    var env   = Math.min(1, p / 0.12)       // quick fade-in at the edges
                    var mid   = (x1 + x2) / 2
                    var reach = gw / 2
                    var xL    = x1 + p * reach
                    var xR    = x2 - p * reach

                    // faint rail for continuity
                    ctx.globalAlpha = 0.16
                    ctx.strokeStyle = seal
                    ctx.lineWidth   = 1.0
                    ctx.beginPath(); ctx.moveTo(x1, cy); ctx.lineTo(x2, cy); ctx.stroke()

                    // current traces: faint at origin edge → bright at the head
                    var lg = ctx.createLinearGradient(x1, 0, xL, 0)
                    lg.addColorStop(0.0, rgba(0.0)); lg.addColorStop(1.0, rgba(0.5 * env))
                    ctx.globalAlpha = 1.0; ctx.strokeStyle = lg; ctx.lineWidth = 1.6
                    ctx.beginPath(); ctx.moveTo(x1, cy); ctx.lineTo(xL, cy); ctx.stroke()
                    var rg = ctx.createLinearGradient(x2, 0, xR, 0)
                    rg.addColorStop(0.0, rgba(0.0)); rg.addColorStop(1.0, rgba(0.5 * env))
                    ctx.strokeStyle = rg
                    ctx.beginPath(); ctx.moveTo(x2, cy); ctx.lineTo(xR, cy); ctx.stroke()

                    // bright heads (seal glow + white core)
                    ctx.globalAlpha = 0.45 * env; ctx.fillStyle = seal
                    ctx.beginPath(); ctx.arc(xL, cy, 4.0, 0, Math.PI * 2); ctx.fill()
                    ctx.beginPath(); ctx.arc(xR, cy, 4.0, 0, Math.PI * 2); ctx.fill()
                    ctx.globalAlpha = 0.95 * env; ctx.fillStyle = "#ffffff"
                    ctx.beginPath(); ctx.arc(xL, cy, 1.7, 0, Math.PI * 2); ctx.fill()
                    ctx.beginPath(); ctx.arc(xR, cy, 1.7, 0, Math.PI * 2); ctx.fill()

                    // soft flash where the two pulses meet
                    if (p > 0.78) {
                        var fl = (p - 0.78) / 0.22          // 0..1 bloom
                        ctx.globalAlpha = 0.50 * (1 - fl); ctx.fillStyle = "#ffffff"
                        ctx.beginPath(); ctx.arc(mid, cy, 2 + fl * 6,  0, Math.PI * 2); ctx.fill()
                        ctx.globalAlpha = 0.30 * (1 - fl); ctx.fillStyle = seal
                        ctx.beginPath(); ctx.arc(mid, cy, 4 + fl * 10, 0, Math.PI * 2); ctx.fill()
                    }

                } else if (root.mode === 3) {
                    // ══ BOLT: current waves charge the field, then discharge as an arc ══
                    var Tb    = 2800
                    var local = now / Tb + g * 0.37          // per-gap offset → cycles stagger
                    var ph    = local - Math.floor(local)    // 0..1 within this gap's cycle
                    var seed  = Math.floor(local) * 131.7 + g * 53.3

                    var charging = ph < 0.82
                    var charge   = Math.pow(Math.min(1, ph / 0.82), 1.6)  // 0..1 build-up (eases in → surges)
                    var dw       = charging ? 0 : (ph - 0.82) / 0.18      // 0..1 through discharge
                    var waveI    = charging ? charge : (1 - dw)           // swells, then collapses into the bolt

                    // ── charged field: two overlapping wave lines that swell as they charge ──
                    var baseAmp = Math.min(height * 0.30, 6.0)
                    var amp     = (0.22 + 0.78 * waveI) * baseAmp          // swells toward discharge
                    var stepw   = Math.max(2, Math.round(gw / 120))        // fine sampling → smooth, crisp curve
                    // (freq, drift, phase, weight) — opposite drifts → the two lines cross and overlap
                    var waves = [ [0.055, -3.0, 0.0, 1.00],
                                  [0.072,  3.6, 2.4, 0.78] ]
                    for (var wi = 0; wi < waves.length; wi++) {
                        var wk = waves[wi][0], wsp = waves[wi][1], wp = waves[wi][2], ww = waves[wi][3]
                        ctx.beginPath()
                        var first = true
                        for (var wx = x1; wx <= x2; wx += stepw) {
                            var wy = cy + amp * ww * Math.sin(wx * wk + now / 1000 * wsp + wp)
                            if (first) { ctx.moveTo(wx, wy); first = false }
                            else        ctx.lineTo(wx, wy)
                        }
                        // faint wide glow, then a crisp thin core (same path → sharp definition)
                        ctx.globalAlpha = (0.05 + waveI * 0.16) * ww
                        ctx.strokeStyle = seal; ctx.lineWidth = 2.6; ctx.stroke()
                        ctx.globalAlpha = (0.22 + waveI * 0.55) * ww
                        ctx.strokeStyle = seal; ctx.lineWidth = 1.0; ctx.stroke()
                    }

                    // ── discharge: the stored charge releases as a bright arc + flash ──
                    if (!charging) {
                        var env  = Math.pow(1 - dw, 1.7)                   // sharp onset, quick decay
                        var aB   = env * (0.7 + 0.3 * Math.sin(now / 30))  // bright crackle
                        var segs = Math.max(4, Math.min(14, Math.round(gw / 26)))
                        var amp  = Math.min(height * 0.26, 4.6)

                        // release flash: a bright bloom filling the gap, lingering after the strike
                        var fla = Math.pow(Math.max(0, 1 - dw / 0.78), 1.3)
                        if (fla > 0) {
                            var fh  = 9
                            var fgr = ctx.createLinearGradient(0, cy - fh, 0, cy + fh)
                            fgr.addColorStop(0.0, rgba(0.0))
                            fgr.addColorStop(0.5, rgba(0.24 * fla))
                            fgr.addColorStop(1.0, rgba(0.0))
                            ctx.globalAlpha = 1.0; ctx.fillStyle = fgr
                            ctx.fillRect(x1, cy - fh, gw, fh * 2)
                        }

                        // the jagged arc — wide seal glow + crisp bright white core
                        ctx.lineJoin = "round"
                        ctx.beginPath(); ctx.moveTo(x1, cy)
                        for (var i = 1; i <= segs; i++) {
                            var bx = x1 + (i / segs) * gw
                            var by = (i === segs) ? cy : cy + (hash(seed + i) - 0.5) * 2 * amp
                            ctx.lineTo(bx, by)
                        }
                        ctx.globalAlpha = 0.42 * aB; ctx.strokeStyle = seal;      ctx.lineWidth = 3.4; ctx.stroke()
                        ctx.globalAlpha = 0.95 * aB; ctx.strokeStyle = "#ffffff"; ctx.lineWidth = 1.2; ctx.stroke()

                        // short fork
                        var bm = Math.floor(segs * 0.45)
                        var fx = x1 + (bm / segs) * gw
                        var fy = cy + (hash(seed + bm) - 0.5) * 2 * amp
                        ctx.beginPath(); ctx.moveTo(fx, fy)
                        for (var j = 1; j <= 3; j++) {
                            ctx.lineTo(fx + j * (gw * 0.07),
                                       fy + (hash(seed + 90 + j) - 0.5) * 2 * amp - j * 1.2)
                        }
                        ctx.globalAlpha = 0.5 * aB; ctx.strokeStyle = "#ffffff"; ctx.lineWidth = 0.8; ctx.stroke()
                    }
                } else if (root.mode === 4) {
                    // ══ SPARK GAP (Bolt2): the pill edges are electrodes ══
                    // Tiny arcs crackle sporadically at the edges — barely-there
                    // life, no rails, no orbs. Every several seconds the gap
                    // breaks down and ONE full bolt arcs across as the payoff,
                    // flickering twice before it dies.
                    var aS  = Math.min(height * 0.30, 5.5)

                    // ── micro sparks: short-lived arcs at random edge spots ──
                    // time is sliced into slots; each slot rolls a few spark
                    // candidates per gap (deterministic — no state kept)
                    var slot = Math.floor(now / 300)
                    var sIn  = (now % 300) / 300            // 0..1 inside the slot
                    for (var sk = 0; sk < 2; sk++) {
                        var sps = slot * 77.7 + g * 13.3 + sk * 311.1
                        if (hash(sps) > 0.32) continue        // most slots stay quiet
                        var life = 1 - sIn                    // quick fade within the slot
                        if (life <= 0) continue
                        var left = hash(sps + 1) < 0.5
                        var ex0  = left ? x1 : x2
                        var dir  = left ? 1 : -1
                        var ey0  = cy + (hash(sps + 2) - 0.5) * height * 0.45
                        var sln  = 4 + hash(sps + 3) * 6      // 4..10 px reach
                        ctx.lineJoin = "round"
                        ctx.beginPath(); ctx.moveTo(ex0, ey0)
                        for (var sj = 1; sj <= 3; sj++) {
                            ctx.lineTo(ex0 + dir * sln * (sj / 3),
                                       ey0 + (hash(sps + 4 + sj) - 0.5) * 4)
                        }
                        var fl4 = 0.6 + 0.4 * Math.sin(now / 23 + sps)
                        ctx.globalAlpha = 0.30 * life * fl4; ctx.strokeStyle = seal;      ctx.lineWidth = 1.6; ctx.stroke()
                        ctx.globalAlpha = 0.75 * life * fl4; ctx.strokeStyle = "#ffffff"; ctx.lineWidth = 0.7; ctx.stroke()
                        // tiny hot point on the electrode
                        ctx.globalAlpha = 0.55 * life
                        ctx.fillStyle   = "#ffffff"
                        ctx.beginPath(); ctx.arc(ex0, ey0, 0.9, 0, Math.PI * 2); ctx.fill()
                    }

                    // ── breakdown: one full arc bridges the gap, then darkness ──
                    var T4  = 4000
                    var lo4 = now / T4 + g * 0.37
                    var ph4 = lo4 - Math.floor(lo4)
                    var sd4 = Math.floor(lo4) * 131.7 + g * 53.3
                    var st4 = 0.10 + hash(sd4 + 99) * 0.75    // irregular breakdown moment
                    var s4  = (ph4 - st4) * T4                // ms since breakdown
                    if (s4 >= 0 && s4 < 340) {
                        // double-flicker envelope: strike, dip, weaker restrike, die
                        var b4 = 0
                        if      (s4 <  90) b4 = 1.0
                        else if (s4 < 150) b4 = 0.25
                        else if (s4 < 230) b4 = 0.7
                        else               b4 = 0.7 * (1 - (s4 - 230) / 110)
                        b4 *= 0.82 + 0.18 * Math.sin(now / 21)

                        var segs = Math.max(4, Math.min(16, Math.round(gw / 22)))
                        ctx.lineJoin = "round"
                        ctx.beginPath(); ctx.moveTo(x1, cy)
                        for (var i = 1; i <= segs; i++) {
                            ctx.lineTo(x1 + (i / segs) * gw,
                                       (i === segs) ? cy : cy + (hash(sd4 + i) - 0.5) * 2 * aS)
                        }
                        ctx.globalAlpha = 0.42 * b4; ctx.strokeStyle = seal;      ctx.lineWidth = 3.4; ctx.stroke()
                        ctx.globalAlpha = 0.95 * b4; ctx.strokeStyle = "#ffffff"; ctx.lineWidth = 1.2; ctx.stroke()

                        // electrode blooms while the arc burns
                        var ebr = 6 + b4 * 3
                        var eps = [ x1, x2 ]
                        for (var eb = 0; eb < 2; eb++) {
                            var eg4 = ctx.createRadialGradient(eps[eb], cy, 0, eps[eb], cy, ebr)
                            eg4.addColorStop(0.0, rgba(0.50 * b4))
                            eg4.addColorStop(1.0, rgba(0.0))
                            ctx.globalAlpha = 1.0; ctx.fillStyle = eg4
                            ctx.beginPath(); ctx.arc(eps[eb], cy, ebr, 0, Math.PI * 2); ctx.fill()
                        }
                    }
                } else if (root.mode === 5) {
                    // ══ TRANSFER (Stream2): the pills exchange energy, drop by drop ══
                    // A droplet of light grows on the left pill edge, detaches,
                    // glides across and is absorbed by the right edge with a
                    // tiny flash. Edge-anchored like Spark Gap; flow stays
                    // left → right like Stream. Between drops: nothing.
                    var T5  = 3200
                    var lo5 = now / T5 + g * 0.41
                    var ph5 = lo5 - Math.floor(lo5)
                    var sd5 = Math.floor(lo5) * 131.7 + g * 53.3
                    var st5 = hash(sd5 + 9) * 0.22            // irregular start
                    var p5  = (ph5 - st5) / 0.74              // the whole hand-over
                    if (p5 >= 0 && p5 <= 1) {
                        var R5 = 2.4                           // droplet core radius
                        var dx5, sc5 = 1.0
                        if (p5 < 0.40) {
                            // growing on the left edge, swelling out of the pill
                            dx5 = x1
                            sc5 = p5 / 0.40
                        } else if (p5 < 0.85) {
                            // detached: glide over, eased — slow exit, fast arrival
                            var u5 = (p5 - 0.40) / 0.45
                            u5  = u5 * u5 * (3 - 2 * u5)       // smoothstep
                            dx5 = x1 + u5 * gw
                        } else {
                            dx5 = -1                            // absorbed — flash phase below
                        }

                        if (dx5 >= 0) {
                            // short fading trail while gliding
                            if (p5 >= 0.40 && dx5 > x1 + 4) {
                                var tt5 = ctx.createLinearGradient(dx5 - 14, 0, dx5, 0)
                                tt5.addColorStop(0.0, rgba(0.0))
                                tt5.addColorStop(1.0, rgba(0.35))
                                ctx.globalAlpha = 1.0; ctx.strokeStyle = tt5; ctx.lineWidth = 1.4
                                ctx.beginPath(); ctx.moveTo(Math.max(x1, dx5 - 14), cy)
                                ctx.lineTo(dx5, cy); ctx.stroke()
                            }
                            // the droplet: seal bloom + white core, breathing slightly
                            var br5 = 0.92 + 0.08 * Math.sin(now / 130)
                            var bg5 = ctx.createRadialGradient(dx5, cy, 0, dx5, cy, R5 * 2.6 * sc5 * br5)
                            bg5.addColorStop(0.0, rgba(0.55 * sc5))
                            bg5.addColorStop(1.0, rgba(0.0))
                            ctx.globalAlpha = 1.0; ctx.fillStyle = bg5
                            ctx.beginPath(); ctx.arc(dx5, cy, R5 * 2.6 * sc5 * br5, 0, Math.PI * 2); ctx.fill()
                            ctx.globalAlpha = 0.92 * sc5; ctx.fillStyle = "#ffffff"
                            ctx.beginPath(); ctx.arc(dx5, cy, R5 * 0.7 * sc5, 0, Math.PI * 2); ctx.fill()
                        } else {
                            // absorbed: quick flash on the right edge, swallowed by the pill
                            var fb5 = 1 - (p5 - 0.85) / 0.15
                            var fg5 = ctx.createRadialGradient(x2, cy, 0, x2, cy, 8)
                            fg5.addColorStop(0.0, rgba(0.60 * fb5))
                            fg5.addColorStop(1.0, rgba(0.0))
                            ctx.globalAlpha = 1.0; ctx.fillStyle = fg5
                            ctx.beginPath(); ctx.arc(x2, cy, 8, 0, Math.PI * 2); ctx.fill()
                            ctx.globalAlpha = 0.9 * fb5; ctx.fillStyle = "#ffffff"
                            ctx.beginPath(); ctx.arc(x2, cy, 1.2 * fb5, 0, Math.PI * 2); ctx.fill()
                        }
                    }
                } else if (root.mode === 6) {
                    // ══ COLLIDER (Surge2): two particles smash mid-gap ══
                    // Surge's converge-DNA, but with punch: two bright points
                    // accelerate from the pill edges, collide in the middle —
                    // impact flash, debris sparks fly off and burn out. Then
                    // darkness until the next shot.
                    var T6  = 3800
                    var lo6 = now / T6 + g * 0.31
                    var ph6 = lo6 - Math.floor(lo6)
                    var sd6 = Math.floor(lo6) * 131.7 + g * 53.3
                    var st6 = hash(sd6 + 9) * 0.5              // irregular shot moment
                    var s6  = (ph6 - st6) * T6                 // ms since launch
                    if (s6 >= 0 && s6 < 1180) {
                        var mid6 = (x1 + x2) / 2
                        var IN6  = 580                          // in-flight time
                        if (s6 < IN6) {
                            // approach: accelerating heads with motion-blur trails
                            var u6  = (s6 / IN6); u6 = u6 * u6
                            var xs6 = [ x1 + u6 * (mid6 - x1), x2 - u6 * (x2 - mid6) ]
                            for (var c6 = 0; c6 < 2; c6++) {
                                var hx6 = xs6[c6]
                                var bk6 = (c6 === 0 ? -1 : 1) * (8 + u6 * 14)   // trail length grows with speed
                                var tg6 = ctx.createLinearGradient(hx6 + bk6, 0, hx6, 0)
                                tg6.addColorStop(0.0, rgba(0.0))
                                tg6.addColorStop(1.0, rgba(0.45))
                                ctx.globalAlpha = 1.0; ctx.strokeStyle = tg6; ctx.lineWidth = 1.6
                                ctx.beginPath(); ctx.moveTo(hx6 + bk6, cy); ctx.lineTo(hx6, cy); ctx.stroke()
                                var hg6 = ctx.createRadialGradient(hx6, cy, 0, hx6, cy, 4.5)
                                hg6.addColorStop(0.0, rgba(0.50))
                                hg6.addColorStop(1.0, rgba(0.0))
                                ctx.fillStyle = hg6
                                ctx.beginPath(); ctx.arc(hx6, cy, 4.5, 0, Math.PI * 2); ctx.fill()
                                ctx.globalAlpha = 0.95; ctx.fillStyle = "#ffffff"
                                ctx.beginPath(); ctx.arc(hx6, cy, 1.5, 0, Math.PI * 2); ctx.fill()
                            }
                        } else {
                            // impact: flash + debris sparks flying out, burning up
                            var t6  = (s6 - IN6) / 600          // 0..1 through the aftermath
                            var fl6 = Math.pow(1 - t6, 1.6)
                            var fr6 = 5 + t6 * 9                // bloom expands as it dies
                            var ig6 = ctx.createRadialGradient(mid6, cy, 0, mid6, cy, fr6)
                            ig6.addColorStop(0.0, rgba(0.60 * fl6))
                            ig6.addColorStop(1.0, rgba(0.0))
                            ctx.globalAlpha = 1.0; ctx.fillStyle = ig6
                            ctx.beginPath(); ctx.arc(mid6, cy, fr6, 0, Math.PI * 2); ctx.fill()
                            if (t6 < 0.25) {
                                ctx.globalAlpha = 0.95 * (1 - t6 / 0.25); ctx.fillStyle = "#ffffff"
                                ctx.beginPath(); ctx.arc(mid6, cy, 1.8, 0, Math.PI * 2); ctx.fill()
                            }
                            // debris: short spark shards, decelerating outward
                            var ez6 = 1 - Math.pow(1 - t6, 2)   // ease-out travel
                            ctx.lineJoin = "round"
                            for (var k6 = 0; k6 < 5; k6++) {
                                var an6 = (hash(sd6 + 30 + k6) - 0.5) * 2.4
                                         + (k6 % 2 === 0 ? 0 : Math.PI)        // both directions
                                var dd6 = (8 + hash(sd6 + 40 + k6) * 14) * ez6
                                var sxa = mid6 + Math.cos(an6) * dd6
                                var sya = cy   + Math.sin(an6) * dd6 * 0.55    // squashed into the bar
                                var sxb = sxa + Math.cos(an6) * 3.5
                                var syb = sya + Math.sin(an6) * 3.5 * 0.55
                                ctx.globalAlpha = 0.75 * fl6
                                ctx.strokeStyle = "#ffffff"; ctx.lineWidth = 0.8
                                ctx.beginPath(); ctx.moveTo(sxa, sya); ctx.lineTo(sxb, syb); ctx.stroke()
                            }
                        }
                    }
                }

                ctx.restore()
            }

            ctx.globalAlpha = 1.0
        }
    }
}
