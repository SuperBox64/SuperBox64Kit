import KitABI

public enum SKSceneScaleMode { case fill, aspectFill, aspectFit, resizeFill }

open class SKScene: SKNode {
    public var size: CGSize
    public var backgroundColor: SKColor = SKColor(white: 0.06, alpha: 1)
    public var anchorPoint = CGPoint.zero
    public var scaleMode: SKSceneScaleMode = .aspectFit
    public let physicsWorld = SKPhysicsWorld()
    #if hasFeature(Embedded)
    public unowned(unsafe) var view: SKView?
    public unowned(unsafe) var camera: SKCameraNode?      // active camera; nil = default top-down
    #else
    public weak var view: SKView?
    public weak var camera: SKCameraNode?      // active camera; nil = default top-down
    #endif

    public init(size: CGSize) {
        self.size = size
        super.init()
    }
    public convenience override init() { self.init(size: CGSize(width: 1184, height: 666)) }

    open func didMove(to view: SKView) {}
    open func willMove(from view: SKView) {}
    open func didChangeSize(_ oldSize: CGSize) {}
    open func sceneDidLoad() {}                // called once before didMove
    var _sceneDidLoadFired = false
    // Apple: a scene's frame is its size at the origin (default anchorPoint).
    override public var frame: CGRect { CGRect(x: 0, y: 0, width: size.width, height: size.height) }
    open func update(_ currentTime: TimeInterval) {}
    open func didEvaluateActions() {}          // after actions, before physics
    open func didSimulatePhysics() {}
    open func didApplyConstraints() {}         // before didFinishUpdate
    open func didFinishUpdate() {}

    // Per-finger multi-touch delivered by the runtime. Open no-op defaults so
    // SKView can call them directly on any scene (no `as? SKTouchResponder`
    // runtime cast — which Embedded Swift can't resolve). Scenes override.
    open func touchBegan(finger: Int, at p: CGPoint) {}
    open func touchMoved(finger: Int, at p: CGPoint) {}
    open func touchEnded(finger: Int, at p: CGPoint) {}

    // SKView's debug render path looks for `convertPoint(fromView:)` and the
    // inverse so games can map mouse coordinates from view space.
    open func convertPoint(fromView p: CGPoint) -> CGPoint { p }
    open func convertPoint(toView p: CGPoint) -> CGPoint { p }

    // input hooks the demo/game can override
    open func keyDown(_ key: Int) { keyDown(with: NSEvent(keyCode: UInt16(truncatingIfNeeded: sfToMacKeyCode(key)))) }
    open func keyUp(_ key: Int) { keyUp(with: NSEvent(keyCode: UInt16(truncatingIfNeeded: sfToMacKeyCode(key)))) }
    open func mouseDown(at p: CGPoint, clickCount: Int = 1) { mouseDown(with: NSEvent(location: p, clickCount: clickCount)) }
    open func mouseUp(at p: CGPoint) { mouseUp(with: NSEvent(location: p)) }
    open func mouseMoved(to p: CGPoint) { mouseDragged(with: NSEvent(location: p)) }
    open func rightMouseDown(at p: CGPoint) { rightMouseDown(with: NSEvent(location: p)) }
    open func rightMouseUp(at p: CGPoint) {}

    // AppKit-shaped input entry points so a game's input overrides can be common
    // with the macOS build (NSResponder uses these signatures). The Int/CGPoint
    // dispatch above forwards into them; a pointer-move maps to mouseDragged (the
    // host only reports moves while a button is held, matching AppKit's drag).
    open func keyDown(with event: NSEvent) {}
    open func keyUp(with event: NSEvent) {}
    open func mouseDown(with event: NSEvent) {}
    open func mouseDragged(with event: NSEvent) {}
    open func mouseUp(with event: NSEvent) {}
    open func rightMouseDown(with event: NSEvent) {}

    // Render the scene's direct child subtrees, optionally skipping one node
    // (the active camera, whose own children draw screen-fixed in a separate
    // pass). The scene root carries an identity transform and draws nothing, so
    // this equals renderTree minus that one subtree.
    func renderWorld(skipping skip: SKNode?, parentAlpha: CGFloat) {
        let eff = parentAlpha * alpha
        // SpriteKit renders by GLOBAL accumulated zPosition — a node's render order
        // is the SUM of its own and all ancestor zPositions, NOT a per-parent sort.
        // That's why a laser at z=-100 (a SCENE child) draws ABOVE the parallax at
        // z=-243 (a WORLD child) yet BELOW the tiles at z=10, while the hero's face
        // child (z=24) still sits on the hero (z=150 -> 174). The old per-parent
        // sort drew the whole world (with its full-screen parallax) on top of the
        // laser, hiding it. Flatten the tree (skip the camera subtree — that's the
        // HUD pass), sort by accumulated z, draw each node's OWN content at its
        // absolute transform.
        var flat: [(node: SKNode, z: CGFloat, a: CGFloat, order: Int)] = []
        var counter = 0
        func collect(_ n: SKNode, _ accZ: CGFloat, _ accA: CGFloat, _ wx: CGFloat, _ wy: CGFloat) {
            if n === skip || n.isHidden || n.alpha <= 0 { return }
            let z = accZ + n.zPosition
            let a = accA * n.alpha
            let nx = wx + n.position.x, ny = wy + n.position.y
            var visible = true
            if let cull = SKNode._cullRect {
                let ext = n._cullExtent
                if ext > 0 {
                    let r = CGRect(x: nx - ext, y: ny - ext, width: ext * 2, height: ext * 2)
                    if !r.intersects(cull) { visible = false }
                }
            }
            if visible { flat.append((n, z, a, counter)); counter += 1 }
            for c in n.children { collect(c, z, a, nx, ny) }
        }
        for c in children where c !== skip { collect(c, 0, eff, 0, 0) }
        flat.sort { $0.z != $1.z ? $0.z < $1.z : $0.order < $1.order }
        for item in flat {
            gfx_save()
            // Re-apply the transform chain from this scene's child down to the node
            // (matches SKNode.renderTree's translate->rotate->scale per level) so the
            // node draws at its true absolute position/rotation/scale.
            var chain: [SKNode] = []
            var cur: SKNode? = item.node
            while let n = cur, n !== self { chain.append(n); cur = n.parent }
            for n in chain.reversed() {
                gfx_translate(Float(n.position.x), Float(n.position.y))
                if n.zRotation != 0 { gfx_rotate(Float(n.zRotation * 180.0 / Double.pi)) }
                if n.xScale != 1 || n.yScale != 1 { gfx_scale(Float(n.xScale), Float(n.yScale)) }
            }
            item.node.draw(alpha: item.a)
            gfx_restore()
        }
    }
}

// A scene opts into per-finger multi-touch by conforming. The host delivers
// these ALONGSIDE the finger-0 mouse pointer (so single-pointer scenes keep
// working untouched); a scene that needs true simultaneous presses (the 3D
// bonus D-pad) reads them here. Declared as a protocol — not SKScene methods —
// so the game conforms with a plain `func` on BOTH wasm and macOS (where the
// real SKScene has no such method to `override`). The macOS app re-declares an
// identical protocol in a companion; nothing calls it there (no touch hardware).
public protocol SKTouchResponder: AnyObject {
    func touchBegan(finger: Int, at p: CGPoint)
    func touchMoved(finger: Int, at p: CGPoint)
    func touchEnded(finger: Int, at p: CGPoint)
}

public typealias TimeInterval = Double

// Mimics the slice of AppKit's NSEvent that SpriteKit input handlers read, so a
// game's keyDown(with:)/mouseDown(with:) overrides can be common across macOS
// and wasm. Backed by a key code plus a scene-space point.
public struct NSEvent {
    public struct ModifierFlags: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let shift   = ModifierFlags(rawValue: 1 << 0)
        public static let control = ModifierFlags(rawValue: 1 << 1)
        public static let option  = ModifierFlags(rawValue: 1 << 2)
        public static let command = ModifierFlags(rawValue: 1 << 3)
        public static let function = ModifierFlags(rawValue: 1 << 4)
    }
    public var keyCode: UInt16
    // Letter/digit for the current (mac virtual) keyCode, like AppKit provides.
    public var charactersIgnoringModifiers: String? {
        let letters: [UInt16: String] = [
            0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h",
            34: "i", 38: "j", 40: "k", 37: "l", 46: "m", 45: "n", 31: "o",
            35: "p", 12: "q", 15: "r", 1: "s", 17: "t", 32: "u", 9: "v",
            13: "w", 7: "x", 16: "y", 6: "z",
            29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
            26: "7", 28: "8", 25: "9", 49: " ",
        ]
        return letters[keyCode]
    }
    public var modifierFlags: ModifierFlags
    // macOS-parity fields so unmodified AppKit game code reads them with no #if.
    // The web runtime delivers discrete key/pointer callbacks: no auto-repeat
    // (the host fires one event per press) and no relative mouse delta.
    public var isARepeat: Bool
    public var deltaX: CGFloat
    public var deltaY: CGFloat
    public var clickCount: Int
    private let point: CGPoint
    public init(keyCode: UInt16 = 0, location: CGPoint = .zero, modifierFlags: ModifierFlags = [],
                isARepeat: Bool = false, deltaX: CGFloat = 0, deltaY: CGFloat = 0, clickCount: Int = 1) {
        self.keyCode = keyCode
        self.point = location
        self.modifierFlags = modifierFlags
        self.isARepeat = isARepeat
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.clickCount = clickCount
    }
    public func location(in node: SKNode) -> CGPoint { point }
}


// The runtime delivers SFML key codes; NSEvent.keyCode is macOS virtual codes.
// Translating here lets unmodified macOS keyCode switches (case 123, 49, ...)
// work on wasm, so games need no platform key tables.
func sfToMacKeyCode(_ sf: Int) -> Int {
    switch sf {
    case 0: return 0       // A
    case 1: return 11      // B
    case 2: return 8       // C
    case 3: return 2       // D
    case 4: return 14      // E
    case 5: return 3       // F
    case 6: return 5       // G
    case 7: return 4       // H
    case 8: return 34      // I
    case 9: return 38      // J
    case 10: return 40     // K
    case 11: return 37     // L
    case 12: return 46     // M
    case 13: return 45     // N
    case 14: return 31     // O
    case 15: return 35     // P
    case 16: return 12     // Q
    case 17: return 15     // R
    case 18: return 1      // S
    case 19: return 17     // T
    case 20: return 32     // U
    case 21: return 9      // V
    case 22: return 13     // W
    case 23: return 7      // X
    case 24: return 16     // Y
    case 25: return 6      // Z
    case 26: return 29     // 0
    case 27: return 18     // 1
    case 28: return 19     // 2
    case 29: return 20     // 3
    case 30: return 21     // 4
    case 31: return 23     // 5
    case 32: return 22     // 6
    case 33: return 26     // 7
    case 34: return 28     // 8
    case 35: return 25     // 9
    case 36: return 53     // Escape
    case 57: return 49     // Space
    case 58: return 36     // Enter -> Return
    case 59: return 51     // Backspace -> Delete
    case 60: return 48     // Tab
    case 71: return 123    // Left
    case 72: return 124    // Right
    case 73: return 126    // Up
    case 74: return 125    // Down
    default: return sf + 1000
    }
}
