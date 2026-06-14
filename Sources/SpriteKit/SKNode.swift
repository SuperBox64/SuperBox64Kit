import KitABI

@inline(never) func _dbgLog(_ s: String) { withUTF8Ptr(s) { js_log($0, $1) } }

// SpriteKit node. World space is y-up (SpriteKit); the SKView root flips it onto
// the kit's y-down Canvas2D. Transforms map to gfx_save/translate/rotate/scale.
open class SKNode {
    public var position = CGPoint.zero
    public var zPosition: CGFloat = 0
    public var xScale: CGFloat = 1
    public var yScale: CGFloat = 1
    public var zRotation: CGFloat = 0       // radians, ccw-positive (SpriteKit)
    public var alpha: CGFloat = 1
    public var isHidden = false
    public var name: String?
    #if hasFeature(Embedded)
    public unowned(unsafe) var parent: SKNode?
    #else
    public weak var parent: SKNode?
    #endif
    public private(set) var children: [SKNode] = []

    public var userData: NSMutableDictionary? = nil
    public var physicsBody: SKPhysicsBody? {
        didSet {
            // Apple SpriteKit removes the old body from the simulation when
            // physicsBody is reassigned or set to nil. Mirror that: destroy
            // the previous Box2D body so it stops colliding and stops being
            // drawn by the showsPhysics overlay (the orphaned-fish bug).
            if oldValue !== physicsBody, let old = oldValue, old.bodyId >= 0 {
                B2.removeBody(old.bodyId)
                SKPhysicsWorld.registry.removeValue(forKey: old.bodyId)
                old.bodyId = -1
            }
            physicsBody?.node = self
        }
    }
    public var speed: CGFloat = 1
    public var isPaused = false
    public var constraints: [SKConstraint]? = nil  // applied after stepActions, before render

    public init() {}

    public func setScale(_ s: CGFloat) {
        xScale = s
        yScale = s
    }

    // Apple's NSCopying-style deep copy. Subclasses override to clone their own
    // state (SKSpriteNode below). Children are cloned recursively so
    // `node.copy() as! SKSpriteNode` returns an independent subtree.
    open func copy() -> SKNode {
        let n = SKNode()
        n.position = position; n.zPosition = zPosition; n.zRotation = zRotation
        n.xScale = xScale; n.yScale = yScale; n.alpha = alpha
        n.name = name; n.isHidden = isHidden; n.speed = speed
        for c in children { n.addChild(c.copy()) }
        return n
    }

    // iOS UIResponder touch surface. On Apple, SKNode: UIResponder; here we vend
    // the same overridable hooks so interactive nodes (GTFlightYoke, HUD fire
    // buttons, GameScene) keep their `override func touchesBegan(_:with:)` etc.
    // The scene's pollEvents synthesizes a UITouch and dispatches to these.
    // Default forwards the touch UP the responder chain (to the parent node),
    // exactly like UIResponder/SKNode on Apple. This is what lets an
    // interaction-enabled node that DOESN'T override the hook (the HUD fire
    // buttons) pass the touch on to the scene, whose touchesBegan dispatches via
    // atPoint(). The scene is the top SKNode responder (parent == nil), so the
    // walk terminates there — no infinite loop even when the scene's override
    // calls super.touchesBegan(...).
    open func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { parent?.touchesBegan(touches, with: event) }
    open func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { parent?.touchesMoved(touches, with: event) }
    open func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { parent?.touchesEnded(touches, with: event) }
    open func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { parent?.touchesCancelled(touches, with: event) }

    open func addChild(_ node: SKNode) {
        node.parent = self
        children.append(node)
    }
    public func insertChild(_ node: SKNode, at index: Int) {
        node.parent = self
        children.insert(node, at: max(0, min(index, children.count)))
    }
    deinit {
        // Children can outlive this node when the game holds direct
        // references (AsteroidZ keeps its flame nodes across respawns). Under
        // Embedded, parent is unowned(unsafe), so a destroyed parent must
        // clear the back-pointers or a later removeFromParent walks freed
        // memory. The body's node pointer dangles the same way.
        // Nonisolated kit on single-threaded wasm — clean up directly.
        for c in children { c.parent = nil }
        physicsBody?.node = nil
    }

    open func removeFromParent() {
        guard let p = parent else { return }
        p.children.removeAll { $0 === self }
        parent = nil
        teardownPhysics()
    }
    public func removeAllChildren() {
        for c in children {
            c.parent = nil
            c.teardownPhysics()
        }
        children.removeAll()
    }

    // Apple SpriteKit destroys a node's physics body when the node leaves the
    // scene. SuperBox64 has to do it explicitly: drop the Box2D body and its
    // registry entry for this node and every descendant, so a removed node's
    // body stops colliding and stops being drawn by the showsPhysics overlay.
    // bodyId is reset to -1 so the body is recreated if the node is re-added.
    @usableFromInline
    func teardownPhysics() {
        if let b = physicsBody, b.bodyId >= 0 {
            B2.removeBody(b.bodyId)
            SKPhysicsWorld.registry.removeValue(forKey: b.bodyId)
            b.bodyId = -1
        }
        for c in children { c.teardownPhysics() }
    }
    public func childNode(withName name: String) -> SKNode? {
        // Apple's "//name" prefix = recursive descendant search (GameWorld uses it
        // to find SKTileMapNode layers nested under a reference node's scene).
        if name.hasPrefix("//") {
            return descendantNamed(String(name.dropFirst(2)))
        }
        return children.first { $0.name == name }
    }
    private func descendantNamed(_ name: String) -> SKNode? {
        for c in children {
            if c.name == name { return c }
            if let found = c.descendantNamed(name) { return found }
        }
        return nil
    }
    public func contains(_ node: SKNode) -> Bool { children.contains { $0 === node } }

    // Swift-friendly enumeration over children (and descendants) matching a name.
    // The block can set `stop = true` to short-circuit.
    public func enumerateChildNodes(withName name: String, using block: (SKNode, inout Bool) -> Void) {
        var stop = false
        enumerateImpl(withName: name, stop: &stop, using: block)
    }
    private func enumerateImpl(withName name: String, stop: inout Bool,
                               using block: (SKNode, inout Bool) -> Void) {
        for c in children {
            if stop { return }
            if c.name == name {
                block(c, &stop)
                if stop { return }
            }
            c.enumerateImpl(withName: name, stop: &stop, using: block)
        }
    }

    public var scene: SKScene? {
        return (self as? SKScene) ?? parent?.scene
    }

    public var isUserInteractionEnabled = false

    // Apple's SKNode.frame is the node's content bounds in *parent* space.
    // For our shim a sensible default is "zero-sized at position"; subclasses
    // (SKSpriteNode, SKShapeNode, SKLabelNode) override to report real bounds.
    open var frame: CGRect { CGRect(x: position.x, y: position.y, width: 0, height: 0) }

    // Union frame across self + every descendant — used for hit-testing whole
    // subtrees and for camera/scroll bounds.
    public func calculateAccumulatedFrame() -> CGRect {
        var r = self.frame
        for c in children {
            let cf = c.calculateAccumulatedFrame()
            // c.calculateAccumulatedFrame() is already in SELF's coordinate
            // space (it folds in c.position via c.frame). Lift it into our
            // PARENT's space by adding OUR position — adding c.position here
            // double-counted it, which collapsed/offset the frame for any
            // subtree whose children sit far from the origin (e.g. baking the
            // maze via SKView.texture(from:)).
            let off = CGRect(x: cf.minX + position.x, y: cf.minY + position.y,
                             width: cf.width, height: cf.height)
            if r == .zero {
                r = off
                continue
            }
            let minX = min(r.minX, off.minX), minY = min(r.minY, off.minY)
            let maxX = max(r.maxX, off.maxX), maxY = max(r.maxY, off.maxY)
            r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        return r
    }

    public func inParentHierarchy(_ candidate: SKNode) -> Bool {
        var n: SKNode? = self.parent
        while let p = n {
            if p === candidate { return true }
            n = p.parent
        }
        return false
    }

    public func move(toParent newParent: SKNode) {
        let world = absolutePosition()
        removeFromParent()
        newParent.addChild(self)
        self.position = CGPoint(x: world.x - newParent.absolutePosition().x,
                                y: world.y - newParent.absolutePosition().y)
    }
    public func removeChildren(in nodes: [SKNode]) {
        for n in nodes where n.parent === self { n.removeFromParent() }
    }
    public func removeAllActions(in nodes: [SKNode]) {
        for n in nodes { n.removeAllActions() }
    }

    // Hit-testing in *this* node's coordinate space. Walks descendants and
    // returns nodes whose accumulated frame contains the point. Top-most
    // (deepest, highest zPosition) wins.
    public func atPoint(_ p: CGPoint) -> SKNode {
        nodes(at: p).first ?? self
    }
    public func nodes(at p: CGPoint) -> [SKNode] {
        // `p` is in THIS node's coordinate space. A child's `frame` is in this
        // same (parent) space, so test it against `p` directly; only convert into
        // the child's LOCAL space when descending to ITS children. The old code
        // subtracted c.position AND tested c.frame (which already includes
        // c.position), double-counting position so any off-origin node (menu
        // arrows, rotated fire HUD) never hit. Nodes at local (0,0) (the joystick
        // backgroundNode/thumbNode) hit under both versions, so capture is kept.
        var hits: [SKNode] = []
        collectNodes(at: p, into: &hits)
        // Frontmost first, like SpriteKit's atPoint: higher zPosition wins; for
        // EQUAL zPosition the LATER-collected node (later in the tree = drawn on
        // top) wins. The fire HUD stacks fire-* over hud-* at the same z; the
        // game checks atPoint(...).name == "fire-*", so the last-drawn fire-*
        // must come first, not whatever node happened to be collected earliest.
        return hits.enumerated()
            .sorted { a, b in
                a.element.zPosition != b.element.zPosition
                    ? a.element.zPosition > b.element.zPosition
                    : a.offset > b.offset
            }
            .map { $0.element }
    }
    private func collectNodes(at p: CGPoint, into hits: inout [SKNode]) {
        for c in children {
            if c.frame.contains(p) { hits.append(c) }
            c.collectNodes(at: c._pointFromParent(p), into: &hits)
        }
    }

    // Convert a point from this node's PARENT coordinate space into this node's
    // LOCAL space — the inverse of the node's transform (translate · rotate ·
    // scale). nodes(at:)/hit-testing recurse with this so a rotated/scaled node
    // (the π/4 fire HUD) hit-tests where it actually drew, not where an
    // axis-aligned box would be.
    func _pointFromParent(_ p: CGPoint) -> CGPoint {
        var q = CGPoint(x: p.x - position.x, y: p.y - position.y)
        if zRotation != 0 {
            let cs = cos(-zRotation), sn = sin(-zRotation)
            q = CGPoint(x: q.x * cs - q.y * sn, y: q.x * sn + q.y * cs)
        }
        if xScale != 0, xScale != 1 { q.x /= xScale }
        if yScale != 0, yScale != 1 { q.y /= yScale }
        return q
    }

    // True if `ancestor` is somewhere above this node in the tree.
    func isUnder(_ ancestor: SKNode) -> Bool {
        var n: SKNode? = parent
        while let cur = n { if cur === ancestor { return true }; n = cur.parent }
        return false
    }

    // Convert a SCENE/WORLD-space point into this node's local space, honoring
    // the SKCameraNode quirk: a camera's children are screen-fixed (the render
    // ignores cam.position for them), so for a node under the camera we strip the
    // camera offset (world − cam.position) and then apply the inverse transforms
    // of every node from the camera's direct child down to self. Used by
    // UITouch.location(in:) so `touch.location(in: joystick)` returns the
    // joystick-local offset the stick math expects.
    func convertFromWorld(_ world: CGPoint) -> CGPoint {
        if self is SKScene { return world }
        // chain: self up to (not including) the scene, then reversed to top-down.
        var chain: [SKNode] = []
        var n: SKNode? = self
        while let cur = n, !(cur is SKScene) { chain.append(cur); n = cur.parent }
        chain.reverse()
        var p = world
        var start = 0
        if let cam = scene?.camera, isUnder(cam) || self === cam {
            p = CGPoint(x: world.x - cam.position.x, y: world.y - cam.position.y)
            if let ci = chain.firstIndex(where: { $0 === cam }) { start = ci + 1 }
        }
        for i in start..<chain.count { p = chain[i]._pointFromParent(p) }
        return p
    }

    // Apple's hit-testing for touch delivery: find the deepest VISUAL node under
    // the world point, then walk UP to the first interaction-enabled ancestor
    // (a node with isUserInteractionEnabled but a zero own-frame — GTFlightYoke —
    // still receives the touch via its child's hit). Returns nil when nothing
    // interactive is hit, so the caller falls back to the scene.
    func deepestInteractiveNode(at world: CGPoint) -> SKNode? {
        let p = (self is SKScene) ? world : convertFromWorld(world)
        let hits = nodes(at: p)
        // DEBUG: dump what's under the pointer so we can see why the joystick/fire
        // are or aren't captured.
        var dbg = ""
        for h in hits.prefix(8) { dbg += (h.name ?? "?") + "(z\(Int(h.zPosition)),i\(h.isUserInteractionEnabled ? 1 : 0)) " }
        _dbgLog("hits@\(Int(p.x)),\(Int(p.y)): \(dbg)")
        // Walk UP from EACH hit (top-z first) to the first interaction-enabled
        // ancestor. The old code only walked up from hits.first, so if the
        // top-z node under the pointer was non-interactive (a tile/overlay) it
        // returned nil even though the joystick/HUD button was also hit lower in
        // the z-order — that was the cap=nil joystick/fire failure.
        for hit in hits {
            var cur: SKNode? = hit
            while let c = cur {
                if c.isUserInteractionEnabled && !(c is SKScene) { return c }
                cur = c.parent
            }
        }
        return nil
    }
    public func intersects(_ other: SKNode) -> Bool {
        frame.intersects(other.frame)
    }

    // ---- rendering ----
    func draw(alpha: CGFloat) {}   // overridden by leaf nodes

    // Viewport (world space) the world pass is allowed to draw in. Set by
    // SKView.render before the world pass and cleared (nil) for the screen-fixed
    // camera-children pass and for offscreen texture bakes. When non-nil, a
    // drawable leaf whose world AABB falls entirely outside is skipped — this is
    // what stops a wide side-scroller from drawing the ENTIRE level every frame
    // (the difference between single-digit and full fps once actors spread out).
    nonisolated(unsafe) static var _cullRect: CGRect? = nil
    // Half-extent of this node's own drawable content, for cheap culling without
    // measuring. 0 = never cull this node (containers/shapes always draw).
    var _cullExtent: CGFloat { 0 }

    func renderTree(parentAlpha: CGFloat, worldX: CGFloat = 0, worldY: CGFloat = 0) {
        if isHidden || alpha <= 0 { return }
        let eff = parentAlpha * alpha
        // World coord of this node's origin (approximate: ignores ancestor
        // rotation/scale, which is fine for the non-rotated world layers we cull;
        // the rotated HUD draws in the camera pass with culling off).
        let wx = worldX + position.x, wy = worldY + position.y
        gfx_save()
        gfx_translate(Float(position.x), Float(position.y))
        // We're rendering inside the SKView's outer scale(1,-1) Y-flip, so
        // Canvas2D's positive-rotate-clockwise convention appears as CCW on
        // Positive zRotation passes through; the runtime's y-up transform keeps
        // SpriteKit's counter-clockwise convention, and the motion math in the
        // games (thrust/bullet vectors from sin/cos of zRotation) agrees with
        // the rendered heading only with the sign unchanged.
        if zRotation != 0 { gfx_rotate(Float(zRotation * 180.0 / Double.pi)) }
        if xScale != 1 || yScale != 1 { gfx_scale(Float(xScale), Float(yScale)) }
        // Cull this node's own draw if it's a sizable leaf fully off-screen.
        var doDraw = true
        if let cull = SKNode._cullRect {
            let ext = _cullExtent
            if ext > 0 {
                let r = CGRect(x: wx - ext, y: wy - ext, width: ext * 2, height: ext * 2)
                if !r.intersects(cull) { doDraw = false }
            }
        }
        if doDraw { draw(alpha: eff) }
        // Hidden children no-op in their own renderTree anyway; dropping them
        // BEFORE the z-sort keeps the per-frame sort at the visible count (a 3D
        // scene pools hundreds of hidden billboards under one layer).
        if children.count > 1 {
            var vis: [SKNode] = []
            vis.reserveCapacity(children.count)
            for c in children where !c.isHidden && c.alpha > 0 { vis.append(c) }
            if vis.count > 1 { vis.sort { $0.zPosition < $1.zPosition } }
            for c in vis { c.renderTree(parentAlpha: eff, worldX: wx, worldY: wy) }
        } else {
            for c in children { c.renderTree(parentAlpha: eff, worldX: wx, worldY: wy) }
        }
        gfx_restore()
    }

    // ---- actions (implemented in SKAction.swift) ----
    var runningActions: [RunningAction] = []
    public func run(_ action: SKAction) { runningActions.append(RunningAction(action)) }
    public func run(_ action: SKAction, withKey key: String) {
        runningActions.removeAll { $0.key == key }
        let r = RunningAction(action)
        r.key = key
        runningActions.append(r)
    }
    public func removeAllActions() { runningActions.removeAll() }
    public func removeAction(forKey key: String) { runningActions.removeAll { $0.key == key } }
    public func action(forKey key: String) -> SKAction? { runningActions.first { $0.key == key }?.action }
    public func hasActions() -> Bool { !runningActions.isEmpty }

    final func stepActions(_ dt: CGFloat) {
        // Apple's SKAudioNode autoplays once it lives in the active tree;
        // the per-frame walk is where the framework knows both facts.
        if let audio = self as? SKAudioNode { audio.autoplayTick() }
        if isPaused { return }                       // halt this subtree
        let scaled = dt * speed                      // SKNode.speed scales time per subtree
        // Step every action ONCE this frame, including actions started mid-frame
        // by a .run block (e.g. WorkerController's chained tile move via
        // run(_:withKey:), which removeAll's the finishing action and appends a
        // new one). Stepping the new action the same frame avoids a 1-frame
        // stall per tile (which would slow a self-chaining mover to boss speed).
        // `stepped` bounds each action to one step/frame; finished actions are
        // removed BY IDENTITY since the array can mutate during a step.
        var stepped = Set<ObjectIdentifier>()
        var i = 0
        while i < runningActions.count {
            let ra = runningActions[i]
            guard stepped.insert(ObjectIdentifier(ra)).inserted else {
                i += 1
                continue
            }
            if ra.step(scaled, node: self) {
                if let idx = runningActions.firstIndex(where: { $0 === ra }) {
                    runningActions.remove(at: idx)
                }
            } else {
                i += 1
            }
        }
        tickSelf(TimeInterval(scaled))
        if let cs = constraints {                    // post-action constraint pass
            for c in cs { c.apply(to: self) }
        }
        for c in children { c.stepActions(scaled) }
    }

    // Per-frame update hook for nodes that animate themselves (e.g. SKEmitterNode).
    // Default is a no-op; overridden by node types that need to advance state.
    open func tickSelf(_ dt: TimeInterval) {}
}



// Apple's SKNode inherits NSObject identity equality; games rely on it for
// array firstIndex(of:) and friends.
extension SKNode: Equatable {
    public static func == (lhs: SKNode, rhs: SKNode) -> Bool { lhs === rhs }
}
