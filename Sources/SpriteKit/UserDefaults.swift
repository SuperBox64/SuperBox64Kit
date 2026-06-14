// Foundation.UserDefaults, backed by window.localStorage through LocalStore
// (store_get / store_set). A ported SpriteKit game calls UserDefaults.standard
// directly on WASI with no platform branch; a game's own persistence layer can
// sit on top unchanged. Values are encoded as strings so the on-disk shape
// matches LocalStore. The overload set mirrors Foundation's so source that
// compiles on Apple compiles here unchanged. ICU-free by construction: literal
// bool matching and plain Int/Double parsing only, never localized/lowercased.
public final class UserDefaults {
    public nonisolated(unsafe) static let standard = UserDefaults()

    // MARK: - Reads
    public func string(forKey key: String) -> String? { LocalStore.string(forKey: key) }

    public func bool(forKey key: String) -> Bool {
        guard let s = LocalStore.string(forKey: key), !s.isEmpty else { return false }
        switch s {
        case "1", "true", "True", "YES", "yes": return true
        default: return false
        }
    }
    public func integer(forKey key: String) -> Int {
        guard let s = LocalStore.string(forKey: key) else { return 0 }
        if let i = Int(s) { return i }
        if let d = Double(s) { return Int(d) }
        return 0
    }
    public func double(forKey key: String) -> Double {
        guard let s = LocalStore.string(forKey: key), let d = Double(s) else { return 0 }
        return d
    }
    public func float(forKey key: String) -> Float { Float(double(forKey: key)) }

    // MARK: - Writes
    public func set(_ value: Bool, forKey key: String)   { LocalStore.setString(value ? "1" : "0", forKey: key) }
    public func set(_ value: Int, forKey key: String)    { LocalStore.setString(String(value), forKey: key) }
    public func set(_ value: Double, forKey key: String) { LocalStore.setString(String(value), forKey: key) }
    public func set(_ value: Float, forKey key: String)  { LocalStore.setString(String(value), forKey: key) }
    public func set(_ value: String, forKey key: String) { LocalStore.setString(value, forKey: key) }
    // KVC-style setValue. Typed overloads so callers resolve to a concrete
    // method (and Embedded Swift, which has no `Any`, still compiles). A game's
    // `setValue(someInt, forKey:)` binds to the Int overload in both modes.
    public func setValue(_ value: Int, forKey key: String)    { set(value, forKey: key) }
    public func setValue(_ value: Bool, forKey key: String)   { set(value, forKey: key) }
    public func setValue(_ value: Double, forKey key: String) { set(value, forKey: key) }
    public func setValue(_ value: Float, forKey key: String)  { set(value, forKey: key) }
    public func setValue(_ value: String, forKey key: String) { set(value, forKey: key) }
    #if !hasFeature(Embedded)
    // Apple's KVC takes Any?; full-Swift builds keep it for source parity.
    public func setValue(_ value: Any?, forKey key: String) {
        switch value {
        case let s as String: LocalStore.setString(s, forKey: key)
        case let b as Bool:   LocalStore.setString(b ? "1" : "0", forKey: key)
        case let i as Int:    LocalStore.setString(String(i), forKey: key)
        case let d as Double: LocalStore.setString(String(d), forKey: key)
        case let f as Float:  LocalStore.setString(String(f), forKey: key)
        default: break
        }
    }
    #endif

    public func removeObject(forKey key: String) { LocalStore.setString("", forKey: key) }
    public func synchronize() -> Bool { true }
}
