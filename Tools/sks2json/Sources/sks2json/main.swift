import Foundation
import SpriteKit

// sks2json — macOS CLI converter for .sks files.
//
// Apple's .sks files are binary plists produced by Xcode's Scene / Particle /
// Tile-Map editors and serialized with NSKeyedArchiver. There is no decoder for
// them outside Apple platforms, so we convert once on macOS — through REAL
// SpriteKit's NSKeyedUnarchiver — and emit portable JSON that the SuperBox64
// SpriteKit runtime (SKSceneLoader) rebuilds at game start.
//
// IMPORTANT (fixes the historical bug): we decode the archive DIRECTLY from the
// file path. The old code tried SKScene(fileNamed:)/SKReferenceNode(fileNamed:)/
// SKEmitterNode(fileNamed:) first — but those search the *app bundle*, not an
// arbitrary CLI path, and SKReferenceNode(fileNamed:) returns a lazy, empty
// node, so every file collapsed to `{"kind":"SKReferenceNode"}`. Decoding the
// archive root with NSKeyedUnarchiver is the authoritative path.
//
// Usage:
//   sks2json [--out <dir>] <file.sks> [file2.sks ...]
//   sks2json                            # recurse into CWD for every .sks
//
// This tool runs ONLY on macOS (it needs Apple's SpriteKit for NSCoding). It is
// never compiled to wasm, so it may use Foundation / Any freely.

// ---- arg parsing -----------------------------------------------------------
var args = Array(CommandLine.arguments.dropFirst())
var outDir: String? = nil
var inputs: [String] = []
var i = 0
while i < args.count {
    let a = args[i]
    if a == "--out" || a == "-o" {
        if i + 1 >= args.count { fail("--out requires a path") }
        outDir = args[i + 1]
        i += 2
        continue
    }
    if a == "-h" || a == "--help" {
        print("""
        sks2json — convert SpriteKit .sks to portable JSON

        Usage:
          sks2json [--out <dir>] <file.sks> [file2.sks ...]
          sks2json                            # recurse into CWD

        Options:
          --out, -o <dir>   write JSON files into <dir>
        """)
        exit(0)
    }
    inputs.append(a)
    i += 1
}

if inputs.isEmpty {
    let cwd = FileManager.default.currentDirectoryPath
    if let enumerator = FileManager.default.enumerator(atPath: cwd) {
        for case let file as String in enumerator where file.hasSuffix(".sks") {
            inputs.append((cwd as NSString).appendingPathComponent(file))
        }
    }
    if inputs.isEmpty { fail("no .sks files found in \(cwd)") }
}

var failures = 0
for input in inputs { convert(input) }
if failures > 0 { exit(1) }

func convert(_ input: String) {
    let url = URL(fileURLWithPath: input)
    let basename = url.deletingPathExtension().lastPathComponent
    let outPath: String
    if let dir = outDir {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        outPath = (dir as NSString).appendingPathComponent("\(basename).json")
    } else {
        outPath = url.deletingPathExtension().path + ".json"
    }

    guard let node = decodeRoot(url) else {
        warn("could not decode \(input)")
        failures += 1
        return
    }

    let json = encode(node)
    do {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: outPath))
        print("✓ \(input)  →  \(outPath)")
    } catch {
        warn("write failed for \(outPath): \(error)")
        failures += 1
    }
}

// ---- decode ----------------------------------------------------------------
// Levels store only `_rawTiles` + `_tileSetName`; the actual SKTileDefinitions
// (names + userData like ["isGrass": true]) live in EXTERNAL tilesets
// (GameTileSets/*.sks). SpriteKit resolves those by searching Bundle.main, so a
// raw NSKeyedUnarchiver of the level alone yields a tile map with empty cells.
//
// Strategy: stage the input .sks AND every sibling GameTileSets/*.sks into the
// CLI's own bundle, then load through SKScene(fileNamed:)/SKEmitterNode(fileNamed:)
// so SpriteKit resolves external tilesets exactly as the app does. Fall back to a
// direct path unarchive for anything the bundle loaders don't claim.
func decodeRoot(_ url: URL) -> SKNode? {
    stageResources(for: url)
    let base = url.deletingPathExtension().lastPathComponent

    // Scenes/levels (resolves embedded + external tilesets → populated cells).
    if let scene = SKScene(fileNamed: base) { return scene }
    // Particle emitters.
    if let emitter = SKEmitterNode(fileNamed: base) { return emitter }

    // Fallback: direct unarchive from the file path.
    guard let data = try? Data(contentsOf: url) else { return nil }
    if let un = try? NSKeyedUnarchiver(forReadingFrom: data) {
        un.requiresSecureCoding = false
        if let node = un.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? SKNode {
            un.finishDecoding()
            return node
        }
        un.finishDecoding()
    }
    if let any = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data),
       let node = any as? SKNode {
        return node
    }
    return nil
}

// Copy the input .sks plus any GameTileSets/*.sks found in an ancestor dir into
// the CLI's bundle resource dir, so SpriteKit's bundle-based loaders + external
// tileSetName resolution find them. Idempotent (overwrites each run).
func stageResources(for url: URL) {
    let fm = FileManager.default
    guard let resDir = Bundle.main.resourceURL ?? Bundle.main.executableURL?.deletingLastPathComponent() else { return }
    func stage(_ src: URL) {
        let dst = resDir.appendingPathComponent(src.lastPathComponent)
        if src.path == dst.path { return }
        try? fm.removeItem(at: dst)
        try? fm.copyItem(at: src, to: dst)
    }
    stage(url)
    var dir = url.deletingLastPathComponent()
    for _ in 0..<5 {
        let ts = dir.appendingPathComponent("GameTileSets")
        if fm.fileExists(atPath: ts.path),
           let en = fm.enumerator(at: ts, includingPropertiesForKeys: nil) {
            for case let f as URL in en where f.pathExtension == "sks" { stage(f) }
        }
        dir = dir.deletingLastPathComponent()
    }
}

// ---- node → dictionary -----------------------------------------------------
func encode(_ node: SKNode) -> [String: Any] {
    var d: [String: Any] = [:]
    d["kind"] = String(describing: type(of: node))
    if let n = node.name { d["name"] = n }
    d["position"]  = [node.position.x, node.position.y]
    if node.zPosition != 0 { d["zPosition"] = node.zPosition }
    if node.zRotation != 0 { d["zRotation"] = node.zRotation }
    if node.xScale   != 1 { d["xScale"]    = node.xScale }
    if node.yScale   != 1 { d["yScale"]    = node.yScale }
    if node.alpha    != 1 { d["alpha"]     = node.alpha }
    if node.isHidden       { d["isHidden"]  = true }

    if let s = node as? SKScene {
        d["size"] = [s.size.width, s.size.height]
        d["backgroundColor"] = rgba(s.backgroundColor)
        d["anchorPoint"] = [s.anchorPoint.x, s.anchorPoint.y]
    }
    if let s = node as? SKSpriteNode {
        d["size"] = [s.size.width, s.size.height]
        d["anchorPoint"] = [s.anchorPoint.x, s.anchorPoint.y]
        d["color"] = rgba(s.color)
        d["colorBlendFactor"] = s.colorBlendFactor
        // Texture name: prefer the description regex, fall back to the private
        // `imgName` ivar (same path the emitter uses for particle textures).
        // Without the fallback, atlas-backed sprites authored in a .sks (the
        // menu's latestlogo) lost their texture and rendered blank.
        if let tex = s.texture {
            let texName = tex.description.captureTextureName()
                ?? ((tex as AnyObject).value(forKey: "imgName") as? String)
            if let texName = texName, !texName.isEmpty { d["texture"] = texName }
        }
    }
    if let l = node as? SKLabelNode {
        d["text"] = l.text ?? ""
        d["fontSize"] = l.fontSize
        if let f = l.fontName { d["fontName"] = f }
        if let c = l.fontColor { d["fontColor"] = rgba(c) }
        // SKLabelHorizontalAlignmentMode raw values are center=0, left=1, right=2
        // (NOT left-first). The array MUST be indexed in that order or a .center
        // label exports as "left" and renders shifted-right (the title-screen
        // copyright was off-centre because of this).
        d["horizontalAlignment"] = ["center","left","right"][l.horizontalAlignmentMode.rawValue]
        d["verticalAlignment"]   = ["baseline","center","top","bottom"][l.verticalAlignmentMode.rawValue]
    }
    if let sh = node as? SKShapeNode {
        d["fillColor"]   = rgba(sh.fillColor)
        d["strokeColor"] = rgba(sh.strokeColor)
        d["lineWidth"]   = sh.lineWidth
    }
    if let e = node as? SKEmitterNode {
        emitter(e, into: &d)
    }
    if let tm = node as? SKTileMapNode {
        tileMap(tm, into: &d)
    }

    if !node.children.isEmpty {
        d["children"] = node.children.map { encode($0) }
    }
    return d
}

// ---- SKEmitterNode (full surface incl. blend mode + keyframe sequences) -----
func emitter(_ e: SKEmitterNode, into d: inout [String: Any]) {
    d["particleBirthRate"] = e.particleBirthRate
    d["numParticlesToEmit"] = e.numParticlesToEmit
    d["particleLifetime"] = e.particleLifetime
    d["particleLifetimeRange"] = e.particleLifetimeRange
    d["particleSpeed"] = e.particleSpeed
    d["particleSpeedRange"] = e.particleSpeedRange
    d["emissionAngle"] = e.emissionAngle
    d["emissionAngleRange"] = e.emissionAngleRange
    d["xAcceleration"] = e.xAcceleration
    d["yAcceleration"] = e.yAcceleration
    d["particlePosition"] = [e.particlePosition.x, e.particlePosition.y]
    d["particlePositionRange"] = [e.particlePositionRange.dx, e.particlePositionRange.dy]
    d["particleAlpha"] = e.particleAlpha
    d["particleAlphaRange"] = e.particleAlphaRange
    d["particleAlphaSpeed"] = e.particleAlphaSpeed
    d["particleScale"] = e.particleScale
    d["particleScaleRange"] = e.particleScaleRange
    d["particleScaleSpeed"] = e.particleScaleSpeed
    d["particleRotation"] = e.particleRotation
    d["particleRotationRange"] = e.particleRotationRange
    d["particleRotationSpeed"] = e.particleRotationSpeed
    d["particleColor"] = rgba(e.particleColor)
    d["particleColorBlendFactor"] = e.particleColorBlendFactor
    d["particleColorBlendFactorRange"] = e.particleColorBlendFactorRange
    d["particleColorBlendFactorSpeed"] = e.particleColorBlendFactorSpeed
    d["particleColorAlphaRange"] = e.particleColorAlphaRange
    d["particleColorAlphaSpeed"] = e.particleColorAlphaSpeed
    d["particleColorRedRange"] = e.particleColorRedRange
    d["particleColorRedSpeed"] = e.particleColorRedSpeed
    d["particleColorGreenRange"] = e.particleColorGreenRange
    d["particleColorGreenSpeed"] = e.particleColorGreenSpeed
    d["particleColorBlueRange"] = e.particleColorBlueRange
    d["particleColorBlueSpeed"] = e.particleColorBlueSpeed
    d["particleZPosition"] = e.particleZPosition
    d["particleBlendMode"] = e.particleBlendMode.rawValue
    d["particleSize"] = [e.particleSize.width, e.particleSize.height]
    // Particle texture name lives in SKTexture's private `_imgName` ivar (the
    // Particle editor's "Texture" field) — Apple exposes no public accessor, so
    // read it via KVC, falling back to the debug-description scrape.
    if let tex = e.particleTexture {
        let name = ((tex as AnyObject).value(forKey: "imgName") as? String)
            ?? tex.description.captureTextureName()
        if let n = name, !n.isEmpty { d["particleTexture"] = n }
    }
    // Per-particle ramps. Apple stores these as SKKeyframeSequence; serialize
    // each as { times:[…], values:[…] } (values are [r,g,b,a] for color ramps
    // or a scalar for alpha/scale/blend ramps).
    if let s = e.particleColorSequence            { d["particleColorSequence"]            = encodeSeq(s) }
    if let s = e.particleAlphaSequence            { d["particleAlphaSequence"]            = encodeSeq(s) }
    if let s = e.particleScaleSequence            { d["particleScaleSequence"]            = encodeSeq(s) }
    if let s = e.particleColorBlendFactorSequence { d["particleColorBlendFactorSequence"] = encodeSeq(s) }
}

func encodeSeq(_ s: SKKeyframeSequence) -> [String: Any] {
    // Resample the ramp at evenly spaced normalized times (0…1 over particle
    // lifetime) via getKeyframeValue(for:). This avoids Apple's ambiguous
    // index-accessor spelling and rebuilds a visually identical ramp on the
    // runtime side (linear interpolation over the same samples).
    var times: [Double] = []
    var values: [Any] = []
    let n = s.count()                                    // Apple: count() is a method
    var k = 0
    while k < n {
        times.append(Double(s.getKeyframeTime(for: k)))  // CGFloat time, label 'for'
        let v = s.getKeyframeValue(for: k)               // value by index, label 'for'
        if let c = v as? NSColor {
            values.append(rgba(c))
        } else if let num = v as? NSNumber {
            values.append(num.doubleValue)
        } else {
            values.append(0)
        }
        k += 1
    }
    return ["times": times, "values": values]
}

// ---- SKTileMapNode (per-cell name / userData / flip / textures) ------------
func tileMap(_ tm: SKTileMapNode, into d: inout [String: Any]) {
    d["tileSize"] = [tm.tileSize.width, tm.tileSize.height]
    d["numberOfColumns"] = tm.numberOfColumns
    d["numberOfRows"] = tm.numberOfRows
    if let setName = tm.tileSet.name { d["tileSet"] = setName }

    var cells: [[String: Any]] = []
    for col in 0..<tm.numberOfColumns {
        for row in 0..<tm.numberOfRows {
            guard let def = tm.tileDefinition(atColumn: col, row: row) else { continue }
            var cell: [String: Any] = ["column": col, "row": row]
            if let n = def.name { cell["name"] = n }
            if def.flipHorizontally { cell["flipHorizontally"] = true }
            if def.flipVertically   { cell["flipVertically"] = true }
            let texNames = def.textures.compactMap { $0.description.captureTextureName() }
            if !texNames.isEmpty { cell["textures"] = texNames }
            if let ud = def.userData, ud.count > 0 { cell["userData"] = jsonifyUserData(ud) }
            cells.append(cell)
        }
    }
    d["cells"] = cells
}

// NSMutableDictionary userData → JSON object. Booleans must survive as JSON
// true/false (the game reads `userData["isGrass"] as? Bool`), so distinguish
// __NSCFBoolean from numeric NSNumber via the CoreFoundation type id.
func jsonifyUserData(_ dict: NSDictionary) -> [String: Any] {
    var out: [String: Any] = [:]
    for (rawKey, rawVal) in dict {
        guard let key = rawKey as? String else { continue }
        if let num = rawVal as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() { out[key] = num.boolValue }
            else { out[key] = num.doubleValue }
        } else if let s = rawVal as? String {
            out[key] = s
        } else {
            out[key] = String(describing: rawVal)
        }
    }
    return out
}

// ---- helpers ---------------------------------------------------------------
func rgba(_ c: NSColor) -> [CGFloat] {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    (c.usingColorSpace(.deviceRGB) ?? c).getRed(&r, green: &g, blue: &b, alpha: &a)
    return [r, g, b, a]
}

extension String {
    // SKTexture's debug description includes "name='foo'"; pull it out so the
    // JSON references the asset by name (Apple exposes no public SKTexture name).
    func captureTextureName() -> String? {
        if let r = range(of: #"name='([^']+)'"#, options: .regularExpression) {
            let inner = String(self[r])
            if let s = inner.range(of: "'"), let e = inner.range(of: "'", range: s.upperBound..<inner.endIndex) {
                return String(inner[s.upperBound..<e.lowerBound])
            }
        }
        return nil
    }
}

func warn(_ s: String) { FileHandle.standardError.write(("⚠️  " + s + "\n").data(using: .utf8)!) }
func fail(_ s: String) -> Never {
    warn(s)
    exit(2)
}
