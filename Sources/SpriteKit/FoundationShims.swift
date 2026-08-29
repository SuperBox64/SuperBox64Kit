// Frame-driven Foundation stand-ins. WASI has no runloop, so anything Apple
// schedules on one (Timer, DispatchQueue.main, notification delivery) is
// driven from SKView.tick once per frame via KitRunLoop. Single-threaded wasm
// makes the unsynchronised globals safe.

// MARK: - Date (minimal — games use it for elapsed-time bookkeeping like
// spawn cooldowns/expiry, not wall-clock persistence, so backing it with the
// kit's per-frame clock is behaviorally equivalent to Foundation's Date here).
public struct Date: Sendable {
    private let t: Double
    public init() { t = Double(SKSpriteNode.kitClock()) }
    public var timeIntervalSince1970: Double { t }
    public var timeIntervalSinceReferenceDate: Double { t }
    public func timeIntervalSince(_ other: Date) -> Double { t - other.t }
}

// MARK: - String.components(separatedBy:) (NSString-bridged on Apple; no
// Foundation here, so split manually)
public extension String {
    func components(separatedBy separator: String) -> [String] {
        if separator.isEmpty { return [self] }
        let h = Array(self), n = Array(separator)
        guard h.count >= n.count else { return [self] }
        var result: [String] = []
        var start = 0, i = 0
        while i <= h.count - n.count {
            var match = true
            for k in 0..<n.count where h[i + k] != n[k] { match = false; break }
            if match {
                result.append(String(h[start..<i]))
                i += n.count
                start = i
            } else {
                i += 1
            }
        }
        result.append(String(h[start...]))
        return result
    }
}

// MARK: - KitRunLoop (the per-frame pump other shims and modules hook into)

public enum KitRunLoop {
    nonisolated(unsafe) private static var perFrame: [() -> Void] = []

    public static func addPerFrameHook(_ hook: @escaping () -> Void) {
        perFrame.append(hook)
    }

    public static func _tick(_ dt: Double) {
        Timer._tick(dt)
        DispatchQueue._tick(dt)
        for hook in perFrame { hook() }
    }
}

// MARK: - Timer

public final class Timer {
    public var tolerance: Double = 0
    public private(set) var isValid = true
    let interval: Double
    let repeats: Bool
    let block: (Timer) -> Void
    var remaining: Double

    nonisolated(unsafe) private static var scheduled: [Timer] = []

    init(interval: Double, repeats: Bool, block: @escaping (Timer) -> Void) {
        self.interval = interval
        self.repeats = repeats
        self.block = block
        self.remaining = interval
    }

    @discardableResult
    public static func scheduledTimer(withTimeInterval interval: Double, repeats: Bool,
                                      block: @escaping (Timer) -> Void) -> Timer {
        let t = Timer(interval: interval, repeats: repeats, block: block)
        scheduled.append(t)
        return t
    }

    public func invalidate() { isValid = false }

    static func _tick(_ dt: Double) {
        var fired: [Timer] = []
        for t in scheduled where t.isValid {
            t.remaining -= dt
            if t.remaining <= 0 {
                fired.append(t)
                if t.repeats { t.remaining = t.interval } else { t.isValid = false }
            }
        }
        scheduled.removeAll { !$0.isValid }
        for t in fired where t.isValid || !t.repeats { t.block(t) }
    }
}

// MARK: - RunLoop (Apple games add timers to it; scheduledTimer already runs them)

public final class RunLoop {
    public nonisolated(unsafe) static let current = RunLoop()
    public nonisolated(unsafe) static let main = RunLoop()
    public struct Mode {
        public nonisolated(unsafe) static let common = Mode()
        public nonisolated(unsafe) static let `default` = Mode()
    }
    public func add(_ timer: Timer, forMode mode: Mode) {}
}

// MARK: - DispatchQueue (main only; deadlines resolve against frame time)

public struct DispatchTime {
    @usableFromInline let offset: Double
    @usableFromInline init(offset: Double) { self.offset = offset }
    @inlinable public static func now() -> DispatchTime { DispatchTime(offset: 0) }
    @inlinable public static func + (lhs: DispatchTime, rhs: Double) -> DispatchTime {
        DispatchTime(offset: lhs.offset + rhs)
    }
}

public final class DispatchQueue {
    public nonisolated(unsafe) static let main = DispatchQueue()
    // Embedded build calls this via `.shared`, never `.main`: the literal member
    // name `DispatchQueue.main` makes the Swift compiler infer @MainActor on the
    // submitted closure (its built-in GCD special-case). Under Embedded Swift
    // there is no MainActor type, so that inference asserts in SILGen
    // ("creating global actor isolation without an actor type"). Same queue,
    // different spelling — the embedded source transform rewrites .main -> .shared.
    public nonisolated(unsafe) static let shared = main

    @usableFromInline nonisolated(unsafe) static var pending: [(remaining: Double, work: () -> Void)] = []

    @inlinable public func async(execute work: @escaping () -> Void) {
        DispatchQueue.pending.append((0, work))
    }
    @inlinable public func asyncAfter(deadline: DispatchTime, execute work: @escaping () -> Void) {
        DispatchQueue.pending.append((deadline.offset, work))
    }

    static func _tick(_ dt: Double) {
        var due: [() -> Void] = []
        for i in pending.indices {
            pending[i].remaining -= dt
            if pending[i].remaining <= 0 { due.append(pending[i].work) }
        }
        pending.removeAll { $0.remaining <= 0 }
        for work in due { work() }
    }
}

// MARK: - Notification / NotificationCenter

public struct Notification {
    public struct Name: Hashable, RawRepresentable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ raw: String) { self.rawValue = raw }
    }
    public let name: Name
    public let object: AnyObject?
    public init(name: Name, object: AnyObject? = nil) {
        self.name = name
        self.object = object
    }
}

public final class NotificationCenter {
    nonisolated(unsafe) public static let `default` = NotificationCenter()
    public final class ObserverToken {}

    private var observers: [(name: Notification.Name?, token: ObserverToken, block: (Notification) -> Void)] = []

    @discardableResult
    public func addObserver(forName name: Notification.Name?, object: AnyObject?, queue: AnyObject?,
                            using block: @escaping (Notification) -> Void) -> ObserverToken {
        let token = ObserverToken()
        observers.append((name, token, block))
        return token
    }

    public func post(name: Notification.Name, object: AnyObject?) {
        let note = Notification(name: name, object: object)
        for o in observers where o.name == nil || o.name == name { o.block(note) }
    }

    public func removeObserver(_ token: ObserverToken) {
        observers.removeAll { $0.token === token }
    }
}

// MARK: - NSMutableDictionary (SKNode.userData's Apple type)

public final class NSMutableDictionary {
    #if hasFeature(Embedded)
    // Embedded Swift has no `Any`; back the dictionary with a small typed union
    // covering what the scene loader writes (bool/double/string tile userData).
    public enum Value {
        case bool(Bool); case uint32(UInt32); case double(Double); case string(String)
        // Typed accessors. Embedded has no `Any`, so the game cannot read tile
        // userData with `dict[k] as? Bool` / `as! String` (those compile but the
        // value is this enum, not Bool/String, so they always fail). Read through
        // these instead: `dict[k]?.boolValue`, `dict[k]?.stringValue`, etc.
        public var boolValue: Bool?     { if case let .bool(v)   = self { return v }; return nil }
        public var uint32Value: UInt32? { if case let .uint32(v) = self { return v }; return nil }
        public var doubleValue: Double? { if case let .double(v) = self { return v }; return nil }
        public var stringValue: String? { if case let .string(v) = self { return v }; return nil }
        public var cgFloatValue: CGFloat? { doubleValue.map { CGFloat($0) } }
    }
    private var storage: [String: Value] = [:]
    public init() {}
    public var count: Int { storage.count }
    public subscript(key: String) -> Value? {
        get { storage[key] }
        set { storage[key] = newValue }
    }
    #else
    private var storage: [String: Any] = [:]
    public init() {}
    public var count: Int { storage.count }
    public subscript(key: String) -> Any? {
        get { storage[key] }
        set { storage[key] = newValue }
    }
    #endif
}

// Apple's NSMutableDictionary bridges to a Swift dictionary literal (games
// write `node.userData = ["key": value]`).
#if hasFeature(Embedded)
extension NSMutableDictionary.Value: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension NSMutableDictionary: ExpressibleByDictionaryLiteral {
    public convenience init(dictionaryLiteral elements: (String, Value)...) {
        self.init()
        for (k, v) in elements { self[k] = v }
    }
}
#else
extension NSMutableDictionary: ExpressibleByDictionaryLiteral {
    public convenience init(dictionaryLiteral elements: (String, Any)...) {
        self.init()
        for (k, v) in elements { self[k] = v }
    }
}
#endif

#if hasFeature(Embedded)
// The Embedded stdlib has no substring search (that lives in _StringProcessing);
// a byte-window scan covers the games' contains(_:) calls.
public extension String {
    func contains(_ other: String) -> Bool {
        let h = Array(utf8), n = Array(other.utf8)
        if n.isEmpty { return true }
        if n.count > h.count { return false }
        for start in 0...(h.count - n.count) {
            var match = true
            for k in 0..<n.count where h[start + k] != n[k] {
                match = false
                break
            }
            if match { return true }
        }
        return false
    }
}
#endif
