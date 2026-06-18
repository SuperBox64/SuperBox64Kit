# SuperBox64Kit

**A Swift reimplementation of Apple's SpriteKit that compiles one game-source tree three ways — browser wasm, wasm cartridge, and native binary — bundling Box2D v3, an SDL3 backend, and a reSVG/nanosvg vector rasterizer.**

Add this package to a macOS or iOS SpriteKit game, keep every `import SpriteKit` (and `AppKit`/`UIKit`/`GameKit`/`GameplayKit`/`GameController`/`AVFoundation`/...) unchanged, and ship the *same* source to WebAssembly running in any modern browser — no Emscripten, no loading screens, no watermarks — or straight to a native arm64 binary.

**Live demo:** [boss-man.us/play](https://boss-man.us/play)

**Web runtime:** [WasmKit](https://github.com/SuperBox64/WasmKit) — the JavaScript host (`runtime.js`) that renders the wasm on Canvas2D and fulfils the KitABI imports in the browser.

License: Apache 2.0 · Bundles Box2D v3.1.1 (Erin Catto, MIT) · Copyright 2026 Todd Bruss

---

## What is this

SuperBox64Kit — **"THE KIT"** — is a drop-in SpriteKit emulation package for Swift. It is the engine layer of a five-repo constellation that runs one unchanged SpriteKit game across seven real build × runtime permutations.

A game written for Apple's SpriteKit adds this package as a SwiftPM dependency, selects the framework products it imports, and:

- On **macOS / iOS**, the modules resolve to Apple's real frameworks (Metal + UIKit). Nothing changes.
- On **WebAssembly** (WASI Preview 1), the modules resolve to this kit's reimplementations and the game runs in a browser on Canvas2D — **no source edits**.
- On **native arm64**, the same source compiles under Embedded Swift into a single self-contained binary backed by SDL3 + Metal, with no wasm at all.

The kit owns everything below the game's `import` line:

| Owned by THE KIT | Where |
|---|---|
| SpriteKit emulation (nodes, actions, scene/view, textures, transitions) | `Sources/SpriteKit` |
| The **KitABI** — a ~100-function C `env` ABI, the one contract every backend fills | `Sources/KitABI/include/KitABI.h` |
| **Box2D v3.1.1** physics, vendored as pure C | `Sources/CBox2D` |
| The **SDL3** native backend (Embedded Swift, fills KitABI in-process) | `native/sdl3-backend.swift` |
| **reSVG / nanosvg** vector + `stb_image` / `stb_truetype` rasterization | `native/kit_stb.c` |
| Apple framework drop-in shims (AppKit, UIKit, GameKit, ...) | `Sources/{AppKit,UIKit,...}` |

The web side of the KitABI (Canvas2D, Web Audio, Web Gamepad, Web Speech) is owned by **[WasmKit](https://github.com/SuperBox64/WasmKit)**. The native cartridge consoles ([WasmCart](https://github.com/SuperBox64/WasmCart), [Wasm5](https://github.com/SuperBox64/Wasm5)) consume this kit's SDL3 backend.

---

## The drop-in story

The trick that makes "no source edits" real is a single header attribute. Every KitABI function is declared `__attribute__((import_module("env")))` **only under `__wasm__`**; on every other target the attribute is an identity macro. So one `KitABI.h` simultaneously:

- declares the wasm *import* the browser runtime satisfies, and
- declares the *C signature* the native SDL3 backend implements with `@_cdecl`.

The game never sees either. It calls `addChild`, `run(_:)`, `physicsWorld.contactDelegate`, `SKView.presentScene` — the ordinary SpriteKit surface — and the kit lowers the scene tree to flat KitABI calls each frame. Whatever is on the other side of that ABI (a browser canvas, an SDL3 window, a wasm host) draws the frame.

```
import SpriteKit            ← unchanged game source
      │
      ▼
SuperBox64Kit (SpriteKit emulation)
      │  walks the node tree, lowers to flat calls
      ▼
KitABI "env"  ── gfx_* snd_* gp_* eng_* tts_* store_* … (~100 fns)
      │
      ├── browser:  runtime.js  → Canvas2D / Web Audio / Web Gamepad   (WasmKit)
      └── native:   sdl3-backend.swift → SDL3 + Metal / WAV mix / SDL input
```

---

## Where this repo sits in the constellation

One legacy game source (UFO Emoji's `GameScene.swift` et al.) runs through five repos:

```
                         ┌─────────────────────────────────────────────┐
                         │            UFO-Emoji-Arcade                  │
                         │   THE GAME — one SpriteKit source of truth   │
                         │   ships to App Store + web + native consoles │
                         └───────────────────┬─────────────────────────┘
                                             │ import SpriteKit (unchanged)
                                             ▼
                         ┌─────────────────────────────────────────────┐
                         │            ►  SuperBox64Kit  ◄               │
                         │  THE KIT — SpriteKit emulation · KitABI ·    │
                         │  Box2D v3 · SDL3 backend · reSVG/nanosvg     │
                         └───────┬───────────────────────────┬─────────┘
                                 │ KitABI "env"              │ KitABI "env"
              browser side ◄─────┘                           └─────► native side
                    │                                                  │
        ┌───────────▼───────────┐              ┌──────────┬────────────▼───────────┐
        │        WasmKit        │              │ WasmCart │          Wasm5          │
        │  runtime.js + Canvas2D│              │ WAMR     │  WKWebView carts (real  │
        │  web KitABI host      │              │ console  │  Canvas2D/runtime.js)   │
        │                       │              │ +wamrc   │  + SDL→DOM key forward  │
        └───────────────────────┘              │  AOT     │                        │
                                               └──────────┴────────────────────────┘
```

- **SuperBox64Kit (this repo)** — the engine. Owns SpriteKit emulation, the KitABI contract, Box2D physics, the SDL3 native backend, and reSVG/nanosvg vector rasterization.
- **[WasmKit](https://github.com/SuperBox64/WasmKit)** — the web runtime: `runtime.js` renders the wasm on Canvas2D and fulfils the KitABI `env` imports in the browser.
- **[WasmCart](https://github.com/SuperBox64/WasmCart)** — a native game console: an Embedded-Swift + SDL3 shell that plays `.wasm`/`.aot` cartridges through **WAMR** (interpreter + `wamrc` AOT).
- **[Wasm5](https://github.com/SuperBox64/Wasm5)** — WasmCart's SDL3 shell, but carts play in a **WKWebView** (the real Canvas2D/`runtime.js` stack), with SDL3 keystrokes forwarded as synthetic DOM `KeyboardEvent`s.
- **[UFO-Emoji-Arcade](https://github.com/SuperBox64/UFO-Emoji-Arcade)** — the flagship demo: one App Store SpriteKit game shipped to Apple-native, the browser, and the native consoles from a single unchanged source.

---

## Features

### SpriteKit emulation

A full node tree and action engine, behavior-matched to Apple SpriteKit:

| Type | Coverage |
|---|---|
| `SKScene` | `sceneDidLoad`, `didMove(to:)`, `update(_:)`, `didEvaluateActions` / `didSimulatePhysics` / `didApplyConstraints` / `didFinishUpdate`, `willMove(from:)`, `didChangeSize`, `camera`, `physicsWorld`, `SKScene(fileNamed:)` |
| `SKNode` | Full tree: `addChild`, `removeFromParent`, `children`, `parent`, `name`, `zPosition`, `alpha`, `isHidden`, `xScale`/`yScale`, `zRotation`, `position`, `run(_:)`, `action(forKey:)` |
| `SKSpriteNode` | Texture, color, `colorBlendFactor`, `anchorPoint`, `size`, blend modes |
| `SKLabelNode` | `fontName`, `fontSize`, `fontColor`, alignment modes, `preferredMaxLayoutWidth` |
| `SKShapeNode` | `fillColor`, `strokeColor`, `lineWidth`, `path`, `init(circleOfRadius:)`, `init(rect:)` |
| `SKEmitterNode` | Particle emitters (position, velocity, lifetime, color range) |
| `SKCameraNode` | Position, scale, `xScale`/`yScale` (camera-aware coordinate conversion) |
| `SKCropNode` / `SKEffectNode` | `maskNode` cropping and offscreen effect passes |
| `SKAction` | `moveBy`/`To`, `scaleTo`/`By`, `fadeIn`/`Out`/`fadeAlphaTo`, `rotate`, `sequence`, `group`, `repeatForever`, `wait`, `run`, `setTexture`, `colorize`, `customAction` |
| `SKTexture` | Image textures, color textures, **atlas sub-rects** (`textureRect`, `init(rect:in:)`), `size` |
| `SKView` | Canvas/SDL-backed, `presentScene`, `presentScene(_:transition:)`, `texture(from:)`, `tick(_:)`, fullscreen, FPS/draw-count HUD |
| `SKTransition` | `fade`, `crossFade`, `doorsOpenHorizontal`, `push`, `reveal`, `moveIn` |
| `SKPhysicsBody` / `World` / `ContactDelegate` | See **Physics** below |
| `CGPath` / `CGMutablePath` / `CGAffineTransform` | Lines, arcs, curves, full matrix transform |

Input shims preserve Apple's delivery semantics: `UITouch`/`UIEvent`/`UIResponder` touch chain (capture-on-began, parent forwarding up to the scene), `NSEvent` keyboard/mouse with SFML→mac virtual-keycode translation, the full `GCController`/`GCExtendedGamepad` element layout, and `skKeyIsDown(_:)` for polled smooth movement.

### Physics — Box2D v3, pure C

`SKPhysicsBody` / `SKPhysicsWorld` / `SKPhysicsContactDelegate` preserve Apple semantics on top of vendored **Box2D v3.1.1** (`Sources/SpriteKit/SKPhysics.swift`, ~960 lines, over the `B2World.swift` wrapper):

- Apple's independent `collisionBitMask` / `contactTestBitMask` map to a **union Box2D filter**; contact-only bodies become **sensors** so they report contacts without imparting impulses.
- Bodies **wake on teleport**, so node-driven movement (`node.position = ...`, `SKAction.move`) keeps producing `didBegin` contacts exactly like Apple SpriteKit.
- **Edge loops and chains** are rebuilt from two-sided segments (Box2D v3 chain shapes are one-sided).
- `didBegin` events are **snapshotted** before delivery, so a handler can safely remove bodies mid-iteration.
- **Sensor pairs are deduped** to keep Apple's one-`didBegin`-per-pair contract.

Box2D v3 is vendored as plain C and called directly from Swift through a module map — **no C++ bridge, no libc++ in the link**. It is compiled with `-DNDEBUG -ffunction-sections -fdata-sections` so `gc-sections` keeps only the physics a game actually calls.

### Native rasterization — reSVG / nanosvg / stb

The native path (`native/kit_stb.c`) provides:

- **PNG / JPEG decode** via `stb_image`,
- **TrueType font metrics + glyph rasterization** via `stb_truetype`,
- **SVG raster** via **nanosvg** (default) or **resvg** (`-DKIT_USE_RESVG`, a full static-SVG renderer with masks, clipPaths, and embedded base64 PNGs), with **`kit_svg_decode_hi`** supersampling so SVGs re-raster crisply at each sprite's live device footprint.

> reSVG is required for PDF-derived SVGs that nanosvg renders blank/0×0. The two backends disagree on some asymmetric clipPaths (reSVG vertically flips certain y-flip-matrix clipPaths), so the asset pipeline picks the backend per asset, or ships pre-rendered PNGs.

### Native graphics & audio backend — SDL3

`native/sdl3-backend.swift` (~2970 lines, Embedded Swift) implements the full ~100-function KitABI `env` surface on SDL3:

- a **Canvas2D-compatible matrix stack** (`Mat`) so the same lowering drives both web and native,
- thick polylines via `SDL_RenderGeometry`,
- **WAV mixing** on one device, plus an `AVAudioEngine`-style node graph (`eng_*`),
- a file-backed persistence store (`store_*`),
- SDL keyboard / mouse / gamepad input,
- host lifecycle: `kitHostInit(appName:)`, `kitHostPump() -> Bool`, `kitHostPresent()`.

Because `SDL_Render` has no GPU shader path, **`native/kit-shader.swift`** (~1670 lines) is a GLSL fragment-shader **subset interpreter** that compiles GLSL to per-pixel Swift evaluation for `SKShader` / `SKLightNode` / `SKWarpGeometry` parity on native.

### Platform shims

Add the modules your game imports. On macOS they resolve to Apple's frameworks; on wasm/native they resolve to these:

| Module | Provides |
|---|---|
| `AppKit` | `NSColor`, `NSFont`, `NSImage`, `NSEvent`, `NSWindow`, `NSScreen`, `NSApplication` |
| `UIKit` | `UIColor`, `UIFont`, `UIImage`, `UIViewController`, `UIScreen`, `UIDevice`, gesture-recognizer family |
| `Cocoa` | Re-exports AppKit |
| `GameKit` | `GKLocalPlayer`, `GKLeaderboard`, `GKScore`, `GKAchievement` |
| `GameplayKit` | `GKRandomDistribution`, `GKShuffledDistribution`, `GKMersenneTwisterRandomSource` |
| `GameController` | `GCController`, `GCExtendedGamepad`, `GCControllerDirectionPad`, full Xbox-style element layout |
| `AVFoundation` | `AVAudioPlayer`, `AVAudioEngine`-style graph, `AVSpeechSynthesizer`, `AVSpeechUtterance` |
| `AudioToolbox` | `AudioServicesPlaySystemSound` |
| `Combine` | `PassthroughSubject`, `CurrentValueSubject`, `AnyCancellable` |
| `SwiftUI` | `Color`, `View` stubs |

### Embedded Swift

Every module compiles under `-enable-experimental-feature Embedded` (`wasm32-unknown-none-wasm` for the embedded web cart; `arm64-apple-macos` for native): no Foundation, no reflection, no runtime metadata. This is what makes the ~6× smaller embedded wasm and the single-file native binary possible.

### Tooling

- **`Tools/sks2json`** — a macOS-only CLI that loads Apple `.sks` scenes/particles through real SpriteKit and emits portable JSON, which `SKSceneLoader` + MiniJSON load at runtime (so `SKScene(fileNamed:)` works off-Apple).
- **Auto-stubbing** — `native/build-native-game.sh` parses `KitABI.h` and generates no-op stubs for any KitABI function the game never calls.

---

## Build × runtime permutation matrix

One source tree, seven real build × runtime shapes across the constellation. **THE KIT owns the highlighted rows** (Embedded-Swift native + the SDL3 backend that every native console shares).

| # | Build (wasm flavor) | Platform | Host (fills KitABI) | Renderer | Owned by |
|---|---|---|---|---|---|
| 1 | None — Apple-native | iOS / iPadOS / macOS | Apple SpriteKit (`@UIApplicationMain`) | Metal + UIKit | UFO-Emoji-Arcade (source of truth) |
| 2 | Full-Swift `wasm32-unknown-wasip1` (SwiftPM) | Any modern browser | `runtime.js` (WASI shim) | Canvas2D | **THE KIT** + WasmKit |
| 3 | Embedded-Swift `wasm32` (raw `swiftc -enable-experimental-feature Embedded`) | Any modern browser | `runtime.js` (minified) | Canvas2D | **THE KIT** + WasmKit |
| 4 | **None — Embedded-Swift native (`arm64-apple-macos`)** | **macOS arm64** | **`native/sdl3-backend.swift`, linked in** | **SDL3 + Metal** | **THE KIT** |
| 5 | Full/Embedded `wasm32` cart (`.wasm`) | macOS / Linux / Android / Win-x64 | **WAMR interpreter** (Embedded-Swift SDL3 shell) | SDL3 + Metal | WasmCart (on **THE KIT**'s backend) |
| 6 | `wasm32` cart AOT-compiled (`.aot`) | arm64 / x64 ELF + Win-x64 COFF | **WAMR + `wamrc` AOT** | SDL3 + Metal | WasmCart |
| 7 | Full/Embedded `wasm32` web build (unchanged) | macOS (Wasm5 console) | **WKWebView** (real `runtime.js`) | Canvas2D in WKWebView | Wasm5 |

Notes that matter for this repo:

- **Row 2 (full-Swift wasm)** is the primary shippable web build (`swift-6.3.2-RELEASE_wasm` SDK). UFO Emoji's web wasm is ~4.18 MB.
- **Row 3 (embedded wasm)** is ~6× smaller (UFO Emoji embedded ~688 KB; Boss-Man ~866 KB / ~344 KB gzip) — the whole point of the embedded permutation — and plays identically through the *same* `runtime.js`, just terser-minified (never a hand fork).
- **Row 4** is THE KIT's "straight to native" build: game source + framework modules + Box2D + `sdl3-backend.swift` + `kit-shader.swift` compiled into one stripped binary, WAV assets baked in, no runtime deps.
- **A wasmtime host variant** (`native/wasmtime-host.swift`, prebuilt `native/asteroidz-wasmtime-host`) is the Embedded-Swift SDL3 + wasmtime analog of the WAMR console — included in this repo for completeness; WasmCart is the production WAMR console.

The reference Embedded build pipeline (exact flags, module order, link line) for the full game lives in the Boss-Man repo at `docs/embedded/build-embedded-game.sh`.

---

## Build & Run

### Add the package

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/SuperBox64/SuperBox64Kit", branch: "main"),
],
targets: [
    .executableTarget(
        name: "MyGame",
        dependencies: [
            .product(name: "SpriteKit",    package: "SuperBox64Kit"),
            .product(name: "AppKit",       package: "SuperBox64Kit"),
            .product(name: "GameKit",      package: "SuperBox64Kit"),
            .product(name: "AVFoundation", package: "SuperBox64Kit"),
        ],
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

The package declares 16 library products: `SpriteKit`, `KitABI`, `AppKit`, `UIKit`, `Cocoa`, `GameKit`, `GameplayKit`, `GameController`, `AVFoundation`, `AudioToolbox`, `CBox2D`, `CSDL3`, `CWamr`, `CZip`, `Combine`, `SwiftUI`. Select the ones your game imports.

### Permutation 2 — browser wasm (the web build)

```bash
# Needs the wasm SDK: swift sdk install <swift-6.3.2-RELEASE_wasm>
xcrun --toolchain swift swift build \
    --swift-sdk swift-6.3.2-RELEASE_wasm \
    -c release
# output: .build/wasm32-unknown-wasip1/release/MyGame.wasm
```

Serve the wasm with [WasmKit](https://github.com/SuperBox64/WasmKit)'s `runtime.js` host page.

### Permutation 4 — pure native arm64 binary (THE KIT's direct path)

```bash
brew install sdl3                 # or use the checked-in vendor/libSDL3.a
cd /Users/.../SuperBox64Kit/native
GAME_SRC=../../../Sources GAME_MAIN=path/to/native-main.swift ./build-native-game.sh
# env knobs: OUT=mygame ASSETS_DIR=path/to/wavs SDL_STATIC_A=... SWIFTC=... NO_STRIP=1
./game-native                     # (or whatever OUT= was set to)
```

`build-native-game.sh` is Embedded Swift end-to-end: it compiles Box2D C, the framework modules (SpriteKit / AppKit / GameplayKit / GameController), the game, the backend, and `main` into one arm64 binary; bakes `.wav` assets via a Python generator; auto-stubs untouched KitABI funcs from the header; and links `vendor/libSDL3.a` (or `-lSDL3`) plus the macOS frameworks. It **hard-pins the `swift-6.3.2-RELEASE.xctoolchain`** and exports `SDKROOT` (see Cross-platform notes).

### Optional — trimmed static SDL3

```bash
cd /Users/.../SuperBox64Kit/native
./build-sdl3-static.sh            # → vendor/libSDL3.a (video+render+audio+events only)
```

Builds a MinSizeRel static SDL3 from `libsdl-org/SDL` (default tag `3.2.24`) with camera/sensor/haptic/gpu/vulkan/dialog/joystick/hidapi **off**, for single-file native binaries. A prebuilt `vendor/libSDL3.a` (~2.86 MB) is checked in.

### wasmtime cartridge host (reference, permutation 2-analog)

```bash
brew install sdl3 wasmtime
cd /Users/.../SuperBox64Kit/native
./build-wasmtime-host.sh
./asteroidz-wasmtime-host         # loads asteroidz-embedded.wasm via wasmtime
```

### sks2json tool

```bash
cd /Users/.../SuperBox64Kit/Tools/sks2json
swift build -c release
sks2json GameScene.sks                          # one file
sks2json --out web/scenes GameScene.sks GameMenu.sks
sks2json                                         # walk current dir for every .sks
```

---

## API & usage

A game built on this kit exports two wasm "reactor" entry points and writes ordinary SpriteKit otherwise.

```swift
// main.swift — the two exports (--export=boot / --export=frame)
import SpriteKit

@_cdecl("boot")
func boot() {
    let view = SKView(frame: CGRect(x: 0, y: 0, width: 1184, height: 666))
    view.presentScene(GameScene(size: CGSize(width: 1184, height: 666)))
}

@_cdecl("frame")
func frame(_ dtMs: Double) {
    // advance actions, run scene.update, step physics, render the tree
    myView.tick(dtMs)
}
```

> **API note:** the per-frame driver is `SKView.tick(_ dtMs: Double)` — it advances actions, calls `scene.update`, steps physics, and renders the tree (converting y-up SpriteKit coordinates to the backend's y-down space). There is **no `SKView.current` static**; hold your own `SKView` reference (e.g. a global created in `boot()`) and call `tick` on it from `frame`. On the cartridge path, `wasmtime-host.swift` / WAMR call the same `boot()` once and `frame(dt)` per tick.

The scene is unmodified SpriteKit:

```swift
// GameScene.swift — same as macOS
import SpriteKit

final class GameScene: SKScene {
    override func didMove(to view: SKView) {
        backgroundColor = .black
        let label = SKLabelNode(text: "Hello from WASM")
        label.fontName = "MarkerFelt-Wide"; label.fontSize = 48; label.fontColor = .white
        label.position = CGPoint(x: size.width / 2, y: size.height / 2)
        addChild(label)
        label.run(.repeatForever(.sequence([
            .fadeOut(withDuration: 1.0),
            .fadeIn(withDuration: 1.0),
        ])))
    }
}
```

**Native host lifecycle** (called by a game's `native-main.swift`, permutation 4):

```swift
kitHostInit(appName: "MyGame")
while kitHostPump() {        // false = quit; pumps SDL events
    myView.tick(16.6)
    kitHostPresent()        // flip the SDL renderer
}
```

Console hooks `kitEscapeReserved` / `kitEscapePressed` / `kitDroppedFile` are the WasmCart/Wasm5 eject + drag-drop integration points.

**KitABI surface (~100 fns, `env` module).** Graphics `gfx_*` (clear/save/restore/translate/rotate/scale/alpha/blend/tint/line, fill & stroke rect/circle/poly, draw_image, offscreen, shadow/filter/composite, shader/lighting/warp/3d, upload_pixels), text `gfx_draw_text`/`txt_width`/`gfx_set_text_baseline`, assets `img_by_name`/`img_width`/`img_height`/`asset_exists`/`asset_text`/`font_by_name`, audio `snd_*` + the `eng_*` node graph, input `key_pressed`/`mouse_*`/`evt_poll`/`gp_*`, speech `tts_*`, storage `store_get`/`store_set`, window `win_*`, debug `dbg_set_overlays`, plus `sb64_*` libm wrappers. The native backend omits the shader/lighting/`vid_*`/`dbg`/`sb64` subset that only the web path needs.

---

## Cross-platform notes

- **`import_module("env")` is wasm-only.** On native it is an identity macro, so the same `KitABI.h` drives both the wasm import and the native `@_cdecl` backend — never special-case the header per platform.
- **Call libm through `sb64_*`, not directly.** Swift's `@_silgen_name` on a free function adds `i32` self/witness args that mismatch libc's `(Double)->Double` and confuse `wasm-ld`; `Sources/KitABI/shim.c` provides clean C wrappers (`sb64_sin`/`cos`/`atan2`/`sqrt`/`floor`/`ceil`/`fmod`/`pow`/`exp`/`tanh`/`hypot`/`rand`/`srand`).
- **Embedded Swift constraints are hard:** no `weak`/`unowned` (the kit uses `unowned(unsafe)` behind `#if hasFeature(Embedded)`), no `Any`/non-class existentials/metatypes/`Mirror`, **no runtime protocol casts** (`as? SomeProtocol` always fails — by design, `embedded/embedded-stubs.c` omits `swift_conformsToProtocol` so it fails *loudly* at link time), and no `async`/`await`/`Task`/`@MainActor`.
- **Toolchain pinning is required.** `xcrun --toolchain swift` resolves to whatever dev-snapshot is installed (some abort-trap compiling Embedded host code), so `build-native-game.sh` hard-pins `swift-6.3.2-RELEASE.xctoolchain` and exports `SDKROOT` (invoking `swiftc` directly otherwise loses the sysroot and ClangImporter can't find `<math.h>` for CBox2D). Override via `SWIFTC` / `SWIFT_TOOLCHAIN`.
- The native build **strips `@MainActor` and `@preconcurrency`** from framework + game source before the Embedded compile (Embedded infers `@MainActor` in ways that crash the compiler).
- A Linux path exists in `detect_sys`, but the native script links macOS frameworks; native binaries are macOS arm64 today.

## Keyboard

The kit reads keyboard through two paths that match Apple's:

- **Apple-shaped:** `SKScene.keyDown(with:)` / `keyUp(with:)` receiving an `NSEvent` struct shim (`keyCode`, `charactersIgnoringModifiers`, `modifierFlags`), with **SFML→mac virtual-keycode translation** so unmodified macOS `keyCode` switches work everywhere. (The web runtime gives no auto-repeat — `isARepeat` is always false — and no relative mouse delta.)
- **Polled:** `skKeyIsDown(_:)` returns `key_pressed != 0` for smooth per-frame movement, with `SKKey` holding the runtime's key codes.

On the web, `runtime.js` maps DOM `KeyboardEvent.code`. On native, SDL events feed the same `key_pressed`/`evt_poll` ABI. In the **Wasm5** WKWebView console, SDL keyboard breaks when WebKit is linked, so an `NSEvent` monitor injects synthetic DOM `KeyboardEvent`s into the cart's JS — the kit's keyboard contract is identical either way.

---

## Repository layout

| Path | What |
|---|---|
| `Sources/SpriteKit` | SpriteKit emulation core (~33 files, ~7.5k lines): nodes, actions, `SKPhysics`/`B2World`, view/scene, textures, loaders, Foundation shims |
| `Sources/KitABI` | `KitABI.h` (the ~100-fn C contract) + `shim.c` libm wrappers |
| `Sources/CBox2D` | Vendored Box2D v3.1.1 pure-C sources + `box2d` headers |
| `Sources/{AppKit,UIKit,Cocoa,GameKit,GameplayKit,GameController,AVFoundation,AudioToolbox,Combine,SwiftUI}` | Per-framework drop-in shims |
| `Sources/{CSDL3,CWamr,CZip}` | C-interop module-map targets (SDL3 headers, WAMR bindings, zip/libz) |
| `native/` | Non-web backends: `sdl3-backend.swift`, `wasmtime-host.swift`, `kit-shader.swift`, `kit_stb.c`, vendored nanosvg/stb, the three `build-*.sh` scripts, `vendor/libSDL3.a`, prebuilt `asteroidz-wasmtime-host`, `README.md` |
| `embedded/` | `embedded-stubs.c` — WASI reactor init + `strtod` shims (deliberately no `conformsToProtocol`) |
| `Tools/sks2json` | macOS CLI converting Apple `.sks` to runtime JSON |

See `native/README.md` for the three-permutation map and exact native build/run commands.

## Dependencies

| Dependency | How it's vendored / required |
|---|---|
| **Box2D v3.1.1** (Erin Catto, MIT) | Vendored as pure C into `Sources/CBox2D`; no C++/libc++ in the link |
| **SDL3** | Homebrew (`brew install sdl3`) via the `CSDL3` module map, **or** a trimmed static `vendor/libSDL3.a` from `build-sdl3-static.sh` (default `SDL_VER` 3.2.24) |
| **wasmtime** | Permutation-2 host only (`brew install wasmtime` / `apt libwasmtime-dev`), via `native/CWasmtime` |
| **stb_image.h / stb_truetype.h** | Vendored at `native/stb/`, used by `kit_stb.c` |
| **nanosvg.h / nanosvgrast.h** | Vendored at `native/`, default SVG rasterizer |
| **resvg / libresvg** | Optional native SVG backend, `-DKIT_USE_RESVG`; required for PDF-derived SVGs nanosvg renders blank |
| **zlib (libz)** | Linked by the `CZip` target |
| **WAMR** | `CWamr` ships binding declarations only; the actual WAMR library is linked at build time by the WasmCart console |
| **Swift toolchain** | Swift 6.3.2+ from swift.org; native scripts pin `swift-6.3.2-RELEASE.xctoolchain` |
| **Wasm SDK** | `swift-6.3.2-RELEASE_wasm` installed via `swift sdk install` for the web build |
| **Embedded link** | `<toolchain>/lib/swift/embedded/arm64-apple-macos/libswiftUnicodeDataTables.a` |

## Requirements

- Swift **6.3.2+** toolchain from swift.org
- `swift-6.3.2-RELEASE_wasm` SDK (for the web build) installed via `swift sdk install`
- macOS arm64 + Homebrew SDL3 (or the checked-in static `vendor/libSDL3.a`) for the native build

---

## Related repos

- [WasmKit](https://github.com/SuperBox64/WasmKit) — the web runtime: `runtime.js` + Canvas2D, the browser side of the KitABI.
- [WasmCart](https://github.com/SuperBox64/WasmCart) — the native console: an SDL3 shell that plays `.wasm`/`.aot` carts through WAMR (interpreter + `wamrc` AOT).
- [Wasm5](https://github.com/SuperBox64/Wasm5) — the WebView console: WasmCart's SDL3 shell with carts running in a WKWebView (real Canvas2D/`runtime.js`), SDL→DOM keyboard forwarding.
- [UFO-Emoji-Arcade](https://github.com/SuperBox64/UFO-Emoji-Arcade) — the flagship single-source App Store game shipped to every target via this kit.
- [Boss-Man](https://github.com/macOS26/Boss-Man) — full arcade game on this engine across 6 platforms; home of the reference Embedded build pipeline (`docs/embedded/build-embedded-game.sh`).
- [Box2D](https://github.com/erincatto/box2d) — upstream; v3.1.1 vendored here.

---

## Credits & acknowledgements

- **SuperBox64 SpriteKit** — Copyright 2026 Todd Bruss.
- **Box2D v3.1.1** — Erin Catto, MIT License (vendored, see `NOTICE`).
- **SDL3** — the [libsdl-org/SDL](https://github.com/libsdl-org/SDL) project.
- **stb_image / stb_truetype** — Sean Barrett (public domain).
- **nanosvg** — Mikko Mononen.
- **resvg** — the [RazrFalcon/resvg](https://github.com/RazrFalcon/resvg) project.
- **WAMR** — the WebAssembly Micro Runtime (Bytecode Alliance).

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE). Apache 2.0 grants an explicit patent license and terminates it on patent litigation, protecting contributors and users from patent ambush. Bundles Box2D v3.1.1 (Erin Catto, MIT).
