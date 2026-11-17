// Fighting game stage for the lock screen, adapted from VirgileHenry/fggreeter.
// Renders the two stickman fighters from fighters-anims.json (extracted from
// fighters.glb) with 24fps->60fps interpolated poses, 50ms transition blending,
// black-and-white impact frames, shockwave ellipses, impact stars, sparks,
// embers, windup charge particles, and camera/UI shake.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: stage

    property bool active: true
    property bool fightEnabled: true

    // True while an impact frame (or post-finisher blackout) is hiding the backdrop.
    readonly property bool impactActive: impactState.active || blackoutActive
    property bool blackoutActive: false

    // UI card shake offset (in px), read by LockSurface.qml.
    property real uiShakeX: 0
    property real uiShakeY: 0

    // Live hit combo counter for the HUD badge.
    property int comboCount: 0
    signal comboHit

    // ------------------------------------------------------------------ data --
    property var animData: null
    readonly property bool ready: animData !== null && animData.anims !== undefined

    FileView {
        id: animFile
        path: Quickshell.shellDir + "/fighters-anims.json"
        onLoaded: {
            try {
                stage.animData = JSON.parse(text())
            } catch (e) {
                console.warn("FightStage: failed to parse fighters-anims.json:", e)
            }
        }
    }

    // --------------------------------------------------------- state machine --
    readonly property int animFps: animData ? animData.fps : 24
    readonly property real frameDuration: 1.0 / animFps
    readonly property int hitFrame: 4
    readonly property int restFrame: 12
    readonly property real hitCloseupTime: hitFrame * frameDuration
    readonly property real transitionDuration: 0.05
    readonly property real sceneHeight: 5.0
    readonly property real sceneCenterY: 1.5

    readonly property var hitAnims: [
        "Hit.HighKick",
        "Hit.KneeUpercut",
        "Hit.LowJab",
        "Hit.Smash",
        "Hit.Uppercut"
    ]

    property string fightingState: "idle" // idle | engaged | windup | finished | countered
    property string currentAnim: "Idle"
    property real animTime: 0.0
    property int lastHitIdx: -1

    property var blendFromPose: null
    property real blendElapsed: 0.0

    property var scheduledEvents: []
    property var particles: []
    property var currentPose: null

    property var impactState: ({
        active: false,
        remaining: 0.0,
        litP: false,
        litA: false,
        restoreBg: true
    })

    property real uiTrauma: 0.0
    property real camTrauma: 0.0
    property real camShakeX: 0.0
    property real camShakeY: 0.0

    Timer {
        id: comboResetTimer
        interval: 1200
        onTriggered: stage.comboCount = 0
    }

    // -------------------------------------------------------- public actions --
    function resetRound() {
        fightingState = "idle"
        blackoutActive = false
        scheduledEvents = []
        particles = []
        impactState = { active: false, remaining: 0.0, litP: false, litA: false, restoreBg: true }
        uiTrauma = 0.0
        camTrauma = 0.0
        uiShakeX = 0.0
        uiShakeY = 0.0
        camShakeX = 0.0
        camShakeY = 0.0
        comboCount = 0
        comboResetTimer.stop()
        playAnim("Idle", 0.0)
        canvas.requestPaint()
    }

    function triggerHit() {
        if (!fightEnabled || !ready)
            return
        if (fightingState === "finished")
            return

        let idx = Math.floor(Math.random() * hitAnims.length)
        if (hitAnims.length > 1 && idx === lastHitIdx)
            idx = (idx + 1) % hitAnims.length
        lastHitIdx = idx

        const clip = hitAnims[idx]
        const startT = fightingState === "engaged" ? hitCloseupTime : 0.0
        const impactDelay = fightingState === "engaged" ? frameDuration : (hitFrame + 1) * frameDuration - startT
        const restDelay = (restFrame * frameDuration) - startT

        fightingState = "engaged"
        playAnim(clip, startT)

        // Cancel pending hit/rest events from the previous chained hit.
        scheduledEvents = scheduledEvents.filter(ev => ev.kind !== "hitImpact" && ev.kind !== "backToIdle")
        schedule(Math.max(0.0, impactDelay), "hitImpact")
        schedule(Math.max(0.05, restDelay), "backToIdle")

        comboCount += 1
        comboResetTimer.restart()
        comboHit()
    }

    function triggerBlock() {
        if (!fightEnabled || !ready)
            return
        if (fightingState === "finished" || fightingState === "windup")
            return
        // Subtle reset/parry on backspace.
        if (fightingState === "engaged") {
            scheduledEvents = scheduledEvents.filter(ev => ev.kind !== "hitImpact" && ev.kind !== "backToIdle")
            fightingState = "idle"
            playAnim("Idle", 0.0)
        }
    }

    function triggerReset() {
        if (!fightEnabled || !ready)
            return
        if (fightingState === "finished")
            return
        comboCount = 0
        comboResetTimer.stop()
        scheduledEvents = scheduledEvents.filter(ev => ev.kind !== "hitImpact" && ev.kind !== "backToIdle")
        fightingState = "idle"
        playAnim("Idle", 0.0)
    }

    function triggerWindup() {
        if (!fightEnabled || !ready)
            return
        if (fightingState === "finished")
            return
        scheduledEvents = []
        fightingState = "windup"
        playAnim("Windup.Classic", 0.0)
        schedule(transitionDuration + frameDuration, "windupCharge")
    }

    function triggerFinisher() {
        if (!fightEnabled || !ready)
            return
        scheduledEvents = []
        fightingState = "finished"
        playAnim("Windup.Finisher.Classic", 0.0)
        schedule(transitionDuration + frameDuration, "finisherImpact")
    }

    function triggerCounter() {
        if (!fightEnabled || !ready)
            return
        scheduledEvents = []
        comboCount = 0
        comboResetTimer.stop()
        fightingState = "countered"
        playAnim("Windup.Counter.Classic", 0.0)
        schedule(transitionDuration + frameDuration, "counterImpact")
    }

    // ------------------------------------------------------------- internals --
    function playAnim(name, startTime) {
        if (currentPose)
            blendFromPose = currentPose
        else if (ready)
            blendFromPose = samplePose(currentAnim, animTime)
        blendElapsed = 0.0
        currentAnim = name
        animTime = startTime
    }

    function schedule(delaySec, kind, payload) {
        scheduledEvents.push({ remaining: delaySec, kind: kind, payload: payload || null })
    }

    function lerp(a, b, t) {
        return a + (b - a) * t
    }

    function clonePose(pose) {
        const copyFighter = f => ({
            s: f.s.map(seg => [seg[0], seg[1], seg[2], seg[3]]),
            h: [f.h[0], f.h[1]]
        })
        return {
            p: copyFighter(pose.p),
            a: copyFighter(pose.a),
            hp: [pose.hp[0], pose.hp[1], pose.hp[2], pose.hp[3]]
        }
    }

    function blendPoses(p0, p1, alpha) {
        if (alpha >= 1.0 || !p0)
            return p1
        const t = Math.max(0.0, Math.min(1.0, alpha))
        const blendFighter = (f0, f1) => {
            const segs = []
            for (let i = 0; i < f1.s.length; i++) {
                const a = f0.s[i]
                const b = f1.s[i]
                segs.push([
                    lerp(a[0], b[0], t),
                    lerp(a[1], b[1], t),
                    lerp(a[2], b[2], t),
                    lerp(a[3], b[3], t)
                ])
            }
            return {
                s: segs,
                h: [lerp(f0.h[0], f1.h[0], t), lerp(f0.h[1], f1.h[1], t)]
            }
        }
        return {
            p: blendFighter(p0.p, p1.p),
            a: blendFighter(p0.a, p1.a),
            hp: [
                lerp(p0.hp[0], p1.hp[0], t),
                lerp(p0.hp[1], p1.hp[1], t),
                lerp(p0.hp[2], p1.hp[2], t),
                lerp(p0.hp[3], p1.hp[3], t)
            ]
        }
    }

    function samplePose(animName, timeSec) {
        if (!ready)
            return null
        const frames = animData.anims[animName]
        if (!frames || frames.length === 0)
            return null
        if (frames.length === 1)
            return frames[0]

        const maxFrame = frames.length - 1
        let f = timeSec * animFps
        if (animName === "Idle") {
            f = ((f % maxFrame) + maxFrame) % maxFrame
        } else {
            f = Math.max(0.0, Math.min(maxFrame, f))
        }
        const i0 = Math.floor(f)
        const i1 = Math.min(maxFrame, i0 + 1)
        const frac = f - i0
        if (frac < 0.001 || i0 === i1)
            return frames[i0]
        return blendPoses(frames[i0], frames[i1], frac)
    }

    function getHitPoint() {
        const pose = currentPose || samplePose(currentAnim, animTime)
        if (!pose)
            return { x: 0.0, y: 1.0, dx: 0.0, dy: 1.0 }
        const hp = pose.hp
        const len = Math.hypot(hp[2], hp[3]) || 1.0
        return { x: hp[0], y: hp[1], dx: hp[2] / len, dy: hp[3] / len }
    }

    // ------------------------------------------------------------ FX spawners --
    function rand(min, max) {
        return min + Math.random() * (max - min)
    }

    function spawnHitImpact() {
        const hp = getHitPoint()
        uiTrauma = Math.min(3.0, uiTrauma + 0.6)
        camTrauma = Math.min(1.0, camTrauma + 0.4)

        startImpactFrame(frameDuration, true, false, true)
        spawnCoreFlash(hp)
        spawnImpactStar(hp)
        spawnEllipses(hp, 2)

        schedule(frameDuration, "hitSparks", hp)
        schedule(frameDuration * 2, "impactFrame", {
            dur: frameDuration, litP: false, litA: true, restoreBg: true
        })
    }

    function spawnSuperImpact(swapped) {
        const hp = getHitPoint()
        const f = frameDuration
        camTrauma = 1.0
        uiTrauma = Math.min(3.0, uiTrauma + 1.2)

        const setLit = (attacker, defender) => swapped
            ? { litP: defender, litA: attacker }
            : { litP: attacker, litA: defender }

        let fc = 0
        // Frame 0: Attacker lit
        let l = setLit(true, false)
        startImpactFrame(f * 2, l.litP, l.litA, false)
        spawnEllipses(hp, 1)

        // Frame 2: Attacker lit + ring
        fc += 2
        l = setLit(true, false)
        schedule(f * fc, "impactFrame", { dur: f * 2, litP: l.litP, litA: l.litA, restoreBg: false })
        schedule(f * fc, "ellipses", { hp: hp, count: 1 })

        // Frame 4: Both lit + double ring
        fc += 2
        l = setLit(true, true)
        schedule(f * fc, "impactFrame", { dur: f * 2, litP: l.litP, litA: l.litA, restoreBg: false })
        schedule(f * fc, "ellipses", { hp: hp, count: 2 })

        // Frame 6: Defender lit + full explosion
        fc += 2
        l = setLit(false, true)
        schedule(f * fc, "impactFrame", { dur: f * 2, litP: l.litP, litA: l.litA, restoreBg: false })
        schedule(f * fc, "superBurst", hp)

        // Strobing defender frames (fit cleanly inside ~800ms)
        for (let k = 0; k < 5; k++) {
            fc += 2
            l = setLit(false, true)
            schedule(f * fc, "impactFrame", { dur: f * 1.5, litP: l.litP, litA: l.litA, restoreBg: false })
        }

        fc += 2
        l = setLit(false, true)
        schedule(f * fc, "impactFrame", { dur: f * 2, litP: l.litP, litA: l.litA, restoreBg: swapped })
        schedule(f * fc, "ellipses", { hp: hp, count: 2 })

        if (swapped) {
            schedule(f * (fc + 2), "endCounter")
        } else {
            // Finisher stays blacked out until unlock completes
            blackoutActive = true
        }
    }

    function startImpactFrame(duration, litP, litA, restoreBg) {
        impactState = {
            active: true,
            remaining: duration,
            litP: litP,
            litA: litA,
            restoreBg: restoreBg
        }
    }

    function spawnCoreFlash(hp) {
        particles.push({
            kind: "circle",
            x: hp.x, y: hp.y,
            vx: 0, vy: 0,
            drag: 0, gravity: 0,
            age: 0, lifetime: 0.10,
            size: 0.32,
            color: "#ffffff",
            profile: "pop"
        })
    }

    function spawnImpactStar(hp) {
        const spikes = Math.floor(rand(10, 17))
        const phase = rand(0, Math.PI * 2)
        for (let i = 0; i < spikes; i++) {
            const angle = phase + (Math.PI * 2 * i) / spikes + rand(-0.25, 0.25)
            let sx = Math.cos(angle) + hp.dx * 0.6
            let sy = Math.sin(angle) + hp.dy * 0.6
            const slen = Math.hypot(sx, sy) || 1.0
            sx /= slen; sy /= slen
            particles.push({
                kind: "spike",
                x: hp.x, y: hp.y,
                ux: sx, uy: sy,
                length: rand(1.0, 2.4),
                width: rand(0.025, 0.055),
                age: 0, lifetime: 0.15,
                color: (i % 2 === 0) ? "#ffffff" : "#ffe650"
            })
        }
    }

    function spawnEllipses(hp, count) {
        // Tilt shockwave ellipse perpendicular to hit dir (projected to 2D)
        const nx = hp.dx
        const ny = hp.dy
        const tx = -ny
        const ty = nx
        const shards = 28
        for (let c = 0; c < count; c++) {
            for (let i = 0; i < shards; i++) {
                const a = (Math.PI * 2 * i) / shards
                const ca = Math.cos(a)
                const sa = Math.sin(a)
                // Squash along hit direction to emulate tilted 3D shockwave ring
                const rx = tx * ca + nx * sa * 0.55
                const ry = ty * ca + ny * sa * 0.55
                const tanx = -ry
                const tany = rx
                const tlen = Math.hypot(tanx, tany) || 1.0
                const scale = rand(0.8, 1.0)
                particles.push({
                    kind: "shard",
                    x: hp.x + rx * 0.2 * scale,
                    y: hp.y + ry * 0.2 * scale,
                    vx: rx * 14.0 * scale,
                    vy: ry * 14.0 * scale,
                    ux: tanx / tlen,
                    uy: tany / tlen,
                    drag: 9.0,
                    gravity: 0.0,
                    length: 0.35 * scale,
                    width: 0.05 * scale,
                    age: 0,
                    lifetime: 0.22,
                    color: "#ffffff",
                    profile: "shrink"
                })
            }
        }
    }

    function spawnSparksAndEmbers(hp) {
        const baseAngle = Math.atan2(hp.dy, hp.dx)
        // 16 wide sparks + 8 long fast sparks
        for (let i = 0; i < 24; i++) {
            const fast = i >= 16
            const spread = fast ? 0.6 : 1.4
            const angle = baseAngle + rand(-spread, spread)
            const speed = fast ? rand(13.0, 20.0) : rand(6.0, 12.0)
            particles.push({
                kind: "streak",
                x: hp.x, y: hp.y,
                vx: Math.cos(angle) * speed,
                vy: Math.sin(angle) * speed,
                drag: fast ? 3.5 : 5.0,
                gravity: 3.0,
                length: fast ? rand(0.22, 0.50) : rand(0.10, 0.22),
                width: rand(0.02, 0.04),
                stretch: 0.04,
                age: 0,
                lifetime: rand(0.18, 0.30),
                color: (i % 3 === 0) ? "#ffffff" : "#ffe042",
                profile: "shrink"
            })
        }
        // 14 drifting embers
        for (let i = 0; i < 14; i++) {
            const angle = baseAngle + rand(-1.8, 1.8)
            const speed = rand(2.0, 6.0)
            particles.push({
                kind: "square",
                x: hp.x + rand(-0.15, 0.15),
                y: hp.y + rand(-0.15, 0.15),
                vx: Math.cos(angle) * speed,
                vy: Math.sin(angle) * speed + rand(0.5, 2.0),
                drag: 4.0,
                gravity: -0.6,
                size: rand(0.04, 0.08),
                age: 0,
                lifetime: rand(0.35, 0.65),
                color: (i % 2 === 0) ? "#ffe042" : "#ff7b1c",
                profile: "shrink"
            })
        }
    }

    function spawnWindupCharge(hp) {
        for (let i = 0; i < 18; i++) {
            const angle = rand(0, Math.PI * 2)
            const dist = rand(0.65, 1.35)
            const sx = hp.x + Math.cos(angle) * dist
            const sy = hp.y + Math.sin(angle) * dist
            const life = rand(0.16, 0.26)
            particles.push({
                kind: "streak",
                x: sx, y: sy,
                vx: -Math.cos(angle) * (dist / life),
                vy: -Math.sin(angle) * (dist / life),
                drag: 0.0,
                gravity: 0.0,
                length: rand(0.08, 0.16),
                width: rand(0.025, 0.04),
                stretch: 0.02,
                age: 0,
                lifetime: life,
                color: (i % 2 === 0) ? "#ff7b1c" : "#ffe042",
                profile: "shrink"
            })
        }
    }

    // ------------------------------------------------------------- main loop --
    property double lastTickMs: 0

    Timer {
        id: ticker
        interval: 16
        repeat: true
        running: stage.active && stage.fightEnabled && stage.ready
        onTriggered: {
            const now = Date.now()
            const dt = stage.lastTickMs > 0 ? Math.min(0.05, (now - stage.lastTickMs) / 1000.0) : 0.016
            stage.lastTickMs = now
            stage.step(dt)
        }
        onRunningChanged: {
            if (running)
                stage.lastTickMs = Date.now()
        }
    }

    function step(dt) {
        animTime += dt
        if (blendFromPose) {
            blendElapsed += dt
            if (blendElapsed >= transitionDuration)
                blendFromPose = null
        }

        // Advance scheduled animation events.
        const remainingEvents = []
        for (let i = 0; i < scheduledEvents.length; i++) {
            const ev = scheduledEvents[i]
            ev.remaining -= dt
            if (ev.remaining <= 0) {
                dispatchEvent(ev)
            } else {
                remainingEvents.push(ev)
            }
        }
        scheduledEvents = remainingEvents

        // Advance impact frame timer.
        if (impactState.active) {
            const nextRem = impactState.remaining - dt
            if (nextRem <= 0) {
                impactState = {
                    active: false,
                    remaining: 0.0,
                    litP: false,
                    litA: false,
                    restoreBg: impactState.restoreBg
                }
            } else {
                impactState = {
                    active: true,
                    remaining: nextRem,
                    litP: impactState.litP,
                    litA: impactState.litA,
                    restoreBg: impactState.restoreBg
                }
            }
        }

        // Advance particles.
        const nextParticles = []
        for (let i = 0; i < particles.length; i++) {
            const p = particles[i]
            p.age += dt
            if (p.age >= p.lifetime)
                continue
            if (p.kind !== "spike") {
                p.x += p.vx * dt
                p.y += p.vy * dt
                const factor = Math.exp(-p.drag * dt)
                p.vx *= factor
                p.vy *= factor
                p.vy -= p.gravity * dt
            }
            nextParticles.push(p)
        }
        particles = nextParticles

        // Decay UI and camera shake trauma.
        uiTrauma = Math.max(0.0, uiTrauma - 3.0 * dt)
        const uiAmt = 12.0 * uiTrauma * uiTrauma
        uiShakeX = uiAmt > 0.05 ? rand(-1.0, 1.0) * uiAmt : 0.0
        uiShakeY = uiAmt > 0.05 ? rand(-1.0, 1.0) * uiAmt : 0.0

        camTrauma = Math.max(0.0, camTrauma - 3.0 * dt)
        const camAmt = 0.045 * camTrauma * camTrauma
        camShakeX = camAmt > 0.0002 ? rand(-1.0, 1.0) * camAmt : 0.0
        camShakeY = camAmt > 0.0002 ? rand(-1.0, 1.0) * camAmt : 0.0

        // Sample current fighter pose.
        const rawPose = samplePose(currentAnim, animTime)
        if (rawPose) {
            if (blendFromPose)
                currentPose = blendPoses(blendFromPose, rawPose, blendElapsed / transitionDuration)
            else
                currentPose = rawPose
        }

        canvas.requestPaint()
    }

    function dispatchEvent(ev) {
        switch (ev.kind) {
        case "hitImpact":
            spawnHitImpact()
            break
        case "hitSparks":
            spawnSparksAndEmbers(ev.payload)
            break
        case "backToIdle":
            if (fightingState === "engaged") {
                fightingState = "idle"
                playAnim("Idle", 0.0)
            }
            break
        case "windupCharge":
            spawnWindupCharge(getHitPoint())
            break
        case "finisherImpact":
            spawnSuperImpact(false)
            break
        case "counterImpact":
            spawnSuperImpact(true)
            break
        case "superBurst":
            spawnCoreFlash(ev.payload)
            spawnImpactStar(ev.payload)
            spawnSparksAndEmbers(ev.payload)
            break
        case "ellipses":
            spawnEllipses(ev.payload.hp, ev.payload.count)
            break
        case "impactFrame":
            startImpactFrame(ev.payload.dur, ev.payload.litP, ev.payload.litA, ev.payload.restoreBg)
            break
        case "endCounter":
            blackoutActive = false
            if (fightingState === "countered") {
                fightingState = "idle"
                playAnim("Idle", 0.0)
            }
            break
        }
    }

    // -------------------------------------------------------------- renderer --
    Canvas {
        id: canvas
        anchors.fill: parent
        visible: stage.fightEnabled && stage.ready

        onPaint: {
            const ctx = getContext("2d")
            const W = width
            const H = height
            ctx.clearRect(0, 0, W, H)

            if (!stage.currentPose || !stage.animData)
                return

            const scale = H / stage.sceneHeight
            const ox = W * 0.5 + stage.camShakeX * scale
            const oy = H * 0.5 + (stage.sceneCenterY + stage.camShakeY) * scale

            const toX = x => ox + x * scale
            const toY = y => oy - y * scale

            const isImpact = stage.impactState.active || stage.blackoutActive

            // Subtle ground stage shadow line when not in impact frame.
            if (!isImpact) {
                const floorY = toY(-0.04)
                const grad = ctx.createLinearGradient(ox - scale * 2.2, floorY, ox + scale * 2.2, floorY)
                grad.addColorStop(0.0, "rgba(255, 255, 255, 0.0)")
                grad.addColorStop(0.25, "rgba(255, 255, 255, 0.14)")
                grad.addColorStop(0.5, "rgba(255, 255, 255, 0.22)")
                grad.addColorStop(0.75, "rgba(255, 255, 255, 0.14)")
                grad.addColorStop(1.0, "rgba(255, 255, 255, 0.0)")
                ctx.strokeStyle = grad
                ctx.lineWidth = Math.max(1.5, scale * 0.01)
                ctx.beginPath()
                ctx.moveTo(ox - scale * 2.2, floorY)
                ctx.lineTo(ox + scale * 2.2, floorY)
                ctx.stroke()
            }

            const limbW = Math.max(3.0, stage.animData.limbRadius * 2.0 * scale)
            const headR = stage.animData.headRadius * scale

            const drawFighter = (fg, fillCol, rimCol) => {
                ctx.lineCap = "round"
                ctx.lineJoin = "round"

                // Subtle rim stroke so dark silhouettes stay legible on dark wallpapers.
                if (rimCol) {
                    ctx.strokeStyle = rimCol
                    ctx.lineWidth = limbW + 3.0
                    for (let i = 0; i < fg.s.length; i++) {
                        const seg = fg.s[i]
                        ctx.beginPath()
                        ctx.moveTo(toX(seg[0]), toY(seg[1]))
                        ctx.lineTo(toX(seg[2]), toY(seg[3]))
                        ctx.stroke()
                    }
                    ctx.fillStyle = rimCol
                    ctx.beginPath()
                    ctx.arc(toX(fg.h[0]), toY(fg.h[1]), headR + 1.5, 0, Math.PI * 2)
                    ctx.fill()
                }

                ctx.strokeStyle = fillCol
                ctx.lineWidth = limbW
                for (let i = 0; i < fg.s.length; i++) {
                    const seg = fg.s[i]
                    ctx.beginPath()
                    ctx.moveTo(toX(seg[0]), toY(seg[1]))
                    ctx.lineTo(toX(seg[2]), toY(seg[3]))
                    ctx.stroke()
                }

                ctx.fillStyle = fillCol
                ctx.beginPath()
                ctx.arc(toX(fg.h[0]), toY(fg.h[1]), headR, 0, Math.PI * 2)
                ctx.fill()
            }

            let pFill = "#d92b3a"
            let pRim = "rgba(255, 160, 170, 0.28)"
            let aFill = "#1c4b6e"
            let aRim = "rgba(130, 195, 240, 0.30)"

            if (stage.impactState.active) {
                pFill = stage.impactState.litP ? "#ffffff" : "#000000"
                aFill = stage.impactState.litA ? "#ffffff" : "#000000"
                pRim = null
                aRim = null
            } else if (stage.blackoutActive) {
                pFill = "#000000"
                aFill = "#000000"
                pRim = null
                aRim = null
            }

            // Draw defender first, attacker on top.
            if (stage.fightingState === "countered") {
                drawFighter(stage.currentPose.p, pFill, pRim)
                drawFighter(stage.currentPose.a, aFill, aRim)
            } else {
                drawFighter(stage.currentPose.a, aFill, aRim)
                drawFighter(stage.currentPose.p, pFill, pRim)
            }

            // Draw particles.
            for (let i = 0; i < stage.particles.length; i++) {
                const p = stage.particles[i]
                const t = Math.min(1.0, p.age / p.lifetime)
                let k
                if (p.profile === "pop") {
                    k = t < 0.15 ? (0.6 + 0.7 * (t / 0.15)) : (1.3 * Math.pow(1.0 - (t - 0.15) / 0.85, 2))
                } else {
                    k = 1.0 - t * t
                }
                if (k <= 0.01)
                    continue

                ctx.fillStyle = p.color
                ctx.strokeStyle = p.color

                if (p.kind === "circle") {
                    ctx.beginPath()
                    ctx.arc(toX(p.x), toY(p.y), p.size * k * scale, 0, Math.PI * 2)
                    ctx.fill()
                } else if (p.kind === "spike") {
                    const len = p.length * k * scale
                    const w = Math.max(1.5, p.width * k * scale)
                    const x0 = toX(p.x)
                    const y0 = toY(p.y)
                    ctx.lineCap = "butt"
                    ctx.lineWidth = w
                    ctx.beginPath()
                    ctx.moveTo(x0, y0)
                    ctx.lineTo(x0 + p.ux * len, y0 - p.uy * len)
                    ctx.stroke()
                } else if (p.kind === "shard") {
                    const len = p.length * k * scale * 0.5
                    const w = Math.max(1.5, p.width * k * scale)
                    const cx = toX(p.x)
                    const cy = toY(p.y)
                    ctx.lineCap = "butt"
                    ctx.lineWidth = w
                    ctx.beginPath()
                    ctx.moveTo(cx - p.ux * len, cy + p.uy * len)
                    ctx.lineTo(cx + p.ux * len, cy - p.uy * len)
                    ctx.stroke()
                } else if (p.kind === "streak") {
                    const spd = Math.hypot(p.vx, p.vy)
                    const ux = spd > 0.001 ? p.vx / spd : 0
                    const uy = spd > 0.001 ? p.vy / spd : 1
                    const len = (p.length + spd * p.stretch) * k * scale * 0.5
                    const w = Math.max(1.5, p.width * k * scale)
                    const cx = toX(p.x)
                    const cy = toY(p.y)
                    ctx.lineCap = "butt"
                    ctx.lineWidth = w
                    ctx.beginPath()
                    ctx.moveTo(cx - ux * len, cy + uy * len)
                    ctx.lineTo(cx + ux * len, cy - uy * len)
                    ctx.stroke()
                } else if (p.kind === "square") {
                    const s = Math.max(2.0, p.size * k * scale)
                    ctx.fillRect(toX(p.x) - s * 0.5, toY(p.y) - s * 0.5, s, s)
                }
            }
        }
    }
}
