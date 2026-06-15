import KitABI
import CBox2D

// Physics on Box2D v3 (the C API, called directly via the B2 backend in
// B2World.swift). SpriteKit points are used directly as Box2D coordinates
// (y-up, same as the scene). Dynamic bodies
// are driven by the simulation and sync back to their SKNode each step; bodies
// the game drives by velocity push that velocity in before stepping.
public protocol SKPhysicsContactDelegate: AnyObject {
    func didBegin(_ contact: SKPhysicsContact)
    func didEnd(_ contact: SKPhysicsContact)
}
public extension SKPhysicsContactDelegate {
    func didBegin(_ contact: SKPhysicsContact) {}
    func didEnd(_ contact: SKPhysicsContact) {}
}

public final class SKPhysicsContact {
    public let bodyA: SKPhysicsBody
    public let bodyB: SKPhysicsBody
    public var contactPoint: CGPoint = .zero
    public var contactNormal: CGVector = .zero
    public var collisionImpulse: CGFloat = 0
    init(_ a: SKPhysicsBody, _ b: SKPhysicsBody) {
        bodyA = a
        bodyB = b
    }
}

public final class SKPhysicsBody {
    public var categoryBitMask: UInt32 = 0xFFFFFFFF {
        didSet { if bodyId >= 0, categoryBitMask != oldValue { syncFilter() } }
    }
    public var contactTestBitMask: UInt32 = 0   // contactTest is re-applied in the drain; no Box2D filter change
    public var collisionBitMask: UInt32 = 0xFFFFFFFF {
        didSet { if bodyId >= 0, collisionBitMask != oldValue { syncFilter() } }
    }
    public var isDynamic = true {
        didSet {
            if bodyId >= 0, isDynamic != oldValue {
                // Flip the Box2D body type, not just the filter — a laser-struck
                // tile is set isDynamic=true so it spins in the air; without this it
                // stayed static and the impulse/torque/angularVelocity did nothing.
                B2.setBodyType(bodyId, isDynamic)
                if isDynamic {
                    // A newly-dynamic body needs positive mass + rotational inertia
                    // to respond to applyImpulse/applyTorque/angularVelocity.
                    let m = max(0.01, massExplicit ? mass : CGFloat(appleAreaPts2() / 22500.0))
                    B2.setMass(bodyId, Float(m), Float(boundingRadius()))
                }
                syncFilter()
            }
        }
    }
    public var affectedByGravity = true
    public var allowsRotation = true
    // 1:1 with SpriteKit: velocity is points/s and (since 150 pts/m) the on-screen
    // speed IS the Box2D velocity, so any multiplier scales screen speed (the
    // getter divides it back out so reads round-trip). SpriteKit has no hidden
    // gain → must be 1.0 (was 1.5, which made everything 1.5× too fast).
    static let appleVelocityScale: CGFloat = 1.0

    var _velocity = CGVector.zero
    public var velocity: CGVector {
        get {
            // Read-after-write within a frame must return the pending value, not
            // the stale Box2D velocity from last step. The joystick relies on
            // this: FlightYokePilot sets velocity, then does
            // `applyImpulse(...)` and `velocity.dx = clamp(velocity.dx)` — a
            // read-modify-write. If the getter returned Box2D's not-yet-updated
            // velocity (≈0 before the step flush), the clamp wrote ≈0 back and
            // the ship never moved. Honor the dirty pending value first.
            if velocityDirty { return _velocity }
            if bodyId >= 0 {
                let (vx, vy) = B2.getVelocity(bodyId)
                return CGVector(dx: CGFloat(vx) / Self.appleVelocityScale,
                                dy: CGFloat(vy) / Self.appleVelocityScale)
            }
            return _velocity
        }
        set {
            _velocity = newValue
            velocityDirty = true
        }
    }
    public var linearDamping: CGFloat = 0.1 {
        didSet { if bodyId >= 0 { B2.setLinearDamping(bodyId, Float(linearDamping)) } }
    }
    public var friction: CGFloat = 0.2
    public var restitution: CGFloat = 0.2
    public var mass: CGFloat = 1 { didSet { massExplicit = true } }
    var massExplicit = false
    public var isSensor = false {
        didSet { if bodyId >= 0, isSensor != oldValue { syncFilter() } }
    }
    public var usesPreciseCollisionDetection = false   // no-op: Box2D continuous detection
    public var fieldBitMask: UInt32 = 0xFFFFFFFF       // no-op: SKFieldNode not yet implemented
    public var pinned = false                          // no-op
    public var isResting = false                       // no-op (single-threaded; not simulated)
    public var density: CGFloat = 1                    // no-op (mass drives the body)
    public var angularDamping: CGFloat = 0.1           // no-op
    public var angularVelocity: CGFloat = 0 { didSet { angularDirty = true } }
    public var charge: CGFloat = 0                     // no-op (SKFieldNode interaction)
    public var resting: Bool = false                   // no-op
    public var area: CGFloat { 0 }                     // computed by shape; cheap to leave at 0

    #if hasFeature(Embedded)
    public internal(set) unowned(unsafe) var node: SKNode?
    #else
    public internal(set) weak var node: SKNode?
    #endif
    var bodyId: Int32 = -1
    var velocityDirty = false
    var angularDirty = false

    enum Shape {
        case rect(CGFloat, CGFloat)
        case circle(CGFloat)
        case edgeLoop(CGRect)
        case polygon([CGPoint])
        case edgeFromTo(CGPoint, CGPoint)
        case edgeChain([CGPoint])
        case texture(CGSize)            // pixel-perfect init falls back to rect of `size`
    }
    let shape: Shape

    // No-arg init — Apple allows `SKPhysicsBody()` (a placeholder body the game
    // assigns to a node and then configures). Defaults to a unit rectangle.
    public init() { shape = .rect(1, 1) }
    public init(rectangleOf size: CGSize) { shape = .rect(size.width, size.height) }
    public init(rectangleOf size: CGSize, center: CGPoint) { shape = .rect(size.width, size.height) }
    public init(circleOfRadius r: CGFloat) { shape = .circle(r) }
    public init(circleOfRadius r: CGFloat, center: CGPoint) { shape = .circle(r) }
    public init(edgeLoopFrom rect: CGRect) {
        shape = .edgeLoop(rect)
        isDynamic = false
    }
    public init(edgeLoopFrom path: CGPath) {
        let pts = path.flattenedPoints
        shape = .edgeChain(pts.isEmpty ? [.zero, .zero] : pts)
        isDynamic = false
    }
    public init(edgeChainFrom path: CGPath) {
        shape = .edgeChain(path.flattenedPoints)
        isDynamic = false
    }
    public init(edgeFrom a: CGPoint, to b: CGPoint) {
        shape = .edgeFromTo(a, b)
        isDynamic = false
    }
    public init(polygonFrom path: CGPath) { shape = .polygon(path.flattenedPoints) }
    // Pixel-perfect init: ask the runtime to trace the texture's alpha
    // boundary (img_polygon_from_alpha runs marching-squares + RDP simplify in
    // the JS side). If tracing fails or returns fewer than 3 points (e.g. the
    // texture isn't loaded yet, or its host blocks getImageData), fall back to
    // a rectangle of the requested size.
    public init(texture: SKTexture, size: CGSize) {
        if let poly = SKPhysicsBody.polygonFromAlpha(texture: texture, threshold: 0.0, fit: size) {
            shape = .polygon(poly)
        } else {
            shape = .texture(size)
        }
    }
    public init(texture: SKTexture, alphaThreshold: Float, size: CGSize) {
        if let poly = SKPhysicsBody.polygonFromAlpha(texture: texture, threshold: alphaThreshold, fit: size) {
            shape = .polygon(poly)
        } else {
            shape = .texture(size)
        }
    }

    // Pulls up to 64 polygon points from the texture's alpha channel through
    // the kit ABI, then scales them to fit `size` (centered on origin). Returns
    // nil when the trace yields < 3 points (image hasn't loaded, blocked by
    // CORS getImageData, etc.); the caller falls back to a rect body.
    private static func polygonFromAlpha(texture: SKTexture, threshold: Float, fit size: CGSize) -> [CGPoint]? {
        var buf = [Float](repeating: 0, count: 64 * 2)
        let n = Int(buf.withUnsafeMutableBufferPointer { ptr in
            img_polygon_from_alpha(texture.handle, threshold, ptr.baseAddress, Int32(64))
        })
        if n < 3 { return nil }
        // The runtime returns centered, y-up coordinates in pixels; rescale to
        // the requested body size.
        var minX = Float.infinity, maxX = -Float.infinity, minY = Float.infinity, maxY = -Float.infinity
        for i in 0..<n {
            let x = buf[i*2], y = buf[i*2+1]
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
        let rangeX = max(maxX - minX, 0.0001), rangeY = max(maxY - minY, 0.0001)
        let sx = Float(size.width)  / rangeX
        let sy = Float(size.height) / rangeY
        var out: [CGPoint] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            out.append(CGPoint(x: CGFloat(buf[i*2] * sx), y: CGFloat(buf[i*2+1] * sy)))
        }
        return out
    }
    public init(bodies: [SKPhysicsBody]) { shape = .rect(0, 0) }   // compound bodies: stub
    // Internal shape-passthrough init so _clone() can faithfully reproduce
    // polygon/edge-chain bodies (whose payload can't be reconstructed from a
    // public initializer without re-flattening a path).
    init(_shape s: Shape) { shape = s; if case .edgeChain = s { isDynamic = false } }

    public func applyImpulse(_ v: CGVector) { velocity = CGVector(dx: velocity.dx + v.dx, dy: velocity.dy + v.dy) }
    public func applyImpulse(_ v: CGVector, at point: CGPoint) { applyImpulse(v) }
    public func applyForce(_ v: CGVector) { B2.applyForce(bodyId, Float(v.dx), Float(v.dy)) }
    public func applyForce(_ v: CGVector, at point: CGPoint) { applyForce(v) }
    public func applyTorque(_ t: CGFloat) { B2.applyTorque(bodyId, Float(t)) }
    public func applyAngularImpulse(_ i: CGFloat) { B2.applyAngularImpulse(bodyId, Float(i)) }

    // Reconstruct the same shape this body was built from. Used by _clone()
    // (which can't see the private `shape` enum's payload through a copy of the
    // struct value alone, and must rebuild via the matching initializer so the
    // new body gets its own Box2D body on the next createInWorld()).
    private func _rebuildSameShape() -> SKPhysicsBody {
        switch shape {
        case let .texture(sz): return SKPhysicsBody(rectangleOf: sz)   // map texture-shape -> rect
        default:               return SKPhysicsBody(_shape: shape)     // rect/circle/edge/polygon: reuse payload
        }
    }

    // Apple's SKPhysicsBody is NSCopying. SKNode.copy()/SKSpriteNode.copy() must
    // clone the body so a duplicated node (laserDupe / DaBomb in UFO Emoji) gets
    // its OWN simulated body — otherwise the copy has no physicsBody, never gets
    // a Box2D body, never moves, and the projectile is invisible/frozen. bodyId
    // is left at -1 so createBodies() builds a brand-new Box2D body for the copy.
    func _clone() -> SKPhysicsBody {
        let b = _rebuildSameShape()
        b.categoryBitMask = categoryBitMask
        b.contactTestBitMask = contactTestBitMask
        b.collisionBitMask = collisionBitMask
        b.isDynamic = isDynamic
        b.affectedByGravity = affectedByGravity
        b.allowsRotation = allowsRotation
        b.linearDamping = linearDamping
        b.angularDamping = angularDamping
        b.friction = friction
        b.restitution = restitution
        b.density = density
        b.fieldBitMask = fieldBitMask
        b.isSensor = isSensor
        b.usesPreciseCollisionDetection = usesPreciseCollisionDetection
        if massExplicit { b.mass = mass }
        // Carry the pending (not-yet-flushed) velocity so the copy launches with
        // the same impulse the game set on the original before copying it.
        b._velocity = velocityDirty ? _velocity : velocity
        b.velocityDirty = true
        b.angularVelocity = angularVelocity
        b.angularDirty = angularVelocity != 0
        return b
    }

    // Returns the set of bodies currently in contact with this one. The Box2D
    // shim doesn't expose a continuous contact list yet, so we filter the
    // global registry by node proximity; good enough for game-level checks.
    public func allContactedBodies() -> [SKPhysicsBody] {
        guard let n = node else { return [] }
        return SKPhysicsWorld.registry.values.filter { other in
            guard other !== self, let on = other.node else { return false }
            let dx = n.position.x - on.position.x, dy = n.position.y - on.position.y
            return (dx*dx + dy*dy) < 4096   // ~64px radius rough cull
        }
    }

    func createInWorld() {
        guard bodyId < 0, let n = node else { return }
        // Spawn at the node's ABSOLUTE scene position (see the per-frame transform
        // push in SKPhysics.step): a body under a moving parent — e.g. UFO Emoji's
        // camera-tracked laserBorder — must enter the flat Box2D world where it
        // actually is, not at its parent-local offset.
        let ap = n.absolutePosition()
        let x = Float(ap.x), y = Float(ap.y)
        let cat = categoryBitMask
        // Apple SpriteKit has two independent filters: collisionBitMask gates
        // physical bounce, contactTestBitMask gates the didBegin callback (OR'd
        // either way). Box2D has a single category/mask filter (two-way AND)
        // that gates BOTH response AND contact generation — so a body with
        // collisionBitMask 0 (Apple's "pass through but still notify me") would
        // be invisible to Box2D contact detection. Feed Box2D the UNION so the
        // pair is generated for either purpose, then mark contact-only bodies
        // (no collision intent) as sensors so they generate the event with no
        // impulse. The post-step drain re-applies Apple's contactTest OR.
        let dyn = isDynamic
        // SpriteKit collisionBitMask is one-way; Box2D's is two-way AND. A static
        // body never moves, so letting it accept every collision makes the
        // dynamic body's own collisionMask the sole decider — matching SpriteKit
        // for dynamic-vs-static (platforms/walls). A collisionMask==0 STATIC body
        // is solid IFF it's a pure wall (the world edge loop, contactTest==0);
        // only a dynamic collisionMask==0 body is otherwise approximated as a sensor.
        let mask = dyn ? collisionBitMask : UInt32(0xFFFFFFFF)
        // Apple's collisionBitMask==0 means "never impart a bounce." A STATIC
        // collisionMask==0 body that ALSO opts into contact callbacks
        // (contactTestBitMask != 0) is a pure DETECTOR volume — Apple removes the
        // laser at the boundary via the contact callback and never bounces it.
        // UFO Emoji's laserBorder is exactly this (collision 0, contactTest laserbeam):
        // making it a Box2D sensor lets the laser fly through and be removed by the
        // didBegin handler, instead of the solid edge stopping/bouncing it (a fast
        // laser, 750 + hero speed up to 1250 pt/s, defeated the restitutionThreshold
        // hack). A static collisionMask==0 body with NO contactTest (the world
        // gameBounds wall) stays SOLID so the hero is still contained one-way.
        let staticDetector = !dyn && collisionBitMask == 0 && contactTestBitMask != 0
        let sensor = isSensor || (collisionBitMask == 0 && dyn) || staticDetector
        // Apple honors these per body; hand them to the next B2 creation.
        B2.pendingProps = B2.BodyProps(friction: Float(friction),
                                       restitution: Float(restitution),
                                       linearDamping: Float(linearDamping),
                                       angularDamping: Float(angularDamping),
                                       gravityScale: affectedByGravity ? 1 : 0)
        switch shape {
        case let .rect(w, h): bodyId = B2.addBox(x, y, max(Float(w/2), 0.5), max(Float(h/2), 0.5), dyn, cat, mask, sensor)
        case let .circle(r):  bodyId = B2.addCircle(x, y, Float(r), dyn, cat, mask, sensor)
        case let .edgeLoop(rc):
            // Closed-loop chain of the rect's four corners (static).
            let pts: [CGPoint] = [
                CGPoint(x: rc.minX, y: rc.minY), CGPoint(x: rc.maxX, y: rc.minY),
                CGPoint(x: rc.maxX, y: rc.maxY), CGPoint(x: rc.minX, y: rc.maxY),
            ]
            if dyn {
                bodyId = B2.addBox(x + Float(rc.midX), y + Float(rc.midY),
                                   Float(rc.width/2), Float(rc.height/2), dyn, cat, mask, sensor)
            } else {
                bodyId = B2.addChain(flatXY(pts), closed: true, dyn, cat, mask, sensor)
            }
        case let .polygon(pts):
            // Real convex polygon (Box2D enforces convexity and caps the vertex
            // count). Falls back to AABB on degenerate inputs.
            if pts.count >= 3 {
                bodyId = B2.addPolygon(x, y, flatXY(pts), dyn, cat, mask, sensor)
            }
            if bodyId < 0 {
                let r = boundingBox(of: pts)
                bodyId = B2.addBox(x + Float(r.midX), y + Float(r.midY),
                                   Float(r.width/2), Float(r.height/2), dyn, cat, mask, sensor)
            }
        case let .edgeFromTo(a, b):
            bodyId = B2.addEdge(Float(a.x), Float(a.y), Float(b.x), Float(b.y), cat, mask)
        case let .edgeChain(pts):
            // Apple lets a game flip an edge-loop body dynamic afterward (the
            // AsteroidZ fragment pattern). Massless segment bodies don't
            // integrate in Box2D v3, so a dynamic outline becomes its convex
            // hull: proper mass, same velocity-driven flight and contacts.
            if dyn, pts.count >= 3 {
                bodyId = B2.addPolygon(x, y, flatXY(pts), dyn, cat, mask, sensor)
                if bodyId < 0 {
                    let r = boundingBox(of: pts)
                    bodyId = B2.addBox(x + Float(r.midX), y + Float(r.midY),
                                       Float(r.width/2), Float(r.height/2), dyn, cat, mask, sensor)
                }
            } else {
                bodyId = B2.addChain(flatXY(pts), closed: false, dyn, cat, mask, sensor)
            }
        case let .texture(size):
            bodyId = B2.addBox(x, y, Float(size.width/2), Float(size.height/2), dyn, cat, mask, sensor)
        }
        // Apple's default mass is density * area at 150 points per meter; v3
        // sensor shapes contribute no mass, so without this a sensor-only ship
        // sits at the 1kg fallback and applyForce barely moves it.
        if bodyId >= 0, dyn {
            // Box2D v3: a DYNAMIC body with zero mass is physically undefined and
            // its position is NOT integrated from linear velocity — so the laser
            // (mass 0, density 0, velocity 750) just sat at its spawn, piling up
            // (laser-vs-laser contacts) and never reaching grass/baddies.
            // SpriteKit happily moves a mass-0 body; mirror that by ALWAYS giving a
            // dynamic body a positive mass (floor it) so Box2D integrates velocity.
            var m = massExplicit ? mass : CGFloat(appleAreaPts2() / 22500.0)
            if m <= 0 { m = max(0.01, CGFloat(appleAreaPts2() / 22500.0)) }
            B2.setMass(bodyId, Float(m), Float(boundingRadius()))
        }
        SKPhysicsWorld.registry[bodyId] = self
    }

    // Re-push Apple's collision filter to the live Box2D body when the game
    // mutates categoryBitMask / collisionBitMask / isDynamic / isSensor AFTER
    // the body was created. SpriteKit honors these changes immediately; the
    // tractor beam relies on it — tractorBeamedThisItem() sets the grabbed
    // prize's category/collision masks to 0 so it stops colliding while it's
    // sucked up (matching SpriteKit, where the SKAction-moved item carries no
    // riders). Without this re-sync the masks stay frozen at creation, the prize
    // remains solid in Box2D, and teleporting it upward via setTransform shoves
    // (de-penetrates) the bad dino resting on it so the dino rides the grass up.
    // The computation mirrors createInWorld() EXACTLY so the dino still rests on
    // its untouched original platform — only the tractored body's filter changes.
    func syncFilter() {
        let dyn = isDynamic
        let mask = dyn ? collisionBitMask : UInt32(0xFFFFFFFF)
        // Mirror createInWorld() EXACTLY: a static detector (collision 0 +
        // contactTest set, e.g. the laserBorder) is a sensor so it never bounces.
        let staticDetector = !dyn && collisionBitMask == 0 && contactTestBitMask != 0
        let sensor = isSensor || (collisionBitMask == 0 && dyn) || staticDetector
        B2.setFilter(bodyId, categoryBitMask, mask, sensor)
    }

    func appleAreaPts2() -> Double {
        switch shape {
        case let .rect(w, h): return Double(w * h)
        case let .circle(r): return Double.pi * Double(r * r)
        case let .texture(sz): return Double(sz.width * sz.height)
        case let .edgeLoop(rc): return Double(rc.width * rc.height)
        case let .polygon(pts), let .edgeChain(pts):
            var a = 0.0
            for i in 0..<pts.count {
                let j = (i + 1) % pts.count
                a += Double(pts[i].x * pts[j].y - pts[j].x * pts[i].y)
            }
            return abs(a) / 2
        case .edgeFromTo: return 0
        }
    }

    func boundingRadius() -> Double {
        switch shape {
        case let .rect(w, h): return Double(max(w, h)) / 2
        case let .circle(r): return Double(r)
        case let .texture(sz): return Double(max(sz.width, sz.height)) / 2
        case let .edgeLoop(rc): return Double(max(rc.width, rc.height)) / 2
        case let .polygon(pts), let .edgeChain(pts):
            var r = 0.0
            for p in pts { r = max(r, Double(p.x * p.x + p.y * p.y).squareRoot()) }
            return r
        case .edgeFromTo: return 1
        }
    }
}

// Flatten a [CGPoint] into a contiguous [Float] xy pair-buffer for the Box2D
// polygon/chain constructors.
@inline(__always)
private func flatXY(_ pts: [CGPoint]) -> [Float] {
    var flat = [Float]()
    flat.reserveCapacity(pts.count * 2)
    for p in pts {
        flat.append(Float(p.x))
        flat.append(Float(p.y))
    }
    return flat
}

// Quick AABB over an arbitrary point list — used for polygon/edge body fallback.
private func boundingBox(of pts: [CGPoint]) -> CGRect {
    guard let first = pts.first else { return .zero }
    var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
    for p in pts.dropFirst() {
        if p.x < minX { minX = p.x }
        if p.x > maxX { maxX = p.x }
        if p.y < minY { minY = p.y }
        if p.y > maxY { maxY = p.y }
    }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

// =============================================================================
// SKPhysicsJoint family — compile-only stubs. The Box2D shim doesn't yet
// surface a create-joint API, so calls succeed but the joint isn't simulated.
// Games using SKPhysicsJointPin (UFOEmoji's flight yoke) compile unchanged.
// =============================================================================
public class SKPhysicsJoint {
    public var bodyA: SKPhysicsBody
    public var bodyB: SKPhysicsBody
    public var reactionForce = CGVector.zero
    public var reactionTorque: CGFloat = 0
    var jointId: Int32 = -1
    init(_ a: SKPhysicsBody, _ b: SKPhysicsBody) {
        bodyA = a
        bodyB = b
    }
    // Subclasses override to create the joint in the Box2D world once both
    // bodies are registered. SKPhysicsWorld.add calls this.
    func createInWorld() {}
}
public final class SKPhysicsJointPin: SKPhysicsJoint {
    public var shouldEnableLimits = false
    public var lowerAngleLimit: CGFloat = 0
    public var upperAngleLimit: CGFloat = 0
    public var frictionTorque: CGFloat = 0
    public var rotationSpeed: CGFloat = 0
    var anchor: CGPoint = .zero
    public static func joint(withBodyA a: SKPhysicsBody, bodyB b: SKPhysicsBody, anchor: CGPoint) -> SKPhysicsJointPin {
        let j = SKPhysicsJointPin(a, b)
        j.anchor = anchor
        return j
    }
    override func createInWorld() {
        if jointId >= 0 || bodyA.bodyId < 0 || bodyB.bodyId < 0 { return }
        jointId = B2.addJointPin(bodyA.bodyId, bodyB.bodyId, Float(anchor.x), Float(anchor.y),
                                 enableLimits: shouldEnableLimits,
                                 Float(lowerAngleLimit), Float(upperAngleLimit),
                                 Float(frictionTorque), Float(rotationSpeed))
    }
}
public final class SKPhysicsJointSpring: SKPhysicsJoint {
    public var damping: CGFloat = 0
    public var frequency: CGFloat = 1
    var anchorA: CGPoint = .zero, anchorB: CGPoint = .zero
    public static func joint(withBodyA a: SKPhysicsBody, bodyB b: SKPhysicsBody, anchorA aa: CGPoint, anchorB ab: CGPoint) -> SKPhysicsJointSpring {
        let j = SKPhysicsJointSpring(a, b)
        j.anchorA = aa
        j.anchorB = ab
        return j
    }
    override func createInWorld() {
        if jointId >= 0 || bodyA.bodyId < 0 || bodyB.bodyId < 0 { return }
        jointId = B2.addJointSpring(bodyA.bodyId, bodyB.bodyId,
                                    Float(anchorA.x), Float(anchorA.y),
                                    Float(anchorB.x), Float(anchorB.y),
                                    Float(frequency), Float(damping))
    }
}
public final class SKPhysicsJointFixed: SKPhysicsJoint {
    var anchor: CGPoint = .zero
    public static func joint(withBodyA a: SKPhysicsBody, bodyB b: SKPhysicsBody, anchor: CGPoint) -> SKPhysicsJointFixed {
        let j = SKPhysicsJointFixed(a, b)
        j.anchor = anchor
        return j
    }
    override func createInWorld() {
        if jointId >= 0 || bodyA.bodyId < 0 || bodyB.bodyId < 0 { return }
        jointId = B2.addJointFixed(bodyA.bodyId, bodyB.bodyId, Float(anchor.x), Float(anchor.y))
    }
}
public final class SKPhysicsJointSliding: SKPhysicsJoint {
    public var shouldEnableLimits = false
    public var lowerDistanceLimit: CGFloat = 0
    public var upperDistanceLimit: CGFloat = 0
    var anchor: CGPoint = .zero, axis: CGVector = CGVector(dx: 1, dy: 0)
    public static func joint(withBodyA a: SKPhysicsBody, bodyB b: SKPhysicsBody, anchor: CGPoint, axis: CGVector) -> SKPhysicsJointSliding {
        let j = SKPhysicsJointSliding(a, b)
        j.anchor = anchor
        j.axis = axis
        return j
    }
    override func createInWorld() {
        if jointId >= 0 || bodyA.bodyId < 0 || bodyB.bodyId < 0 { return }
        jointId = B2.addJointSliding(bodyA.bodyId, bodyB.bodyId,
                                     Float(anchor.x), Float(anchor.y),
                                     Float(axis.dx), Float(axis.dy),
                                     enableLimits: shouldEnableLimits,
                                     Float(lowerDistanceLimit), Float(upperDistanceLimit))
    }
}
public final class SKPhysicsJointLimit: SKPhysicsJoint {
    public var maxLength: CGFloat = 0
    var anchorA: CGPoint = .zero, anchorB: CGPoint = .zero
    public static func joint(withBodyA a: SKPhysicsBody, bodyB b: SKPhysicsBody, anchorA aa: CGPoint, anchorB ab: CGPoint) -> SKPhysicsJointLimit {
        let j = SKPhysicsJointLimit(a, b)
        j.anchorA = aa
        j.anchorB = ab
        return j
    }
    override func createInWorld() {
        if jointId >= 0 || bodyA.bodyId < 0 || bodyB.bodyId < 0 { return }
        jointId = B2.addJointLimit(bodyA.bodyId, bodyB.bodyId,
                                   Float(anchorA.x), Float(anchorA.y),
                                   Float(anchorB.x), Float(anchorB.y),
                                   Float(maxLength))
    }
}
public final class SKPhysicsJointDistance: SKPhysicsJoint {
    var anchorA: CGPoint = .zero, anchorB: CGPoint = .zero
    public static func joint(withBodyA a: SKPhysicsBody, bodyB b: SKPhysicsBody, anchorA aa: CGPoint, anchorB ab: CGPoint) -> SKPhysicsJointDistance {
        let j = SKPhysicsJointDistance(a, b)
        j.anchorA = aa
        j.anchorB = ab
        return j
    }
    override func createInWorld() {
        if jointId >= 0 || bodyA.bodyId < 0 || bodyB.bodyId < 0 { return }
        jointId = B2.addJointDistance(bodyA.bodyId, bodyB.bodyId,
                                      Float(anchorA.x), Float(anchorA.y),
                                      Float(anchorB.x), Float(anchorB.y))
    }
}

public final class SKPhysicsWorld {
    public var gravity = CGVector(dx: 0, dy: -9.8)
    public var speed: CGFloat = 1            // not yet honored by the Box2D step
    #if hasFeature(Embedded)
    public unowned(unsafe) var contactDelegate: SKPhysicsContactDelegate?
    #else
    public weak var contactDelegate: SKPhysicsContactDelegate?
    #endif
    nonisolated(unsafe) static var registry: [Int32: SKPhysicsBody] = [:]
    private var started = false
    private var joints: [SKPhysicsJoint] = []

    // Debug visualization. When true, SKView.render strokes the outline
    // of every registered Box2D body on top of the scene so the player
    // can see where the physics shapes actually sit relative to the
    // sprites. OFF by default to match Apple SpriteKit (SKView.showsPhysics
    // is false by default); opt in via scene.physicsWorld.showsPhysics = true.
    // Secondary opt-in (Apple's primary is SKView.showsPhysics, honored in
    // SKView.render). OFF by default to match Apple SpriteKit.
    public var showsPhysics: Bool = false

    // Walks every body in the registry and strokes its shape on the
    // active draw target. Called from SKView.render after the scene
    // tree is drawn, inside the same y-up transform the scene uses,
    // so positions read straight from the body's Box2D coordinates.
    func renderDebug() {
        // Bright green outlines, 1.5 px stroke. Mirrors Apple SpriteKit's
        // showsPhysics default look.
        let rgba: UInt32 = 0x00FF00CC
        let t: Float = 1.5
        for (id, b) in SKPhysicsWorld.registry {
            guard b.node?.scene != nil else { continue }
            let (x, y) = B2.getPosition(id)
            let angle = B2.getAngle(id)
            switch b.shape {
            case let .circle(r):
                gfx_stroke_circle(x, y, Float(r), t, rgba)
            case let .rect(w, h):
                if angle == 0 {
                    gfx_stroke_rect(x - Float(w/2), y - Float(h/2),
                                    Float(w), Float(h), t, rgba)
                } else {
                    let hw = Float(w/2), hh = Float(h/2)
                    let c = Float(sb64_cos(Double(angle))), s = Float(sb64_sin(Double(angle)))
                    let pts: [Float] = [
                        x + (-hw*c - -hh*s), y + (-hw*s + -hh*c),
                        x + ( hw*c - -hh*s), y + ( hw*s + -hh*c),
                        x + ( hw*c -  hh*s), y + ( hw*s +  hh*c),
                        x + (-hw*c -  hh*s), y + (-hw*s +  hh*c),
                    ]
                    pts.withUnsafeBufferPointer { buf in
                        gfx_stroke_poly(buf.baseAddress, 4, 1, t, rgba)
                    }
                }
            case let .polygon(verts):
                var flat = [Float]()
                flat.reserveCapacity(verts.count * 2)
                let c = Float(sb64_cos(Double(angle))), s = Float(sb64_sin(Double(angle)))
                for p in verts {
                    let px = Float(p.x), py = Float(p.y)
                    flat.append(x + px*c - py*s)
                    flat.append(y + px*s + py*c)
                }
                flat.withUnsafeBufferPointer { buf in
                    gfx_stroke_poly(buf.baseAddress, Int32(verts.count), 1, t, rgba)
                }
            case let .edgeLoop(rc):
                gfx_stroke_rect(x + Float(rc.minX), y + Float(rc.minY),
                                Float(rc.width), Float(rc.height), t, rgba)
            case let .edgeFromTo(a, p2):
                let pts: [Float] = [
                    x + Float(a.x), y + Float(a.y),
                    x + Float(p2.x), y + Float(p2.y),
                ]
                pts.withUnsafeBufferPointer { buf in
                    gfx_stroke_poly(buf.baseAddress, 2, 0, t, rgba)
                }
            case let .edgeChain(pts):
                var flat = [Float]()
                for p in pts {
                    flat.append(x + Float(p.x))
                    flat.append(y + Float(p.y))
                }
                flat.withUnsafeBufferPointer { buf in
                    gfx_stroke_poly(buf.baseAddress, Int32(pts.count), 0, t, rgba)
                }
            case let .texture(size):
                gfx_stroke_rect(x - Float(size.width/2), y - Float(size.height/2),
                                Float(size.width), Float(size.height), t, rgba)
            }
        }
    }

    // Create the joint in Box2D as soon as both bodies are registered. If
    // bodies are still missing, the joint is deferred and tried again from
    // step() (see createPendingJoints).
    public func add(_ joint: SKPhysicsJoint) {
        joints.append(joint)
        joint.createInWorld()
    }
    public func remove(_ joint: SKPhysicsJoint) {
        if joint.jointId >= 0 {
            B2.removeJoint(joint.jointId)
            joint.jointId = -1
        }
        joints.removeAll { $0 === joint }
    }
    public func removeAllJoints() {
        for j in joints where j.jointId >= 0 {
            B2.removeJoint(j.jointId)
            j.jointId = -1
        }
        joints.removeAll()
    }
    fileprivate func createPendingJoints() {
        for j in joints where j.jointId < 0 { j.createInWorld() }
    }

    // Hit testing: caller-driven, no Box2D query yet. We scan the registry.
    public func body(at point: CGPoint) -> SKPhysicsBody? {
        SKPhysicsWorld.registry.values.first { b in
            guard let n = b.node else { return false }
            let dx = point.x - n.position.x, dy = point.y - n.position.y
            return (dx*dx + dy*dy) < 256
        }
    }
    public func body(in rect: CGRect) -> SKPhysicsBody? {
        SKPhysicsWorld.registry.values.first { b in
            guard let n = b.node else { return false }
            return rect.contains(n.position)
        }
    }
    public func enumerateBodies(at point: CGPoint, using block: (SKPhysicsBody, UnsafeMutablePointer<Bool>) -> Void) {
        var stop = false
        for b in SKPhysicsWorld.registry.values {
            if stop { return }
            if let n = b.node {
                let dx = point.x - n.position.x, dy = point.y - n.position.y
                if (dx*dx + dy*dy) < 256 { block(b, &stop) }
            }
        }
    }
    public func enumerateBodies(in rect: CGRect, using block: (SKPhysicsBody, UnsafeMutablePointer<Bool>) -> Void) {
        var stop = false
        for b in SKPhysicsWorld.registry.values {
            if stop { return }
            if let n = b.node, rect.contains(n.position) { block(b, &stop) }
        }
    }
    // Ray-cast: walks bodies along a line segment in scene space, returning
    // the first body hit. The Box2D shim doesn't yet expose a ray query, so
    // we sample at fixed intervals — accurate enough for most game queries.
    public func body(alongRayStart start: CGPoint, end: CGPoint) -> SKPhysicsBody? {
        let dx = end.x - start.x, dy = end.y - start.y
        let len = (Double(dx*dx + dy*dy)).squareRoot()
        if len == 0 { return body(at: start) }
        let steps = max(2, Int(len / 8))
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: start.x + dx * t, y: start.y + dy * t)
            if let b = body(at: p) { return b }
        }
        return nil
    }
    public func enumerateBodies(alongRayStart start: CGPoint, end: CGPoint,
                                using block: (SKPhysicsBody, CGPoint, CGVector, UnsafeMutablePointer<Bool>) -> Void) {
        var stop = false
        let dx = end.x - start.x, dy = end.y - start.y
        let len = (Double(dx*dx + dy*dy)).squareRoot()
        if len == 0 { return }
        let steps = max(2, Int(len / 8))
        var seen = Set<Int32>()
        for i in 0...steps {
            if stop { return }
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: start.x + dx * t, y: start.y + dy * t)
            if let b = body(at: p), !seen.contains(b.bodyId) {
                seen.insert(b.bodyId)
                block(b, p, CGVector(dx: dx / CGFloat(len), dy: dy / CGFloat(len)), &stop)
            }
        }
    }

    func begin(_ scene: SKScene) {
        SKPhysicsWorld.registry.removeAll()
        B2.reset(Float(gravity.dx), Float(gravity.dy))
        started = true
        createBodies(scene)
    }

    private func createBodies(_ node: SKNode) {
        if let b = node.physicsBody, b.bodyId < 0 {
            b.node = node
            b.createInWorld()
        }
        for c in node.children { createBodies(c) }
    }

    // Walk the scene once collecting active field nodes, then for every
    // dynamic body whose fieldBitMask overlaps the field's categoryBitMask,
    // sample the force the field would apply at the body's position and call
    // B2.applyForce. Field models honored: linearGravity, radialGravity,
    // vortex, drag, spring, magnetic (treated as radialGravity with sign),
    // noise/turbulence/electric/customField left as no-ops.
    // Global kill-switch for SKFieldNode forces. Apple applies a field to every
    // body in its region every frame; the UFO portals/tractor were sucking the
    // whole level toward them. Disabled for now (per debugging) — the tractor is
    // meant to grab only items touching its small beam, which we'll model as a
    // local contact, not a global field. Flip to true once fields are scoped.
    nonisolated(unsafe) public static var fieldsEnabled = false

    private func applyFields(_ scene: SKNode, dt: TimeInterval) {
        guard SKPhysicsWorld.fieldsEnabled else { return }
        var fields: [SKFieldNode] = []
        collectFields(scene, into: &fields)
        if fields.isEmpty { return }
        for (_, body) in SKPhysicsWorld.registry {
            guard body.isDynamic, let n = body.node else { continue }
            let p = n.absolutePosition()
            for f in fields where (f.categoryBitMask & body.fieldBitMask) != 0 {
                let fp = f.absolutePosition()
                let dx: CGFloat = p.x - fp.x
                let dy: CGFloat = p.y - fp.y
                let dist: CGFloat = (dx*dx + dy*dy).squareRoot()
                if f.minimumRadius > 0 && dist < CGFloat(f.minimumRadius) { continue }
                // Scope the field to its region: a portal's pull only affects
                // bodies inside its SKRegion (Apple), not the whole scene — else
                // one field sucks every body toward it.
                if let region = f.region, dist > region.radius { continue }
                let atten: CGFloat = (f.falloff > 0 && dist > 0)
                    ? 1 / CGFloat(sb64_pow(Double(dist), Double(f.falloff)))
                    : 1
                let strength: CGFloat = CGFloat(f.strength) * atten
                var fx: CGFloat = 0, fy: CGFloat = 0
                switch f.fieldType {
                case .linearGravity:
                    fx = strength * f.direction.dx
                    fy = strength * f.direction.dy
                case .radialGravity:
                    if dist == 0 { continue }
                    fx = (-dx / dist) * strength
                    fy = (-dy / dist) * strength
                case .vortex:
                    if dist == 0 { continue }
                    fx = (-dy / dist) * strength
                    fy = ( dx / dist) * strength
                case .drag:
                    fx = -body.velocity.dx * strength
                    fy = -body.velocity.dy * strength
                case .spring:
                    fx = -dx * strength
                    fy = -dy * strength
                case .magnetic:
                    if dist == 0 { continue }
                    let s = strength * body.charge
                    fx = (-dx / dist) * s
                    fy = (-dy / dist) * s
                case .noise, .turbulence, .electric, .velocityField, .customField:
                    continue
                }
                B2.applyForce(body.bodyId, Float(fx), Float(fy))
            }
        }
        _ = dt   // currently unused; kept for future per-frame ramping
    }
    private func collectFields(_ node: SKNode, into out: inout [SKFieldNode]) {
        if let f = node as? SKFieldNode { out.append(f) }
        for c in node.children { collectFields(c, into: &out) }
    }

    func step(_ dt: TimeInterval, scene: SKScene) {
        if !started {
            begin(scene)
            return
        }
        createBodies(scene)                                   // pick up nodes added since last step
        createPendingJoints()                                 // joints added before their bodies
        applyFields(scene, dt: dt)                            // SKFieldNode → B2.applyForce
        // Apple semantics: bodies fused by a pin/fixed joint move as one rigid
        // cluster, so writing velocity to one member must apply to the whole
        // cluster. The game zeroes ONLY the hero on stick release; canape+tractor
        // are pinned to it and would otherwise keep their own velocity and feed
        // momentum back through the joint solver — so the ship coasts instead of
        // stopping on a dime. Propagate each velocity-dirty body's linear velocity
        // (and zero angular velocity) into every body rigidly joined to it.
        for (_, b) in SKPhysicsWorld.registry where b.velocityDirty {
            let vx = Float(b._velocity.dx * SKPhysicsBody.appleVelocityScale)
            let vy = Float(b._velocity.dy * SKPhysicsBody.appleVelocityScale)
            B2.setVelocity(b.bodyId, vx, vy)
            b.velocityDirty = false
            for j in joints where (j is SKPhysicsJointPin || j is SKPhysicsJointFixed) {
                let other: SKPhysicsBody?
                if j.bodyA === b { other = j.bodyB }
                else if j.bodyB === b { other = j.bodyA }
                else { other = nil }
                guard let n = other, n.bodyId >= 0, !n.velocityDirty else { continue }
                B2.setVelocity(n.bodyId, vx, vy)
                B2.setAngularVelocity(n.bodyId, 0)
            }
        }
        for (_, b) in SKPhysicsWorld.registry where b.angularDirty {
            B2.setAngularVelocity(b.bodyId, Float(b.angularVelocity))
            b.angularDirty = false
        }
        // Push every body's Box2D transform FROM its SKNode each frame
        // so contact detection always sees the actual current scene
        // positions. Apple SpriteKit does this implicitly; SuperBox64
        // has to do it explicitly because Box2D bodies don't observe
        // SKNode mutations on their own.
        //
        // This is the missing half of node<->body sync. Without it, a
        // dynamic body that the game moves via SKAction.move or by
        // writing node.position directly (which is what every consumer
        // does, including bossman-apple) stays at its spawn position
        // in Box2D's world — and no contacts fire because the body
        // never goes anywhere as far as Box2D is concerned.
        var orphaned: [Int32] = []
        for (id, b) in SKPhysicsWorld.registry {
            guard let n = b.node else {
                orphaned.append(id)
                continue
            }
            // Box2D is one flat world, so a body must sit at its node's ABSOLUTE
            // scene position — not its parent-local `position`. Most game bodies
            // live at the scene root (local == absolute) or under an origin-pinned
            // container (local ≈ absolute), so the old local shortcut happened to
            // work for them. But a body parented to a MOVING node breaks: UFO
            // Emoji's laserBorder edge-loop is a CAMERA child and the camera tracks
            // the hero (cam.position.x = hero.x). With local position the border
            // stayed frozen at the world origin while the hero/laser flew off to
            // large x — so a fired laser (whose ONLY collisionBitMask is the
            // laserBorder) either got destroyed by the stale origin-centered border
            // before it reached any target, or fired entirely outside it; the laser
            // "did nothing". absolutePosition() walks the parent chain so the border
            // follows the camera, exactly like Apple SpriteKit's implicit sync.
            let p = n.absolutePosition()
            B2.setTransform(id, Float(p.x), Float(p.y),
                            Float(n.zRotation))
        }
        // A registry body whose weak SKNode has left the scene is an orphan:
        // Box2D keeps it colliding and the showsPhysics overlay keeps stroking
        // it. Apple destroys a node's body when it leaves the scene; mirror that
        // for any node removed by a path that bypassed teardownPhysics.
        for id in orphaned {
            B2.removeBody(id)
            SKPhysicsWorld.registry.removeValue(forKey: id)
        }
        B2.step(Float(dt))
        // Read positions back for true dynamic bodies (so simulated
        // motion — gravity, contacts with non-zero collisionBitMask —
        // is visible). For game-driven bodies the read-back will equal
        // what we just pushed in.
        for (id, b) in SKPhysicsWorld.registry {
            guard b.isDynamic, let n = b.node else { continue }
            let (x, y) = B2.getPosition(id)
            // Box2D positions are ABSOLUTE (we push absolutePosition() in above),
            // so convert back to the node's PARENT-LOCAL frame before writing
            // `position`. For scene-root / origin-pinned bodies the parent origin
            // is (0,0) so this is a no-op; for a dynamic body under a moving parent
            // it keeps the round-trip exact instead of teleporting it by the
            // parent's offset every frame.
            let off = n.parent?.absolutePosition() ?? .zero
            let lx = CGFloat(x) - off.x, ly = CGFloat(y) - off.y
            if abs(n.position.x - lx) > 0.001 || abs(n.position.y - ly) > 0.001 {
                n.position = CGPoint(x: lx, y: ly)
            }
            if b.allowsRotation {
                let a = CGFloat(B2.getAngle(id))
                if abs(n.zRotation - a) > 0.0005 { n.zRotation = a }
            }
        }
        for c in B2.drainBeginContacts() {
            guard let A = SKPhysicsWorld.registry[c.bodyA], let B = SKPhysicsWorld.registry[c.bodyB] else { continue }
            let hit = (A.categoryBitMask & B.contactTestBitMask) != 0
                   || (B.categoryBitMask & A.contactTestBitMask) != 0
            if hit {
                let contact = SKPhysicsContact(A, B)
                contact.contactPoint = CGPoint(x: CGFloat(c.pointX), y: CGFloat(c.pointY))
                contactDelegate?.didBegin(contact)
            }
        }
    }
}


