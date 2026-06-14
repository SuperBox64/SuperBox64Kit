import KitABI

// .sks → JSON scene loader.
//
// Apple's .sks files are binary plists from the SpriteKit Particle / Scene
// editors; they aren't portable to WASI. The companion CLI sks2json
// (Tools/sks2json on macOS) walks the in-memory scene graph through Apple's
// SpriteKit and emits a portable JSON file with the same name, e.g.:
//   Level5.sks → Level5.json
//
// At runtime SKScene(fileNamed:) / SKReferenceNode(fileNamed:) /
// SKEmitterNode(fileNamed:) look for that JSON via the kit's asset_text ABI,
// then rebuild the node tree by walking the parsed JSONValue.
//
// JSON schema (subset of SpriteKit's node attributes):
//   {
//     "kind": "SKScene" | "SKSpriteNode" | "SKShapeNode" | "SKLabelNode" |
//             "SKEmitterNode" | "SKReferenceNode" | "SKNode" | "SKCameraNode" |
//             "SKTileMapNode" | ...,
//     "name": "playerSpawn",
//     "position": [x, y],
//     "zRotation": 0.0,
//     "zPosition": 0.0,
//     "xScale": 1.0,
//     "yScale": 1.0,
//     "alpha": 1.0,
//     "size": [w, h],                      // SKScene / SKSpriteNode / SKLabelNode
//     "anchorPoint": [x, y],               // SKSpriteNode
//     "color": [r, g, b, a],               // 0..1
//     "colorBlendFactor": 0..1,
//     "texture": "image-name",             // SKSpriteNode
//     "text": "Score",                     // SKLabelNode
//     "fontSize": 24,
//     "fontName": "JetBrainsMono-Bold",
//     "fontColor": [r, g, b, a],
//     "horizontalAlignment": "center"|"left"|"right",
//     "verticalAlignment":   "center"|"top"|"bottom"|"baseline",
//     "particleBirthRate": ...,            // SKEmitterNode + all property surface
//     "fileNamed": "Level5",               // SKReferenceNode
//     "children": [ ... ]
//   }

public enum SKSceneLoader {
    // Public entry: load a JSON file (compiled from .sks) and reconstruct the
    // root SKNode. Returns nil when the file isn't found or parsing fails.
    public static func loadNode(fileNamed name: String) -> SKNode? {
        guard let json = loadJSON(named: name) else { return nil }
        return build(from: json)
    }
    public static func loadScene(fileNamed name: String) -> SKScene? {
        guard let json = loadJSON(named: name) else { return nil }
        guard let node = build(from: json) as? SKScene else {
            // Wrap a non-scene root in a default scene for compatibility.
            let scene = SKScene(size: CGSize(width: 1184, height: 666))
            if let n = build(from: json) { scene.addChild(n) }
            return scene
        }
        return node
    }
    public static func loadEmitter(fileNamed name: String) -> SKEmitterNode? {
        let emitter = SKEmitterNode()
        return applyEmitterFile(name, to: emitter) ? emitter : nil
    }

    // Populate an EXISTING emitter from its particle JSON. SKEmitterNode(fileNamed:)
    // configures `self` (a failable init can't swap in loadEmitter's fresh
    // instance), so the load logic lives here and both paths share it.
    static func applyEmitterFile(_ name: String, to e: SKEmitterNode) -> Bool {
        guard let json = loadJSON(named: name) else { return false }
        applyCommonProps(json, to: e)
        applyEmitterProps(json, to: e)
        return true
    }

    // ---- File loader ----------------------------------------------------------
    private static func loadJSON(named name: String) -> JSONValue? {
        // Try a few common spellings. The CLI emits "<basename>.json" so the
        // most common case is direct.
        for candidate in [name, "\(name).json", "\(name).sks.json"] {
            if let bytes = readAssetText(candidate),
               let obj = parseJSON(bytes), obj.objectValue != nil {
                return obj
            }
        }
        return nil
    }

    // Public helper for non-loader call sites (SKShader(fileNamed:) etc.).
    public static func loadAssetText(_ path: String) -> String? { readAssetText(path) }

    private static func readAssetText(_ path: String) -> String? {
        let exists = withUTF8Ptr(path) { ptr, n -> Int32 in asset_exists(ptr, n) }
        if exists == 0 { return nil }
        // Probe size by passing a 1-byte buffer first; asset_text returns the
        // total byte length so we can allocate the right size.
        var probe: [Int8] = [0]
        let total = probe.withUnsafeMutableBufferPointer { p in
            withUTF8Ptr(path) { kptr, kn in asset_text(kptr, kn, p.baseAddress, Int32(1)) }
        }
        if total <= 0 { return nil }
        let cap = Int(total) + 1
        var buf = [Int8](repeating: 0, count: cap)
        _ = buf.withUnsafeMutableBufferPointer { p -> Int32 in
            let cap32 = Int32(p.count)
            return withUTF8Ptr(path) { kptr, kn in asset_text(kptr, kn, p.baseAddress, cap32) }
        }
        return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    // ---- Construction --------------------------------------------------------
    private static func build(from json: JSONValue) -> SKNode? {
        let kind = json["kind"]?.stringValue ?? "SKNode"
        let node: SKNode
        switch kind {
        case "SKScene":
            let size = readSize(json["size"]) ?? CGSize(width: 1184, height: 666)
            let scene = SKScene(size: size)
            if let bg = readColor(json["backgroundColor"]) { scene.backgroundColor = bg }
            if let ap = readPoint(json["anchorPoint"]) { scene.anchorPoint = ap }
            node = scene
        case "SKSpriteNode":
            let size = readSize(json["size"]) ?? CGSize(width: 32, height: 32)
            let color = readColor(json["color"]) ?? .white
            let sprite = SKSpriteNode(color: color, size: size)
            if let texName = json["texture"]?.stringValue {
                sprite.texture = SKTexture(imageNamed: texName)
            }
            if let ap = readPoint(json["anchorPoint"]) { sprite.anchorPoint = ap }
            if let cbf = readCGFloat(json["colorBlendFactor"]) { sprite.colorBlendFactor = cbf }
            node = sprite
        case "SKLabelNode":
            let text = json["text"]?.stringValue ?? ""
            let label = SKLabelNode(text: text)
            if let s = readCGFloat(json["fontSize"]) { label.fontSize = s }
            if let f = json["fontName"]?.stringValue { label.fontName = f }
            if let c = readColor(json["fontColor"]) { label.fontColor = c }
            if let h = json["horizontalAlignment"]?.stringValue {
                switch h {
                    case "left": label.horizontalAlignmentMode = .left
                    case "right": label.horizontalAlignmentMode = .right
                    default: label.horizontalAlignmentMode = .center
                }
            }
            if let v = json["verticalAlignment"]?.stringValue {
                switch v {
                    case "top": label.verticalAlignmentMode = .top
                    case "bottom": label.verticalAlignmentMode = .bottom
                    case "baseline": label.verticalAlignmentMode = .baseline
                    default: label.verticalAlignmentMode = .center
                }
            }
            node = label
        case "SKShapeNode":
            let shape: SKShapeNode
            if let r = readCGFloat(json["radius"]) {
                shape = SKShapeNode(circleOfRadius: r)
            } else if let size = readSize(json["size"]) {
                shape = SKShapeNode(rectOf: size)
            } else {
                shape = SKShapeNode()
            }
            if let c = readColor(json["fillColor"])   { shape.fillColor = c }
            if let c = readColor(json["strokeColor"]) { shape.strokeColor = c }
            if let w = readCGFloat(json["lineWidth"]) { shape.lineWidth = w }
            node = shape
        case "SKEmitterNode":
            let emitter = SKEmitterNode()
            applyEmitterProps(json, to: emitter)
            node = emitter
        case "SKReferenceNode":
            if let inner = json["fileNamed"]?.stringValue,
               let ref = loadNode(fileNamed: inner) {
                node = ref
            } else {
                node = SKReferenceNode()
            }
        case "SKCameraNode":
            node = SKCameraNode()
        case "SKTileMapNode":
            // Rebuild the tile map from sks2json cells so GameWorld can read each
            // cell's tileDefinition(name + userData) — the level geometry/spawns.
            let cols = json["numberOfColumns"]?.intValue ?? 0
            let rows = json["numberOfRows"]?.intValue ?? 0
            let tsz = readSize(json["tileSize"]) ?? .zero
            let tm = SKTileMapNode(tileSet: SKTileSet(), columns: cols, rows: rows, tileSize: tsz)
            if let cells = json["cells"]?.arrayValue {
                for cell in cells {
                    guard let col = cell["column"]?.intValue, let row = cell["row"]?.intValue else { continue }
                    let def = SKTileDefinition()
                    if let nm = cell["name"]?.stringValue { def.name = nm }
                    if let fh = cell["flipHorizontally"]?.boolValue { def.flipHorizontally = fh }
                    if let fv = cell["flipVertically"]?.boolValue { def.flipVertically = fv }
                    if let texs = cell["textures"]?.arrayValue {
                        def.textures = texs.compactMap { $0.stringValue }.map { SKTexture(imageNamed: $0) }
                    }
                    if let ud = cell["userData"]?.objectValue, !ud.isEmpty {
                        let dict = NSMutableDictionary()
                        for (k, v) in ud {
                            if let b = v.boolValue        { dict[k] = b }
                            else if let d = v.doubleValue { dict[k] = d }
                            else if let s = v.stringValue { dict[k] = s }
                        }
                        def.userData = dict
                    }
                    tm.setTileGroup(SKTileGroup(tileDefinition: def), andTileDefinition: def, forColumn: col, row: row)
                }
            }
            node = tm
        default:
            node = SKNode()
        }
        applyCommonProps(json, to: node)
        if let kids = json["children"]?.arrayValue {
            for child in kids {
                if child.objectValue != nil, let cnode = build(from: child) {
                    node.addChild(cnode)
                }
            }
        }
        return node
    }

    // ---- Property helpers ----------------------------------------------------
    private static func applyCommonProps(_ json: JSONValue, to node: SKNode) {
        if let p = readPoint(json["position"])  { node.position  = p }
        if let z = readCGFloat(json["zPosition"]) { node.zPosition = z }
        if let r = readCGFloat(json["zRotation"]) { node.zRotation = r }
        if let s = readCGFloat(json["xScale"])    { node.xScale = s }
        if let s = readCGFloat(json["yScale"])    { node.yScale = s }
        if let a = readCGFloat(json["alpha"])     { node.alpha = a }
        if let n = json["name"]?.stringValue       { node.name = n }
        if let h = json["isHidden"]?.boolValue     { node.isHidden = h }
    }
    private static func applyEmitterProps(_ json: JSONValue, to e: SKEmitterNode) {
        if let v = readCGFloat(json["particleBirthRate"])     { e.particleBirthRate = v }
        if let v = json["numParticlesToEmit"]?.intValue        { e.numParticlesToEmit = v }
        if let v = readCGFloat(json["particleLifetime"])       { e.particleLifetime = v }
        if let v = readCGFloat(json["particleLifetimeRange"])  { e.particleLifetimeRange = v }
        if let v = readCGFloat(json["particleSpeed"])          { e.particleSpeed = v }
        if let v = readCGFloat(json["particleSpeedRange"])     { e.particleSpeedRange = v }
        if let v = readCGFloat(json["emissionAngle"])          { e.emissionAngle = v }
        if let v = readCGFloat(json["emissionAngleRange"])     { e.emissionAngleRange = v }
        if let v = readCGFloat(json["xAcceleration"])          { e.xAcceleration = v }
        if let v = readCGFloat(json["yAcceleration"])          { e.yAcceleration = v }
        if let v = readCGFloat(json["particleAlpha"])          { e.particleAlpha = v }
        if let v = readCGFloat(json["particleAlphaRange"])     { e.particleAlphaRange = v }
        if let v = readCGFloat(json["particleAlphaSpeed"])     { e.particleAlphaSpeed = v }
        if let v = readCGFloat(json["particleScale"])          { e.particleScale = v }
        if let v = readCGFloat(json["particleScaleRange"])     { e.particleScaleRange = v }
        if let v = readCGFloat(json["particleScaleSpeed"])     { e.particleScaleSpeed = v }
        if let v = readCGFloat(json["particleRotation"])       { e.particleRotation = v }
        if let v = readCGFloat(json["particleRotationRange"])  { e.particleRotationRange = v }
        if let v = readCGFloat(json["particleRotationSpeed"])  { e.particleRotationSpeed = v }
        if let c = readColor(json["particleColor"])            { e.particleColor = c }
        if let v = readCGFloat(json["particleColorBlendFactor"])      { e.particleColorBlendFactor = v }
        if let v = readCGFloat(json["particleColorBlendFactorRange"]) { e.particleColorBlendFactorRange = v }
        if let v = readCGFloat(json["particleColorBlendFactorSpeed"]) { e.particleColorBlendFactorSpeed = v }
        if let s = readSize(json["particleSize"])              { e.particleSize = s }
        if let texName = json["particleTexture"]?.stringValue {
            e.particleTexture = SKTexture(imageNamed: texName)
        }
        if let bm = json["particleBlendMode"]?.intValue, let mode = SKBlendMode(rawValue: bm) {
            e.particleBlendMode = mode
        }
        // Keyframe sequences ({"times":[…],"values":[…]}). Colours are [r,g,b,a]
        // arrays; alpha/scale/blendFactor are scalars. These drive the per-particle
        // ramps — e.g. the white-hole's white→cyan colour fade. Without them the
        // particle stays its flat base colour for its whole life.
        if let s = readColorSequence(json["particleColorSequence"])             { e.particleColorSequence = s }
        if let s = readNumberSequence(json["particleAlphaSequence"])            { e.particleAlphaSequence = s }
        if let s = readNumberSequence(json["particleScaleSequence"])            { e.particleScaleSequence = s }
        if let s = readNumberSequence(json["particleColorBlendFactorSequence"]) { e.particleColorBlendFactorSequence = s }
    }

    private static func readColorSequence(_ v: JSONValue?) -> SKKeyframeSequence? {
        guard let o = v?.objectValue,
              let times = o["times"]?.arrayValue,
              let vals  = o["values"]?.arrayValue,
              !times.isEmpty, times.count == vals.count else { return nil }
        var kfv: [SKKeyframeValue] = [], kft: [Double] = []
        for (t, c) in zip(times, vals) {
            guard let tt = t.doubleValue, let col = readColor(c) else { continue }
            kfv.append(.color(col)); kft.append(tt)
        }
        return kfv.isEmpty ? nil : SKKeyframeSequence(keyframeValues: kfv, times: kft)
    }
    private static func readNumberSequence(_ v: JSONValue?) -> SKKeyframeSequence? {
        guard let o = v?.objectValue,
              let times = o["times"]?.arrayValue,
              let vals  = o["values"]?.arrayValue,
              !times.isEmpty, times.count == vals.count else { return nil }
        var kfv: [SKKeyframeValue] = [], kft: [Double] = []
        for (t, n) in zip(times, vals) {
            guard let tt = t.doubleValue, let nn = n.doubleValue else { continue }
            kfv.append(.number(nn)); kft.append(tt)
        }
        return kfv.isEmpty ? nil : SKKeyframeSequence(keyframeValues: kfv, times: kft)
    }

    private static func readSize(_ v: JSONValue?) -> CGSize? {
        guard let arr = v?.arrayValue, arr.count >= 2,
              let w = readCGFloat(arr[0]), let h = readCGFloat(arr[1]) else { return nil }
        return CGSize(width: w, height: h)
    }
    private static func readPoint(_ v: JSONValue?) -> CGPoint? {
        guard let arr = v?.arrayValue, arr.count >= 2,
              let x = readCGFloat(arr[0]), let y = readCGFloat(arr[1]) else { return nil }
        return CGPoint(x: x, y: y)
    }
    private static func readColor(_ v: JSONValue?) -> SKColor? {
        guard let arr = v?.arrayValue, arr.count >= 3,
              let r = readCGFloat(arr[0]), let g = readCGFloat(arr[1]), let b = readCGFloat(arr[2]) else { return nil }
        let a = arr.count >= 4 ? (readCGFloat(arr[3]) ?? 1) : 1
        return SKColor(red: r, green: g, blue: b, alpha: a)
    }
    private static func readCGFloat(_ v: JSONValue?) -> CGFloat? {
        if let d = v?.doubleValue { return CGFloat(d) }
        return nil
    }
}

// =============================================================================
// SKScene(fileNamed:) / SKReferenceNode(fileNamed:) routes through the loader.
// We add convenience initializers that try the loader and fall back to the
// existing empty-node behaviour if the JSON isn't found.
// =============================================================================
public extension SKScene {
    convenience init?(fileNamed name: String) {
        if let scene = SKSceneLoader.loadScene(fileNamed: name) {
            self.init(size: scene.size)
            self.backgroundColor = scene.backgroundColor
            self.anchorPoint = scene.anchorPoint
            for child in scene.children { self.addChild(child) }
            return
        }
        return nil
    }
}
