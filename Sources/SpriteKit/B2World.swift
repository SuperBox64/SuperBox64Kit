import CBox2D

// Apple-faithful collision filter (registered on every world). SpriteKit's
// collisionBitMask is ONE-WAY and OR-combined across the two bodies, whereas
// Box2D's built-in category/mask filter is a symmetric AND. To match SpriteKit
// EXACTLY we make the broadphase permissive (every solid shape masks in
// everything — see shapeDef) and decide the real collision here, with
// SpriteKit's precise rule:
//
//   collide ⇔ (A.category & B.collisionMask) ≠ 0  OR  (B.category & A.collisionMask) ≠ 0
//
// This is what keeps a body inside a boundary whose own collisionMask is 0 (the
// world edge loop) and stops the tractor/world from grabbing bodies that didn't
// opt in. Sensor shapes always pass so the kit's contact-detection twins keep
// surfacing every overlap to drainBeginContacts. Any lookup failure defaults to
// "collide" so a missing registry entry can never silently drop physics.
func sb64AppleCollisionFilter(_ sa: b2ShapeId, _ sb: b2ShapeId, _ ctx: UnsafeMutableRawPointer?) -> Bool {
    if b2Shape_IsSensor(sa) || b2Shape_IsSensor(sb) { return true }
    guard let ra = b2Body_GetUserData(b2Shape_GetBody(sa)),
          let rb = b2Body_GetUserData(b2Shape_GetBody(sb)) else { return true }
    let slotA = Int32(Int(bitPattern: UnsafeRawPointer(ra)) - 1)
    let slotB = Int32(Int(bitPattern: UnsafeRawPointer(rb)) - 1)
    guard let pa = SKPhysicsWorld.registry[slotA],
          let pb = SKPhysicsWorld.registry[slotB] else { return true }
    return (pa.categoryBitMask & pb.collisionBitMask) != 0
        || (pb.categoryBitMask & pa.collisionBitMask) != 0
}

// Apple-faithful restitution mixing. Box2D v3's DEFAULT mix is
// b2MaxFloat(restitutionA, restitutionB) (see CBox2D src/world.c
// b2DefaultRestitutionCallback), so a restitution-0 body STILL bounces off any
// boundary whose restitution is non-zero — e.g. UFO Emoji's laser (restitution
// 0) bouncing off a border. SpriteKit (whose physics is Box2D-derived) does NOT
// do this: when EITHER body's restitution is 0 the collision is effectively
// dead — the laser stops at the boundary instead of springing back. We install
// this callback (b2World_SetRestitutionCallback / def.restitutionCallback) so a
// 0 on either side yields 0 (no bounce off ANY boundary), while two genuinely
// bouncy bodies still combine via MAX exactly like Box2D's default — so DaBomb
// (restitution 0.5) and the 0.2 rock bounds keep bouncing. This is the precise,
// per-contact lever the engine provides for this mismatch; the global
// restitutionThreshold can't express it (a 0-restitution contact never bounces
// regardless of threshold, but a non-zero one bounces once it clears the
// threshold — so the threshold can't single out "either side is 0").
// Signature matches b2RestitutionCallback (float, int, float, int) — the int
// args are per-shape material ids, ignored here. @convention(c) so it can be
// handed to Box2D as a raw C function pointer (def.restitutionCallback).
let sb64AppleRestitutionMix: @convention(c) (Float, Int32, Float, Int32) -> Float = { ra, _, rb, _ in
    if ra == 0 || rb == 0 { return 0 }
    return ra > rb ? ra : rb
}

// MARK: - Box2D v3 backend (replaces the C++ cbox2d bridge; Swift calls C directly)

// Coordinates are SpriteKit points treated as Box2D length units. Telling Box2D
// the unit scale keeps its internal tolerances (linear slop, speculative contact
// distance, sleep thresholds) proportionate to pixel-sized worlds, and the
// explicit speed cap leaves velocity-driven bodies unclamped at gameplay speeds.
enum B2 {
    nonisolated(unsafe) static var world: b2WorldId? = nil
    nonisolated(unsafe) static var bodies: [b2BodyId?] = []
    nonisolated(unsafe) static var joints: [b2JointId?] = []
    nonisolated(unsafe) private static var unitsConfigured = false

    struct BeginContact {
        let catA: UInt32
        let catB: UInt32
        let bodyA: Int32
        let bodyB: Int32
        // Scene-space contact point. All begin-touch events arrive via the sensor
        // stream (shapes use enableSensorEvents; see shapeDef), which carries no
        // b2Manifold, so this is the midpoint of the two body centers — Apple's
        // contact.contactPoint for an overlap. Box2D coords are absolute scene
        // points (absolutePosition() pushed in; 150 length-units/m == 1:1 points).
        let pointX: Float
        let pointY: Float
    }

    static func reset(_ gx: Float, _ gy: Float) {
        if let w = world { b2DestroyWorld(w) }
        if !unitsConfigured {
            b2SetLengthUnitsPerMeter(150.0)
            unitsConfigured = true
        }
        var def = b2DefaultWorldDef()
        // SpriteKit gravity is in m/s² (default (0,-9.8)); Box2D works in the
        // world's length units (here points, with 150 pts/m via
        // b2SetLengthUnitsPerMeter). So convert m/s² -> points/s² by ×150,
        // otherwise gravity is 150× too weak and bodies float instead of falling.
        def.gravity = b2Vec2(x: gx * 150.0, y: gy * 150.0)
        def.enableSleep = false
        def.maximumLinearSpeed = 4000.0
        // Apple-faithful restitution mixing (see sb64AppleRestitutionMix): a body
        // with restitution 0 (the laser) never bounces off ANY boundary, while
        // two bouncy bodies still combine via MAX like Box2D's default. This is
        // the real fix for the laser bouncing off its removal border — Box2D's
        // default MAX mix let the 0-restitution laser inherit the border's
        // bounciness, unlike SpriteKit.
        def.restitutionCallback = sb64AppleRestitutionMix
        // Restitution threshold: contacts slower than this don't bounce (Box2D
        // uses it to kill jitter on resting stacks). The kit briefly forced this
        // to 1000 to mask the laser bounce, but with the mixing callback above the
        // laser contact is genuinely 0-restitution (skipped entirely, threshold
        // irrelevant), so we restore Box2D's sane default — 1 m/s × 150 pts/m =
        // 150 pts/s. A 1000-pt/s threshold also wrongly suppressed legitimately
        // bouncy fast collisions (DaBomb restitution 0.5, the 0.2 rock bounds).
        def.restitutionThreshold = 150.0
        world = b2CreateWorld(&def)
        bodies.removeAll()
        joints.removeAll()
    }

    private static func ensureWorld() -> b2WorldId {
        if world == nil { reset(0, 0) }
        return world!
    }

    // Bodies are addressed by a stable Int32 slot (the registry key); removal
    // nulls the slot so older ids never alias a newer body. The Box2D-side
    // userData carries slot+1 (0 would decode as a nil pointer).
    struct BodyProps {
        var friction: Float = 0.2
        var restitution: Float = 0.1
        var linearDamping: Float = 0
        var angularDamping: Float = 0
        var gravityScale: Float = 1
    }
    nonisolated(unsafe) static var pendingProps = BodyProps()

    private static func newBody(_ x: Float, _ y: Float, _ dynamic: Bool) -> (Int32, b2BodyId) {
        let w = ensureWorld()
        var bd = b2DefaultBodyDef()
        bd.type = dynamic ? b2_dynamicBody : b2_staticBody
        bd.position = b2Vec2(x: x, y: y)
        bd.linearDamping = pendingProps.linearDamping
        bd.angularDamping = pendingProps.angularDamping
        bd.gravityScale = pendingProps.gravityScale
        let id = Int32(bodies.count)
        bd.userData = UnsafeMutableRawPointer(bitPattern: Int(id) + 1)
        let body = b2CreateBody(w, &bd)
        bodies.append(body)
        return (id, body)
    }

    // Apple's contactTest/collision split is emulated upstream (SKPhysicsBody
    // feeds the union mask + sensor flag); every shape opts into both event
    // streams so sensor and solid pairs alike surface in drainBeginContacts.
    // Apple has two independent one-sided filters: collisionBitMask gates the
    // bounce, contactTestBitMask gates didBegin. Box2D's two-way AND filter
    // can't express that, so every body carries TWO shapes: the SOLID shape
    // with the pure collision filter (real physics, no events), and a SENSOR
    // twin on a reserved category bit with an everything mask. The sensor
    // observes every solid one-sidedly; the drain dedups pairs and applies
    // Apple's contactTest rule.
    static let sensorBit: UInt64 = 1 << 63

    private static func shapeDef(_ cat: UInt32, _ mask: UInt32, _ sensor: Bool) -> b2ShapeDef {
        var sd = b2DefaultShapeDef()
        sd.density = 1.0
        sd.material.friction = pendingProps.friction
        sd.material.restitution = pendingProps.restitution
        sd.filter.categoryBits = UInt64(cat)
        sd.filter.maskBits = sensor ? 0 : (UInt64(mask) | sensorBit)
        sd.isSensor = false
        sd.enableContactEvents = false
        sd.enableSensorEvents = true
        return sd
    }

    private static func sensorDef() -> b2ShapeDef {
        var sd = b2DefaultShapeDef()
        sd.density = 0
        sd.filter.categoryBits = sensorBit
        sd.filter.maskBits = UInt64.max
        sd.isSensor = true
        sd.enableSensorEvents = true
        return sd
    }

    static func addBox(_ x: Float, _ y: Float, _ hw: Float, _ hh: Float,
                       _ dynamic: Bool, _ cat: UInt32, _ mask: UInt32, _ sensor: Bool) -> Int32 {
        let (id, body) = newBody(x, y, dynamic)
        var sd = shapeDef(cat, mask, sensor)
        // Floor half-extents: a zero-size b2MakeBox is a degenerate, zero-area shape
        // that neither collides nor draws. Mirrors the .rect path's max(...,0.5) so
        // any degenerate AABB fallback still yields a real, visible, colliding body.
        var poly = b2MakeBox(max(hw, 0.5), max(hh, 0.5))
        b2CreatePolygonShape(body, &sd, &poly)
        var twin = sensorDef()
        b2CreatePolygonShape(body, &twin, &poly)
        return id
    }

    static func addCircle(_ x: Float, _ y: Float, _ r: Float,
                          _ dynamic: Bool, _ cat: UInt32, _ mask: UInt32, _ sensor: Bool) -> Int32 {
        let (id, body) = newBody(x, y, dynamic)
        var sd = shapeDef(cat, mask, sensor)
        var circle = b2Circle(center: b2Vec2(x: 0, y: 0), radius: r)
        b2CreateCircleShape(body, &sd, &circle)
        var twin = sensorDef()
        b2CreateCircleShape(body, &twin, &circle)
        return id
    }

    // Convex polygon in body-local coordinates. Box2D caps the vertex count and
    // requires convexity (the hull pass enforces it); degenerate hulls fall back
    // to the caller's box path via the negative return.
    static func addPolygon(_ x: Float, _ y: Float, _ pts: [Float],
                           _ dynamic: Bool, _ cat: UInt32, _ mask: UInt32, _ sensor: Bool) -> Int32 {
        let maxVerts = Int(B2_MAX_POLYGON_VERTICES)
        let n = pts.count / 2
        if n < 3 { return -1 }
        var verts = [b2Vec2]()
        verts.reserveCapacity(n)
        for i in 0..<n { verts.append(b2Vec2(x: pts[i*2], y: pts[i*2+1])) }
        // b2ComputeHull only accepts up to maxVerts INPUT points (it hulls a
        // small hand-specified polygon, not an arbitrary point cloud) — a path
        // with curves (addQuadCurve/addCurve) flattens to far more points than
        // that (e.g. any non-trivial SKPhysicsBody(polygonFrom:) outline), so
        // this used to just take the FIRST maxVerts raw points in path order
        // and hull those, silently building a wrong/degenerate shape from an
        // arbitrary chunk of the boundary (players fell through the floor with
        // no visible cause). Reduce to the real hull ourselves first when
        // there are too many points, then decimate that hull's perimeter down
        // to maxVerts — preserves the actual silhouette instead of truncating.
        if verts.count > maxVerts {
            verts = decimatePolygon(convexHull(verts), to: maxVerts)
        }
        let hull = verts.withUnsafeBufferPointer { b2ComputeHull($0.baseAddress, Int32(verts.count)) }
        if hull.count < 3 { return -1 }
        let (id, body) = newBody(x, y, dynamic)
        var sd = shapeDef(cat, mask, sensor)
        var h = hull
        var poly = b2MakePolygon(&h, 0)
        b2CreatePolygonShape(body, &sd, &poly)
        var twin = sensorDef()
        b2CreatePolygonShape(body, &twin, &poly)
        return id
    }

    private static func hullCross(_ o: b2Vec2, _ a: b2Vec2, _ b: b2Vec2) -> Float {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }

    // Simple O(n^2) selection sort by (x, then y) — n is a handful of path
    // points here, not a hot loop, and this avoids handing a capturing
    // closure to Array.sorted(by:).
    private static func hullSortedByXY(_ pts: [b2Vec2]) -> [b2Vec2] {
        var points = pts
        let count = points.count
        var i = 0
        while i < count {
            var minIdx = i
            var j = i + 1
            while j < count {
                let a = points[j], b = points[minIdx]
                if a.x < b.x || (a.x == b.x && a.y < b.y) { minIdx = j }
                j += 1
            }
            if minIdx != i { points.swapAt(i, minIdx) }
            i += 1
        }
        return points
    }

    // Andrew's monotone-chain convex hull, O(n log n) sort + O(n) sweep.
    // Unlike b2ComputeHull this accepts any number of input points.
    private static func convexHull(_ pts: [b2Vec2]) -> [b2Vec2] {
        let points = hullSortedByXY(pts)
        let count = points.count
        var lower: [b2Vec2] = []
        var i = 0
        while i < count {
            let p = points[i]
            while lower.count >= 2 && hullCross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
            i += 1
        }
        var upper: [b2Vec2] = []
        i = count - 1
        while i >= 0 {
            let p = points[i]
            while upper.count >= 2 && hullCross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
            i -= 1
        }
        lower.removeLast()
        upper.removeLast()
        var result = lower
        result.append(contentsOf: upper)
        return result
    }

    // Evenly resample a convex polygon's perimeter down to at most maxVerts
    // vertices, keeping the overall silhouette instead of dropping a run of
    // consecutive vertices (which can carve off a whole side of the shape).
    private static func decimatePolygon(_ hull: [b2Vec2], to maxVerts: Int) -> [b2Vec2] {
        guard hull.count > maxVerts else { return hull }
        var out: [b2Vec2] = []
        out.reserveCapacity(maxVerts)
        for i in 0..<maxVerts { out.append(hull[(i * hull.count) / maxVerts]) }
        return out
    }

    static func addEdge(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float,
                        _ cat: UInt32, _ mask: UInt32) -> Int32 {
        let (id, body) = newBody(0, 0, false)
        var sd = shapeDef(cat, mask, false)
        var seg = b2Segment(point1: b2Vec2(x: x1, y: y1), point2: b2Vec2(x: x2, y: y2))
        b2CreateSegmentShape(body, &sd, &seg)
        var twin = sensorDef()
        b2CreateSegmentShape(body, &twin, &seg)
        return id
    }

    // Polyline / closed loop as individual two-sided segments on one body.
    // v3 chain shapes are one-sided with a winding requirement; discrete
    // segments keep the 2.4 two-sided behavior the games were written against.
    // Apple allows flipping an edge-loop body dynamic afterward (AsteroidZ
    // fragments fly this way), so dynamic + sensor are honored here too.
    static func addChain(_ pts: [Float], closed: Bool, _ dynamic: Bool,
                         _ cat: UInt32, _ mask: UInt32, _ sensor: Bool) -> Int32 {
        let n = pts.count / 2
        if n < 2 { return -1 }
        let (id, body) = newBody(0, 0, dynamic)
        var sd = shapeDef(cat, mask, sensor)
        var twin = sensorDef()
        for i in 0..<(closed ? n : n - 1) {
            let j = (i + 1) % n
            var seg = b2Segment(point1: b2Vec2(x: pts[i*2], y: pts[i*2+1]),
                                point2: b2Vec2(x: pts[j*2], y: pts[j*2+1]))
            b2CreateSegmentShape(body, &sd, &seg)
            b2CreateSegmentShape(body, &twin, &seg)
        }
        return id
    }

    private static func body(_ id: Int32) -> b2BodyId? {
        guard id >= 0, Int(id) < bodies.count else { return nil }
        return bodies[Int(id)]
    }

    static func removeBody(_ id: Int32) {
        guard let b = body(id) else { return }
        b2DestroyBody(b)
        bodies[Int(id)] = nil
    }

    static func getVelocity(_ id: Int32) -> (Float, Float) {
        guard let b = body(id) else { return (0, 0) }
        let v = b2Body_GetLinearVelocity(b)
        return (v.x, v.y)
    }

    static func setVelocity(_ id: Int32, _ vx: Float, _ vy: Float) {
        guard let b = body(id) else { return }
        b2Body_SetLinearVelocity(b, b2Vec2(x: vx, y: vy))
    }

    static func setTransform(_ id: Int32, _ x: Float, _ y: Float, _ angle: Float) {
        guard let b = body(id) else { return }
        let p = b2Body_GetPosition(b)
        let a = b2Rot_GetAngle(b2Body_GetRotation(b))
        // Epsilon, not equality: angle/position round-trip through b2Rot with
        // float error, and exact compares re-teleported every body every frame
        // (a visible wobble on rotating ships).
        if abs(p.x - x) < 0.001, abs(p.y - y) < 0.001, abs(a - angle) < 0.0005 { return }
        b2Body_SetTransform(b, b2Vec2(x: x, y: y), b2MakeRot(angle))
        // SetTransform refreshes the broad phase but does not wake the body.
        // Game-driven bodies move by teleport with zero velocity, so without
        // the wake they fall asleep and their contact pairs stop being
        // evaluated — didBegin never fires. Waking on a real move keeps the
        // pair live, matching Apple SpriteKit where node-driven bodies always
        // report contacts.
        b2Body_SetAwake(b, true)
    }

    // Re-apply Apple's collision/category filter to a live body's SOLID shapes
    // AFTER creation. SpriteKit lets a game flip collisionBitMask/categoryBitMask
    // at runtime (the tractor beam sets the grabbed prize's masks to 0 so it
    // passes through everything while it's sucked up); without this, the masks
    // are frozen at createInWorld() and the prize stays solid in Box2D, so
    // teleporting it upward de-penetrates (shoves) any body resting on it — the
    // bad dino "rides" the tractored grass. We mirror shapeDef()'s exact encoding
    // (solid mask | sensorBit, or 0 when the body is a sensor/collisionMask-0
    // dynamic) and touch ONLY the solid shapes; the sensor-twin shapes keep their
    // everything-mask so contact detection (drainBeginContacts) is unaffected.
    static func setFilter(_ id: Int32, _ cat: UInt32, _ mask: UInt32, _ sensor: Bool) {
        guard let b = body(id) else { return }
        let count = Int(b2Body_GetShapeCount(b))
        if count <= 0 { return }
        var shapes = [b2ShapeId](repeating: b2ShapeId(), count: count)
        let got = shapes.withUnsafeMutableBufferPointer { buf in
            Int(b2Body_GetShapes(b, buf.baseAddress, Int32(count)))
        }
        for i in 0..<got {
            let s = shapes[i]
            if b2Shape_IsSensor(s) { continue }   // leave the contact-detection twin alone
            var f = b2Shape_GetFilter(s)
            f.categoryBits = UInt64(cat)
            f.maskBits = sensor ? 0 : (UInt64(mask) | sensorBit)
            b2Shape_SetFilter(s, f)
        }
        b2Body_SetAwake(b, true)
    }

    static func getPosition(_ id: Int32) -> (Float, Float) {
        guard let b = body(id) else { return (0, 0) }
        let p = b2Body_GetPosition(b)
        return (p.x, p.y)
    }

    static func getAngle(_ id: Int32) -> Float {
        guard let b = body(id) else { return 0 }
        return b2Rot_GetAngle(b2Body_GetRotation(b))
    }

    // SpriteKit force is N (kg·m/s²); masses here are real kg (density kg/m²,
    // area/150²). With b2SetLengthUnitsPerMeter(150) Box2D works in points, so a
    // screen-space force must be ×150 to stay dimensionally 1:1 (in lock step with
    // mass denom 22500=150² and the gravity ×150). Impulse is folded into velocity
    // upstream (applyImpulse) and is NOT scaled here.
    static let forceScale: Float = 150.0
    static func applyForce(_ id: Int32, _ fx: Float, _ fy: Float) {
        guard let b = body(id) else { return }
        b2Body_ApplyForceToCenter(b, b2Vec2(x: fx * forceScale, y: fy * forceScale), true)
    }

    static func applyImpulse(_ id: Int32, _ ix: Float, _ iy: Float) {
        guard let b = body(id) else { return }
        b2Body_ApplyLinearImpulseToCenter(b, b2Vec2(x: ix, y: iy), true)
    }

    static func setMass(_ id: Int32, _ m: Float, _ r: Float) {
        guard let b = body(id) else { return }
        var md = b2MassData()
        md.mass = m
        md.center = b2Vec2(x: 0, y: 0)
        md.rotationalInertia = 0.5 * m * r * r
        b2Body_SetMassData(b, md)
    }

    // Switch a live body between static and dynamic. SpriteKit lets a game flip
    // SKPhysicsBody.isDynamic at runtime (UFO Emoji turns a laser-struck grass/dirt
    // tile dynamic so it spins weightlessly in the air). The kit set body type only
    // at creation, so the flip did nothing in Box2D and the tile stayed frozen.
    static func setBodyType(_ id: Int32, _ dynamic: Bool) {
        guard let b = body(id) else { return }
        b2Body_SetType(b, dynamic ? b2_dynamicBody : b2_staticBody)
        b2Body_SetAwake(b, true)
    }

    static func applyTorque(_ id: Int32, _ t: Float) {
        guard let b = body(id) else { return }
        b2Body_ApplyTorque(b, t, true)
    }

    static func applyAngularImpulse(_ id: Int32, _ i: Float) {
        guard let b = body(id) else { return }
        b2Body_ApplyAngularImpulse(b, i, true)
    }

    static func setAngularVelocity(_ id: Int32, _ w: Float) {
        guard let b = body(id) else { return }
        b2Body_SetAngularVelocity(b, w)
    }

    static func setLinearDamping(_ id: Int32, _ d: Float) {
        guard let b = body(id) else { return }
        b2Body_SetLinearDamping(b, d)
    }

    static func getAngularVelocity(_ id: Int32) -> Float {
        guard let b = body(id) else { return 0 }
        return b2Body_GetAngularVelocity(b)
    }

    static func step(_ dt: Float) {
        guard let w = world else { return }
        b2World_Step(w, dt, 4)
    }

    // MARK: - Joints

    private static func storeJoint(_ j: b2JointId) -> Int32 {
        let id = Int32(joints.count)
        joints.append(j)
        return id
    }

    static func removeJoint(_ id: Int32) {
        guard id >= 0, Int(id) < joints.count, let j = joints[Int(id)] else { return }
        b2DestroyJoint(j)
        joints[Int(id)] = nil
    }

    private static func relativeAngle(_ a: b2BodyId, _ b: b2BodyId) -> Float {
        b2Rot_GetAngle(b2Body_GetRotation(b)) - b2Rot_GetAngle(b2Body_GetRotation(a))
    }

    static func addJointPin(_ a: Int32, _ b: Int32, _ ax: Float, _ ay: Float,
                            enableLimits: Bool, _ lower: Float, _ upper: Float,
                            _ frictionTorque: Float, _ motorSpeed: Float) -> Int32 {
        guard let w = world, let ba = body(a), let bb = body(b) else { return -1 }
        let anchor = b2Vec2(x: ax, y: ay)
        var def = b2DefaultRevoluteJointDef()
        def.bodyIdA = ba
        def.bodyIdB = bb
        def.localAnchorA = b2Body_GetLocalPoint(ba, anchor)
        def.localAnchorB = b2Body_GetLocalPoint(bb, anchor)
        def.referenceAngle = relativeAngle(ba, bb)
        def.enableLimit = enableLimits
        def.lowerAngle = lower
        def.upperAngle = upper
        def.maxMotorTorque = frictionTorque
        def.motorSpeed = motorSpeed
        def.enableMotor = motorSpeed != 0 || frictionTorque != 0
        return storeJoint(b2CreateRevoluteJoint(w, &def))
    }

    private static func distanceDef(_ ba: b2BodyId, _ bb: b2BodyId,
                                    _ ax: Float, _ ay: Float, _ bx: Float, _ by: Float) -> b2DistanceJointDef {
        var def = b2DefaultDistanceJointDef()
        def.bodyIdA = ba
        def.bodyIdB = bb
        def.localAnchorA = b2Body_GetLocalPoint(ba, b2Vec2(x: ax, y: ay))
        def.localAnchorB = b2Body_GetLocalPoint(bb, b2Vec2(x: bx, y: by))
        let dx = bx - ax
        let dy = by - ay
        def.length = (dx * dx + dy * dy).squareRoot()
        return def
    }

    static func addJointSpring(_ a: Int32, _ b: Int32, _ ax: Float, _ ay: Float,
                               _ bx: Float, _ by: Float, _ frequency: Float, _ damping: Float) -> Int32 {
        guard let w = world, let ba = body(a), let bb = body(b) else { return -1 }
        var def = distanceDef(ba, bb, ax, ay, bx, by)
        def.enableSpring = true
        def.hertz = frequency
        def.dampingRatio = damping
        return storeJoint(b2CreateDistanceJoint(w, &def))
    }

    static func addJointSliding(_ a: Int32, _ b: Int32, _ ax: Float, _ ay: Float,
                                _ dx: Float, _ dy: Float,
                                enableLimits: Bool, _ lower: Float, _ upper: Float) -> Int32 {
        guard let w = world, let ba = body(a), let bb = body(b) else { return -1 }
        let anchor = b2Vec2(x: ax, y: ay)
        var def = b2DefaultPrismaticJointDef()
        def.bodyIdA = ba
        def.bodyIdB = bb
        def.localAnchorA = b2Body_GetLocalPoint(ba, anchor)
        def.localAnchorB = b2Body_GetLocalPoint(bb, anchor)
        def.localAxisA = b2Body_GetLocalVector(ba, b2Vec2(x: dx, y: dy))
        def.referenceAngle = relativeAngle(ba, bb)
        def.enableLimit = enableLimits
        def.lowerTranslation = lower
        def.upperTranslation = upper
        return storeJoint(b2CreatePrismaticJoint(w, &def))
    }

    // Rope-style limit: free within the limit, rigid at the bound. A zero-hertz
    // spring removes the rigid-length constraint while the limit clamps.
    static func addJointLimit(_ a: Int32, _ b: Int32, _ ax: Float, _ ay: Float,
                              _ bx: Float, _ by: Float, _ maxLength: Float) -> Int32 {
        guard let w = world, let ba = body(a), let bb = body(b) else { return -1 }
        var def = distanceDef(ba, bb, ax, ay, bx, by)
        def.enableSpring = true
        def.hertz = 0
        def.dampingRatio = 0
        def.enableLimit = true
        def.minLength = 0
        def.maxLength = maxLength
        if def.length > maxLength { def.length = maxLength }
        return storeJoint(b2CreateDistanceJoint(w, &def))
    }

    static func addJointFixed(_ a: Int32, _ b: Int32, _ ax: Float, _ ay: Float) -> Int32 {
        guard let w = world, let ba = body(a), let bb = body(b) else { return -1 }
        let anchor = b2Vec2(x: ax, y: ay)
        var def = b2DefaultWeldJointDef()
        def.bodyIdA = ba
        def.bodyIdB = bb
        def.localAnchorA = b2Body_GetLocalPoint(ba, anchor)
        def.localAnchorB = b2Body_GetLocalPoint(bb, anchor)
        def.referenceAngle = relativeAngle(ba, bb)
        return storeJoint(b2CreateWeldJoint(w, &def))
    }

    static func addJointDistance(_ a: Int32, _ b: Int32, _ ax: Float, _ ay: Float,
                                 _ bx: Float, _ by: Float) -> Int32 {
        guard let w = world, let ba = body(a), let bb = body(b) else { return -1 }
        var def = distanceDef(ba, bb, ax, ay, bx, by)
        return storeJoint(b2CreateDistanceJoint(w, &def))
    }

    // MARK: - Contact events

    // Snapshot the step's begin-touch events (contact pairs for solid bodies,
    // sensor pairs for contact-only bodies) BEFORE delivery: didBegin handlers
    // destroy bodies (pellet eaten -> removeFromParent), which would invalidate
    // the shape ids the remaining events still reference. A sensor overlap is
    // reported from each sensor's side, so symmetric pairs are deduped to keep
    // Apple's one-didBegin-per-pair contract.
    static func drainBeginContacts() -> [BeginContact] {
        guard let w = world else { return [] }
        var out = [BeginContact]()
        var seen = Set<UInt64>()

        func record(_ shapeA: b2ShapeId, _ shapeB: b2ShapeId) {
            let bodyA = b2Shape_GetBody(shapeA)
            let bodyB = b2Shape_GetBody(shapeB)
            let idA = Int32(Int(bitPattern: b2Body_GetUserData(bodyA)) - 1)
            let idB = Int32(Int(bitPattern: b2Body_GetUserData(bodyB)) - 1)
            guard idA >= 0, idB >= 0 else { return }
            let lo = UInt64(UInt32(bitPattern: min(idA, idB)))
            let hi = UInt64(UInt32(bitPattern: max(idA, idB)))
            let key = (hi << 32) | lo
            if seen.contains(key) { return }
            seen.insert(key)
            let pa = b2Body_GetPosition(bodyA)
            let pb = b2Body_GetPosition(bodyB)
            out.append(BeginContact(
                catA: UInt32(truncatingIfNeeded: b2Shape_GetFilter(shapeA).categoryBits),
                catB: UInt32(truncatingIfNeeded: b2Shape_GetFilter(shapeB).categoryBits),
                bodyA: idA, bodyB: idB,
                pointX: (pa.x + pb.x) * 0.5, pointY: (pa.y + pb.y) * 0.5))
        }

        let ce = b2World_GetContactEvents(w)
        for i in 0..<Int(ce.beginCount) {
            let e = ce.beginEvents[i]
            record(e.shapeIdA, e.shapeIdB)
        }
        let se = b2World_GetSensorEvents(w)
        for i in 0..<Int(se.beginCount) {
            let e = se.beginEvents[i]
            record(e.sensorShapeId, e.visitorShapeId)
        }
        return out
    }
}
