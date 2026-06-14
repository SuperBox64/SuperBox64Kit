@_exported import SpriteKit

// AppKit shim. The graphics value types (NSImage / NSFont / NSBezierPath /
// NSCoder / NSColorSpace) now live in the SpriteKit module (AppleCompat.swift)
// so `import SpriteKit`-only games see them; AppKit re-exports SpriteKit above,
// so macOS code that `import AppKit` keeps compiling unchanged. This file keeps
// only the macOS-only window / alert / cursor / screen stubs.

public typealias NSColor = SKColor

public final class NSScreen {
    nonisolated(unsafe) public static let main: NSScreen? = NSScreen()
    public var frame: CGRect = .zero
    public var backingScaleFactor: CGFloat = 1
}

public final class NSWindow {
    public var title: String = ""
    public init() {}
}

public enum NSApplication {
    public struct ModalResponse: Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let alertFirstButtonReturn = ModalResponse(rawValue: 1000)
        public static let alertSecondButtonReturn = ModalResponse(rawValue: 1001)
    }
}

public final class NSAlert {
    public enum Style { case warning, informational, critical }
    public var messageText = ""
    public var informativeText = ""
    public var alertStyle: Style = .warning
    private var buttonTitles: [String] = []
    public init() {}
    public func addButton(withTitle title: String) { buttonTitles.append(title) }
    public func runModal() -> NSApplication.ModalResponse { .alertFirstButtonReturn }
}

public enum NSCursor {
    public static func hide() {}
    public static func unhide() {}
}
