import KitABI

// Per-frame completion callbacks for one-shot audio. Web Audio finishes a
// buffer source asynchronously with no callback into wasm, so the AVFoundation
// shim registers a snd_play voice + handler here and tick() polls snd_status
// each frame, firing the handler once the voice goes idle. This lets
// AVAudioPlayerNode.scheduleBuffer's completionHandler behave like the apple
// engine (e.g. BossMan's teleport one-shot guard).
nonisolated(unsafe) var _kitAudioCompletions: [(voice: Int32, handler: () -> Void)] = []

public func _kitRegisterAudioCompletion(_ voice: Int32, _ handler: @escaping () -> Void) {
    _kitAudioCompletions.append((voice, handler))
}

func _kitDrainAudioCompletions() {
    guard !_kitAudioCompletions.isEmpty else { return }
    var pending: [(voice: Int32, handler: () -> Void)] = []
    for entry in _kitAudioCompletions {
        if snd_status(entry.voice) == 0 { entry.handler() }
        else { pending.append(entry) }
    }
    _kitAudioCompletions = pending
}

// Drives a presented SKScene from the kit's frame(dtMs): advances actions,
// calls scene.update, steps physics, renders the tree (flipping y-up to the
// Canvas y-down surface).
public class SKView: UIView {
    public private(set) var scene: SKScene?
    private var elapsed: TimeInterval = 0
    // Wall-clock accrued toward the next render. Seeded large so the first tick
    // after presentScene always draws; reset on each render. Lets the title
    // screen idle at 1 fps (preferredFramesPerSecond) without skipping startup.
    private var renderAccum: Double = 1e9

    // SKView debug/config knobs (Apple-faithful: the GAME sets these; the kit
    // honors the ones it can actually render). showsFPS + showsDrawCount drive
    // the runtime's HUD overlay (via dbg_set_overlays); showsPhysics strokes the
    // Box2D bodies in SKView.render. showsNodeCount/showsQuadCount/showsFields are
    // accepted so source drops in unchanged but have no kit data source yet, so
    // they're settable no-ops until the kit tracks those counts.
    public var showsFPS = false       { didSet { pushOverlayFlags() } }
    public var showsNodeCount = false
    public var showsPhysics = false
    public var showsDrawCount = false { didSet { pushOverlayFlags() } }
    public var showsFields = false
    public var showsQuadCount = false
    public var ignoresSiblingOrder = false
    public var allowsTransparency = false
    public var shouldCullNonVisibleNodes = true
    public var preferredFramesPerSecond: Int = 60
    public var isAsynchronous = true
    public var isPaused = false
    public var showsLargeContentViewer = false
    // `bounds`, `backgroundColor`, `isMultipleTouchEnabled`, `isOpaque`,
    // `clipsToBounds`, `isUserInteractionEnabled`, `drawHierarchy(...)` are
    // inherited from UIView so the unchanged `self.view as? SKView` path and the
    // view-property assignments in GameViewController/LevelUp compile + succeed.

    public override init() { super.init() }

    // Push the runtime HUD overlay flags whenever showsFPS/showsDrawCount change
    // (and once at presentScene). bit0 = showsFPS (FPS + frame ms), bit1 =
    // showsDrawCount (per-frame img/txt draw counts). The runtime composes the
    // HUD from the enabled bits and draws nothing when both are off.
    func pushOverlayFlags() {
        var f: Int32 = 0
        if showsFPS { f |= 1 }
        if showsDrawCount { f |= 2 }
        dbg_set_overlays(f)
    }

    public func presentScene(_ scene: SKScene?) {
        // Tear down the outgoing scene first (Apple calls willMove(from:) on
        // it). Without this a scene's teardown never runs — e.g. a per-scene
        // SoundManager's looping music voice lives in the runtime and outlives
        // the Swift object, so the next scene's music stacks on top of it.
        if let old = self.scene, old !== scene {
            old.willMove(from: self)
            old.view = nil
        }
        self.scene = scene
        SKScene._presented = scene   // fallback for SKNode.scene when a parent chain is incomplete
        renderAccum = 1e9   // draw the incoming scene on the very next tick
        pushOverlayFlags()  // sync the HUD overlay (showsFPS/showsDrawCount) to the runtime
        if let s = scene {
            s.view = self
            if !s._sceneDidLoadFired {
                s._sceneDidLoadFired = true
                s.sceneDidLoad()
            }
            s.didMove(to: self)
        }
    }

    // Transitioning between scenes — the transition itself is a no-op; we just
    // present the new scene immediately. Games using SKTransition keep their
    // call sites intact.
    public func presentScene(_ scene: SKScene, transition: SKTransition) {
        presentScene(scene)
    }

    // Snapshot a node subtree to an SKTexture. Renders the tree into an
    // offscreen canvas sized to the node's accumulated frame, then commits
    // it as an image asset the kit can re-draw via gfx_draw_image.
    public func texture(from node: SKNode) -> SKTexture? {
        let frame = node.calculateAccumulatedFrame()
        let w = max(1, Int(frame.width)), h = max(1, Int(frame.height))
        let handle = gfx_offscreen_begin(Int32(w), Int32(h))
        // Replicate the main render's y-up -> y-down flip (SKView.render does
        // translate(0,h)+scale(1,-1) before drawing the tree). Without it the
        // baked bitmap is vertically mirrored — invisible on symmetric content
        // (a dot) but it flips an asymmetric maze onto the wrong rows. Then
        // translate so the node's frame origin maps to the offscreen origin.
        gfx_save()
        gfx_translate(0, Float(h))
        gfx_scale(1, -1)
        gfx_translate(Float(-frame.minX), Float(-frame.minY))
        node.renderTree(parentAlpha: 1)
        gfx_restore()
        let img = gfx_offscreen_end_to_image(handle)
        if img <= 0 { return nil }
        let t = SKTexture(handle: img)
        t._size = CGSize(width: CGFloat(w), height: CGFloat(h))
        return t
    }
    public func texture(from node: SKNode, crop: CGRect) -> SKTexture? { texture(from: node) }

    // Fullscreen, forwarded to the host (Element.requestFullscreen / exitFullscreen
    // with the runtime's pseudo-fullscreen fallback). The Apple build supplies the
    // same two methods via an AppKit window-toggling SKView extension, so a game
    // calls view?.enterFullscreen() / exitFullscreen() with no platform branch.
    public func enterFullscreen() { win_request_fullscreen() }
    public func exitFullscreen()  { win_exit_fullscreen() }

    public func tick(_ dtMs: Double) {
        // Clamp the frame delta to one 60 Hz step. On the web a dropped frame,
        // GC pause, or tab refocus hands us a large delta that makes
        // SKAction-driven movement (Pete) lurch forward more than a step, while
        // the fixed-1/60 game logic (the bosses) does not — so only the hero
        // skips. Capping at 1/60 means Pete advances at most one frame per
        // render: real-time on a steady 60 Hz+ display, degrading to slow-mo
        // (never a jump) under sustained drops, in lockstep with the bosses.
        let dt = min(dtMs / 1000.0, 1.0 / 60.0)
        elapsed += dt
        SKSpriteNode._setKitClock(Float(elapsed))    // u_time for SKShader binds
        // Pump the run loop (Timer + DispatchQueue.main + per-frame hooks) BEFORE
        // the scene guard. The standard GameViewController idiom presents the
        // first scene from inside `DispatchQueue.main.async { view.presentScene }`;
        // if we returned early on a nil scene we'd never drain that queue and the
        // game would never start rendering. Draining first lets the deferred
        // presentScene take effect on the very next frame.
        KitRunLoop._tick(dt)
        _kitDrainAudioCompletions()
        guard let s = scene else { return }
        SKNode._cullRect = computeCullRect(s)   // valid for stepActions this frame (cam 1 frame stale, masked by margin)
        let hadInput = pollEvents(s)
        s.stepActions(dt)
        SKAudioNode.reapDetached()
        s.update(elapsed)
        s.physicsWorld.step(dt, scene: s)
        s.didSimulatePhysics()
        s.didFinishUpdate()
        // Render every frame at the display rate (>= 60) so motion stays smooth —
        // throttling there drops frames unevenly on ProMotion / variable-refresh
        // displays and makes Pete + bosses jitter. Only sub-60 scenes (the static
        // 1fps title, the 30fps editor) gate rendering; input forces a redraw so
        // clicks/toggles stay instant.
        let fps = max(1, preferredFramesPerSecond)
        renderAccum += dt
        if hadInput || fps >= 60 || renderAccum + 1e-9 >= 1.0 / Double(fps) {
            renderAccum = 0
            render(s)
        }
    }

    @discardableResult
    private func pollEvents(_ s: SKScene) -> Bool {
        // Drain the whole frame first so we can tell a TOUCH device (which the
        // runtime reports as BOTH a synthetic MouseButtonPressed AND a TouchBegan
        // for one finger-down: runtime.js touchstart pushes type 9 then type 19)
        // from a DESKTOP mouse (MouseButtonPressed only). Without this we
        // double-dispatch the iOS UITouch path on touch: case 9 and case 19 BOTH
        // call dispatchTouches(.began), so GameScene.touchesBegan -> laserbeak
        // fires twice per tap on mobile while once on desktop. Apple delivers
        // exactly one UITouch began per finger, so when ANY touch event is present
        // this frame the touch cases are authoritative and the mouse cases only
        // drive the AppKit mouseDown/Up/Moved hooks (no second dispatchTouches).
        // On desktop (no touch events) the mouse cases still synthesize the
        // UITouch path so the game's touchesBegan-only input works. Pre-scanning
        // is required because the synthetic mouse event (type 9) is enqueued
        // BEFORE the touch event (type 19) within one touchstart.
        var batch: [(Int32, Int32, Int32, Int32, Int32)] = []
        var type: Int32 = 0, a: Int32 = 0, b: Int32 = 0, c: Int32 = 0, d: Int32 = 0
        while evt_poll(&type, &a, &b, &c, &d) != 0 { batch.append((type, a, b, c, d)) }
        if batch.isEmpty { return false }
        let hasTouch = batch.contains { $0.0 == 19 || $0.0 == 20 || $0.0 == 21 }
        for (type, a, b, c, d) in batch {
            switch type {
            case 5:  s.keyDown(Int(a))
            case 6:  s.keyUp(Int(a))
            case 9:
                if a == 1 { s.rightMouseDown(at: scenePoint(b, c, s)) }
                else {
                    s.mouseDown(at: scenePoint(b, c, s), clickCount: max(1, Int(d)))
                    if !hasTouch { dispatchTouches(.began, at: worldPoint(b, c, s), to: s) }   // iOS-style touch path (desktop only)
                }
            case 10:
                if a == 1 { s.rightMouseUp(at: scenePoint(b, c, s)) }
                else {
                    s.mouseUp(at: scenePoint(b, c, s))
                    if !hasTouch { dispatchTouches(.ended, at: worldPoint(b, c, s), to: s) }
                }
            case 11:
                s.mouseMoved(to: scenePoint(a, b, s))
                if !hasTouch { dispatchTouches(.moved, at: worldPoint(a, b, s), to: s) }
            case 19:
                s.touchBegan(finger: Int(a), at: scenePoint(b, c, s))
                dispatchTouches(.began, at: worldPoint(b, c, s), to: s)
            case 20:
                s.touchMoved(finger: Int(a), at: scenePoint(b, c, s))
                dispatchTouches(.moved, at: worldPoint(b, c, s), to: s)
            case 21:
                s.touchEnded(finger: Int(a), at: scenePoint(b, c, s))
                dispatchTouches(.ended, at: worldPoint(b, c, s), to: s)
            default: break
            }
        }
        return true
    }

    // Bridge host pointer/touch events to the iOS UIResponder touch API. Many
    // ported games drive their UI from `touchesBegan(_:with:)` (UITouch) rather
    // than the AppKit mouseDown(with:) path — without this, taps on menu buttons
    // never reach the game. We synthesize a single UITouch carrying the resolved
    // scene-space point (so `touch.location(in: node)` returns it directly) and
    // hand it to the scene's touchesBegan/Moved/Ended.
    // The interaction-enabled node that captured the current touch sequence (the
    // joystick while you drag it). nil = the touch goes to the scene. SpriteKit
    // delivers an entire began→moved→ended sequence to the node hit on began.
    #if hasFeature(Embedded)
    private unowned(unsafe) var _capturedTouchNode: SKNode?
    #else
    private weak var _capturedTouchNode: SKNode?
    #endif

    private func dispatchTouches(_ phase: UITouchPhase, at world: CGPoint, to s: SKScene) {
        let t = UITouch()
        t.phase = phase
        t.view = self
        t._sceneLocation = world      // WORLD coords; UITouch.location(in:) converts per target node
        let set: Set<UITouch> = [t]
        let evt = UIEvent()
        switch phase {
        case .began:
            // Deepest interaction-enabled node under the touch captures it; an
            // un-overridden handler forwards up the responder chain to the scene
            // (so HUD fire taps still reach GameScene.touchesBegan via atPoint).
            let target = s.deepestInteractiveNode(at: world)
            _capturedTouchNode = target
            (target ?? s).touchesBegan(set, with: evt)
        case .moved:
            (_capturedTouchNode ?? s).touchesMoved(set, with: evt)
        case .ended, .cancelled:
            (_capturedTouchNode ?? s).touchesEnded(set, with: evt)
            _capturedTouchNode = nil
        default: break
        }
    }

    // Raw host pixel (y-down) -> WORLD/scene coords, camera-aware. Inverts the
    // render world pass: undo the screen-centre, camera zoom and camera position
    // so a touch maps to the same world point the nodes were drawn at. Falls back
    // to the anchor-based mapping when the scene has no camera.
    private func worldPoint(_ x: Int32, _ y: Int32, _ s: SKScene) -> CGPoint {
        let w = s.size.width, h = s.size.height
        if let cam = s.camera {
            let sx = cam.xScale == 0 ? 1 : cam.xScale
            let sy = cam.yScale == 0 ? 1 : cam.yScale
            return CGPoint(x: (CGFloat(x) - w/2) * sx + cam.position.x,
                           y: (h/2 - CGFloat(y)) * sy + cam.position.y)
        }
        let ax = s.anchorPoint.x, ay = s.anchorPoint.y
        return CGPoint(x: CGFloat(x) - ax * w, y: h - ay * h - CGFloat(y))
    }

    private func scenePoint(_ x: Int32, _ y: Int32, _ s: SKScene) -> CGPoint {
        // Runtime gives y-down logical px. Map to the scene's y-up space, honoring
        // the scene anchorPoint so a centred scene (anchor 0.5,0.5 — the menu)
        // hit-tests where it actually drew. Mirrors the anchor translate in
        // render(): scene origin sits at view (ax*w, h - ay*h).
        let w = s.size.width, h = s.size.height
        let ax = s.anchorPoint.x, ay = s.anchorPoint.y
        return CGPoint(x: CGFloat(x) - ax * w, y: h - ay * h - CGFloat(y))
    }

    // World-space viewport rect for frustum culling. Computed once at the top of
    // tick (so it's valid at stepActions time, using the previous frame's camera
    // position — one frame of staleness, masked by the 256px margin) and re-applied
    // idempotently by render(). Returns nil when shouldCullNonVisibleNodes is off.
    private func computeCullRect(_ s: SKScene) -> CGRect? {
        guard shouldCullNonVisibleNodes else { return nil }
        let margin: CGFloat = 256
        if let cam = s.camera {
            let sx = cam.xScale == 0 ? 1 : abs(cam.xScale)
            let sy = cam.yScale == 0 ? 1 : abs(cam.yScale)
            let vw = s.size.width * sx, vh = s.size.height * sy
            return CGRect(x: cam.position.x - vw/2 - margin,
                          y: cam.position.y - vh/2 - margin,
                          width: vw + margin*2, height: vh + margin*2)
        } else {
            return CGRect(x: -s.anchorPoint.x * s.size.width - margin,
                          y: -s.anchorPoint.y * s.size.height - margin,
                          width: s.size.width + margin*2,
                          height: s.size.height + margin*2)
        }
    }

    private func render(_ s: SKScene) {
        gfx_clear(s.backgroundColor.rgba)
        let cam = s.camera
        // Viewport in WORLD coords for the world pass — drawable leaves fully
        // outside are skipped (frustum culling). Generous margin so nothing pops
        // at the edge. Cleared before the screen-fixed HUD pass below.
        SKNode._cullRect = computeCullRect(s)   // idempotent: same value tick already set
        // World pass: under the camera's inverse so the scene appears as if shot
        // through its lens (cam.position centred, scaled/rotated by the inverse),
        // but SKIP the camera node's own subtree — its children are screen-fixed
        // UI drawn in the second pass.
        gfx_save()
        gfx_translate(0, Float(s.size.height))   // map world y-up -> screen y-down
        gfx_scale(1, -1)
        if let cam {
            gfx_translate(Float(s.size.width / 2), Float(s.size.height / 2))
            let sx = cam.xScale == 0 ? 1 : 1 / cam.xScale
            let sy = cam.yScale == 0 ? 1 : 1 / cam.yScale
            gfx_scale(Float(sx), Float(sy))
            if cam.zRotation != 0 { gfx_rotate(Float(cam.zRotation * 180.0 / Double.pi)) }
            gfx_translate(Float(-cam.position.x), Float(-cam.position.y))
            // Snap the world pass to whole device pixels so the zoomed board's
            // tile grid keeps a stable sub-pixel phase as it scrolls (kills the
            // background shimmer on low-DPR desktops) while staying full-res.
            if cam.zRotation == 0 { gfx_snap_translation() }
        }
        if cam != nil {
            s.renderWorld(skipping: cam, parentAlpha: 1)
        } else {
            // No camera: honor the scene anchorPoint so scene-space (0,0) lands
            // at the anchor fraction of the view (a 0.5,0.5 menu draws centred).
            // Matches the inverse mapping in scenePoint(). Camera scenes ignore
            // anchorPoint — the camera controls the viewport instead.
            if s.anchorPoint != .zero {
                gfx_translate(Float(s.anchorPoint.x * s.size.width),
                              Float(s.anchorPoint.y * s.size.height))
            }
            s.renderTree(parentAlpha: 1)
        }
        // Apple-style showsPhysics overlay: strokes every Box2D body's
        // outline on top of the scene. Lives inside the same y-up
        // transform so positions read straight from Box2D coordinates.
        if showsPhysics || s.physicsWorld.showsPhysics { s.physicsWorld.renderDebug() }
        gfx_restore()
        // Camera-children pass: screen-fixed overlays (HUD, PAUSED, joystick,
        // fire button, game-over). Same y-flip + scene-centring, but no zoom,
        // no camera rotation, no -cam.position — so they ignore the camera the
        // way SKCameraNode children do on native SpriteKit. World-space culling
        // must be OFF here (these draw in screen space, not world space).
        SKNode._cullRect = nil
        if let cam {
            gfx_save()
            gfx_translate(0, Float(s.size.height))
            gfx_scale(1, -1)
            gfx_translate(Float(s.size.width / 2), Float(s.size.height / 2))
            for c in cam.children.sorted(by: { $0.zPosition < $1.zPosition }) {
                c.renderTree(parentAlpha: cam.alpha)
            }
            gfx_restore()
        }
    }
}

