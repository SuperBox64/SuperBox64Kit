import KitABI

// SKEmitterNode: a programmatic particle emitter. Spawns up to particleBirthRate*dt
// particles per frame (or stops at numParticlesToEmit), ages them, integrates
// velocity + accelerations, applies per-particle alpha/scale/color ramps and
// keyframe sequences, and draws each as a textured quad (or a colored circle
// when no particleTexture is set).
//
// Properties match Apple's API surface so .sks-driven games drop in once the
// .sks loader populates them. Targeted scope: rendering still happens on a
// flat Canvas2D path (no GPU shaders, no targetNode reparent yet).
public enum SKParticleRenderOrder: Int { case oldestLast, oldestFirst, dontCare }

public final class SKEmitterNode: SKNode {
    // ---- Birth / lifetime ----
    public var particleBirthRate: CGFloat = 0
    public var numParticlesToEmit: Int = 0           // 0 = continuous
    public var particleLifetime: CGFloat = 1
    public var particleLifetimeRange: CGFloat = 0

    // ---- Position spawning ----
    public var particlePosition: CGPoint = .zero
    public var particlePositionRange: CGVector = .zero

    // ---- Velocity ----
    public var particleSpeed: CGFloat = 100
    public var particleSpeedRange: CGFloat = 0
    public var emissionAngle: CGFloat = 0            // radians (0 = +x)
    public var emissionAngleRange: CGFloat = 0
    public var xAcceleration: CGFloat = 0
    public var yAcceleration: CGFloat = 0

    // ---- Alpha ----
    public var particleAlpha: CGFloat = 1
    public var particleAlphaRange: CGFloat = 0
    public var particleAlphaSpeed: CGFloat = -1      // alpha per second
    public var particleAlphaSequence: SKKeyframeSequence?

    // ---- Scale ----
    public var particleScale: CGFloat = 1
    public var particleScaleRange: CGFloat = 0
    public var particleScaleSpeed: CGFloat = 0
    public var particleScaleSequence: SKKeyframeSequence?

    // ---- Rotation ----
    public var particleRotation: CGFloat = 0
    public var particleRotationRange: CGFloat = 0
    public var particleRotationSpeed: CGFloat = 0

    // ---- Color ----
    public var particleColor: SKColor = .white
    public var particleColorBlendFactor: CGFloat = 1
    public var particleColorBlendFactorRange: CGFloat = 0
    public var particleColorBlendFactorSpeed: CGFloat = 0
    public var particleColorBlendFactorSequence: SKKeyframeSequence?
    public var particleColorSequence: SKKeyframeSequence?
    public var particleColorRedRange: CGFloat = 0
    public var particleColorGreenRange: CGFloat = 0
    public var particleColorBlueRange: CGFloat = 0
    public var particleColorAlphaRange: CGFloat = 0
    public var particleColorRedSpeed: CGFloat = 0
    public var particleColorGreenSpeed: CGFloat = 0
    public var particleColorBlueSpeed: CGFloat = 0
    public var particleColorAlphaSpeed: CGFloat = 0

    // ---- Z position (rendering depth ramp; recorded but flat draw order applies) ----
    public var particleZPosition: CGFloat = 0
    public var particleZPositionRange: CGFloat = 0
    public var particleZPositionSpeed: CGFloat = 0

    // ---- Rendering ----
    public var particleTexture: SKTexture?
    public var particleBlendMode: SKBlendMode = .alpha
    public var particleRenderOrder: SKParticleRenderOrder = .oldestLast
    public var particleSize = CGSize(width: 4, height: 4)
    public var shader: SKShader?
    #if hasFeature(Embedded)
    public unowned(unsafe) var targetNode: SKNode?              // recorded; particles still render under self
    #else
    public weak var targetNode: SKNode?              // recorded; particles still render under self
    #endif
    public var fieldBitMask: UInt32 = 0xFFFFFFFF
    public var particleAction: SKAction?             // run on each particle as it spawns (no-op for now)

    private struct Particle {
        var x, y, vx, vy: CGFloat
        var age, life, alpha, scale, rotation, rotSpeed: CGFloat
        var r, g, b, a: CGFloat
        var blendFactor: CGFloat
    }
    private var particles: [Particle] = []
    // Hard cap on simultaneously-live particles per emitter: bounds the per-frame tick
    // + per-particle draw-FFI cost so dense effects (fire/explosions/aura) can't tank
    // the frame. Dense fire floats ~600; 256 is visually indistinguishable here.
    public var maxLiveParticles: Int = 256
    private var emitAccum: CGFloat = 0
    private var emittedSoFar = 0

    // Cull radius so an emitter whose entire particle spread is off-screen is
    // skipped (default 0 = never cull). The white-hole/level-up effects are
    // scattered across a long level; without this EVERY one drew all its
    // particles every frame (one Canvas2D drawImage each) and FPS collapsed.
    // Bound by how far particles travel from the origin: speed*lifetime + the
    // position jitter + the largest the textured quad grows to.
    override var _cullExtent: CGFloat {
        let travel = abs(particleSpeed) * particleLifetime
        let spread = max(particlePositionRange.dx, particlePositionRange.dy) / 2
        let maxScale = max(particleScale,
                           particleScale + particleScaleRange / 2,
                           particleScale + particleScaleSpeed * particleLifetime)
        let quad = max(particleSize.width, particleSize.height) * max(1, maxScale)
        // Scale the particle-space extent by the emitter node's own scale, like
        // SKSpriteNode/SKLabelNode do — else a setScale(0.334) emitter (the
        // blackHole/level-up marker) gets a cull box ~3× its real footprint and
        // ticks+draws far off the screen where it's actually visible.
        return (travel + spread + quad) * max(abs(xScale), abs(yScale)) + 32
    }

    public override init() { super.init() }

    // Programmatic load from a particle file. The .sks was converted to JSON by
    // sks2json and ships under assets/particles/<name>.json; populate THIS
    // instance from it (a failable init can't return the loader's fresh object).
    // Was a no-op stub, so every SKEmitterNode(fileNamed:) came back with
    // particleBirthRate 0 and emitted NOTHING — the entire game had no particle
    // effects (black-hole/level-up, explosions, smoke, aura, …). Return nil when
    // the file is missing so `if let` call sites skip cleanly, like Apple.
    public init?(fileNamed name: String) {
        super.init()
        guard SKSceneLoader.applyEmitterFile(name, to: self) else { return nil }
    }

    public func resetSimulation() {
        particles.removeAll()
        emitAccum = 0
        emittedSoFar = 0
    }
    public func advanceSimulationTime(_ t: TimeInterval) {
        let dt: TimeInterval = 1.0 / 60.0
        var remaining = t
        while remaining > 0 {
            tickSelf(min(dt, remaining))
            remaining -= dt
        }
    }

    public override func tickSelf(_ dt: TimeInterval) {
        // Universal particle-sim cull. Emitters don't move via SKActions, so
        // culling the sim is always safe: particles only matter where drawn, and
        // the draw is already culled by _cullExtent. When the world cull rect is
        // active and this emitter's spread is entirely outside it, skip integrate
        // + spawn for the frame. _cullRect is nil during the HUD pass and offscreen
        // bakes (saved+nil'd) — then we run normally. Reuse _cullExtent (already
        // computed from speed*lifetime + spread + quad) so the sim cull matches the
        // draw cull. absolutePosition() and _cullRect are both y-up world space.
        if let cull = SKNode._cullRect {
            let ext = _cullExtent
            if ext > 0 {
                let p = absolutePosition()
                let r = CGRect(x: p.x - ext, y: p.y - ext, width: ext * 2, height: ext * 2)
                if !r.intersects(cull) { return }
            }
        }
        let d = CGFloat(dt)
        // age + integrate (reverse iterate for safe in-place removal)
        var i = particles.count - 1
        while i >= 0 {
            particles[i].age += d
            let p = particles[i]
            if p.age >= p.life {
                particles[i] = particles[particles.count - 1]   // swap-remove: O(1), no O(n) array shift
                particles.removeLast()
                i -= 1
                continue
            }

            // Velocity integration (with global acceleration).
            particles[i].vx += xAcceleration * d
            particles[i].vy += yAcceleration * d
            particles[i].x  += particles[i].vx * d
            particles[i].y  += particles[i].vy * d

            // Alpha, scale, rotation.
            let agePct = p.life > 0 ? p.age / p.life : 1
            if let s = particleAlphaSequence?.sample(atTime: Double(agePct))?.cgFloat {
                particles[i].alpha = s
            } else {
                particles[i].alpha = max(0, p.alpha + particleAlphaSpeed * d)
            }
            if let s = particleScaleSequence?.sample(atTime: Double(agePct))?.cgFloat {
                particles[i].scale = s
            } else {
                particles[i].scale = max(0, p.scale + particleScaleSpeed * d)
            }
            particles[i].rotation += p.rotSpeed * d

            // Per-channel color drift.
            particles[i].r = clamp01(p.r + particleColorRedSpeed   * d)
            particles[i].g = clamp01(p.g + particleColorGreenSpeed * d)
            particles[i].b = clamp01(p.b + particleColorBlueSpeed  * d)
            particles[i].a = clamp01(p.a + particleColorAlphaSpeed * d)
            particles[i].blendFactor = clamp01(p.blendFactor + particleColorBlendFactorSpeed * d)
            if let c = particleColorSequence?.sample(atTime: Double(agePct))?.color {
                particles[i].r = c.r
                particles[i].g = c.g
                particles[i].b = c.b
                particles[i].a = c.a
            }
            if let bf = particleColorBlendFactorSequence?.sample(atTime: Double(agePct))?.cgFloat {
                particles[i].blendFactor = bf
            }
            i -= 1
        }
        // spawn
        let exhausted = numParticlesToEmit > 0 && emittedSoFar >= numParticlesToEmit
        if !exhausted && particleBirthRate > 0 {
            emitAccum += particleBirthRate * d
            while emitAccum >= 1 {
                emitAccum -= 1
                if particles.count >= maxLiveParticles { emitAccum = 0; break }   // cap live particles
                emitOne()
                emittedSoFar += 1
                if numParticlesToEmit > 0 && emittedSoFar >= numParticlesToEmit { break }
            }
        }
    }

    private static let UNIT: [(CGFloat, CGFloat)] = [
        (1, 0), (0.924, 0.383), (0.707, 0.707), (0.383, 0.924), (0, 1),
        (-0.383, 0.924), (-0.707, 0.707), (-0.924, 0.383), (-1, 0),
        (-0.924, -0.383), (-0.707, -0.707), (-0.383, -0.924), (0, -1),
        (0.383, -0.924), (0.707, -0.707), (0.924, -0.383),
    ]
    private func emitOne() {
        let halfAng = emissionAngleRange / 2
        let ang = emissionAngle + (halfAng > 0 ? Double.random(in: -halfAng...halfAng) : 0)
        let speed = particleSpeed + (particleSpeedRange > 0 ? Double.random(in: -particleSpeedRange/2 ... particleSpeedRange/2) : 0)
        let life = particleLifetime + (particleLifetimeRange > 0 ? Double.random(in: -particleLifetimeRange/2 ... particleLifetimeRange/2) : 0)
        // Continuous emission direction (Apple uses the exact angle). The old
        // 16-entry UNIT-table lookup quantized 360° radial emitters (aura,
        // blackHole, smoke, magic) into chunky spokes instead of a smooth halo.
        let cx = cos(ang), cy = sin(ang)

        // Position jitter inside particlePositionRange (treated as ±halfRange).
        let px = particlePosition.x + (particlePositionRange.dx > 0
                                       ? Double.random(in: -particlePositionRange.dx/2 ... particlePositionRange.dx/2)
                                       : 0)
        let py = particlePosition.y + (particlePositionRange.dy > 0
                                       ? Double.random(in: -particlePositionRange.dy/2 ... particlePositionRange.dy/2)
                                       : 0)

        let initialScale = particleScale + (particleScaleRange > 0
                                            ? Double.random(in: -particleScaleRange/2 ... particleScaleRange/2)
                                            : 0)
        let initialAlpha = particleAlpha + (particleAlphaRange > 0
                                            ? Double.random(in: -particleAlphaRange/2 ... particleAlphaRange/2)
                                            : 0)
        let initialRot   = particleRotation + (particleRotationRange > 0
                                               ? Double.random(in: -particleRotationRange/2 ... particleRotationRange/2)
                                               : 0)

        // Per-channel color initialization with range.
        let r0 = clamp01(particleColor.r + randRange(particleColorRedRange))
        let g0 = clamp01(particleColor.g + randRange(particleColorGreenRange))
        let b0 = clamp01(particleColor.b + randRange(particleColorBlueRange))
        let a0 = clamp01(particleColor.a + randRange(particleColorAlphaRange))
        let bf0 = clamp01(particleColorBlendFactor + randRange(particleColorBlendFactorRange))

        particles.append(Particle(x: px, y: py,
                                  vx: cx * speed, vy: cy * speed,
                                  age: 0, life: max(0.05, life),
                                  alpha: initialAlpha, scale: initialScale,
                                  rotation: initialRot, rotSpeed: particleRotationSpeed,
                                  r: r0, g: g0, b: b0, a: a0, blendFactor: bf0))
    }

    private func randRange(_ range: CGFloat) -> CGFloat {
        range > 0 ? Double.random(in: -range/2 ... range/2) : 0
    }
    private func clamp01(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }

    override func draw(alpha: CGFloat) {
        // Sort order honored only when oldestFirst (reverse drawing). dontCare/
        // oldestLast keep insertion order (newest on top).
        let list: [Particle] = particleRenderOrder == .oldestFirst ? particles.reversed() : particles
        if list.isEmpty { return }
        // Apply the emitter's blend mode once for the whole batch. screen/add make
        // particles GLOW (the white-hole/level-up effect is screen); reset after.
        let blendArg: Int32
        switch particleBlendMode {
        case .add:      blendArg = 1
        case .multiply: blendArg = 2
        case .screen:   blendArg = 3
        default:        blendArg = 0
        }
        if blendArg != 0 { gfx_set_blend(blendArg) }
        particleTexture?.resolvePending()   // live handle for deferred-name textures
        for p in list {
            let aOut = max(0, min(1, p.alpha)) * alpha * p.a
            if aOut <= 0.001 { continue }
            if let tex = particleTexture {
                // particleColorBlendFactor tints the TEXTURE: 0 = texture's own
                // colours (white tint), 1 = fully tinted by the particle's current
                // colour (driven by particleColorSequence / drift). The old code
                // tinted toward the flat, often-dark `particleColor`, so the
                // sequence-coloured white-hole rendered near-black and looked
                // missing. lerp(white -> particle colour) by blendFactor.
                let bf = p.blendFactor
                let w = Float(particleSize.width * p.scale)
                let h = Float(particleSize.height * p.scale)
                gfx_save()
                gfx_translate(Float(p.x), Float(p.y))
                if p.rotation != 0 { gfx_rotate(Float(p.rotation * 180.0 / Double.pi)) }
                // Apple colorBlendFactor: blend the texture TOWARD the particle's
                // current sequence colour by bf — the runtime does tex*(1-bf)+colour*bf
                // masked by alpha (source-atop). Correct for the COLOUR emoji textures
                // (smoke/magic/fire); white-texture emitters (aura/blackHole) render
                // identically. The draw rgba below carries the particle ALPHA only.
                gfx_set_tint(Float(p.r), Float(p.g), Float(p.b), Float(bf))
                // sw/sh MUST be -1 (full-source sentinel), NOT 0. A 0-size source
                // rect makes the runtime slice a 0×0 region (SVG) / throw (raster)
                // and the particle draws nothing — the white-hole was invisible
                // even though it spawned and moved. SKSpriteNode passes -1/-1 too.
                gfx_draw_image(tex.handle, 0, 0, -1, -1, -w/2, -h/2, w, h, SKColor(red: 1, green: 1, blue: 1, alpha: aOut).rgba)
                gfx_restore()
            } else {
                // Untextured: the particle is just its own colour.
                let c = SKColor(red: p.r, green: p.g, blue: p.b, alpha: aOut)
                let r = Float(max(0.5, particleSize.width / 2 * p.scale))
                gfx_fill_circle(Float(p.x), Float(p.y), r, c.rgba)
            }
        }
        if blendArg != 0 { gfx_set_blend(0) }
    }
}


