@_exported import SpriteKit
@_exported import AppKit

// UIKit shim. Every UIKit type the games use (UIView, UIViewController, UITouch,
// UIEvent, UIScreen, UIApplication, UIImage, UIBezierPath, UIDevice, gesture
// recognizers, UIRectEdge, UIInterfaceOrientationMask, CADisplayLink, …) now
// lives in the SpriteKit module (AppleCompat.swift) so `import SpriteKit`-only
// game files resolve them. This module simply re-exports SpriteKit + AppKit so
// existing `import UIKit` code keeps compiling with a single definition of each
// type (no cross-module ambiguity).
