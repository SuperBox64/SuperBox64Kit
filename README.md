# SuperBox64Kit

A Swift reimplementation of Apple's SpriteKit that compiles to WebAssembly via WASI Preview 1. A macOS or iOS SpriteKit game adds this package, keeps every `import SpriteKit` unchanged, and runs in any modern browser with no source edits.

No Emscripten. No loading screens. No watermarks.

**Live demo:** [boss-man.us/play](https://boss-man.us/play)

**Runtime:** [WasmKit](https://github.com/SuperBox64/WasmKit) — the JavaScript runtime that loads and drives the WASM binary

---

## One source, three shapes

Every game built on this framework compiles three ways from the same source
tree: a wasm for the browser, a wasm "cartridge" played by a native host
(see WasmKit/cartridge), and a plain native binary with no wasm
at all. `native/` holds the SDL3 backend that fills the KitABI surface
in-process plus `build-native-game.sh`, which links game + framework +
Box2D v3 into one Embedded Swift executable (AsteroidZ: 662 KB). The web
build is untouched; the KitABI import attribute only applies under
`__wasm__`. See `native/README.md` for the full permutation map.

## Quick Start

### 1. Add the package

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/SuperBox64/SuperBox64Kit", branch: "main"),
],
targets: [
    .executableTarget(
        name: "MyGame",
        dependencies: [
            .product(name: "SpriteKit",   package: "SuperBox64Kit"),
            .product(name: "AppKit",      package: "SuperBox64Kit"),
            .product(name: "GameKit",     package: "SuperBox64Kit"),
            .product(name: "AVFoundation",package: "SuperBox64Kit"),
        ],
        swiftSettings: [.defaultIsolation(MainActor.self)],
        linkerSettings: [.unsafeFlags([
            "-Xclang-linker", "-mexec-model=reactor",
            "-Xlinker", "--export=boot",
            "-Xlinker", "--export=frame",
            "-Xlinker", "--export-if-defined=_initialize",
            "-Xlinker", "--allow-undefined",
        ])]
    ),
]
```

### 2. Write the entry points

```swift
// main.swift
import SpriteKit

@_cdecl("boot")
nonisolated func boot() {
    MainActor.assumeIsolated {
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 1184, height: 666))
        view.presentScene(GameScene(size: CGSize(width: 1184, height: 666)))
    }
}

@_cdecl("frame")
nonisolated func frame(_ dtMs: Double) {
    MainActor.assumeIsolated {
        SKView.current?.update(dtMs / 1000.0)
    }
}
```

### 3. Write the scene — same as macOS

```swift
// GameScene.swift
import SpriteKit

final class GameScene: SKScene {

    override func didMove(to view: SKView) {
        backgroundColor = .black

        let label = SKLabelNode(text: "Hello from WASM")
        label.fontName = "MarkerFelt-Wide"
        label.fontSize = 48
        label.fontColor = .white
        label.position = CGPoint(x: size.width / 2, y: size.height / 2)
        addChild(label)

        label.run(.repeatForever(.sequence([
            .fadeOut(withDuration: 1.0),
            .fadeIn(withDuration: 1.0),
        ])))
    }

    override func update(_ currentTime: TimeInterval) {
    }
}
```

### 4. Build

```bash
xcrun --toolchain swift swift build \
    --swift-sdk swift-6.3.2-RELEASE_wasm \
    -c release
```

The output is a WASM reactor at `.build/wasm32-unknown-wasip1/release/MyGame.wasm`. Serve it with [WasmKit](https://github.com/SuperBox64/WasmKit).

---

## What Is Included

### SpriteKit

| Type | Coverage |
|---|---|
| `SKScene` | `didMove(to:)`, `update(_:)`, `didFinishUpdate()`, `willMove(from:)`, `presentScene`, `camera`, `physicsWorld` |
| `SKNode` | Full tree: `addChild`, `removeFromParent`, `children`, `parent`, `name`, `zPosition`, `alpha`, `isHidden`, `xScale/yScale`, `zRotation`, `position`, `run(_:)`, `action(forKey:)` |
| `SKSpriteNode` | Texture, color, colorBlendFactor, anchorPoint, size, blending modes |
| `SKLabelNode` | fontName, fontSize, fontColor, horizontalAlignmentMode, verticalAlignmentMode, preferredMaxLayoutWidth |
| `SKShapeNode` | fillColor, strokeColor, lineWidth, path, `.init(circleOfRadius:)`, `.init(rect:)` |
| `SKEmitterNode` | Particle emitter (position, velocity, lifetime, color range) |
| `SKCameraNode` | Position, scale, xScale/yScale |
| `SKCropNode` | maskNode-based cropping |
| `SKAction` | `moveBy/To`, `scaleTo/By`, `fadeIn/Out`, `fadeAlphaTo`, `rotate`, `sequence`, `group`, `repeatForever`, `wait`, `run`, `setTexture`, `colorize`, `customAction` |
| `SKTexture` | Image textures, color textures, `textureRect`, `size` |
| `SKView` | Canvas-backed, `presentScene`, `texture(from:)`, `ignoresSiblingOrder` |
| `SKTransition` | `fade`, `crossFade`, `doorsOpenHorizontal`, `push`, `reveal`, `moveIn` |
| `SKPhysicsBody` | `dynamic`, bit masks, `velocity`, `applyImpulse`, `isDynamic`, `affectedByGravity` |
| `SKPhysicsWorld` | `gravity`, `contactDelegate`, `enumerateBodies(inRect:)` |
| `CGPath / CGMutablePath` | `addLine`, `addArc`, `addCurve`, `closeSubpath` |
| `CGAffineTransform` | Full matrix transform |

### Platform Shims

Add the modules your game imports. On macOS they resolve to Apple's frameworks. On WASM they resolve to these shims.

| Module | Provides |
|---|---|
| `AppKit` | `NSColor`, `NSFont`, `NSImage`, `NSEvent`, `NSWindow`, `NSScreen`, `NSApplication` |
| `UIKit` | `UIColor`, `UIFont`, `UIImage`, `UIViewController`, `UIScreen`, `UIDevice` |
| `GameKit` | `GKLocalPlayer`, `GKLeaderboard`, `GKScore`, `GKAchievement` |
| `GameplayKit` | `GKRandomDistribution`, `GKShuffledDistribution`, `GKMersenneTwisterRandomSource` |
| `GameController` | `GCController`, `GCExtendedGamepad`, `GCControllerDirectionPad` |
| `AVFoundation` | `AVAudioPlayer`, `AVSpeechSynthesizer`, `AVSpeechUtterance` |
| `AudioToolbox` | `AudioServicesPlaySystemSound` |
| `Combine` | `PassthroughSubject`, `CurrentValueSubject`, `AnyCancellable` |
| `SwiftUI` | `Color`, `View` stubs |

### Physics (Box2D v3, pure C)

`CBox2D` ships with the package: vendored [Box2D v3.1.1](https://github.com/erincatto/box2d), compiled as plain C and called directly from Swift through a module map. There is no C++ bridge and no libc++ anywhere in the link (the old `Box2DBridge` C++ 2.4 layer is gone).

`SKPhysicsBody` / `SKPhysicsWorld` / `SKPhysicsContactDelegate` preserve Apple's semantics on top of v3:

- Apple's independent `collisionBitMask` / `contactTestBitMask` map to a union Box2D filter; contact-only bodies become sensors so they report without imparting impulses.
- Bodies wake on teleport, so node-driven movement (`node.position = ...`, `SKAction.move`) keeps producing `didBegin` contacts exactly like Apple SpriteKit.
- Edge loops and chains are built from two-sided segments (v3 chain shapes are one-sided).
- Begin-touch events are snapshotted before delivery, so a `didBegin` handler can safely remove bodies mid-iteration.
- Sensor pairs are deduped to keep Apple's one-`didBegin`-per-pair contract.

Why v3 instead of staying on 2.4: v3 is pure C (Embedded Swift imports it directly, no bridge to maintain), actively developed (2.4 is frozen), and compiled with function/data sections + `-DNDEBUG` so the linker keeps only the physics a game actually calls.

---

## How a frame renders

`SKView.render` walks the scene tree like Apple's compositor (transforms, anchor points, z-order, alpha, color blending) and emits flat calls over a ~100-function C ABI that the [wasmkit runtime](https://github.com/SuperBox64/WasmKit) implements in the browser:

- `SKSpriteNode` → `gfx_draw_image(handle, srcRect, dstRect, tint)`; textures are browser-decoded images addressed by handle, and `SKTexture(rect:in:)` sub-rects give atlas sampling.
- `SKShapeNode` / color sprites → `gfx_fill_rect` / `gfx_fill_poly` / `gfx_stroke_*`; `SKLabelNode` → `gfx_draw_text` with real font metrics.
- `SKView.texture(from:)`, `SKCropNode`, `SKEffectNode` render through offscreen canvases (`gfx_offscreen_*`), so bake-to-texture and masking behave like macOS.
- `SKShader`, `SKLightNode`, `SKWarpGeometry` compile real GLSL on a hidden WebGL2 canvas and blit back into the 2D scene.

Audio takes the same shape: `SKAudioNode` / `AVFoundation` land on Web Audio buffers and an `AVAudioEngine`-style node graph; `AVSpeechSynthesizer` is the browser's own speech synthesis.

---

## Embedded Swift

All package modules compile under `-enable-experimental-feature Embedded` (target `wasm32-unknown-none-wasm`): no Foundation, no runtime metadata, no reflection. A full game built this way (Boss-Man: this framework + 48 game files) ships as an 866 KB wasm, 344 KB gzipped, roughly 6x smaller than the same game with the Swift stdlib, and plays identically.

What it takes to write Embedded-compatible code against this framework:

- No `weak`/`unowned` (the framework uses `unowned(unsafe)` behind `#if hasFeature(Embedded)` for Apple-contract non-owning refs like `node` and `delegate`).
- No `Any`, non-class existentials, metatypes, or `Mirror`; APIs here are typed (e.g. `SKKeyframeSequence` takes an `SKKeyframeValue` enum, never `[Any]`).
- No runtime protocol casts: `as? SomeProtocol` never succeeds in Embedded. Use a concrete class downcast or base-class override; if a new cast sneaks in, the link fails loudly rather than silently returning nil.
- No `async`/`await`/`Task`/`@MainActor`: the framework's GameKit and friends are completion-handler based, and timers belong in `update(_:)`/`SKAction`.
- Classes, inheritance, generics, closures, optionals and all the collection types work normally.

The reference Embedded build pipeline (exact flags, module order, link line) lives in the Boss-Man repo at `docs/embedded/build-embedded-game.sh`.

---

## Requirements

- Swift 6.3.2+ toolchain from swift.org
- `swift-6.3.2-RELEASE_wasm` SDK installed via `swift sdk install`

---

## Related

- [WasmKit](https://github.com/SuperBox64/WasmKit) — JavaScript runtime, host page, and C++ SFML shim
- [Boss-Man](https://github.com/macOS26/Boss-Man) — full arcade game built with this engine, shipping on 6 platforms from one Swift source
- [UFO Emoji Arcade](https://github.com/SuperBox64/UFO-Emoji-Arcade) — 5-star App Store SpriteKit game running in the browser via this engine, source unchanged

---

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). Apache 2.0 grants an explicit patent license and terminates it on patent litigation, protecting contributors and users from patent ambush. Bundles Box2D v3.1.1 (MIT, Erin Catto).
