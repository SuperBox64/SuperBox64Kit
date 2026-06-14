import KitABI

// =============================================================================
// AppleCompat — UIKit / AppKit drop-in surface, hosted in the SpriteKit module.
//
// iOS/macOS SpriteKit games routinely use `import SpriteKit` alone yet reference
// UIKit/AppKit types (UIImage, UITouch, NSCoder, UIScreen, UIBezierPath, …)
// because Apple's SpriteKit umbrella re-exports them. To match that, these
// shims live in SpriteKit (the lowest module) so `import SpriteKit` provides
// them; the AppKit and UIKit modules re-export this module so their own
// importers keep working. Single definition each → no cross-module ambiguity.
// =============================================================================

// ---- Colors / color space --------------------------------------------------
public typealias UIColor = SKColor

public enum NSColorSpace: Sendable { case deviceRGB, genericRGB, sRGB, displayP3, genericGray }
public extension SKColor {
    func usingColorSpace(_ space: NSColorSpace) -> SKColor? { self }
}

// ---- NSCoder (name-only; .sks never archives at runtime) --------------------
public final class NSCoder { public init() {} }

// ---- NSImage / UIImage -----------------------------------------------------
public final class NSImage {
    public let name: String
    public init?(named name: String) {
        guard textureNamed(name) != nil else { return nil }
        self.name = name
    }
    public init?(contentsOfFile path: String) {
        guard textureNamed(path) != nil else { return nil }
        self.name = path
    }
    public convenience init?(contentsOf url: URL) { self.init(named: url.resource) }
    public var size: CGSize { textureNamed(name)?.size() ?? .zero }
}
public typealias UIImage = NSImage

public extension SKTexture {
    convenience init(image: NSImage) { self.init(imageNamed: image.name) }
}

// ---- NSFont / UIFont -------------------------------------------------------
public final class NSFont {
    public let fontName: String
    public let pointSize: CGFloat
    public init(name: String, size: CGFloat) { self.fontName = name; self.pointSize = size }
    public static func systemFont(ofSize size: CGFloat) -> NSFont { NSFont(name: "system", size: size) }
    public static func boldSystemFont(ofSize size: CGFloat) -> NSFont { NSFont(name: "system-bold", size: size) }
}
public typealias UIFont = NSFont

// ---- NSBezierPath / UIBezierPath -------------------------------------------
public final class NSBezierPath {
    public let cgPath = CGMutablePath()
    public init() {}
    public init(rect r: CGRect) { cgPath.addRect(r) }
    public init(ovalIn r: CGRect) { cgPath.addEllipse(in: r) }
    // iOS UIBezierPath surface used by the game (arcs + curves).
    public convenience init(arcCenter center: CGPoint, radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat, clockwise: Bool) {
        self.init()
        cgPath.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: clockwise)
    }
    public func move(to p: CGPoint) { cgPath.move(to: p) }
    public func line(to p: CGPoint) { cgPath.addLine(to: p) }
    public func addLine(to p: CGPoint) { cgPath.addLine(to: p) }
    public func addQuadCurve(to end: CGPoint, controlPoint cp: CGPoint) {
        cgPath.addQuadCurve(to: end, control: cp)
    }
    public func addCurve(to end: CGPoint, controlPoint1 c1: CGPoint, controlPoint2 c2: CGPoint) {
        cgPath.addCurve(to: end, control1: c1, control2: c2)
    }
    public func close() { cgPath.closeSubpath() }
}
public typealias UIBezierPath = NSBezierPath

// ---- UIScreen --------------------------------------------------------------
public final class UIScreen {
    nonisolated(unsafe) public static let main = UIScreen()
    public var bounds: CGRect { CGRect(x: 0, y: 0, width: CGFloat(win_width()), height: CGFloat(win_height())) }
    public var nativeBounds: CGRect { bounds }
    public var scale: CGFloat = 1
    public var nativeScale: CGFloat = 1
}

// ---- UIApplication / delegate ----------------------------------------------
public protocol UIApplicationDelegate: AnyObject {}
public protocol UISceneDelegate: AnyObject {}

public enum UIApplicationState: Int, Sendable { case active, inactive, background }

public final class UIApplication {
    nonisolated(unsafe) public static let shared = UIApplication()
    #if hasFeature(Embedded)
    public unowned(unsafe) var delegate: UIApplicationDelegate?
    #else
    public weak var delegate: UIApplicationDelegate?
    #endif
    public var isIdleTimerDisabled = false
    public var applicationState: UIApplicationState = .active
    public struct LaunchOptionsKey: Hashable { public let raw: String; public init(_ r: String = "") { raw = r } }
    public func open(_ url: URL, options: [String: String] = [:], completionHandler: ((Bool) -> Void)? = nil) {
        completionHandler?(false)
    }
}

// ---- UIResponder / UITouch / UIEvent ---------------------------------------
open class UIResponder {
    public init() {}
    open var next: UIResponder? { nil }
    open func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
    open func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
    open func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
    open func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}
}

public enum UITouchPhase { case began, moved, stationary, ended, cancelled, regionEntered, regionMoved, regionExited }

public final class UITouch: Hashable {
    public var phase: UITouchPhase = .began
    public var tapCount: Int = 1
    public var force: CGFloat = 0
    public var maximumPossibleForce: CGFloat = 1
    public var timestamp: TimeInterval = 0
    #if hasFeature(Embedded)
    public unowned(unsafe) var view: UIView?
    #else
    public weak var view: UIView?
    #endif
    private let id = UUID()
    public init() {}
    // Scene-relative location injected by the runtime; defaults read live mouse.
    public var _sceneLocation: CGPoint? = nil
    public func location(in view: UIView?) -> CGPoint { CGPoint(x: CGFloat(mouse_x()), y: CGFloat(mouse_y())) }
    public func location(in node: SKNode) -> CGPoint {
        // _sceneLocation is the touch in WORLD coords (set by SKView.dispatch).
        // Convert into the target node's LOCAL space — for the joystick that's
        // the offset-from-centre the stick math needs; for the scene it's the
        // world point its atPoint() dispatch expects. convertFromWorld is
        // camera-aware (the HUD/joystick live under the SKCameraNode).
        if let p = _sceneLocation { return node.convertFromWorld(p) }
        let h = CGFloat(node.scene?.size.height ?? CGFloat(win_height()))
        return CGPoint(x: CGFloat(mouse_x()), y: h - CGFloat(mouse_y()))
    }
    public func previousLocation(in view: UIView?) -> CGPoint { location(in: view) }
    public func hash(into h: inout Hasher) { h.combine(id) }
    public static func == (a: UITouch, b: UITouch) -> Bool { a.id == b.id }
}

public final class UIEvent {
    public init() {}
    public func allTouches() -> Set<UITouch>? { nil }
    public func touches(for view: UIView?) -> Set<UITouch>? { nil }
}

// Minimal UUID (libc-seeded via KitABI) so UITouch identity works without Foundation.
public struct UUID: Hashable {
    private let a: UInt64, b: UInt64
    public init() {
        a = (UInt64(UInt32(bitPattern: sb64_rand())) << 32) | UInt64(UInt32(bitPattern: sb64_rand()))
        b = (UInt64(UInt32(bitPattern: sb64_rand())) << 32) | UInt64(UInt32(bitPattern: sb64_rand()))
    }
}

// ---- UIView / UIViewController / UIWindow -----------------------------------
public enum UIUserInterfaceIdiom: Int { case unspecified = -1, phone, pad, tv, carPlay, mac, vision }
public enum UIDeviceOrientation: Int { case unknown, portrait, portraitUpsideDown, landscapeLeft, landscapeRight, faceUp, faceDown }

public struct UIRectEdge: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let top    = UIRectEdge(rawValue: 1 << 0)
    public static let left   = UIRectEdge(rawValue: 1 << 1)
    public static let bottom = UIRectEdge(rawValue: 1 << 2)
    public static let right  = UIRectEdge(rawValue: 1 << 3)
    public static let all: UIRectEdge = [.top, .left, .bottom, .right]
    public static let none: UIRectEdge = []
}
public struct UIInterfaceOrientationMask: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let portrait           = UIInterfaceOrientationMask(rawValue: 1 << 1)
    public static let landscapeLeft      = UIInterfaceOrientationMask(rawValue: 1 << 4)
    public static let landscapeRight     = UIInterfaceOrientationMask(rawValue: 1 << 3)
    public static let portraitUpsideDown = UIInterfaceOrientationMask(rawValue: 1 << 2)
    public static let landscape: UIInterfaceOrientationMask = [.landscapeLeft, .landscapeRight]
    public static let all: UIInterfaceOrientationMask = [.portrait, .landscapeLeft, .landscapeRight, .portraitUpsideDown]
    public static let allButUpsideDown: UIInterfaceOrientationMask = [.portrait, .landscapeLeft, .landscapeRight]
}

open class UIView: UIResponder {
    public var frame: CGRect = .zero
    public var bounds: CGRect = .zero
    public var center: CGPoint = .zero
    public var backgroundColor: UIColor? = nil
    public var isUserInteractionEnabled = true
    public var isMultipleTouchEnabled = false
    public var isOpaque = true
    public var isHidden = false
    public var alpha: CGFloat = 1
    public var tag: Int = 0
    public var clipsToBounds = false
    public var subviews: [UIView] = []
    #if hasFeature(Embedded)
    public unowned(unsafe) var superview: UIView?
    #else
    public weak var superview: UIView?
    #endif

    public override init() { super.init() }
    public init(frame: CGRect) {
        self.frame = frame
        self.bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        super.init()
    }
    public func addSubview(_ v: UIView) { v.superview = self; subviews.append(v) }
    public func removeFromSuperview() { superview?.subviews.removeAll { $0 === self }; superview = nil }
    public func bringSubviewToFront(_ v: UIView) {}
    public func sendSubviewToBack(_ v: UIView) {}
    public func addGestureRecognizer(_ g: UIGestureRecognizer) { g.view = self }
    public func removeGestureRecognizer(_ g: UIGestureRecognizer) { g.view = nil }
    public func setNeedsLayout() {}
    public func setNeedsDisplay() {}
    public func layoutIfNeeded() {}
    public func layoutSubviews() {}
    public func drawHierarchy(in rect: CGRect, afterScreenUpdates: Bool) -> Bool { false }
}

open class UIViewController: UIResponder {
    public var view: UIView = UIView()
    public var title: String?
    public var presentingViewController: UIViewController?
    public var presentedViewController: UIViewController?
    public var children: [UIViewController] = []
    public var parent: UIViewController?

    public override init() { super.init() }
    open func loadView() {}
    open func viewDidLoad() {}
    open func viewWillAppear(_ animated: Bool) {}
    open func viewDidAppear(_ animated: Bool) {}
    open func viewWillDisappear(_ animated: Bool) {}
    open func viewDidDisappear(_ animated: Bool) {}
    open func viewDidLayoutSubviews() {}
    open func didReceiveMemoryWarning() {}
    // Orientation / status-bar override surface (iOS view controllers override these).
    open var shouldAutorotate: Bool { true }
    open var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
    open var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { [] }
    open var prefersHomeIndicatorAutoHidden: Bool { false }
    open var prefersStatusBarHidden: Bool { false }
    public func present(_ vc: UIViewController, animated: Bool, completion: (() -> Void)? = nil) { completion?() }
    public func dismiss(animated: Bool, completion: (() -> Void)? = nil) { completion?() }
    public func addChild(_ vc: UIViewController) { children.append(vc); vc.parent = self }
}

public final class UIWindow: UIView {
    public var rootViewController: UIViewController?
    public var windowScene: Any?
    public func makeKeyAndVisible() {}
}

// ---- UIDevice --------------------------------------------------------------
public final class UIDevice {
    nonisolated(unsafe) public static let current = UIDevice()
    public var name: String = "web"
    public var systemName: String = "Web"
    public var systemVersion: String = "1.0"
    public var model: String = "Browser"
    // Deterministic on web: derive phone/pad from the live aspect ratio.
    public var userInterfaceIdiom: UIUserInterfaceIdiom {
        let w = CGFloat(win_width()), h = CGFloat(win_height())
        guard w > 0, h > 0 else { return .phone }
        let aspect = max(w, h) / min(w, h)
        return aspect < 1.5 ? .pad : .phone
    }
    public var orientation: UIDeviceOrientation = .landscapeRight
    public var isMultitaskingSupported = true
    public func playInputClick() {}
}

// ---- Gesture recognizers (compile-only) ------------------------------------
public struct Selector { public let raw: String; public init(_ raw: String) { self.raw = raw } }

open class UIGestureRecognizer {
    #if hasFeature(Embedded)
    public unowned(unsafe) var view: UIView?
    #else
    public weak var view: UIView?
    #endif
    public var state: UIGestureRecognizerState = .possible
    public var isEnabled = true
    var target: AnyObject?
    var action: Selector?
    public init(target: AnyObject? = nil, action: Selector? = nil) { self.target = target; self.action = action }
    public func addTarget(_ target: AnyObject, action: Selector) { self.target = target; self.action = action }
    public func removeTarget(_ target: AnyObject?, action: Selector?) {}
    open func location(in v: UIView?) -> CGPoint { CGPoint(x: CGFloat(mouse_x()), y: CGFloat(mouse_y())) }
    open func locationOfTouch(_ i: Int, in v: UIView?) -> CGPoint { location(in: v) }
    public var numberOfTouches: Int { 0 }
}
public enum UIGestureRecognizerState: Int, Sendable {
    case possible, began, changed, ended, cancelled, failed
    public static let recognized = ended
}
public final class UISwipeGestureRecognizer: UIGestureRecognizer {
    public struct Direction: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let right = Direction(rawValue: 1 << 0)
        public static let left  = Direction(rawValue: 1 << 1)
        public static let up    = Direction(rawValue: 1 << 2)
        public static let down  = Direction(rawValue: 1 << 3)
    }
    public var direction: Direction = .right
    public var numberOfTouchesRequired: Int = 1
}
public final class UIRotationGestureRecognizer: UIGestureRecognizer { public var rotation: CGFloat = 0; public var velocity: CGFloat = 0 }
public final class UIPinchGestureRecognizer: UIGestureRecognizer { public var scale: CGFloat = 1; public var velocity: CGFloat = 0 }
public final class UILongPressGestureRecognizer: UIGestureRecognizer {
    public var minimumPressDuration: TimeInterval = 0.5
    public var allowableMovement: CGFloat = 10
    public var numberOfTapsRequired: Int = 0
    public var numberOfTouchesRequired: Int = 1
}
public final class UITapGestureRecognizer: UIGestureRecognizer { public var numberOfTapsRequired: Int = 1; public var numberOfTouchesRequired: Int = 1 }
public final class UIPanGestureRecognizer: UIGestureRecognizer {
    public func translation(in v: UIView?) -> CGPoint { .zero }
    public func velocity(in v: UIView?) -> CGPoint { .zero }
    public func setTranslation(_ t: CGPoint, in v: UIView?) {}
}

// ---- CADisplayLink (game loop driver; the kit ticks via SKView.tick) -------
// Apple's CADisplayLink fires a target/selector once per frame. wasm has no
// Objective-C runtime, so selector dispatch can't resolve a method by name.
// We keep the target/selector init for source compatibility (it compiles but
// won't fire, matching the no-op nature of selectors here) AND add a portable
// closure init `CADisplayLink(every:)` that actually drives the callback every
// frame via KitRunLoop. Games whose source uses #selector get a build-time
// transform that rewrites the call to the closure form.
public final class CADisplayLink {
    public var isPaused = false {
        didSet { if isPaused { unregister() } else if registered == false && tick != nil { register() } }
    }
    public var preferredFramesPerSecond = 60
    #if hasFeature(Embedded)
    unowned(unsafe) var target: AnyObject?
    #else
    weak var target: AnyObject?
    #endif
    var selector: Selector?
    private var tick: (() -> Void)?
    private var registered = false
    private var alive = true

    public init(target: AnyObject, selector sel: Selector) { self.target = target; self.selector = sel }

    // Portable closure-driven display link. Registers a per-frame hook that runs
    // until invalidate() is called or isPaused is set.
    public init(every block: @escaping () -> Void) {
        self.tick = block
        register()
    }

    private func register() {
        guard registered == false else { return }
        registered = true
        #if hasFeature(Embedded)
        // Embedded Swift has no `weak`; the hook still self-guards via `alive`,
        // and a CADisplayLink lives for its driver's lifetime (never freed mid-run).
        KitRunLoop.addPerFrameHook { [unowned(unsafe) self] in
            guard self.alive, self.isPaused == false else { return }
            self.tick?()
        }
        #else
        KitRunLoop.addPerFrameHook { [weak self] in
            guard let self = self, self.alive, self.isPaused == false else { return }
            self.tick?()
        }
        #endif
    }
    private func unregister() { /* hook self-guards via `alive`/`isPaused` */ }

    public func add(to runloop: RunLoop, forMode mode: RunLoop.Mode) {}
    public func invalidate() { alive = false; tick = nil }
}

// ---- UIGraphics image-context + Photos (demo screenshot path; no-ops) -------
public func UIGraphicsBeginImageContextWithOptions(_ size: CGSize, _ opaque: Bool, _ scale: CGFloat) {}
public func UIGraphicsGetImageFromCurrentImageContext() -> UIImage? { nil }
public func UIGraphicsEndImageContext() {}
public func UIImageWriteToSavedPhotosAlbum(_ image: UIImage, _ target: AnyObject?, _ selector: Selector?, _ context: UnsafeRawPointer?) {}

// ---- libc-ish globals games expect without importing Foundation ------------
public func arc4random_uniform(_ n: UInt32) -> UInt32 {
    guard n > 0 else { return 0 }
    return UInt32(bitPattern: sb64_rand()) % n
}
public func round(_ x: Double) -> Double { x.rounded() }   // CGFloat == Double on this target
