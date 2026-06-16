// Permutation 3: NO WASM AT ALL. The game + framework compile straight to a
// native arm64 binary; KitABI's env surface links directly against this SDL3
// backend (the same contract the web runtime and the wasmtime host fill).
// Embedded Swift, no stdlib, no Foundation. Box2D v3 links as plain C.
import CSDL3

let LOGICAL_W: Float = 1920
let LOGICAL_H: Float = 1080
let windowResizable: UInt64 = 0x20
let windowHighPixelDensity: UInt64 = 0x2000

struct Mat {
    var a: Float = 1, b: Float = 0, c: Float = 0, d: Float = 1, e: Float = 0, f: Float = 0

    mutating func mul(_ n: Mat) {
        self = Mat(
            a: a * n.a + c * n.b, b: b * n.a + d * n.b,
            c: a * n.c + c * n.d, d: b * n.c + d * n.d,
            e: a * n.e + c * n.f + e, f: b * n.e + d * n.f + f
        )
    }

    func apply(_ x: Float, _ y: Float) -> SDL_FPoint {
        SDL_FPoint(x: a * x + c * y + e, y: b * x + d * y + f)
    }

    var lengthScale: Float {
        (SDL_sqrtf(a * a + b * b) + SDL_sqrtf(c * c + d * d)) / 2
    }
}

@_silgen_name("kit_asset_data")
func kit_asset_data(_ name: UnsafePointer<CChar>?, _ len: UnsafeMutablePointer<UInt32>?) -> UnsafePointer<UInt8>?

@_silgen_name("kit_png_decode")
func kit_png_decode(_ bytes: UnsafePointer<UInt8>?, _ len: Int32, _ w: UnsafeMutablePointer<Int32>?, _ h: UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<UInt8>?

@_silgen_name("kit_svg_decode")
func kit_svg_decode(_ bytes: UnsafePointer<UInt8>?, _ len: Int32, _ w: UnsafeMutablePointer<Int32>?, _ h: UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<UInt8>?

@_silgen_name("kit_svg_decode_hi")
func kit_svg_decode_hi(_ bytes: UnsafePointer<UInt8>?, _ len: Int32, _ ss: Int32, _ texW: UnsafeMutablePointer<Int32>?, _ texH: UnsafeMutablePointer<Int32>?, _ logW: UnsafeMutablePointer<Int32>?, _ logH: UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<UInt8>?

@_silgen_name("kit_stb_free")
func kit_stb_free(_ p: UnsafeMutableRawPointer?)

@_silgen_name("kit_font_init")
func kit_font_init(_ ttf: UnsafePointer<UInt8>?, _ len: Int32) -> UnsafeMutableRawPointer?

@_silgen_name("kit_font_scale_for_px")
func kit_font_scale_for_px(_ font: UnsafeMutableRawPointer?, _ px: Float) -> Float

@_silgen_name("kit_font_vmetrics")
func kit_font_vmetrics(_ font: UnsafeMutableRawPointer?, _ ascent: UnsafeMutablePointer<Int32>?, _ descent: UnsafeMutablePointer<Int32>?, _ lineGap: UnsafeMutablePointer<Int32>?)

@_silgen_name("kit_font_hmetrics")
func kit_font_hmetrics(_ font: UnsafeMutableRawPointer?, _ codepoint: Int32, _ advance: UnsafeMutablePointer<Int32>?, _ lsb: UnsafeMutablePointer<Int32>?)

@_silgen_name("kit_font_kern")
func kit_font_kern(_ font: UnsafeMutableRawPointer?, _ cp1: Int32, _ cp2: Int32) -> Int32

@_silgen_name("kit_font_glyph_bitmap")
func kit_font_glyph_bitmap(_ font: UnsafeMutableRawPointer?, _ scale: Float, _ codepoint: Int32, _ w: UnsafeMutablePointer<Int32>?, _ h: UnsafeMutablePointer<Int32>?, _ xoff: UnsafeMutablePointer<Int32>?, _ yoff: UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<UInt8>?

@_silgen_name("kit_font_glyph_index")
func kit_font_glyph_index(_ font: UnsafeMutableRawPointer?, _ codepoint: Int32) -> Int32

@_silgen_name("kit_emoji_init")
func kit_emoji_init(_ ttf: UnsafePointer<UInt8>?, _ len: Int32) -> UnsafeMutableRawPointer?

@_silgen_name("kit_emoji_glyph_png")
func kit_emoji_glyph_png(_ handle: UnsafeMutableRawPointer?, _ codepoint: Int32, _ pngLen: UnsafeMutablePointer<UInt32>?, _ ppem: UnsafeMutablePointer<Int32>?, _ bearingX: UnsafeMutablePointer<Int32>?, _ bearingY: UnsafeMutablePointer<Int32>?, _ advance: UnsafeMutablePointer<Int32>?) -> UnsafePointer<UInt8>?

final class Kit {
    static let shared = Kit()
    var window: OpaquePointer? = nil
    var renderer: OpaquePointer? = nil
    var mat = Mat()
    var stack: [Mat] = []
    var alpha: Float = 1
    // one-shot particle tint: gfx_set_tint sets it, the next gfx_draw_image consumes
    // it (SpriteKit colorBlendFactor). r,g,b in 0...1, bf = blend amount; nil = none.
    var partTint: (r: Float, g: Float, b: Float, bf: Float)? = nil
    // per-frame profiler (ns accumulated, reset each second): image-draw vs text-draw
    // vs present time, to compare against the web's img/txt/rest HUD.
    var profImgNs: UInt64 = 0
    var profTxtNs: UInt64 = 0
    var profPresentNs: UInt64 = 0
    var profCartNs: UInt64 = 0   // wasm frame() execution incl. its gfx callbacks (WAMR)
    var profBlitNs: UInt64 = 0   // offscreen screenTex -> window blit (queue only)
    var profVsyncNs: UInt64 = 0  // SDL_RenderPresent: GPU flush + vblank wait (mostly idle)
    var events: [(Int32, Int32, Int32, Int32, Int32)] = []
    var evtMutex: OpaquePointer? = nil

    func pushEvent(_ e: (Int32, Int32, Int32, Int32, Int32)) {
        if evtMutex == nil { evtMutex = SDL_CreateMutex() }
        SDL_LockMutex(evtMutex)
        events.append(e)
        SDL_UnlockMutex(evtMutex)
    }

    func popEvent() -> (Int32, Int32, Int32, Int32, Int32)? {
        if evtMutex == nil { evtMutex = SDL_CreateMutex() }
        SDL_LockMutex(evtMutex)
        let e = events.isEmpty ? nil : events.removeFirst()
        SDL_UnlockMutex(evtMutex)
        return e
    }
    var soundSpecs: [SDL_AudioSpec] = [SDL_AudioSpec()]
    var soundBufs: [UnsafeMutablePointer<UInt8>?] = [nil]
    var soundLens: [UInt32] = [0]
    var soundNames: [String: Int32] = [:]
    var audioDevice: UInt32 = 0
    var voiceStreams: [OpaquePointer] = []
    var voiceLoops: [Int32] = []
    var voiceIds: [Int32] = []
    var voicePans: [Float] = []
    var voiceGains: [Float] = []
    var duck: Float = 1
    var nextVoice: Int32 = 1
    var additive = false
    var composite: Int32 = 0
    var deadTextures: [UnsafeMutablePointer<SDL_Texture>] = []

    var gamepads: [OpaquePointer?] = [nil, nil, nil, nil]
    var gamepadInstanceIds: [UInt32] = [0, 0, 0, 0]
    var mapToKeys = false

    var lineJoin: Int32 = 1
    var lineCap: Int32 = 1
    var lineMiterLimit: Float = 10

    var mouseLogX: Int32 = 0
    var mouseLogY: Int32 = 0
    var mouseHeld: [Bool] = [false, false, false]
    var sfKeyHeld: [Bool] = Array(repeating: false, count: 128)

    // Auto-hide the pointer when it sits still over our window (SDL_HideCursor is
    // the one cross-platform path: it covers every SDL video backend). Any mouse
    // activity re-shows it; the OS draws its own cursor while the pointer is off
    // our window, so we only hide while it actually has mouse focus here.
    var lastMouseActivityMs: UInt64 = 0
    var cursorHidden = false
    let cursorIdleHideMs: UInt64 = 2000
    func noteMouseActivity() {
        lastMouseActivityMs = SDL_GetTicks()
        if cursorHidden {
            _ = SDL_ShowCursor()
            cursorHidden = false
        }
    }
    func tickCursorIdle() {
        if lastMouseActivityMs == 0 { lastMouseActivityMs = SDL_GetTicks() }
        guard !cursorHidden else { return }
        guard SDL_GetMouseFocus() == window else { return }
        if SDL_GetTicks() &- lastMouseActivityMs >= cursorIdleHideMs {
            _ = SDL_HideCursor()
            cursorHidden = true
        }
    }

    var ttsPreferredVoice = ""
    var shaderProgs: [ShProgram?] = [nil]
    var cpuPixels: [Int32: (w: Int32, h: Int32, px: [UInt8])] = [:]
    var lightingShaderId: Int32 = -1
    var lightingState: Int32 = 0
    var shadowBlur: Float = 0
    var shadowDx: Float = 0
    var shadowDy: Float = 0
    var shadowRgba: UInt32 = 0
    var suppressShadow = false
    var whiteTex: UnsafeMutablePointer<SDL_Texture>? = nil

    // Canvas2D globalCompositeOperation table; destination-in/out and screen
    // have no SDL preset and compose from blend factors
    lazy var blendDestIn: SDL_BlendMode = SDL_ComposeCustomBlendMode(
        SDL_BLENDFACTOR_ZERO, SDL_BLENDFACTOR_SRC_ALPHA, SDL_BLENDOPERATION_ADD,
        SDL_BLENDFACTOR_ZERO, SDL_BLENDFACTOR_SRC_ALPHA, SDL_BLENDOPERATION_ADD)
    lazy var blendDestOut: SDL_BlendMode = SDL_ComposeCustomBlendMode(
        SDL_BLENDFACTOR_ZERO, SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, SDL_BLENDOPERATION_ADD,
        SDL_BLENDFACTOR_ZERO, SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, SDL_BLENDOPERATION_ADD)
    lazy var blendScreen: SDL_BlendMode = SDL_ComposeCustomBlendMode(
        SDL_BLENDFACTOR_ONE, SDL_BLENDFACTOR_ONE_MINUS_SRC_COLOR, SDL_BLENDOPERATION_ADD,
        SDL_BLENDFACTOR_ONE, SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, SDL_BLENDOPERATION_ADD)

    func currentBlend() -> SDL_BlendMode {
        if additive { return SDL_BLENDMODE_ADD }
        switch composite {
        case 1: return blendDestIn
        case 2: return blendDestOut
        case 3: return SDL_BLENDMODE_ADD
        case 4: return SDL_BLENDMODE_MUL
        case 5: return blendScreen
        case 6: return blendScreen
        default: return SDL_BLENDMODE_BLEND
        }
    }

    func retireTexture(_ tex: UnsafeMutablePointer<SDL_Texture>?) {
        if let tex { deadTextures.append(tex) }
    }

    // scratch render-target pool: per-frame helpers (translucent strokes,
    // shadow and blur downsamples) reuse targets by size instead of paying
    // texture creation every frame; recycled textures rejoin the pool after
    // present so queued draws that sample them stay valid
    var targetPool: [Int: [UnsafeMutablePointer<SDL_Texture>]] = [:]
    var poolPending: [(Int, UnsafeMutablePointer<SDL_Texture>)] = []

    func acquireTarget(_ w: Int32, _ h: Int32) -> UnsafeMutablePointer<SDL_Texture>? {
        let key = Int(w) << 16 | Int(h)
        if var list = targetPool[key], !list.isEmpty {
            let tex = list.removeLast()
            targetPool[key] = list
            return tex
        }
        return SDL_CreateTexture(renderer, targetFormat, SDL_TEXTUREACCESS_TARGET, w, h)
    }

    func recycleTarget(_ tex: UnsafeMutablePointer<SDL_Texture>?, _ w: Int32, _ h: Int32) {
        if let tex { poolPending.append((Int(w) << 16 | Int(h), tex)) }
    }

    func flushTargetPool() {
        for (key, tex) in poolPending {
            var list = targetPool[key] ?? []
            if list.count < 6 {
                list.append(tex)
                targetPool[key] = list
            } else {
                SDL_DestroyTexture(tex)
            }
        }
        poolPending.removeAll(keepingCapacity: true)
    }

    // 1x1 white texture: RenderGeometry honors TEXTURE blend modes, the
    // reliable route to alpha and additive (matchstick crossings brighten)
    func geometryTexture() -> UnsafeMutablePointer<SDL_Texture>? {
        if whiteTex == nil {
            whiteTex = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_RGBA8888,
                                         SDL_TEXTUREACCESS_STATIC, 1, 1)
            var px: UInt32 = 0xFFFFFFFF
            var rect = SDL_Rect(x: 0, y: 0, w: 1, h: 1)
            _ = SDL_UpdateTexture(whiteTex, &rect, &px, 4)
        }
        _ = SDL_SetTextureBlendMode(whiteTex, currentBlend())
        return whiteTex
    }
    var storeKeys: [String] = []
    var storeVals: [String] = []
    var assetDir = "assets/sfx"
    var storePath = ".native-store.tsv"
    var fullscreen = false

    // host-pluggable asset source (WasmCart serves cart zip entries here);
    // falls back to baked-in kit_asset_data, then plain files on disk
    var assetProvider: ((String) -> [UInt8]?)? = nil
    var baseScale: Float = 1
    var textBaseline: Int32 = 2

    // the game's fixed logical canvas, the same per-game value the web host
    // page passes as WASMWEB.logicalWidth/Height; carts carry it in their
    // manifest.json and the host sets it at insert
    var logicalW: Float = LOGICAL_W
    var logicalH: Float = LOGICAL_H

    // persistent screen target, the SDL stand-in for the web canvas: frames
    // that repaint nothing (static title screens) keep showing the last
    // composite instead of flipping to an undefined backbuffer
    var screenTex: UnsafeMutablePointer<SDL_Texture>? = nil
    var screenW: Int32 = 0
    var screenH: Int32 = 0

    func ensureScreenTarget() {
        var pw: Int32 = 0
        var ph: Int32 = 0
        _ = SDL_GetWindowSizeInPixels(window, &pw, &ph)
        if screenTex == nil || pw != screenW || ph != screenH {
            if let old = screenTex { SDL_DestroyTexture(old) }
            screenTex = SDL_CreateTexture(renderer, targetFormat, SDL_TEXTUREACCESS_TARGET, pw, ph)
            screenW = pw
            screenH = ph
        }
        _ = SDL_SetRenderTarget(renderer, screenTex)
    }

    struct ImgRec {
        var tex: UnsafeMutablePointer<SDL_Texture>?
        var w: Int32
        var h: Int32
        // Resolution independence (mirrors runtime.js svgRaster): for vector art we keep
        // the SVG source and re-rasterize at the sprite's live on-screen device footprint,
        // quantized to power-of-two buckets. nil svgBytes = raster image (no re-raster).
        var svgBytes: [UInt8]? = nil
        var rasterMult: Int32 = 1   // power-of-two intrinsic multiple the current tex was baked at
    }
    var images: [ImgRec?] = [nil]
    var freeImageSlots: [Int] = []
    var imageNames: [String: Int32] = [:]

    var fontInfos: [UnsafeMutableRawPointer?] = [nil]
    var fontNames: [String: Int32] = [:]
    var defaultFont: Int32 = -1

    // Three emoji sources the games can render through, chosen by emojiMode:
    //   0 apple — Apple Color Emoji sbix font (macOS only)
    //   1 png   — Apple-art PNGs pulled from a bundled zip (emojiPngProvider)
    //   2 noto  — NotoColorEmoji CBDT font
    // The chosen mode is tried first, the rest fall back behind it with Noto
    // last in the apple/png chains, so a glyph one source lacks still renders.
    static let emojiModeApple: Int32 = 0
    static let emojiModePng: Int32 = 1
    static let emojiModeNoto: Int32 = 2
    var emojiMode: Int32 = 0
    var appleEmojiFont: UnsafeMutableRawPointer? = nil
    var notoEmojiFont: UnsafeMutableRawPointer? = nil

    struct EmojiGlyph {
        var tex: UnsafeMutablePointer<SDL_Texture>?
        var w: Int32
        var h: Int32
        var ppem: Int32
        var bearingX: Int32
        var bearingY: Int32
        var advance: Int32
    }
    var emojiCache: [Int: EmojiGlyph] = [:]

    // Host-pluggable PNG emoji source (png mode): given a codepoint, the host
    // hands back the raw bytes of a square color PNG (e.g. pulled on the fly out
    // of a bundled emoji zip). nil = no glyph for that codepoint.
    var emojiPngProvider: ((Int32) -> [UInt8]?)? = nil

    // Back-compat: single-font games keep calling setEmojiFont; that font is the
    // apple slot, and the default mode renders through it.
    func setEmojiFont(_ ttf: UnsafePointer<UInt8>?, _ len: Int) {
        appleEmojiFont = kit_emoji_init(ttf, Int32(len))
    }
    func setNotoEmojiFont(_ ttf: UnsafePointer<UInt8>?, _ len: Int) {
        notoEmojiFont = kit_emoji_init(ttf, Int32(len))
    }
    // The mode is a preference with fallback, so the source that actually
    // renders a glyph can differ (e.g. NOTO mode but a glyph Noto lacks falls to
    // Apple). Log the FIRST glyph each source renders after a mode change, so the
    // console shows exactly which source is in use without per-glyph spam.
    var emojiLoggedSources: Set<Int32> = []
    private func emojiModeName(_ m: Int32) -> String {
        m == Kit.emojiModePng ? "PNG" : m == Kit.emojiModeNoto ? "NOTO" : "APPLE"
    }
    private func logEmojiSource(_ src: Int32, _ cp: Int32) {
        guard emojiLoggedSources.insert(src).inserted else { return }
        let name = src == Kit.emojiModePng ? "PNG zip (apple-color-emoji.zip)"
                 : src == Kit.emojiModeNoto ? "NOTO CBDT font (NotoColorEmoji.ttf)"
                 : "APPLE sbix font (Apple Color Emoji.ttc)"
        print("emoji: rendering via \(name)  [mode=\(emojiModeName(emojiMode)), first cp=\(cp)]")
    }
    func setEmojiMode(_ m: Int32) {
        guard m != emojiMode else { return }
        emojiMode = m
        emojiLoggedSources.removeAll()
        print("emoji: mode set to \(emojiModeName(m))")
        for (_, g) in emojiCache where g.tex != nil { SDL_DestroyTexture(g.tex) }
        emojiCache.removeAll()
    }

    func emojiGlyph(_ cp: Int32) -> EmojiGlyph? {
        if let g = emojiCache[Int(cp)] { return g }
        let order: [Int32] = emojiMode == Kit.emojiModePng ? [1, 0, 2]
                           : emojiMode == Kit.emojiModeNoto ? [2, 0, 1]
                           : [0, 1, 2]
        for src in order {
            if src == Kit.emojiModePng {
                if let provider = emojiPngProvider, let bytes = provider(cp),
                   let g = pngEmojiGlyph(bytes, cp) { logEmojiSource(src, cp); return g }
            } else if let font = (src == Kit.emojiModeNoto ? notoEmojiFont : appleEmojiFont),
                      let g = fontEmojiGlyph(font, cp) {
                logEmojiSource(src, cp)
                return g
            }
        }
        return nil
    }

    private func fontEmojiGlyph(_ font: UnsafeMutableRawPointer, _ cp: Int32) -> EmojiGlyph? {
        var pngLen: UInt32 = 0
        var ppem: Int32 = 0
        var bearingX: Int32 = 0
        var bearingY: Int32 = 0
        var advance: Int32 = 0
        guard let png = kit_emoji_glyph_png(font, cp, &pngLen, &ppem, &bearingX, &bearingY, &advance) else { return nil }
        return buildEmoji(png, Int32(pngLen), cp, ppem: ppem, bearingX: bearingX, bearingY: bearingY, advance: advance)
    }

    private func pngEmojiGlyph(_ bytes: [UInt8], _ cp: Int32) -> EmojiGlyph? {
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return nil }
            // No sbix metrics in a loose PNG: a 160px Apple strike sits ~79%
            // above the baseline, square advance — the same rule the font path
            // applies with a zero origin.
            return buildEmoji(base, Int32(buf.count), cp,
                              ppem: 0, bearingX: 0, bearingY: 0, advance: 0, looseSquare: true)
        }
    }

    private func buildEmoji(_ png: UnsafePointer<UInt8>, _ pngLen: Int32, _ cp: Int32,
                            ppem: Int32, bearingX: Int32, bearingY: Int32, advance: Int32,
                            looseSquare: Bool = false) -> EmojiGlyph? {
        var w: Int32 = 0
        var h: Int32 = 0
        guard let pixels = kit_png_decode(png, pngLen, &w, &h), w > 0, h > 0 else { return nil }
        let tex = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STATIC, w, h)
        var rect = SDL_Rect(x: 0, y: 0, w: w, h: h)
        _ = SDL_UpdateTexture(tex, &rect, pixels, w * 4)
        kit_stb_free(pixels)
        _ = SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND)
        let g = looseSquare
            ? EmojiGlyph(tex: tex, w: w, h: h, ppem: h, bearingX: 0, bearingY: h * 79 / 100, advance: w)
            : EmojiGlyph(tex: tex, w: w, h: h, ppem: ppem, bearingX: bearingX, bearingY: bearingY, advance: advance)
        emojiCache[Int(cp)] = g
        return g
    }

    struct Glyph {
        var tex: UnsafeMutablePointer<SDL_Texture>?
        var w: Int32
        var h: Int32
        var xoff: Int32
        var yoff: Int32
    }
    var glyphCache: [Int: Glyph] = [:]

    struct OffTarget {
        var tex: UnsafeMutablePointer<SDL_Texture>?
        var w: Int32
        var h: Int32
        var savedMat: Mat
        var savedStack: [Mat]
        var savedAlpha: Float
        var prevTarget: UnsafeMutablePointer<SDL_Texture>?
        var blur: Float = 0
        var brightness: Float = 1
    }
    var targets: [OffTarget?] = []

    // Gaussian-ish blur via downsample + bilinear upsample, the same trick
    // the soft shadows use; blur is linear so blurring the finished bake
    // once equals Canvas2D blurring every draw op into it
    func blurTexture(_ tex: UnsafeMutablePointer<SDL_Texture>?, _ w: Int32, _ h: Int32, _ blurLogical: Float) -> UnsafeMutablePointer<SDL_Texture>? {
        let f = max(2, blurLogical * max(1, baseScale) / 2)
        let sw = max(1, Int32(Float(w) / f))
        let sh = max(1, Int32(Float(h) / f))
        guard let small = acquireTarget(sw, sh),
              let out = SDL_CreateTexture(renderer, targetFormat, SDL_TEXTUREACCESS_TARGET, w, h) else { return nil }
        let prev = SDL_GetRenderTarget(renderer)
        _ = SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_NONE)
        _ = SDL_SetRenderTarget(renderer, small)
        _ = SDL_SetRenderDrawColorFloat(renderer, 0, 0, 0, 0)
        _ = SDL_RenderClear(renderer)
        _ = SDL_RenderTexture(renderer, tex, nil, nil)
        _ = SDL_SetTextureBlendMode(small, SDL_BLENDMODE_NONE)
        _ = SDL_SetRenderTarget(renderer, out)
        _ = SDL_RenderClear(renderer)
        _ = SDL_RenderTexture(renderer, small, nil, nil)
        _ = SDL_SetRenderTarget(renderer, prev)
        _ = SDL_SetTextureBlendMode(out, SDL_BLENDMODE_BLEND)
        recycleTarget(small, sw, sh)
        return out
    }

    var engVolumes: [Int32: Float] = [:]
    var engPlayers: [Int32: (sound: Int32, loops: Int32, voice: Int32)] = [:]
    var nextEngId: Int32 = 1

    // text-to-speech, buffered: a line's first utterance speaks instantly
    // through the pre-warmed say process while a parallel silent synth
    // (say -o) renders the same line to a wav; the wav loads into the sound
    // table so every repeat plays with sound-effect latency
    var ttsProcess: OpaquePointer? = nil
    var ttsTool: String? = nil
    var ttsQueue: [(String, Float)] = []
    var ttsWarm: OpaquePointer? = nil
    var ttsCache: [String: Int32] = [:]
    var ttsSynth: OpaquePointer? = nil
    var ttsSynthKey = ""
    var ttsSynthPath = ""
    var ttsVoice: Int32 = 0

    func gpButtonValue(_ slot: Int, _ webButton: Int32) -> Float {
        guard slot >= 0, slot < 4, let pad = gamepads[slot] else { return 0 }
        switch webButton {
        case 0: return SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_SOUTH) ? 1 : 0
        case 1: return SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_EAST) ? 1 : 0
        case 2: return SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_WEST) ? 1 : 0
        case 3: return SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_NORTH) ? 1 : 0
        case 4: return SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_LEFT_SHOULDER) ? 1 : 0
        case 5: return SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER) ? 1 : 0
        case 6: return max(0, Float(SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFT_TRIGGER)) / 32767)
        case 7: return max(0, Float(SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER)) / 32767)
        case 8: return SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_BACK) ? 1 : 0
        case 9: return SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_START) ? 1 : 0
        case 10: return SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_LEFT_STICK) ? 1 : 0
        case 11: return SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_RIGHT_STICK) ? 1 : 0
        case 12: return SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_DPAD_UP) ? 1 : 0
        case 13: return SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_DPAD_DOWN) ? 1 : 0
        case 14: return SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_DPAD_LEFT) ? 1 : 0
        case 15: return SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_DPAD_RIGHT) ? 1 : 0
        case 16: return SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_GUIDE) ? 1 : 0
        default: return 0
        }
    }

    func gpAxisValue(_ slot: Int, _ webAxis: Int32) -> Float {
        guard slot >= 0, slot < 4, let pad = gamepads[slot] else { return 0 }
        let sdlAxis: SDL_GamepadAxis
        switch webAxis {
        case 0: sdlAxis = SDL_GAMEPAD_AXIS_LEFTX
        case 1: sdlAxis = SDL_GAMEPAD_AXIS_LEFTY
        case 2: sdlAxis = SDL_GAMEPAD_AXIS_RIGHTX
        case 3: sdlAxis = SDL_GAMEPAD_AXIS_RIGHTY
        default: return 0
        }
        let v = SDL_GetGamepadAxis(pad, sdlAxis)
        return Float(v) / (v < 0 ? 32768 : 32767)
    }

    func sdlButtonToSfKey(_ btn: UInt8) -> Int32 {
        switch Int32(btn) {
        case SDL_GAMEPAD_BUTTON_SOUTH.rawValue: return 57
        case SDL_GAMEPAD_BUTTON_BACK.rawValue: return 36
        case SDL_GAMEPAD_BUTTON_START.rawValue: return 58
        case SDL_GAMEPAD_BUTTON_DPAD_UP.rawValue: return 73
        case SDL_GAMEPAD_BUTTON_DPAD_DOWN.rawValue: return 74
        case SDL_GAMEPAD_BUTTON_DPAD_LEFT.rawValue: return 71
        case SDL_GAMEPAD_BUTTON_DPAD_RIGHT.rawValue: return 72
        default: return -1
        }
    }

    func ttsToolPath() -> String? {
        if let ttsTool { return ttsTool.isEmpty ? nil : ttsTool }
        var found = ""
        for candidate in ["/usr/bin/say", "/usr/bin/espeak", "/usr/bin/espeak-ng", "/usr/bin/spd-say"] {
            var info = SDL_PathInfo()
            if candidate.withCString({ SDL_GetPathInfo($0, &info) }) {
                found = candidate
                break
            }
        }
        ttsTool = found
        return found.isEmpty ? nil : found
    }

    func ttsWpm(_ rate: Float) -> Int32 {
        let r = rate <= 0 ? 1 : max(0.1, min(rate, 10))
        return Int32(max(60, min(400, 175 * r)))
    }

    func ttsBusy() -> Bool {
        ttsProcess != nil || ttsVoice != 0
    }

    func ttsStop() {
        ttsQueue = []
        if let p = ttsProcess {
            _ = SDL_KillProcess(p, false)
            SDL_DestroyProcess(p)
            ttsProcess = nil
        }
        if ttsVoice != 0 {
            let v = ttsVoice
            ttsVoice = 0
            stopVoice(v)
        }
        setDuck(1)
    }

    func ttsSpeak(_ text: String, rate: Float) -> Bool {
        guard ttsToolPath() != nil else { return false }
        if ttsBusy() {
            ttsQueue.append((text, rate))
            return true
        }
        let key = String(ttsWpm(rate)) + "|" + ttsPreferredVoice + "|" + text
        if let id = ttsCache[key] {
            ttsVoice = play(id, volume: 100, loop: false)
            if ttsVoice > 0 {
                setDuck(0.4)
            } else {
                ttsVoice = 0
            }
            return true
        }
        if ttsSynth == nil { ttsSynthesize(text, rate: rate) }
        return ttsSpawn(text, rate: rate)
    }

    // queue advance + synth harvesting, called once per frame
    func ttsReap() {
        if let w = ttsWarm {
            var wcode: Int32 = 0
            if SDL_WaitProcess(w, false, &wcode) {
                SDL_DestroyProcess(w)
                ttsWarm = nil
                ttsWarmup()
            }
        }
        if let p = ttsSynth {
            var code: Int32 = 0
            if SDL_WaitProcess(p, false, &code) {
                SDL_DestroyProcess(p)
                ttsSynth = nil
                var spec = SDL_AudioSpec()
                var buf: UnsafeMutablePointer<UInt8>? = nil
                var len: UInt32 = 0
                let ok = ttsSynthPath.withCString { SDL_LoadWAV($0, &spec, &buf, &len) }
                _ = ttsSynthPath.withCString { SDL_RemovePath($0) }
                if ok, len > 0 {
                    let id = Int32(soundSpecs.count)
                    soundSpecs.append(spec)
                    soundBufs.append(buf)
                    soundLens.append(len)
                    ttsCache[ttsSynthKey] = id
                }
            }
        }
        if let p = ttsProcess {
            var code: Int32 = 0
            if SDL_WaitProcess(p, false, &code) {
                SDL_DestroyProcess(p)
                ttsProcess = nil
            }
        }
        if ttsVoice != 0 {
            var alive = false
            for v in voiceIds where v == ttsVoice {
                alive = true
                break
            }
            if !alive { ttsVoice = 0 }
        }
        if !ttsBusy() {
            if duck < 1 { setDuck(1) }
            if !ttsQueue.isEmpty {
                let (text, rate) = ttsQueue.removeFirst()
                _ = ttsSpeak(text, rate: rate)
            }
        }
    }

    // a full but silent utterance at startup loads the daemon's voice end to
    // end (synthesis + audio path at zero volume), so the first real line
    // speaks without the cold-start lag
    func ttsPrime() {
        guard let tool = ttsToolPath() else { return }
        var args: [String]
        if tool.hasSuffix("/say") {
            args = [tool, "[[volm 0]] ok"]
        } else if tool.hasSuffix("spd-say") {
            return
        } else {
            args = [tool, "-a", "0", "ok"]
        }
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { s in s.withCString { SDL_strdup($0) } }
        argv.append(nil)
        let proc = argv.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) {
                SDL_CreateProcess($0, false)
            }
        }
        for p in argv where p != nil { SDL_free(p) }
        if let proc { SDL_DestroyProcess(proc) }
    }

    // say pays ~400ms of voice setup at launch, so one process always sits
    // warm with stdin piped; speaking is write + EOF, near-instant, and the
    // replacement warms while the line plays
    func ttsWarmup() {
        guard let tool = ttsToolPath(), tool.hasSuffix("/say"), ttsWarm == nil else { return }
        var args = [tool]
        if !ttsPreferredVoice.isEmpty { args += ["-v", ttsPreferredVoice] }
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { s in s.withCString { SDL_strdup($0) } }
        argv.append(nil)
        let props = SDL_CreateProperties()
        argv.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafeRawPointer?.self, capacity: buf.count) { rb in
                _ = "SDL.process.create.args".withCString {
                    SDL_SetPointerProperty(props, $0, UnsafeMutableRawPointer(mutating: rb))
                }
            }
            _ = "SDL.process.create.stdin_option".withCString {
                SDL_SetNumberProperty(props, $0, Int64(SDL_PROCESS_STDIO_APP.rawValue))
            }
            ttsWarm = SDL_CreateProcessWithProperties(props)
        }
        SDL_DestroyProperties(props)
        for p in argv where p != nil { SDL_free(p) }
    }

    func ttsSpawn(_ text: String, rate: Float) -> Bool {
        guard let tool = ttsToolPath() else { return false }
        let wpm = String(ttsWpm(rate))

        if tool.hasSuffix("/say") {
            if ttsWarm == nil { ttsWarmup() }
            guard let warm = ttsWarm, let input = SDL_GetProcessInput(warm) else { return false }
            let line = "[[rate " + wpm + "]] " + text + "\n"
            let bytes = Array(line.utf8)
            _ = bytes.withUnsafeBufferPointer { SDL_WriteIO(input, $0.baseAddress, $0.count) }
            _ = SDL_CloseIO(input)
            ttsProcess = warm
            ttsWarm = nil
            ttsWarmup()
            setDuck(0.4)
            return true
        }

        var args: [String]
        if tool.hasSuffix("spd-say") {
            args = [tool, "-w", text]
        } else {
            args = [tool, "-s", wpm, text]
        }
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { s in s.withCString { SDL_strdup($0) } }
        argv.append(nil)
        let proc = argv.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) {
                SDL_CreateProcess($0, false)
            }
        }
        for p in argv where p != nil { SDL_free(p) }
        guard let proc else { return false }
        ttsProcess = proc
        setDuck(0.4)
        return true
    }

    // silent render of the same line into the cache for instant replays
    func ttsSynthesize(_ text: String, rate: Float) {
        guard let tool = ttsToolPath() else { return }
        let wpm = String(ttsWpm(rate))
        ttsSynthPath = storePath + ".tts.wav"
        var args: [String]
        if tool.hasSuffix("/say") {
            var a = [tool, "-o", ttsSynthPath, "--data-format=LEI16@22050"]
            if !ttsPreferredVoice.isEmpty { a += ["-v", ttsPreferredVoice] }
            a += ["-r", wpm, text]
            args = a
        } else if tool.hasSuffix("spd-say") {
            return
        } else {
            args = [tool, "-w", ttsSynthPath, "-s", wpm, text]
        }
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { s in s.withCString { SDL_strdup($0) } }
        argv.append(nil)
        let proc = argv.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) {
                SDL_CreateProcess($0, false)
            }
        }
        for p in argv where p != nil { SDL_free(p) }
        guard let proc else { return }
        ttsSynth = proc
        ttsSynthKey = wpm + "|" + ttsPreferredVoice + "|" + text
    }

    func assetBytes(_ name: String) -> [UInt8]? {
        if let provider = assetProvider {
            if let d = provider(name) { return d }
        }
        var memLen: UInt32 = 0
        if let mem = name.withCString({ kit_asset_data($0, &memLen) }), memLen > 0 {
            var out = [UInt8]()
            out.reserveCapacity(Int(memLen))
            for i in 0..<Int(memLen) { out.append(mem[i]) }
            return out
        }
        for path in [name, "assets/" + name] {
            var size = 0
            if let data = path.withCString({ SDL_LoadFile($0, &size) }), size > 0 {
                let bytes = UnsafeRawPointer(data).bindMemory(to: UInt8.self, capacity: size)
                var out = [UInt8]()
                out.reserveCapacity(size)
                for i in 0..<size { out.append(bytes[i]) }
                SDL_free(data)
                return out
            }
        }
        return nil
    }

    func baseName(_ name: String) -> String {
        var bytes = Array(name.utf8)
        var lastSlash = -1
        for i in 0..<bytes.count where bytes[i] == 47 { lastSlash = i }
        if lastSlash >= 0 { bytes.removeFirst(lastSlash + 1) }
        bytes.append(0)
        return bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    func registerImage(_ rec: ImgRec) -> Int32 {
        if let slot = freeImageSlots.popLast() {
            images[slot] = rec
            return Int32(slot)
        }
        images.append(rec)
        return Int32(images.count - 1)
    }

    // Resolution-independent vector re-raster: grow an SVG's texture to the sprite's live
    // on-screen device footprint, quantized to power-of-two buckets (grow-only, so a sprite
    // re-rasters at most ~log2(maxMult) times over its life and never thrashes on a boundary).
    // This is the native analog of runtime.js svgRaster — the texture is always >= display
    // size, so SDL only ever downsamples it = sharp, instead of upscaling a frozen raster.
    func svgTexForFootprint(_ img: Int32, _ needDevW: Float, _ needDevH: Float) -> ImgRec? {
        guard img > 0, Int(img) < images.count, var rec = images[Int(img)] else { return nil }
        guard let bytes = rec.svgBytes, rec.w > 0, rec.h > 0 else { return rec }   // raster image: skip
        let needMult = max(needDevW / Float(rec.w), needDevH / Float(rec.h))
        var mult: Int32 = 1
        while Float(mult) < needMult && mult < 16 { mult <<= 1 }   // smallest pow2 >= need, capped
        guard mult > rec.rasterMult else { return rec }            // already crisp enough
        var tw: Int32 = 0, th: Int32 = 0, lw: Int32 = 0, lh: Int32 = 0
        let px = bytes.withUnsafeBufferPointer {
            kit_svg_decode_hi($0.baseAddress, Int32(bytes.count), mult, &tw, &th, &lw, &lh)
        }
        guard let px, tw > 0, th > 0 else { return rec }
        let nt = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STATIC, tw, th)
        var r = SDL_Rect(x: 0, y: 0, w: tw, h: th)
        _ = SDL_UpdateTexture(nt, &r, px, tw * 4)
        kit_stb_free(px)
        _ = SDL_SetTextureScaleMode(nt, SDL_SCALEMODE_LINEAR)
        _ = SDL_SetTextureBlendMode(nt, SDL_BLENDMODE_BLEND)
        retireTexture(rec.tex)
        rec.tex = nt
        rec.rasterMult = mult
        images[Int(img)] = rec
        return rec
    }

    func imageByName(_ name: String) -> Int32 {
        if let id = imageNames[name] { return id }
        var data = assetBytes(name)
        if data == nil { data = assetBytes("images/" + name) }
        if data == nil { data = assetBytes("images/" + name + ".png") }
        // Scenes reference textures by bare name (e.g. "latestlogo"); UFO's art is
        // .svg, so without these the lookup only ever tried .png and every sprite
        // fell through to a placeholder box. (BossMan ships .png, so it "worked".)
        if data == nil { data = assetBytes("images/" + name + ".svg") }
        if data == nil { data = assetBytes(name + ".svg") }
        if data == nil { data = assetBytes(baseName(name)) }
        let imgDbg = ("KIT_IMG_DEBUG".withCString { SDL_getenv($0) }) != nil
        guard let data else { if imgDbg { print("IMG MISS: \(name)") }; return 0 }
        var w: Int32 = 0   // texture pixel size (supersampled for SVG)
        var h: Int32 = 0
        var logW: Int32 = 0   // logical/intrinsic size — drives UVs + img_width/height
        var logH: Int32 = 0
        var svgMult: Int32 = 0   // >0 once SVG-decoded: the intrinsic multiple this first raster used
        var pixels = data.withUnsafeBufferPointer { kit_png_decode($0.baseAddress, Int32(data.count), &w, &h) }
        if pixels != nil { logW = w; logH = h }
        if pixels == nil {   // not PNG/JPEG — menu sprites, parallax + gameplay art are .svg
            // Supersample SVGs to the device scale so embedded detail survives instead of
            // rasterizing the tiny declared canvas and upscaling (the soft grass/dirt).
            // The hi-res texture is sampled through normalized UVs that use the LOGICAL
            // size, so it's res-independent with no UV/atlas change. baseScale = screen
            // px per logical unit; ss=2 floor covers any pre-first-clear decode.
            let ss = Int32(max(2, min(4, Int(baseScale.rounded()))))
            pixels = data.withUnsafeBufferPointer { kit_svg_decode_hi($0.baseAddress, Int32(data.count), ss, &w, &h, &logW, &logH) }
            svgMult = ss
        }
        guard let pixels, w > 0, h > 0, logW > 0, logH > 0 else { if imgDbg { print("IMG DECODE-FAIL: \(name)") }; return 0 }
        if imgDbg { print("IMG OK: \(name) -> tex \(w)x\(h) / logical \(logW)x\(logH)") }
        let tex = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STATIC, w, h)
        var rect = SDL_Rect(x: 0, y: 0, w: w, h: h)
        _ = SDL_UpdateTexture(tex, &rect, pixels, w * 4)
        kit_stb_free(pixels)
        _ = SDL_SetTextureScaleMode(tex, SDL_SCALEMODE_LINEAR)   // tex is >= display footprint ⇒ downsample-only ⇒ sharp
        _ = SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND)
        var rec = ImgRec(tex: tex, w: logW, h: logH)
        if svgMult > 0 { rec.svgBytes = data; rec.rasterMult = svgMult }   // vector: enable footprint re-raster
        let id = registerImage(rec)
        imageNames[name] = id
        return id
    }

    func fontByName(_ name: String) -> Int32 {
        if let id = fontNames[name] { return id }
        var data = assetBytes(name)
        if data == nil { data = assetBytes("fonts/" + name) }
        if data == nil { data = assetBytes("fonts/" + name + ".ttf") }
        if data == nil { data = assetBytes(baseName(name)) }
        // Not in the cart — fall back to the OS font directories so unbundled families
        // (e.g. "AmericanTypewriter") resolve to the real system face instead of nothing.
        // EXCEPT the color-emoji families: they must return 0 so emoji codepoints route to
        // emojiGlyph (the sbix/CBDT color path). Loading Apple Color Emoji.ttc as a plain
        // outline font makes kit_font_glyph_index != 0, so the glyph draws BLANK instead.
        if data == nil, name != "Apple Color Emoji", name != "NotoColorEmoji" {
            for dir in ["/System/Library/Fonts/", "/System/Library/Fonts/Supplemental/", "/Library/Fonts/"] where data == nil {
                for ext in [".ttf", ".ttc", ".otf"] where data == nil {
                    data = assetBytes(dir + name + ext)
                }
            }
        }
        guard let data else { return 0 }
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
        for i in 0..<data.count { buf[i] = data[i] }
        guard let info = kit_font_init(buf, Int32(data.count)) else {
            buf.deallocate()
            return 0
        }
        let id = Int32(fontInfos.count)
        fontInfos.append(info)
        fontNames[name] = id
        return id
    }

    func resolveFont(_ font: Int32) -> UnsafeMutableRawPointer? {
        if font > 0, Int(font) < fontInfos.count { return fontInfos[Int(font)] }
        // font 0 = "use the default face" (a missing/emoji family). Resolve to ANY real
        // font we can load and RETRY each call until one exists — the old code cached this
        // once, pinning defaultFont to nil if no TTF had loaded yet, which blanked the
        // title's emoji + copyright labels (gfx_draw_text bails before the emoji-glyph
        // fallback). Emoji codepoints still route to emojiGlyph after this resolves.
        if defaultFont <= 0 {
            for candidate in ["Emulogic.ttf", "JetBrainsMono-Bold.ttf", "Menlo-Regular.ttf", "Menlo-Bold.ttf"] {
                let id = fontByName(candidate)
                if id > 0 { defaultFont = id; break }
            }
            if defaultFont <= 0 {
                for i in 1..<fontInfos.count where fontInfos[i] != nil { defaultFont = Int32(i); break }
            }
        }
        if defaultFont > 0, Int(defaultFont) < fontInfos.count { return fontInfos[Int(defaultFont)] }
        return nil
    }

    func decodeUTF8(_ p: UnsafePointer<CChar>?, _ len: Int32) -> [Int32] {
        var cps = [Int32]()
        guard let p else { return cps }
        var i = 0
        let n = Int(len)
        while i < n {
            let b0 = UInt32(UInt8(bitPattern: p[i]))
            var cp: UInt32 = 0
            var extra = 0
            if b0 < 0x80 { cp = b0 } else if b0 < 0xE0 { cp = b0 & 0x1F; extra = 1 } else if b0 < 0xF0 { cp = b0 & 0x0F; extra = 2 } else { cp = b0 & 0x07; extra = 3 }
            if i + extra >= n { break }
            for j in 1...max(1, extra) where extra > 0 {
                cp = (cp << 6) | (UInt32(UInt8(bitPattern: p[i + j])) & 0x3F)
            }
            cps.append(Int32(bitPattern: cp))
            i += 1 + extra
        }
        return cps
    }

    func glyph(_ font: Int32, _ info: UnsafeMutableRawPointer, _ cp: Int32, _ sizePx: Int32) -> Glyph? {
        let key = (Int(font) << 44) | (Int(cp) << 12) | Int(sizePx & 0xFFF)
        if let g = glyphCache[key] { return g }
        let scale = kit_font_scale_for_px(info, Float(sizePx))
        var w: Int32 = 0
        var h: Int32 = 0
        var xoff: Int32 = 0
        var yoff: Int32 = 0
        guard let bitmap = kit_font_glyph_bitmap(info, scale, cp, &w, &h, &xoff, &yoff) else {
            let g = Glyph(tex: nil, w: 0, h: 0, xoff: 0, yoff: 0)
            glyphCache[key] = g
            return g
        }
        var g = Glyph(tex: nil, w: w, h: h, xoff: xoff, yoff: yoff)
        if w > 0, h > 0 {
            var rgba = [UInt8](repeating: 255, count: Int(w * h * 4))
            for i in 0..<Int(w * h) { rgba[i * 4 + 3] = bitmap[i] }
            let tex = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STATIC, w, h)
            var rect = SDL_Rect(x: 0, y: 0, w: w, h: h)
            _ = rgba.withUnsafeBufferPointer { SDL_UpdateTexture(tex, &rect, $0.baseAddress, w * 4) }
            _ = SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND)
            g.tex = tex
        }
        kit_stb_free(bitmap)
        glyphCache[key] = g
        return g
    }

    func drawTexturedQuad(_ tex: UnsafeMutablePointer<SDL_Texture>?, _ dx: Float, _ dy: Float, _ dw: Float, _ dh: Float,
                          _ u0: Float, _ v0: Float, _ u1: Float, _ v1: Float, _ color: SDL_FColor) {
        guard let tex else { return }
        let q0 = mat.apply(dx, dy)
        let q1 = mat.apply(dx + dw, dy)
        let q2 = mat.apply(dx + dw, dy + dh)
        let q3 = mat.apply(dx, dy + dh)
        if cullsOffscreen(min(min(q0.x, q1.x), min(q2.x, q3.x)),
                          min(min(q0.y, q1.y), min(q2.y, q3.y)),
                          max(max(q0.x, q1.x), max(q2.x, q3.x)),
                          max(max(q0.y, q1.y), max(q2.y, q3.y)), 1) { return }
        if !suppressShadow, (shadowBlur > 0 || shadowDx != 0 || shadowDy != 0), shadowRgba & 0xFF > 0 {
            suppressShadow = true
            if shadowBlur > 0 {
                let texel = max(4, shadowBlur)
                let margin: Float = 2
                let tw = Int32(SDL_ceilf(dw / texel) + margin * 2)
                let th = Int32(SDL_ceilf(dh / texel) + margin * 2)
                if tw > 0, th > 0, let small = acquireTarget(tw, th) {
                    _ = SDL_SetTextureBlendMode(small, SDL_BLENDMODE_BLEND)
                    let prev = SDL_GetRenderTarget(renderer)
                    _ = SDL_SetRenderTarget(renderer, small)
                    _ = SDL_SetRenderDrawColorFloat(renderer, 0, 0, 0, 0)
                    _ = SDL_RenderClear(renderer)
                    let savedMat = mat
                    mat = Mat()
                    let (sr, sg, sb) = gameColor(shadowRgba)
                    _ = SDL_SetTextureColorModFloat(tex, sr, sg, sb)
                    drawTexturedQuad(tex, margin, margin, Float(tw) - margin * 2, Float(th) - margin * 2,
                                     u0, v0, u1, v1, SDL_FColor(r: 1, g: 1, b: 1, a: 1))
                    _ = SDL_SetTextureColorModFloat(tex, 1, 1, 1)
                    mat = savedMat
                    _ = SDL_SetRenderTarget(renderer, prev)
                    let sa = Float(shadowRgba & 0xFF) / 255 * alpha
                    drawTexturedQuad(small, dx + shadowDx - margin * texel, dy + shadowDy - margin * texel,
                                     dw + 2 * margin * texel, dh + 2 * margin * texel,
                                     0, 0, 1, 1, SDL_FColor(r: 1, g: 1, b: 1, a: sa))
                    recycleTarget(small, tw, th)
                }
            } else {
                let sa = Float(shadowRgba & 0xFF) / 255 * alpha
                let (sr, sg, sb) = gameColor(shadowRgba)
                _ = SDL_SetTextureColorModFloat(tex, sr, sg, sb)
                drawTexturedQuad(tex, dx + shadowDx, dy + shadowDy, dw, dh, u0, v0, u1, v1,
                                 SDL_FColor(r: 1, g: 1, b: 1, a: sa))
                _ = SDL_SetTextureColorModFloat(tex, 1, 1, 1)
            }
            suppressShadow = false
        }
        _ = SDL_SetTextureBlendMode(tex, currentBlend())
        let verts = [
            SDL_Vertex(position: q0, color: color, tex_coord: SDL_FPoint(x: u0, y: v0)),
            SDL_Vertex(position: q1, color: color, tex_coord: SDL_FPoint(x: u1, y: v0)),
            SDL_Vertex(position: q2, color: color, tex_coord: SDL_FPoint(x: u1, y: v1)),
            SDL_Vertex(position: q3, color: color, tex_coord: SDL_FPoint(x: u0, y: v1)),
        ]
        let idx: [Int32] = [0, 1, 2, 0, 2, 3]
        SDL_RenderGeometry(renderer, tex, verts, 4, idx, 6)
    }

    // Wide gamut: the web runtime renders game colors as display-p3, so game
    // rgba is interpreted as P3 coordinates and converted to sRGB with gamut
    // clipping. The pipeline stays nonlinear sRGB end to end because Canvas2D
    // composites in the canvas's nonlinear space; a linear EDR swapchain
    // blends translucency visibly heavier than the web.
    var wideGamut = true

    var targetFormat: SDL_PixelFormat {
        SDL_PIXELFORMAT_ABGR8888
    }

    func srgbLinearize(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : SDL_powf((c + 0.055) / 1.055, 2.4)
    }

    // sign-preserving so out-of-gamut linear values survive as extended sRGB
    func srgbEncode(_ c: Float) -> Float {
        let v = SDL_fabsf(c)
        let e = v <= 0.0031308 ? v * 12.92 : 1.055 * SDL_powf(v, 1 / 2.4) - 0.055
        return c < 0 ? -e : e
    }

    // P3 -> sRGB with clipping: in-gamut colors match the web's display-p3
    // exactly, out-of-gamut ones land on the nearest sRGB edge
    func gameColor(_ rgba: UInt32) -> (r: Float, g: Float, b: Float) {
        let r = Float((rgba >> 24) & 0xFF) / 255
        let g = Float((rgba >> 16) & 0xFF) / 255
        let b = Float((rgba >> 8) & 0xFF) / 255
        if !wideGamut { return (r, g, b) }
        let lr = srgbLinearize(r)
        let lg = srgbLinearize(g)
        let lb = srgbLinearize(b)
        return (max(0, min(1, srgbEncode(1.22494 * lr - 0.22494 * lg))),
                max(0, min(1, srgbEncode(-0.04206 * lr + 1.04206 * lg))),
                max(0, min(1, srgbEncode(-0.01963 * lr - 0.07879 * lg + 1.09842 * lb))))
    }

    // shouldCullNonVisibleNodes: a primitive whose device-space bounds land
    // entirely outside the active render target is skipped before any vertex
    // building or SDL submission. Shadowed draws bypass the cull (the offset
    // shadow can re-enter the frame; its own pass culls itself).
    var shadowActive: Bool {
        !suppressShadow && (shadowBlur > 0 || shadowDx != 0 || shadowDy != 0) && shadowRgba & 0xFF > 0
    }

    func cullsOffscreen(_ minX: Float, _ minY: Float, _ maxX: Float, _ maxY: Float, _ pad: Float) -> Bool {
        if shadowActive { return false }
        var tw = Float(screenW)
        var th = Float(screenH)
        var i = targets.count - 1
        while i >= 0 {
            if let t = targets[i] {
                tw = Float(t.w)
                th = Float(t.h)
                break
            }
            i -= 1
        }
        if tw <= 0 || th <= 0 { return false }
        return maxX < -pad || minX > tw + pad || maxY < -pad || minY > th + pad
    }

    // Drawing always targets a texture now, where vertex alpha blends
    // reliably, so translucency is real; additive keeps the premultiplied
    // scale-toward-black so overlaps brighten instead of washing out.
    func fcolor(_ rgba: UInt32) -> SDL_FColor {
        let a = Float(rgba & 0xFF) / 255 * alpha
        let (r, g, b) = gameColor(rgba)
        if additive {
            return SDL_FColor(r: r * a, g: g * a, b: b * a, a: 1)
        }
        return SDL_FColor(r: r, g: g, b: b, a: a)
    }

    func strokePoly(_ pts: [SDL_FPoint], closed: Bool, thickness: Float, rgba: UInt32) {
        if pts.count < 2 { return }
        if !suppressShadow, (shadowBlur > 0 || shadowDx != 0 || shadowDy != 0), shadowRgba & 0xFF > 0 {
            suppressShadow = true
            let sdx = mat.a * shadowDx
            let sdy = mat.d * shadowDy
            let shifted = pts.map { SDL_FPoint(x: $0.x + sdx, y: $0.y + sdy) }
            strokePoly(shifted, closed: closed, thickness: thickness, rgba: shadowRgba)
            suppressShadow = false
        }
        // degenerate paths (pathless container shapes) must not leave a dot
        var minX = pts[0].x, maxX = pts[0].x, minY = pts[0].y, maxY = pts[0].y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        if maxX - minX < 0.01, maxY - minY < 0.01 { return }
        if cullsOffscreen(minX, minY, maxX, maxY, max(1, thickness * mat.lengthScale) / 2 + 2) { return }

        // A translucent stroke is many overlapping quads and join fans, and
        // every overlap double-blends into blotches. Canvas2D strokes the
        // path as ONE coverage shape, so do the same: render opaque into a
        // scratch target, composite once at the stroke's alpha.
        let aVal = Float(rgba & 0xFF) / 255 * alpha
        if !additive, aVal < 0.999 {
            let pad = max(1, thickness * mat.lengthScale) / 2 + 2
            let ox = minX - pad
            let oy = minY - pad
            let tw = Int32(SDL_ceilf(maxX - minX + pad * 2))
            let th = Int32(SDL_ceilf(maxY - minY + pad * 2))
            if tw > 0, th > 0, let scratch = acquireTarget(tw, th) {
                _ = SDL_SetTextureBlendMode(scratch, SDL_BLENDMODE_BLEND)
                let prev = SDL_GetRenderTarget(renderer)
                _ = SDL_SetRenderTarget(renderer, scratch)
                _ = SDL_SetRenderDrawColorFloat(renderer, 0, 0, 0, 0)
                _ = SDL_RenderClear(renderer)
                var shifted = pts
                for i in 0..<shifted.count {
                    shifted[i].x -= ox
                    shifted[i].y -= oy
                }
                let savedAlpha = alpha
                alpha = 1
                strokePoly(shifted, closed: closed, thickness: thickness, rgba: rgba | 0xFF)
                alpha = savedAlpha
                _ = SDL_SetRenderTarget(renderer, prev)
                let savedMat = mat
                mat = Mat()
                drawTexturedQuad(scratch, ox, oy, Float(tw), Float(th), 0, 0, 1, 1,
                                 SDL_FColor(r: 1, g: 1, b: 1, a: aVal))
                mat = savedMat
                recycleTarget(scratch, tw, th)
                return
            }
        }

        let color = fcolor(rgba)
        var clear = color
        clear.a = 0
        let w = max(1, thickness * mat.lengthScale) / 2
        var verts = [SDL_Vertex]()
        var idx = [Int32]()
        let n = pts.count
        let segs = closed ? n : n - 1

        var segTx = [Float](repeating: 0, count: segs)
        var segTy = [Float](repeating: 0, count: segs)
        var segNx = [Float](repeating: 0, count: segs)
        var segNy = [Float](repeating: 0, count: segs)
        for i in 0..<segs {
            let p1 = pts[i], p2 = pts[(i + 1) % n]
            let dx = p2.x - p1.x, dy = p2.y - p1.y
            let len = max(SDL_sqrtf(dx * dx + dy * dy), 0.0001)
            segTx[i] = dx / len; segTy[i] = dy / len
            segNx[i] = -dy / len; segNy[i] = dx / len
        }

        for i in 0..<segs {
            let p1 = pts[i], p2 = pts[(i + 1) % n]
            let ux = segNx[i], uy = segNy[i]
            let nx = ux * w, ny = uy * w
            let base = Int32(verts.count)
            verts.append(SDL_Vertex(position: SDL_FPoint(x: p1.x + nx, y: p1.y + ny), color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
            verts.append(SDL_Vertex(position: SDL_FPoint(x: p2.x + nx, y: p2.y + ny), color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
            verts.append(SDL_Vertex(position: SDL_FPoint(x: p2.x - nx, y: p2.y - ny), color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
            verts.append(SDL_Vertex(position: SDL_FPoint(x: p1.x - nx, y: p1.y - ny), color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
            idx.append(base); idx.append(base + 1); idx.append(base + 2)
            idx.append(base); idx.append(base + 2); idx.append(base + 3)
            if !additive {
                let fb = Int32(verts.count)
                verts.append(SDL_Vertex(position: SDL_FPoint(x: p1.x + nx + ux, y: p1.y + ny + uy), color: clear, tex_coord: SDL_FPoint(x: 0, y: 0)))
                verts.append(SDL_Vertex(position: SDL_FPoint(x: p2.x + nx + ux, y: p2.y + ny + uy), color: clear, tex_coord: SDL_FPoint(x: 0, y: 0)))
                verts.append(SDL_Vertex(position: SDL_FPoint(x: p2.x - nx - ux, y: p2.y - ny - uy), color: clear, tex_coord: SDL_FPoint(x: 0, y: 0)))
                verts.append(SDL_Vertex(position: SDL_FPoint(x: p1.x - nx - ux, y: p1.y - ny - uy), color: clear, tex_coord: SDL_FPoint(x: 0, y: 0)))
                idx.append(base); idx.append(base + 1); idx.append(fb + 1)
                idx.append(base); idx.append(fb + 1); idx.append(fb)
                idx.append(base + 3); idx.append(base + 2); idx.append(fb + 2)
                idx.append(base + 3); idx.append(fb + 2); idx.append(fb + 3)
            }
        }

        if !additive {
            let join = lineJoin
            let cap = lineCap
            for vi in 0..<n {
                let isFirst = !closed && vi == 0
                let isLast  = !closed && vi == n - 1
                let p = pts[vi]
                if isFirst || isLast {
                    if cap == 0 { continue }
                    let si = isLast ? segs - 1 : 0
                    let tx: Float = isLast ? segTx[si] : -segTx[si]
                    let ty: Float = isLast ? segTy[si] : -segTy[si]
                    let nx = segNx[si], ny = segNy[si]
                    if cap == 2 {
                        let base = Int32(verts.count)
                        verts.append(SDL_Vertex(position: SDL_FPoint(x: p.x + nx*w, y: p.y + ny*w), color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
                        verts.append(SDL_Vertex(position: SDL_FPoint(x: p.x - nx*w, y: p.y - ny*w), color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
                        verts.append(SDL_Vertex(position: SDL_FPoint(x: p.x + nx*w + tx*w, y: p.y + ny*w + ty*w), color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
                        verts.append(SDL_Vertex(position: SDL_FPoint(x: p.x - nx*w + tx*w, y: p.y - ny*w + ty*w), color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
                        idx.append(base); idx.append(base+1); idx.append(base+2)
                        idx.append(base+1); idx.append(base+3); idx.append(base+2)
                        let fb = Int32(verts.count)
                        verts.append(SDL_Vertex(position: SDL_FPoint(x: p.x + nx*(w+1) + tx*(w+1), y: p.y + ny*(w+1) + ty*(w+1)), color: clear, tex_coord: SDL_FPoint(x: 0, y: 0)))
                        verts.append(SDL_Vertex(position: SDL_FPoint(x: p.x - nx*(w+1) + tx*(w+1), y: p.y - ny*(w+1) + ty*(w+1)), color: clear, tex_coord: SDL_FPoint(x: 0, y: 0)))
                        idx.append(base+2); idx.append(base+3); idx.append(fb+1)
                        idx.append(base+2); idx.append(fb+1); idx.append(fb)
                        continue
                    }
                } else {
                    if join != 1 {
                        let inSeg  = closed ? (vi + n - 1) % n : vi - 1
                        let outSeg = vi
                        let n1x = segNx[inSeg], n1y = segNy[inSeg]
                        let n2x = segNx[outSeg], n2y = segNy[outSeg]
                        let o1x = p.x + n1x * w, o1y = p.y + n1y * w
                        let o2x = p.x + n2x * w, o2y = p.y + n2y * w
                        var bx = n1x + n2x, by = n1y + n2y
                        let bl = SDL_sqrtf(bx * bx + by * by)
                        if bl < 0.001 {
                            let base = Int32(verts.count)
                            verts.append(SDL_Vertex(position: p, color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
                            verts.append(SDL_Vertex(position: SDL_FPoint(x: o1x, y: o1y), color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
                            verts.append(SDL_Vertex(position: SDL_FPoint(x: o2x, y: o2y), color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
                            idx.append(base); idx.append(base+1); idx.append(base+2)
                            continue
                        }
                        bx /= bl; by /= bl
                        let dot = n1x * bx + n1y * by
                        if join == 0, dot > 0.001 {
                            let miterLen = w / dot
                            if miterLen <= lineMiterLimit * w {
                                let mx = p.x + bx * miterLen
                                let my = p.y + by * miterLen
                                let base = Int32(verts.count)
                                verts.append(SDL_Vertex(position: p, color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
                                verts.append(SDL_Vertex(position: SDL_FPoint(x: o1x, y: o1y), color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
                                verts.append(SDL_Vertex(position: SDL_FPoint(x: mx, y: my), color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
                                verts.append(SDL_Vertex(position: SDL_FPoint(x: o2x, y: o2y), color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
                                idx.append(base); idx.append(base+1); idx.append(base+2)
                                idx.append(base); idx.append(base+2); idx.append(base+3)
                                continue
                            }
                        }
                        let base = Int32(verts.count)
                        verts.append(SDL_Vertex(position: p, color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
                        verts.append(SDL_Vertex(position: SDL_FPoint(x: o1x, y: o1y), color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
                        verts.append(SDL_Vertex(position: SDL_FPoint(x: o2x, y: o2y), color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
                        idx.append(base); idx.append(base+1); idx.append(base+2)
                        continue
                    }
                }
                let base = Int32(verts.count)
                verts.append(SDL_Vertex(position: p, color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
                for j in 0...8 {
                    let t = Float(j) / 8 * 2 * Float.pi
                    verts.append(SDL_Vertex(position: SDL_FPoint(x: p.x + w * SDL_cosf(t), y: p.y + w * SDL_sinf(t)), color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
                }
                for j in 0...8 {
                    let t = Float(j) / 8 * 2 * Float.pi
                    verts.append(SDL_Vertex(position: SDL_FPoint(x: p.x + (w + 1) * SDL_cosf(t), y: p.y + (w + 1) * SDL_sinf(t)), color: clear, tex_coord: SDL_FPoint(x: 0, y: 0)))
                }
                for j in 0..<8 {
                    idx.append(base); idx.append(base + 1 + Int32(j)); idx.append(base + 2 + Int32(j))
                    idx.append(base + 1 + Int32(j)); idx.append(base + 10 + Int32(j)); idx.append(base + 11 + Int32(j))
                    idx.append(base + 1 + Int32(j)); idx.append(base + 11 + Int32(j)); idx.append(base + 2 + Int32(j))
                }
            }
        }
        SDL_RenderGeometry(renderer, geometryTexture(), verts, Int32(verts.count), idx, Int32(idx.count))
    }

    func fillPoly(_ pts: [SDL_FPoint], rgba: UInt32) {
        if pts.count < 3 { return }
        if !suppressShadow, (shadowBlur > 0 || shadowDx != 0 || shadowDy != 0), shadowRgba & 0xFF > 0 {
            suppressShadow = true
            let sdx = mat.a * shadowDx
            let sdy = mat.d * shadowDy
            let shifted = pts.map { SDL_FPoint(x: $0.x + sdx, y: $0.y + sdy) }
            fillPoly(shifted, rgba: shadowRgba)
            suppressShadow = false
        }
        var cMinX = pts[0].x
        var cMaxX = pts[0].x
        var cMinY = pts[0].y
        var cMaxY = pts[0].y
        for p in pts {
            cMinX = min(cMinX, p.x)
            cMaxX = max(cMaxX, p.x)
            cMinY = min(cMinY, p.y)
            cMaxY = max(cMaxY, p.y)
        }
        if cullsOffscreen(cMinX, cMinY, cMaxX, cMaxY, 2) { return }
        let color = fcolor(rgba)
        var verts = [SDL_Vertex]()
        verts.reserveCapacity(pts.count * 2)
        for p in pts {
            verts.append(SDL_Vertex(position: p, color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
        }
        var idx = [Int32]()
        for i in 1..<(pts.count - 1) {
            idx.append(0)
            idx.append(Int32(i))
            idx.append(Int32(i + 1))
        }

        // 1-device-px feather ring along the boundary: the edge smoothing
        // Canvas2D paths get for free; vertex alpha ramps to clear outward
        if !additive {
            let n = pts.count
            var area: Float = 0
            for i in 0..<n {
                let p1 = pts[i]
                let p2 = pts[(i + 1) % n]
                area += p1.x * p2.y - p2.x * p1.y
            }
            let sign: Float = area >= 0 ? 1 : -1
            var clear = color
            clear.a = 0
            let base = Int32(verts.count)
            for i in 0..<n {
                let prev = pts[(i + n - 1) % n]
                let cur = pts[i]
                let next = pts[(i + 1) % n]
                var n1x = (cur.y - prev.y) * sign
                var n1y = (prev.x - cur.x) * sign
                var n2x = (next.y - cur.y) * sign
                var n2y = (cur.x - next.x) * sign
                let l1 = max(SDL_sqrtf(n1x * n1x + n1y * n1y), 0.0001)
                n1x /= l1
                n1y /= l1
                let l2 = max(SDL_sqrtf(n2x * n2x + n2y * n2y), 0.0001)
                n2x /= l2
                n2y /= l2
                var nx = n1x + n2x
                var ny = n1y + n2y
                let l = max(SDL_sqrtf(nx * nx + ny * ny), 0.0001)
                nx /= l
                ny /= l
                verts.append(SDL_Vertex(position: SDL_FPoint(x: cur.x + nx, y: cur.y + ny),
                                        color: clear, tex_coord: SDL_FPoint(x: 0, y: 0)))
            }
            for i in 0..<n {
                let j = (i + 1) % n
                idx.append(Int32(i))
                idx.append(Int32(j))
                idx.append(base + Int32(i))
                idx.append(Int32(j))
                idx.append(base + Int32(j))
                idx.append(base + Int32(i))
            }
        }
        SDL_RenderGeometry(renderer, geometryTexture(), verts, Int32(verts.count), idx, Int32(idx.count))
    }

    func circlePts(_ cx: Float, _ cy: Float, _ r: Float) -> [SDL_FPoint] {
        var out = [SDL_FPoint]()
        out.reserveCapacity(32)
        for i in 0..<32 {
            let t = Float(i) / 32 * 2 * Float.pi
            out.append(mat.apply(cx + r * SDL_cosf(t), cy + r * SDL_sinf(t)))
        }
        return out
    }

    func cString(_ p: UnsafePointer<CChar>?, _ len: Int32) -> String {
        guard let p else { return "" }
        var bytes = [UInt8]()
        bytes.reserveCapacity(Int(len) + 1)
        for i in 0..<Int(len) { bytes.append(UInt8(bitPattern: p[i])) }
        bytes.append(0)
        return bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    func loadSound(_ name: String) -> Int32 {
        return loadSoundImpl(name)
    }

    func loadSoundImpl(_ name: String) -> Int32 {
        var base = name
        var lastSlash = -1
        var i = 0
        for ch in base.utf8 {
            if ch == 47 { lastSlash = i }
            i += 1
        }
        if lastSlash >= 0 {
            var bytes = Array(base.utf8)
            bytes.removeFirst(lastSlash + 1)
            bytes.append(0)
            base = bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }
        if let id = soundNames[base] { return id }
        let id = Int32(soundSpecs.count)
        soundNames[base] = id
        var spec = SDL_AudioSpec()
        var buf: UnsafeMutablePointer<UInt8>? = nil
        var len: UInt32 = 0
        // assets baked into the binary take priority; disk is the fallback
        var memLen: UInt32 = 0
        let mem = base.withCString { kit_asset_data($0, &memLen) }
        if let mem, memLen > 0 {
            let io = SDL_IOFromConstMem(mem, Int(memLen))
            _ = SDL_LoadWAV_IO(io, true, &spec, &buf, &len)
        } else {
            let path = assetDir + "/" + base
            _ = path.withCString { SDL_LoadWAV($0, &spec, &buf, &len) }
        }
        soundSpecs.append(spec)
        soundBufs.append(buf)
        soundLens.append(len)
        return id
    }

    @discardableResult
    func play(_ id: Int32, volume: Float, loop: Bool) -> Int32 {
        let i = Int(id)
        guard i > 0, i < soundBufs.count, let buf = soundBufs[i] else { return -1 }
        if audioDevice == 0 {
            audioDevice = SDL_OpenAudioDevice(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, nil)
            guard audioDevice != 0 else { return -1 }
            _ = SDL_ResumeAudioDevice(audioDevice)
        }
        var spec = soundSpecs[i]
        guard let stream = SDL_CreateAudioStream(&spec, nil) else { return -1 }
        let gain = max(0, min(1, volume / 100))
        _ = SDL_SetAudioStreamGain(stream, gain * duck)
        _ = SDL_BindAudioStream(audioDevice, stream)
        _ = SDL_PutAudioStreamData(stream, buf, Int32(soundLens[i]))
        if !loop { _ = SDL_FlushAudioStream(stream) }
        let voice = nextVoice
        nextVoice += 1
        voiceStreams.append(stream)
        voiceLoops.append(loop ? id : 0)
        voiceIds.append(voice)
        voicePans.append(0)
        voiceGains.append(gain)
        return voice
    }

    // Pan by re-encoding the mono source as gain-weighted stereo at put time.
    // Loops refill every buffer, so pan changes land within a buffer's length.
    func putData(_ stream: OpaquePointer, _ soundIdx: Int, pan: Float) {
        guard let buf = soundBufs[soundIdx] else { return }
        var spec = soundSpecs[soundIdx]
        let len = Int(soundLens[soundIdx])
        let isU8 = spec.format == SDL_AUDIO_U8
        let isS16 = spec.format == SDL_AUDIO_S16LE
        if spec.channels == 1, pan != 0, isU8 || isS16 {
            let gl = min(1, 1 - pan)
            let gr = min(1, 1 + pan)
            var stereo = spec
            stereo.channels = 2
            _ = SDL_SetAudioStreamFormat(stream, &stereo, nil)
            if isU8 {
                var out = [UInt8]()
                out.reserveCapacity(len * 2)
                for i in 0..<len {
                    let centered = Float(buf[i]) - 128
                    out.append(UInt8(max(0, min(255, 128 + centered * gl))))
                    out.append(UInt8(max(0, min(255, 128 + centered * gr))))
                }
                _ = out.withUnsafeBufferPointer { SDL_PutAudioStreamData(stream, $0.baseAddress, Int32(out.count)) }
            } else {
                let samples = len / 2
                let src = UnsafeRawPointer(buf)
                var out = [Int16]()
                out.reserveCapacity(samples * 2)
                for i in 0..<samples {
                    let v = Float(src.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                    out.append(Int16(max(-32768, min(32767, v * gl))))
                    out.append(Int16(max(-32768, min(32767, v * gr))))
                }
                _ = out.withUnsafeBufferPointer { SDL_PutAudioStreamData(stream, $0.baseAddress, Int32(out.count * 2)) }
            }
        } else {
            _ = SDL_SetAudioStreamFormat(stream, &spec, nil)
            _ = SDL_PutAudioStreamData(stream, buf, Int32(len))
        }
    }

    func setVoicePan(_ voice: Int32, _ pan: Float) {
        for i in 0..<voiceIds.count where voiceIds[i] == voice {
            voicePans[i] = max(-1, min(1, pan))
            return
        }
    }

    func stopVoice(_ voice: Int32) {
        for i in 0..<voiceIds.count where voiceIds[i] == voice {
            SDL_UnbindAudioStream(voiceStreams[i])
            SDL_DestroyAudioStream(voiceStreams[i])
            voiceStreams.remove(at: i)
            voiceLoops.remove(at: i)
            voiceIds.remove(at: i)
            voicePans.remove(at: i)
            voiceGains.remove(at: i)
            return
        }
    }

    func setVoiceVolume(_ voice: Int32, _ volume: Float) {
        for i in 0..<voiceIds.count where voiceIds[i] == voice {
            voiceGains[i] = max(0, min(1, volume / 100))
            _ = SDL_SetAudioStreamGain(voiceStreams[i], voiceGains[i] * (voiceIds[i] == ttsVoice ? 1 : duck))
            return
        }
    }

    // speech ducking: every non-speech voice scales by the duck factor, the
    // way the web runtime ducks around utterances
    func setDuck(_ d: Float) {
        duck = d
        for i in 0..<voiceIds.count where voiceIds[i] != ttsVoice {
            _ = SDL_SetAudioStreamGain(voiceStreams[i], voiceGains[i] * duck)
        }
    }

    func stopAllVoices() {
        for stream in voiceStreams {
            SDL_UnbindAudioStream(stream)
            SDL_DestroyAudioStream(stream)
        }
        voiceStreams.removeAll()
        voiceLoops.removeAll()
        voiceIds.removeAll()
        voicePans.removeAll()
        voiceGains.removeAll()
        soundSpecs = [SDL_AudioSpec()]
        soundBufs = [nil]
        soundLens = [0]
        soundNames = [:]
        ttsCache = [:]
        ttsVoice = 0
        duck = 1
    }

    func reapVoices() {
        var i = 0
        while i < voiceStreams.count {
            let stream = voiceStreams[i]
            let queued = SDL_GetAudioStreamQueued(stream)
            let loopId = voiceLoops[i]
            if loopId > 0 {
                let li = Int(loopId)
                if queued < Int32(soundLens[li]) / 2 {
                    putData(stream, li, pan: voicePans[i])
                }
                i += 1
            } else if queued <= 0, SDL_GetAudioStreamAvailable(stream) <= 0 {
                SDL_UnbindAudioStream(stream)
                SDL_DestroyAudioStream(stream)
                voiceStreams.remove(at: i)
                voiceLoops.remove(at: i)
                voiceIds.remove(at: i)
                voicePans.remove(at: i)
                voiceGains.remove(at: i)
            } else {
                i += 1
            }
        }
    }

    // A store key ending in ".json" is a JSON blob, persisted as a real .json
    // file beside the .tsv (e.g. levels.json) instead of a multi-line row that
    // bloats the settings file. Generic: no per-game code, and the resulting
    // file is directly shareable / re-loadable. Plain settings stay in the .tsv.
    private func jsonBlobPath(_ key: String) -> String? {
        guard key.hasSuffix(".json") else { return nil }
        var stem = storePath
        if stem.hasSuffix(".store.tsv") { stem = String(stem.dropLast(10)) }
        else if stem.hasSuffix(".tsv") { stem = String(stem.dropLast(4)) }
        return stem + "." + key
    }

    func storeGet(_ key: String) -> String? {
        if let path = jsonBlobPath(key) {
            var size = 0
            if let data = path.withCString({ SDL_LoadFile($0, &size) }) {
                let bytes = UnsafeRawPointer(data).bindMemory(to: UInt8.self, capacity: size)
                var out = [UInt8]()
                out.reserveCapacity(size + 1)
                for i in 0..<size { out.append(bytes[i]) }
                SDL_free(data)
                out.append(0)
                return out.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            }
            // fall through: a value still living in the .tsv from before the split
        }
        for i in 0..<storeKeys.count where storeKeys[i] == key { return storeVals[i] }
        return nil
    }

    func storeSet(_ key: String, _ val: String) {
        print("DBGSET key=[\(key)] hasJsonSuffix=\(key.hasSuffix(".json")) blobPath=\(jsonBlobPath(key) ?? "nil")")
        if let path = jsonBlobPath(key) {
            let bytes = Array(val.utf8)
            _ = path.withCString { p in bytes.withUnsafeBufferPointer { SDL_SaveFile(p, $0.baseAddress, $0.count) } }
            // migrate: drop any legacy .tsv row so the settings file stays clean
            for i in 0..<storeKeys.count where storeKeys[i] == key {
                storeKeys.remove(at: i)
                storeVals.remove(at: i)
                saveStore()
                break
            }
            return
        }
        for i in 0..<storeKeys.count where storeKeys[i] == key {
            storeVals[i] = val
            saveStore()
            return
        }
        storeKeys.append(key)
        storeVals.append(val)
        saveStore()
    }

    func saveStore() {
        var out = [UInt8]()
        for i in 0..<storeKeys.count {
            out.append(contentsOf: Array(storeKeys[i].utf8))
            out.append(9)
            out.append(contentsOf: Array(storeVals[i].utf8))
            out.append(10)
        }
        _ = storePath.withCString { path in
            out.withUnsafeBufferPointer { SDL_SaveFile(path, $0.baseAddress, $0.count) }
        }
    }

    func loadStore() {
        var size = 0
        let data = storePath.withCString { SDL_LoadFile($0, &size) }
        guard let data else { return }
        let bytes = UnsafeRawPointer(data).bindMemory(to: UInt8.self, capacity: size)
        var field = [UInt8]()
        var key = ""
        for i in 0..<size {
            let ch = bytes[i]
            if ch == 9 {
                field.append(0)
                key = field.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                field = []
            } else if ch == 10 {
                field.append(0)
                let val = field.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                field = []
                storeKeys.append(key)
                storeVals.append(val)
            } else {
                field.append(ch)
            }
        }
        SDL_free(data)
    }
}

func sfKey(_ scancode: UInt32) -> Int32 {
    switch scancode {
    case UInt32(SDL_SCANCODE_LEFT.rawValue): return 71
    case UInt32(SDL_SCANCODE_RIGHT.rawValue): return 72
    case UInt32(SDL_SCANCODE_UP.rawValue): return 73
    case UInt32(SDL_SCANCODE_DOWN.rawValue): return 74
    case UInt32(SDL_SCANCODE_SPACE.rawValue): return 57
    case UInt32(SDL_SCANCODE_ESCAPE.rawValue): return 36
    case UInt32(SDL_SCANCODE_RETURN.rawValue): return 58
    case UInt32(SDL_SCANCODE_BACKSPACE.rawValue): return 59
    case UInt32(SDL_SCANCODE_TAB.rawValue): return 60
    case UInt32(SDL_SCANCODE_A.rawValue)...UInt32(SDL_SCANCODE_Z.rawValue):
        return Int32(scancode - UInt32(SDL_SCANCODE_A.rawValue))
    case UInt32(SDL_SCANCODE_1.rawValue)...UInt32(SDL_SCANCODE_9.rawValue):
        return Int32(27 + scancode - UInt32(SDL_SCANCODE_1.rawValue))
    case UInt32(SDL_SCANCODE_0.rawValue): return 26
    default: return -1
    }
}

func toLogical(_ window: OpaquePointer?, _ x: Float, _ y: Float) -> (Int32, Int32) {
    let k = Kit.shared
    var w: Int32 = 0
    var h: Int32 = 0
    _ = SDL_GetWindowSize(window, &w, &h)
    let sc = min(Float(w) / k.logicalW, Float(h) / k.logicalH)
    let ox = (Float(w) - k.logicalW * sc) / 2
    let oy = (Float(h) - k.logicalH * sc) / 2
    return (Int32((x - ox) / sc), Int32((y - oy) / sc))
}

// MARK: - host lifecycle (called by main)

func kitHostInit(appName: String = "KitGame") {
    guard SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO) else { fatalError("SDL_Init failed") }
    _ = SDL_Init(SDL_INIT_GAMEPAD)
    let k = Kit.shared
    k.window = appName.withCString {
        SDL_CreateWindow($0, 1920, 1080, windowResizable | windowHighPixelDensity)
    }
    guard k.window != nil else { fatalError("window failed") }
    _ = SDL_SetWindowAspectRatio(k.window, 1920.0 / 1080.0, 1920.0 / 1080.0)
    k.renderer = SDL_CreateRenderer(k.window, nil)
    guard k.renderer != nil else { fatalError("renderer failed") }
    _ = SDL_SetRenderVSync(k.renderer, 1)
    _ = SDL_SetRenderDrawBlendMode(k.renderer, SDL_BLENDMODE_BLEND)
    if let pref = ("SuperBox64".withCString { org in appName.withCString { SDL_GetPrefPath(org, $0) } }) {
        k.storePath = String(cString: pref) + "store.tsv"
        SDL_free(pref)
    }
    k.loadStore()
    k.ttsPrime()
    k.ttsWarmup()
}

// Pump SDL into the ABI event queue; false = quit requested.
// A console host (WasmCart) reserves CTRL+ESC for eject; plain ESC still
// reaches the game, the chord lands in kitEscapePressed instead.
nonisolated(unsafe) var kitEscapeReserved = false
nonisolated(unsafe) var kitEscapePressed = false
nonisolated(unsafe) var kitDroppedFile: String? = nil

func kitHostPump() -> Bool {
    let k = Kit.shared
    var alive = true
    var e = SDL_Event()
    while SDL_PollEvent(&e) {
        if e.type == SDL_EVENT_QUIT.rawValue {
            alive = false
        } else if e.type == SDL_EVENT_DROP_FILE.rawValue {
            if let dropped = e.drop.data {
                kitDroppedFile = String(cString: dropped)
            }
        } else if e.type == SDL_EVENT_GAMEPAD_ADDED.rawValue {
            let which = e.gdevice.which
            if let slot = (0..<4).first(where: { k.gamepads[$0] == nil }) {
                k.gamepads[slot] = SDL_OpenGamepad(which)
                k.gamepadInstanceIds[slot] = which
            }
        } else if e.type == SDL_EVENT_GAMEPAD_REMOVED.rawValue {
            let which = e.gdevice.which
            for i in 0..<4 where k.gamepadInstanceIds[i] == which {
                SDL_CloseGamepad(k.gamepads[i])
                k.gamepads[i] = nil
                k.gamepadInstanceIds[i] = 0
            }
        } else if e.type == SDL_EVENT_GAMEPAD_BUTTON_DOWN.rawValue || e.type == SDL_EVENT_GAMEPAD_BUTTON_UP.rawValue {
            if k.mapToKeys {
                let sfk = k.sdlButtonToSfKey(e.gbutton.button)
                if sfk >= 0 {
                    let isDown = e.type == SDL_EVENT_GAMEPAD_BUTTON_DOWN.rawValue
                    let t: Int32 = isDown ? 5 : 6
                    k.pushEvent((t, sfk, 0, 0, 0))
                    if sfk < 128 { k.sfKeyHeld[Int(sfk)] = isDown }
                }
            }
        } else if e.type == SDL_EVENT_KEY_DOWN.rawValue, e.key.scancode == SDL_SCANCODE_F, !e.key.`repeat` {
            k.fullscreen = !k.fullscreen
            _ = SDL_SetWindowFullscreen(k.window, k.fullscreen)
        } else if kitEscapeReserved, e.type == SDL_EVENT_KEY_DOWN.rawValue,
                  e.key.scancode == SDL_SCANCODE_ESCAPE, !e.key.`repeat`,
                  (UInt32(e.key.mod) & SDL_KMOD_CTRL) != 0 {
            kitEscapePressed = true
        } else if e.type == SDL_EVENT_KEY_DOWN.rawValue || e.type == SDL_EVENT_KEY_UP.rawValue {
            let sf = sfKey(e.key.scancode.rawValue)
            let isDown = e.type == SDL_EVENT_KEY_DOWN.rawValue
            if sf >= 0, !e.key.`repeat` {
                let t: Int32 = isDown ? 5 : 6
                let shift: Int32 = (UInt32(e.key.mod) & SDL_KMOD_SHIFT) != 0 ? 1 : 0
                k.pushEvent((t, sf, shift, 0, 0))
            }
            if sf >= 0, sf < 128 { k.sfKeyHeld[Int(sf)] = isDown }
        } else if e.type == SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue || e.type == SDL_EVENT_MOUSE_BUTTON_UP.rawValue {
            k.noteMouseActivity()
            let t: Int32 = e.type == SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue ? 9 : 10
            let (lx, ly) = toLogical(k.window, e.button.x, e.button.y)
            k.pushEvent((t, 0, lx, ly, Int32(e.button.clicks)))
            let isDown = e.type == SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue
            let btn = Int(e.button.button) - 1
            if btn >= 0, btn < 3 { k.mouseHeld[btn] = isDown }
        } else if e.type == SDL_EVENT_MOUSE_MOTION.rawValue {
            k.noteMouseActivity()
            let (lx, ly) = toLogical(k.window, e.motion.x, e.motion.y)
            k.pushEvent((11, lx, ly, 0, 0))
            k.mouseLogX = lx
            k.mouseLogY = ly
        }
    }
    k.tickCursorIdle()
    return alive
}

func kitHostPresent() {
    let k = Kit.shared
    k.reapVoices()
    k.ttsReap()
    if let screen = k.screenTex {
        let _b0 = SDL_GetTicksNS()
        _ = SDL_SetRenderTarget(k.renderer, nil)
        _ = SDL_SetTextureBlendMode(screen, SDL_BLENDMODE_NONE)
        _ = SDL_RenderTexture(k.renderer, screen, nil, nil)
        k.profBlitNs += SDL_GetTicksNS() - _b0
        let _v0 = SDL_GetTicksNS()
        _ = SDL_RenderPresent(k.renderer)
        k.profVsyncNs += SDL_GetTicksNS() - _v0
        _ = SDL_SetRenderTarget(k.renderer, screen)
    } else {
        let _v0 = SDL_GetTicksNS()
        _ = SDL_RenderPresent(k.renderer)
        k.profVsyncNs += SDL_GetTicksNS() - _v0
    }
    for tex in k.deadTextures { SDL_DestroyTexture(tex) }
    k.deadTextures.removeAll(keepingCapacity: true)
    k.flushTargetPool()
}

// MARK: - the KitABI env surface, linked directly (no wasm in between)

@_cdecl("js_log")
func js_log(_ p: UnsafePointer<CChar>?, _ len: Int32) {
    print(Kit.shared.cString(p, len))
}

@_cdecl("gfx_clear")
func gfx_clear(_ rgba: UInt32) {
    let k = Kit.shared
    k.partTint = nil   // drop any stranded particle tint so it can't bleed into this frame
    if k.targets.contains(where: { $0 != nil }) {
        let c = k.fcolor(rgba)
        _ = SDL_SetRenderDrawColorFloat(k.renderer, c.r, c.g, c.b, 1)
        _ = SDL_RenderClear(k.renderer)
        return
    }
    k.ensureScreenTarget()
    let pw = k.screenW
    let ph = k.screenH
    let sc = min(Float(pw) / k.logicalW, Float(ph) / k.logicalH)
    k.baseScale = sc
    k.mat = Mat(a: sc, b: 0, c: 0, d: sc,
                e: (Float(pw) - k.logicalW * sc) / 2,
                f: (Float(ph) - k.logicalH * sc) / 2)
    k.stack = []
    k.alpha = 1
    k.additive = false
    k.composite = 0
    k.shadowBlur = 0
    k.shadowDx = 0
    k.shadowDy = 0
    k.shadowRgba = 0
    let c = k.fcolor(rgba)
    _ = SDL_SetRenderDrawColorFloat(k.renderer, c.r, c.g, c.b, 1)
    _ = SDL_RenderClear(k.renderer)
}

@_cdecl("gfx_save")
func gfx_save() { Kit.shared.stack.append(Kit.shared.mat) }

@_cdecl("gfx_restore")
func gfx_restore() { if let m = Kit.shared.stack.popLast() { Kit.shared.mat = m } }

@_cdecl("gfx_translate")
func gfx_translate(_ x: Float, _ y: Float) {
    Kit.shared.mat.mul(Mat(a: 1, b: 0, c: 0, d: 1, e: x, f: y))
}

@_cdecl("gfx_rotate")
func gfx_rotate(_ degrees: Float) {
    let r = degrees * Float.pi / 180
    Kit.shared.mat.mul(Mat(a: SDL_cosf(r), b: SDL_sinf(r), c: -SDL_sinf(r), d: SDL_cosf(r), e: 0, f: 0))
}

@_cdecl("gfx_scale")
func gfx_scale(_ sx: Float, _ sy: Float) {
    Kit.shared.mat.mul(Mat(a: sx, b: 0, c: 0, d: sy, e: 0, f: 0))
}

@_cdecl("gfx_set_alpha")
func gfx_set_alpha(_ a: Float) { Kit.shared.alpha = a }

@_cdecl("gfx_set_blend")
func gfx_set_blend(_ mode: Int32) { Kit.shared.additive = mode == 1 }

@_cdecl("gfx_stroke_poly")
func gfx_stroke_poly(_ xy: UnsafePointer<Float>?, _ n: Int32, _ closed: Int32, _ t: Float, _ rgba: UInt32) {
    guard let xy, n >= 2 else { return }
    let k = Kit.shared
    var pts = [SDL_FPoint]()
    pts.reserveCapacity(Int(n))
    for i in 0..<Int(n) { pts.append(k.mat.apply(xy[i * 2], xy[i * 2 + 1])) }
    k.strokePoly(pts, closed: closed != 0, thickness: t, rgba: rgba)
}

@_cdecl("gfx_fill_poly")
func gfx_fill_poly(_ xy: UnsafePointer<Float>?, _ n: Int32, _ rgba: UInt32) {
    guard let xy, n >= 3 else { return }
    let k = Kit.shared
    var pts = [SDL_FPoint]()
    pts.reserveCapacity(Int(n))
    for i in 0..<Int(n) { pts.append(k.mat.apply(xy[i * 2], xy[i * 2 + 1])) }
    k.fillPoly(pts, rgba: rgba)
}

@_cdecl("gfx_fill_circle")
func gfx_fill_circle(_ cx: Float, _ cy: Float, _ r: Float, _ rgba: UInt32) {
    let k = Kit.shared
    k.fillPoly(k.circlePts(cx, cy, r), rgba: rgba)
}

@_cdecl("gfx_stroke_circle")
func gfx_stroke_circle(_ cx: Float, _ cy: Float, _ r: Float, _ t: Float, _ rgba: UInt32) {
    let k = Kit.shared
    k.strokePoly(k.circlePts(cx, cy, r), closed: true, thickness: t, rgba: rgba)
}

@_cdecl("gfx_fill_rect")
func gfx_fill_rect(_ x: Float, _ y: Float, _ w: Float, _ h: Float, _ rgba: UInt32) {
    let k = Kit.shared
    k.fillPoly([k.mat.apply(x, y), k.mat.apply(x + w, y),
                k.mat.apply(x + w, y + h), k.mat.apply(x, y + h)], rgba: rgba)
}

@_cdecl("gfx_stroke_rect")
func gfx_stroke_rect(_ x: Float, _ y: Float, _ w: Float, _ h: Float, _ t: Float, _ rgba: UInt32) {
    let k = Kit.shared
    k.strokePoly([k.mat.apply(x, y), k.mat.apply(x + w, y),
                  k.mat.apply(x + w, y + h), k.mat.apply(x, y + h)],
                 closed: true, thickness: t, rgba: rgba)
}

@_cdecl("evt_poll")
func evt_poll(_ type: UnsafeMutablePointer<Int32>?, _ a: UnsafeMutablePointer<Int32>?,
              _ b: UnsafeMutablePointer<Int32>?, _ c: UnsafeMutablePointer<Int32>?,
              _ d: UnsafeMutablePointer<Int32>?) -> Int32 {
    let k = Kit.shared
    guard let e = k.popEvent() else { return 0 }
    type?.pointee = e.0
    a?.pointee = e.1
    b?.pointee = e.2
    c?.pointee = e.3
    d?.pointee = e.4
    return 1
}

@_cdecl("snd_by_name")
func snd_by_name(_ name: UnsafePointer<CChar>?, _ len: Int32) -> Int32 {
    Kit.shared.loadSound(Kit.shared.cString(name, len))
}

@_cdecl("snd_play")
func snd_play(_ buffer: Int32, _ volume: Float, _ loop: Int32) -> Int32 {
    Kit.shared.play(buffer, volume: volume, loop: loop != 0)
}

@_cdecl("snd_stop")
func snd_stop(_ voice: Int32) {
    Kit.shared.stopVoice(voice)
}

@_cdecl("snd_set_volume")
func snd_set_volume(_ voice: Int32, _ volume: Float) {
    Kit.shared.setVoiceVolume(voice, volume)
}

@_cdecl("snd_set_pan")
func snd_set_pan(_ voice: Int32, _ pan: Float) {
    Kit.shared.setVoicePan(voice, pan)
}

@_cdecl("store_get")
func store_get(_ key: UnsafePointer<CChar>?, _ klen: Int32,
               _ buf: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
    let k = Kit.shared
    guard let v = k.storeGet(k.cString(key, klen)) else { return -1 }
    let bytes = Array(v.utf8)
    let n = min(bytes.count, Int(cap))
    if let buf {
        for i in 0..<n { buf[i] = CChar(bitPattern: bytes[i]) }
    }
    // Return the FULL length, not the copied count: games probe with a small
    // buffer to learn the size, then re-read with a buffer that fits. Returning
    // the truncated count made them read a 1-byte value ("26" -> "2", and the
    // leaderboard JSON -> "[", which fails to parse). Matches the web runtime.
    return Int32(bytes.count)
}

@_cdecl("store_set")
func store_set(_ key: UnsafePointer<CChar>?, _ klen: Int32,
               _ val: UnsafePointer<CChar>?, _ vlen: Int32) {
    let k = Kit.shared
    k.storeSet(k.cString(key, klen), k.cString(val, vlen))
}

@_cdecl("gp_connected")
func gp_connected(_ pad: Int32) -> Int32 {
    guard pad >= 0, pad < 4 else { return 0 }
    return Kit.shared.gamepads[Int(pad)] != nil ? 1 : 0
}

@_cdecl("gp_button")
func gp_button(_ pad: Int32, _ button: Int32) -> Int32 {
    return Kit.shared.gpButtonValue(Int(pad), button) > 0.5 ? 1 : 0
}

@_cdecl("gp_button_value")
func gp_button_value(_ pad: Int32, _ button: Int32) -> Float {
    return Kit.shared.gpButtonValue(Int(pad), button)
}

@_cdecl("gp_axis")
func gp_axis(_ pad: Int32, _ axis: Int32) -> Float {
    return Kit.shared.gpAxisValue(Int(pad), axis)
}

@_cdecl("gp_map_to_keys")
func gp_map_to_keys(_ enable: Int32) {
    Kit.shared.mapToKeys = enable != 0
}

@_cdecl("key_pressed")
func key_pressed(_ sfKey: Int32) -> Int32 {
    guard sfKey >= 0, sfKey < 128 else { return 0 }
    return Kit.shared.sfKeyHeld[Int(sfKey)] ? 1 : 0
}

@_cdecl("mouse_x")
func mouse_x() -> Int32 { Kit.shared.mouseLogX }

@_cdecl("mouse_y")
func mouse_y() -> Int32 { Kit.shared.mouseLogY }

@_cdecl("mouse_button")
func mouse_button(_ b: Int32) -> Int32 {
    guard b >= 0, b < 3 else { return 0 }
    return Kit.shared.mouseHeld[Int(b)] ? 1 : 0
}

// MARK: - images, offscreen targets, text (the texture half of the ABI)

@_cdecl("img_by_name")
func img_by_name(_ name: UnsafePointer<CChar>?, _ len: Int32) -> Int32 {
    let k = Kit.shared
    return k.imageByName(k.cString(name, len))
}

@_cdecl("img_width")
func img_width(_ img: Int32) -> Int32 {
    let k = Kit.shared
    guard img > 0, Int(img) < k.images.count, let rec = k.images[Int(img)] else { return 0 }
    return rec.w
}

@_cdecl("img_height")
func img_height(_ img: Int32) -> Int32 {
    let k = Kit.shared
    guard img > 0, Int(img) < k.images.count, let rec = k.images[Int(img)] else { return 0 }
    return rec.h
}

@_cdecl("img_polygon_from_alpha")
func img_polygon_from_alpha(_ img: Int32, _ alphaThreshold: Float,
                             _ outXY: UnsafeMutablePointer<Float>?, _ cap: Int32) -> Int32 {
    let k = Kit.shared
    guard img > 0, Int(img) < k.images.count,
          let rec = k.images[Int(img)], let tex = rec.tex,
          let outXY, cap >= 4 else { return 0 }
    let iw = rec.w, ih = rec.h
    guard iw > 0, ih > 0 else { return 0 }

    guard let tmp = SDL_CreateTexture(k.renderer, k.targetFormat,
                                      SDL_TEXTUREACCESS_TARGET, iw, ih) else { return 0 }
    _ = SDL_SetTextureBlendMode(tmp, SDL_BLENDMODE_NONE)
    let prevTarget = SDL_GetRenderTarget(k.renderer)
    _ = SDL_SetRenderTarget(k.renderer, tmp)
    _ = SDL_SetRenderDrawColorFloat(k.renderer, 0, 0, 0, 0)
    _ = SDL_RenderClear(k.renderer)
    _ = SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_NONE)
    _ = SDL_RenderTexture(k.renderer, tex, nil, nil)
    _ = SDL_SetRenderTarget(k.renderer, prevTarget)
    _ = SDL_SetTextureBlendMode(tex, k.currentBlend())

    var readRect = SDL_Rect(x: 0, y: 0, w: iw, h: ih)
    _ = SDL_SetRenderTarget(k.renderer, tmp)
    guard let rawSurf = SDL_RenderReadPixels(k.renderer, &readRect) else {
        _ = SDL_SetRenderTarget(k.renderer, prevTarget)
        SDL_DestroyTexture(tmp)
        return 0
    }
    _ = SDL_SetRenderTarget(k.renderer, prevTarget)
    SDL_DestroyTexture(tmp)

    let surf: UnsafeMutablePointer<SDL_Surface>
    if rawSurf.pointee.format != SDL_PIXELFORMAT_ABGR8888,
       let conv = SDL_ConvertSurface(rawSurf, SDL_PIXELFORMAT_ABGR8888) {
        SDL_DestroySurface(rawSurf)
        surf = conv
    } else {
        surf = rawSurf
    }
    guard let pixBase = surf.pointee.pixels else { SDL_DestroySurface(surf); return 0 }
    let px = pixBase.assumingMemoryBound(to: UInt8.self)
    let pitch = surf.pointee.pitch
    let thresh = UInt8(max(0, min(255, Int(alphaThreshold * 255))))

    struct RD { var xl: Int32; var xr: Int32 }
    var rows = [RD](repeating: RD(xl: iw, xr: -1), count: Int(ih))
    for y in 0..<Int(ih) {
        let rowBase = y * Int(pitch)
        for x in 0..<Int(iw) {
            if px[rowBase + x * 4 + 3] > thresh {
                if Int32(x) < rows[y].xl { rows[y].xl = Int32(x) }
                if Int32(x) > rows[y].xr { rows[y].xr = Int32(x) }
            }
        }
    }
    SDL_DestroySurface(surf)

    var poly = [(Float, Float)]()
    poly.reserveCapacity(Int(ih) * 2 + 4)
    for y in 0..<Int(ih) where rows[y].xr >= 0 {
        poly.append((Float(rows[y].xl), Float(y)))
    }
    var y2 = Int(ih) - 1
    while y2 >= 0 {
        if rows[y2].xr >= 0 { poly.append((Float(rows[y2].xr), Float(y2))) }
        y2 -= 1
    }
    guard poly.count >= 3 else { return 0 }

    var keep = [Bool](repeating: true, count: poly.count)
    var stack = [(Int, Int)]()
    stack.reserveCapacity(64)
    stack.append((0, poly.count - 1))
    while !stack.isEmpty {
        let (lo, hi) = stack.removeLast()
        guard hi - lo >= 2 else { continue }
        let (ax, ay) = poly[lo]
        let (bx, by) = poly[hi]
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        var maxD: Float = 0
        var maxI = lo + 1
        for i in (lo + 1)..<hi {
            let d: Float
            if len2 < 0.0001 {
                let ex = poly[i].0 - ax, ey = poly[i].1 - ay
                d = ex * ex + ey * ey
            } else {
                let t = max(0, min(1, ((poly[i].0 - ax) * dx + (poly[i].1 - ay) * dy) / len2))
                let qx = ax + t * dx, qy = ay + t * dy
                let ex = poly[i].0 - qx, ey = poly[i].1 - qy
                d = ex * ex + ey * ey
            }
            if d > maxD { maxD = d; maxI = i }
        }
        if maxD > 4 {
            stack.append((lo, maxI))
            stack.append((maxI, hi))
        } else {
            for i in (lo + 1)..<hi { keep[i] = false }
        }
    }

    var written = 0
    let maxPts = Int(cap) / 2
    for i in 0..<poly.count {
        if keep[i], written < maxPts {
            outXY[written * 2] = poly[i].0
            outXY[written * 2 + 1] = poly[i].1
            written += 1
        }
    }
    return Int32(written * 2)
}

@_cdecl("gfx_set_tint")
func gfx_set_tint(_ r: Float, _ g: Float, _ b: Float, _ bf: Float) {
    // SKEmitterNode particle colorBlendFactor: stored one-shot, consumed by the next
    // gfx_draw_image. Without it the import is unlinked and the emitter draw traps
    // ("failed to call unlinked import function (env, gfx_set_tint)").
    Kit.shared.partTint = bf > 0 ? (r: r, g: g, b: b, bf: min(1, bf)) : nil
}

@_cdecl("gfx_draw_image")
func gfx_draw_image(_ img: Int32, _ sx: Float, _ sy: Float, _ sw: Float, _ sh: Float,
                    _ dx: Float, _ dy: Float, _ dw: Float, _ dh: Float, _ rgba: UInt32) {
    let k = Kit.shared
    let _pt0 = SDL_GetTicksNS(); defer { k.profImgNs += SDL_GetTicksNS() - _pt0 }
    // consume the one-shot particle tint FIRST, before the missing-texture early return,
    // so an unloaded-texture draw can't strand it onto the next frame's first draw.
    let pt = k.partTint; k.partTint = nil
    guard img > 0, Int(img) < k.images.count, let rec0 = k.images[Int(img)], rec0.tex != nil else { return }
    // Vector sprites re-rasterize at their live device footprint so scaling never blurs.
    let rec: Kit.ImgRec
    if rec0.svgBytes != nil {
        let m = k.mat
        rec = k.svgTexForFootprint(img, dw * SDL_sqrtf(m.a * m.a + m.b * m.b),
                                        dh * SDL_sqrtf(m.c * m.c + m.d * m.d)) ?? rec0
    } else {
        rec = rec0
    }
    let a = Float(rgba & 0xFF) / 255 * k.alpha
    var color = SDL_FColor(r: 1, g: 1, b: 1, a: a)
    if let pt = pt {   // mix white -> tint by blend factor (SpriteKit colorBlendFactor)
        color.r = 1 - pt.bf + pt.r * pt.bf
        color.g = 1 - pt.bf + pt.g * pt.bf
        color.b = 1 - pt.bf + pt.b * pt.bf
    }
    var u0: Float = 0
    var v0: Float = 0
    var u1: Float = 1
    var v1: Float = 1
    if sw >= 0, sh >= 0, rec.w > 0, rec.h > 0 {
        u0 = sx / Float(rec.w)
        v0 = sy / Float(rec.h)
        u1 = (sx + sw) / Float(rec.w)
        v1 = (sy + sh) / Float(rec.h)
    }
    k.drawTexturedQuad(rec.tex, dx, dy, dw, dh, u0, v0, u1, v1, color)
}

@_cdecl("gfx_free_image")
func gfx_free_image(_ img: Int32) {
    let k = Kit.shared
    guard img > 0, Int(img) < k.images.count, let rec = k.images[Int(img)] else { return }
    k.retireTexture(rec.tex)
    k.images[Int(img)] = nil
    k.freeImageSlots.append(Int(img))
    k.cpuPixels.removeValue(forKey: img)
}

@_cdecl("gfx_upload_pixels")
func gfx_upload_pixels(_ img: Int32, _ w: Int32, _ h: Int32, _ rgba: UnsafePointer<UInt8>?, _ len: Int32) -> Int32 {
    let k = Kit.shared
    guard let rgba, w > 0, h > 0, len >= w * h * 4 else { return img }
    let tex = SDL_CreateTexture(k.renderer, SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STATIC, w, h)
    var rect = SDL_Rect(x: 0, y: 0, w: w, h: h)
    _ = SDL_UpdateTexture(tex, &rect, rgba, w * 4)
    _ = SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND)
    if img > 0, Int(img) < k.images.count {
        k.retireTexture(k.images[Int(img)]?.tex)
        k.images[Int(img)] = Kit.ImgRec(tex: tex, w: w, h: h)
        k.cpuPixels.removeValue(forKey: img)
        return img
    }
    return k.registerImage(Kit.ImgRec(tex: tex, w: w, h: h))
}

@_cdecl("gfx_offscreen_begin")
func gfx_offscreen_begin(_ w: Int32, _ h: Int32) -> Int32 {
    let k = Kit.shared
    let dpr = max(1, k.baseScale)
    let tw = Int32(Float(w) * dpr + 0.5)
    let th = Int32(Float(h) * dpr + 0.5)
    guard tw > 0, th > 0,
          let tex = SDL_CreateTexture(k.renderer, k.targetFormat, SDL_TEXTUREACCESS_TARGET, tw, th) else { return 0 }
    _ = SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND)
    let prev = SDL_GetRenderTarget(k.renderer)
    _ = SDL_SetRenderTarget(k.renderer, tex)
    _ = SDL_SetRenderDrawColorFloat(k.renderer, 0, 0, 0, 0)
    _ = SDL_RenderClear(k.renderer)
    k.targets.append(Kit.OffTarget(tex: tex, w: tw, h: th,
                                   savedMat: k.mat, savedStack: k.stack, savedAlpha: k.alpha,
                                   prevTarget: prev))
    k.mat = Mat(a: dpr, b: 0, c: 0, d: dpr, e: 0, f: 0)
    k.stack = []
    k.alpha = 1
    return Int32(k.targets.count)
}

@_cdecl("gfx_offscreen_end_to_image")
func gfx_offscreen_end_to_image(_ handle: Int32) -> Int32 {
    let k = Kit.shared
    guard handle >= 1, Int(handle) <= k.targets.count, let t = k.targets[Int(handle) - 1] else { return 0 }
    _ = SDL_SetRenderTarget(k.renderer, t.prevTarget)
    k.mat = t.savedMat
    k.stack = t.savedStack
    k.alpha = t.savedAlpha
    k.targets[Int(handle) - 1] = nil
    while let last = k.targets.last, last == nil { k.targets.removeLast() }
    var tex = t.tex
    if t.blur > 0, let blurred = k.blurTexture(t.tex, t.w, t.h, t.blur) {
        k.retireTexture(t.tex)
        tex = blurred
    }
    if t.brightness != 1, let texRef = tex {
        _ = SDL_SetTextureColorModFloat(texRef, t.brightness, t.brightness, t.brightness)
    }
    return k.registerImage(Kit.ImgRec(tex: tex, w: t.w, h: t.h))
}

@_cdecl("gfx_offscreen_end_discard")
func gfx_offscreen_end_discard(_ handle: Int32) {
    let k = Kit.shared
    guard handle >= 1, Int(handle) <= k.targets.count, let t = k.targets[Int(handle) - 1] else { return }
    _ = SDL_SetRenderTarget(k.renderer, t.prevTarget)
    k.mat = t.savedMat
    k.stack = t.savedStack
    k.alpha = t.savedAlpha
    k.retireTexture(t.tex)
    k.targets[Int(handle) - 1] = nil
    while let last = k.targets.last, last == nil { k.targets.removeLast() }
}

@_cdecl("font_by_name")
func font_by_name(_ name: UnsafePointer<CChar>?, _ len: Int32) -> Int32 {
    let k = Kit.shared
    return k.fontByName(k.cString(name, len))
}

@_cdecl("txt_width")
func txt_width(_ font: Int32, _ utf8: UnsafePointer<CChar>?, _ len: Int32, _ sizePx: Int32, _ spacing: Float) -> Int32 {
    let k = Kit.shared
    guard let info = k.resolveFont(font) else { return 0 }
    let cps = k.decodeUTF8(utf8, len)
    if cps.isEmpty { return 0 }
    let scale = kit_font_scale_for_px(info, Float(sizePx))
    var w: Float = 0
    for i in 0..<cps.count {
        let cp = cps[i]
        if cp == 0xFE0F || cp == 0x200D { continue }
        if kit_font_glyph_index(info, cp) == 0, let eg = k.emojiGlyph(cp) {
            w += Float(eg.advance) * Float(sizePx) / Float(eg.ppem)
        } else {
            var advance: Int32 = 0
            var lsb: Int32 = 0
            kit_font_hmetrics(info, cp, &advance, &lsb)
            w += Float(advance) * scale
            if i + 1 < cps.count {
                w += Float(kit_font_kern(info, cp, cps[i + 1])) * scale
            }
        }
    }
    w += spacing * Float(cps.count - 1)
    return Int32(SDL_ceilf(w))
}

@_cdecl("gfx_set_text_baseline")
func gfx_set_text_baseline(_ mode: Int32) {
    Kit.shared.textBaseline = mode
}

@_cdecl("gfx_draw_text")
func gfx_draw_text(_ font: Int32, _ utf8: UnsafePointer<CChar>?, _ len: Int32,
                   _ x: Float, _ y: Float, _ sizePx: Int32, _ rgba: UInt32, _ spacing: Float) {
    let k = Kit.shared
    let _pt0 = SDL_GetTicksNS(); defer { k.profTxtNs += SDL_GetTicksNS() - _pt0 }
    guard let info = k.resolveFont(font) else { return }
    let cps = k.decodeUTF8(utf8, len)
    if cps.isEmpty { return }
    let scale = kit_font_scale_for_px(info, Float(sizePx))
    var ascent: Int32 = 0
    var descent: Int32 = 0
    var lineGap: Int32 = 0
    kit_font_vmetrics(info, &ascent, &descent, &lineGap)
    let ascentPx = Float(ascent) * scale
    let descentPx = Float(descent) * scale
    let dpr = max(1, k.baseScale)
    let rasterPx = Int32(Float(sizePx) * dpr + 0.5)
    let fid = font > 0 ? font : k.defaultFont
    var baselineY = y
    switch k.textBaseline {
    case 0: baselineY = y
    case 1:
        // visual centring like the web: the string's measured ink bounds,
        // not the em box, land centred on y (emoji read as the emoji's box)
        var inkAscent: Float = 0
        var inkDescent: Float = 0
        var any = false
        for cp in cps where cp != 0xFE0F && cp != 0x200D {
            if kit_font_glyph_index(info, cp) == 0, let eg = k.emojiGlyph(cp), eg.tex != nil {
                let escale = Float(sizePx) / Float(eg.ppem)
                inkAscent = max(inkAscent, Float(eg.bearingY) * escale)
                inkDescent = max(inkDescent, Float(eg.h - eg.bearingY) * escale)
                any = true
            } else if let g = k.glyph(fid, info, cp, rasterPx), g.h > 0 {
                inkAscent = max(inkAscent, Float(-g.yoff) / dpr)
                inkDescent = max(inkDescent, Float(g.yoff + g.h) / dpr)
                any = true
            }
        }
        if !any {
            inkAscent = Float(sizePx) * 0.8
            inkDescent = Float(sizePx) * 0.2
        }
        baselineY = y + (inkAscent - inkDescent) / 2
    case 3: baselineY = y + descentPx
    default: baselineY = y + ascentPx
    }
    let a = Float(rgba & 0xFF) / 255 * k.alpha
    let (cr, cg, cb) = k.gameColor(rgba)
    let color = SDL_FColor(r: cr, g: cg, b: cb, a: a)
    var pen = x
    for i in 0..<cps.count {
        let cp = cps[i]
        if cp == 0xFE0F || cp == 0x200D { continue }
        if kit_font_glyph_index(info, cp) == 0, let eg = k.emojiGlyph(cp), let tex = eg.tex {
            let escale = Float(sizePx) / Float(eg.ppem)
            k.drawTexturedQuad(tex,
                               pen + Float(eg.bearingX) * escale, baselineY - Float(eg.bearingY) * escale,
                               Float(eg.w) * escale, Float(eg.h) * escale,
                               0, 0, 1, 1, SDL_FColor(r: 1, g: 1, b: 1, a: a))
            pen += Float(eg.advance) * escale + spacing
            continue
        }
        let fid = font > 0 ? font : k.defaultFont
        if let g = k.glyph(fid, info, cp, rasterPx), let tex = g.tex {
            k.drawTexturedQuad(tex,
                               pen + Float(g.xoff) / dpr, baselineY + Float(g.yoff) / dpr,
                               Float(g.w) / dpr, Float(g.h) / dpr,
                               0, 0, 1, 1, color)
        }
        var advance: Int32 = 0
        var lsb: Int32 = 0
        kit_font_hmetrics(info, cp, &advance, &lsb)
        pen += Float(advance) * scale + spacing
        if i + 1 < cps.count {
            pen += Float(kit_font_kern(info, cp, cps[i + 1])) * scale
        }
    }
}

// MARK: - shadows, filters, composite (approximations where SDL has no blur)

@_cdecl("gfx_draw_shadow_image")
func gfx_draw_shadow_image(_ img: Int32, _ x: Float, _ y: Float, _ w: Float, _ h: Float, _ blur: Float, _ rgba: UInt32) {
    let k = Kit.shared
    guard img > 0, Int(img) < k.images.count, let rec = k.images[Int(img)], let tex = rec.tex else { return }
    let a = Float(rgba & 0xFF) / 255 * k.alpha

    // a real soft shadow without a blur shader: downsample the silhouette
    // into a tiny render target, then bilinear-upscale it back out; the
    // texel-wide alpha edge stretches into a smooth falloff
    let texel = max(4, blur)
    let margin: Float = 2
    let tw = Int32(SDL_ceilf(w / texel) + margin * 2)
    let th = Int32(SDL_ceilf(h / texel) + margin * 2)
    guard tw > 0, th > 0, let small = k.acquireTarget(tw, th) else { return }
    _ = SDL_SetTextureBlendMode(small, SDL_BLENDMODE_BLEND)

    let prev = SDL_GetRenderTarget(k.renderer)
    _ = SDL_SetRenderTarget(k.renderer, small)
    _ = SDL_SetRenderDrawColorFloat(k.renderer, 0, 0, 0, 0)
    _ = SDL_RenderClear(k.renderer)
    let savedMat = k.mat
    k.mat = Mat()
    let (sr, sg, sb) = k.gameColor(rgba)
    _ = SDL_SetTextureColorModFloat(tex, sr, sg, sb)
    k.drawTexturedQuad(tex, margin, margin, Float(tw) - margin * 2, Float(th) - margin * 2,
                       0, 0, 1, 1, SDL_FColor(r: 1, g: 1, b: 1, a: 1))
    _ = SDL_SetTextureColorModFloat(tex, 1, 1, 1)
    k.mat = savedMat
    _ = SDL_SetRenderTarget(k.renderer, prev)

    k.drawTexturedQuad(small, x - margin * texel, y - margin * texel,
                       w + 2 * margin * texel, h + 2 * margin * texel,
                       0, 0, 1, 1, SDL_FColor(r: 1, g: 1, b: 1, a: a))
    k.recycleTarget(small, tw, th)
}

@_cdecl("gfx_set_shadow")
func gfx_set_shadow(_ blurRadius: Float, _ dx: Float, _ dy: Float, _ rgba: UInt32) {
    let k = Kit.shared
    k.shadowBlur = blurRadius
    k.shadowDx = dx
    k.shadowDy = dy
    k.shadowRgba = rgba
}

@_cdecl("gfx_clear_shadow")
func gfx_clear_shadow() {
    let k = Kit.shared
    k.shadowBlur = 0
    k.shadowDx = 0
    k.shadowDy = 0
    k.shadowRgba = 0
}

@_cdecl("gfx_set_filter")
func gfx_set_filter(_ utf8: UnsafePointer<CChar>?, _ len: Int32) {
    let k = Kit.shared
    let s = k.cString(utf8, len)
    let bytes = Array(s.utf8)

    func parseNum(_ start: Int) -> Float {
        var p = start
        var v: Float = 0
        var frac: Float = 0
        while p < bytes.count, bytes[p] >= 48, bytes[p] <= 57 { v = v * 10 + Float(bytes[p] - 48); p += 1 }
        if p < bytes.count, bytes[p] == 46 {
            p += 1
            var div: Float = 10
            while p < bytes.count, bytes[p] >= 48, bytes[p] <= 57 { frac += Float(bytes[p] - 48) / div; div *= 10; p += 1 }
        }
        return v + frac
    }

    func findPattern(_ pat: [UInt8]) -> Int? {
        var i = 0
        while i + pat.count <= bytes.count {
            var match = true
            for j in 0..<pat.count where bytes[i + j] != pat[j] { match = false; break }
            if match { return i + pat.count }
            i += 1
        }
        return nil
    }

    var blur: Float = 0
    var brightness: Float = 1
    if let p = findPattern(Array("blur(".utf8)) { blur = parseNum(p) }
    if let p = findPattern(Array("brightness(".utf8)) { brightness = parseNum(p) }
    for i in stride(from: k.targets.count - 1, through: 0, by: -1) where k.targets[i] != nil {
        if blur > 0 { k.targets[i]!.blur = max(k.targets[i]!.blur, blur) }
        if brightness != 1 { k.targets[i]!.brightness = brightness }
        break
    }
}

@_cdecl("gfx_clear_filter")
func gfx_clear_filter() {}

@_cdecl("gfx_set_composite")
func gfx_set_composite(_ mode: Int32) {
    Kit.shared.composite = mode
}

@_cdecl("gfx_snap_translation")
func gfx_snap_translation() {
    let k = Kit.shared
    k.mat.e = SDL_roundf(k.mat.e)
    k.mat.f = SDL_roundf(k.mat.f)
}

@_cdecl("gfx_set_line_style")
func gfx_set_line_style(_ join: Int32, _ cap: Int32, _ miterLimit: Float) {
    let k = Kit.shared
    k.lineJoin = join
    k.lineCap = cap
    k.lineMiterLimit = miterLimit <= 0 ? 10 : miterLimit
}

// MARK: - assets

@_cdecl("asset_exists")
func asset_exists(_ name: UnsafePointer<CChar>?, _ len: Int32) -> Int32 {
    let k = Kit.shared
    return k.assetBytes(k.cString(name, len)) != nil ? 1 : 0
}

@_cdecl("asset_text")
func asset_text(_ name: UnsafePointer<CChar>?, _ len: Int32, _ buf: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
    let k = Kit.shared
    guard let data = k.assetBytes(k.cString(name, len)) else { return -1 }
    if let buf {
        let n = min(Int(cap), data.count)
        for i in 0..<n { buf[i] = CChar(bitPattern: data[i]) }
    }
    return Int32(data.count)
}

// MARK: - sound extensions

@_cdecl("snd_create_pcm")
func snd_create_pcm(_ samples: UnsafePointer<Float>?, _ frameCount: Int32, _ sampleRate: Int32) -> Int32 {
    let k = Kit.shared
    guard let samples, frameCount > 0 else { return 0 }
    let id = Int32(k.soundSpecs.count)
    var spec = SDL_AudioSpec()
    spec.format = SDL_AUDIO_F32LE
    spec.channels = 1
    spec.freq = sampleRate > 0 ? sampleRate : 44100
    let byteLen = Int(frameCount) * 4
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: byteLen)
    let src = UnsafeRawPointer(samples)
    let dst = UnsafeMutableRawPointer(buf)
    dst.copyMemory(from: src, byteCount: byteLen)
    k.soundSpecs.append(spec)
    k.soundBufs.append(buf)
    k.soundLens.append(UInt32(byteLen))
    return id
}

@_cdecl("snd_status")
func snd_status(_ voice: Int32) -> Int32 {
    let k = Kit.shared
    for v in k.voiceIds where v == voice { return 1 }
    return 0
}

@_cdecl("snd_pause_all")
func snd_pause_all() {
    let k = Kit.shared
    if k.audioDevice != 0 { _ = SDL_PauseAudioDevice(k.audioDevice) }
}

@_cdecl("snd_resume_all")
func snd_resume_all() {
    let k = Kit.shared
    if k.audioDevice != 0 { _ = SDL_ResumeAudioDevice(k.audioDevice) }
}

@_cdecl("snd_set_rate")
func snd_set_rate(_ voice: Int32, _ rate: Float) {
    let k = Kit.shared
    for i in 0..<k.voiceIds.count where k.voiceIds[i] == voice {
        _ = SDL_SetAudioStreamFrequencyRatio(k.voiceStreams[i], max(0.0625, min(16, rate)))
        return
    }
}

// MARK: - AVAudioEngine shim mapped onto voices

@_cdecl("eng_player_create")
func eng_player_create() -> Int32 {
    let k = Kit.shared
    let id = k.nextEngId
    k.nextEngId += 1
    k.engPlayers[id] = (sound: 0, loops: 0, voice: 0)
    k.engVolumes[id] = 1
    return id
}

@_cdecl("eng_player_release")
func eng_player_release(_ id: Int32) {
    let k = Kit.shared
    if let p = k.engPlayers[id], p.voice != 0 { k.stopVoice(p.voice) }
    k.engPlayers[id] = nil
    k.engVolumes[id] = nil
}

@_cdecl("eng_mixer_create")
func eng_mixer_create() -> Int32 {
    let k = Kit.shared
    let id = k.nextEngId
    k.nextEngId += 1
    k.engVolumes[id] = 1
    return id
}

@_cdecl("eng_node_set_volume")
func eng_node_set_volume(_ id: Int32, _ v: Float) {
    let k = Kit.shared
    k.engVolumes[id] = v
    if let p = k.engPlayers[id], p.voice != 0 { k.setVoiceVolume(p.voice, v * 100) }
}

@_cdecl("eng_node_set_pan")
func eng_node_set_pan(_ id: Int32, _ p: Float) {
    let k = Kit.shared
    if let player = k.engPlayers[id], player.voice != 0 { k.setVoicePan(player.voice, p) }
}

@_cdecl("eng_connect")
func eng_connect(_ src: Int32, _ dst: Int32) {}

@_cdecl("eng_player_schedule_buffer")
func eng_player_schedule_buffer(_ player: Int32, _ sound: Int32, _ loops: Int32) -> Int32 {
    let k = Kit.shared
    guard var p = k.engPlayers[player] else { return 0 }
    p.sound = sound
    p.loops = loops
    k.engPlayers[player] = p
    return 1
}

@_cdecl("eng_player_play")
func eng_player_play(_ id: Int32) {
    let k = Kit.shared
    guard var p = k.engPlayers[id], p.sound > 0 else { return }
    if p.voice != 0 { k.stopVoice(p.voice) }
    let vol = k.engVolumes[id] ?? 1
    p.voice = k.play(p.sound, volume: vol * 100, loop: p.loops != 0)
    k.engPlayers[id] = p
}

@_cdecl("eng_player_stop")
func eng_player_stop(_ id: Int32) {
    let k = Kit.shared
    guard var p = k.engPlayers[id] else { return }
    if p.voice != 0 { k.stopVoice(p.voice) }
    p.voice = 0
    k.engPlayers[id] = p
}

@_cdecl("eng_start")
func eng_start() {}

@_cdecl("eng_stop")
func eng_stop() {}

// MARK: - window

@_cdecl("win_width")
func win_width() -> Int32 { Int32(Kit.shared.logicalW) }

@_cdecl("win_height")
func win_height() -> Int32 { Int32(Kit.shared.logicalH) }

@_cdecl("win_set_title")
func win_set_title(_ s: UnsafePointer<CChar>?, _ len: Int32) {
    let k = Kit.shared
    _ = k.cString(s, len).withCString { SDL_SetWindowTitle(k.window, $0) }
}

@_cdecl("win_request_fullscreen")
func win_request_fullscreen() {
    let k = Kit.shared
    _ = SDL_SetWindowFullscreen(k.window, true)
    k.fullscreen = true
}

@_cdecl("win_exit_fullscreen")
func win_exit_fullscreen() {
    let k = Kit.shared
    _ = SDL_SetWindowFullscreen(k.window, false)
    k.fullscreen = false
}

@_cdecl("win_download")
func win_download(_ name: UnsafePointer<CChar>?, _ nlen: Int32, _ data: UnsafePointer<CChar>?, _ dlen: Int32) {
    let k = Kit.shared
    guard let data, dlen > 0 else { return }
    let fname = k.cString(name, nlen)
    // The web build downloads the file to the browser; the macOS app reveals it
    // in Finder. The native console has neither, so write it to the user's
    // Downloads (discoverable, app-agnostic; the binary's folder as a fallback)
    // and open it in the default handler so SHOW actually shows the data — a
    // bare filename to the cwd wrote it somewhere invisible and looked broken.
    var dir = ""
    if let dl = SDL_GetUserFolder(SDL_FOLDER_DOWNLOADS) { dir = String(cString: dl) }
    else if let base = SDL_GetBasePath() { dir = String(cString: base) }
    let path = dir + fname
    let ok = path.withCString { SDL_SaveFile($0, data, Int(dlen)) }
    if ok {
        print("download: wrote \(path)")
        _ = ("file://" + path).withCString { SDL_OpenURL($0) }
    }
}

// MARK: - text to speech

@_cdecl("tts_speak")
func tts_speak(_ utf8: UnsafePointer<CChar>?, _ len: Int32, _ rate: Float, _ pitch: Float, _ volume: Float) -> Int32 {
    let k = Kit.shared
    return k.ttsSpeak(k.cString(utf8, len), rate: rate) ? 1 : 0
}

@_cdecl("tts_cancel")
func tts_cancel() {
    Kit.shared.ttsStop()
}

@_cdecl("tts_set_preferred_voices")
func tts_set_preferred_voices(_ csv: UnsafePointer<CChar>?, _ len: Int32) {
    let k = Kit.shared
    let s = k.cString(csv, len)
    var first = ""
    for b in s.utf8 {
        if b == 44 { break }
        first.append(Character(UnicodeScalar(b)))
    }
    guard first != k.ttsPreferredVoice else { return }
    k.ttsPreferredVoice = first
    if let warm = k.ttsWarm {
        if let input = SDL_GetProcessInput(warm) { _ = SDL_CloseIO(input) }
        SDL_DestroyProcess(warm)
        k.ttsWarm = nil
    }
    k.ttsWarmup()
}

@_cdecl("tts_set_robotic_voices")
func tts_set_robotic_voices(_ csv: UnsafePointer<CChar>?, _ len: Int32) {}

@_cdecl("tts_set_female_voices")
func tts_set_female_voices(_ csv: UnsafePointer<CChar>?, _ len: Int32) {}

// MARK: - warp + billboard

@_cdecl("gfx_warp_draw")
func gfx_warp_draw(_ srcImg: Int32, _ cols: Int32, _ rows: Int32,
                   _ srcUV: UnsafePointer<Float>?, _ dstXY: UnsafePointer<Float>?,
                   _ dstX: Float, _ dstY: Float, _ dstW: Float, _ dstH: Float, _ colorRgba: UInt32) {
    let k = Kit.shared
    guard srcImg > 0, Int(srcImg) < k.images.count,
          let rec = k.images[Int(srcImg)], let tex = rec.tex else { return }
    guard let srcUV, let dstXY, cols > 0, rows > 0 else { return }
    _ = SDL_SetTextureBlendMode(tex, k.currentBlend())
    let a = Float(colorRgba & 0xFF) / 255 * k.alpha
    let color = SDL_FColor(r: 1, g: 1, b: 1, a: a)
    let vCount = Int((cols + 1) * (rows + 1))
    var verts = [SDL_Vertex]()
    verts.reserveCapacity(vCount)
    for i in 0..<vCount {
        let px = dstX + dstXY[i * 2] * dstW
        let py = dstY + dstXY[i * 2 + 1] * dstH
        let pos = k.mat.apply(px, py)
        let uv = SDL_FPoint(x: srcUV[i * 2], y: srcUV[i * 2 + 1])
        verts.append(SDL_Vertex(position: pos, color: color, tex_coord: uv))
    }
    var idx = [Int32]()
    idx.reserveCapacity(Int(cols * rows * 6))
    let stride = Int(cols + 1)
    for r in 0..<Int(rows) {
        for c in 0..<Int(cols) {
            let tl = Int32(r * stride + c)
            let tr = tl + 1
            let bl = Int32((r + 1) * stride + c)
            let br = bl + 1
            idx.append(contentsOf: [tl, tr, br, tl, br, bl])
        }
    }
    SDL_RenderGeometry(k.renderer, tex, verts, Int32(vCount), idx, Int32(idx.count))
}

@_cdecl("gfx_3d_draw_billboard")
func gfx_3d_draw_billboard(_ srcImg: Int32, _ camX: Float, _ camY: Float, _ camZ: Float,
                            _ dstX: Float, _ dstY: Float, _ dstW: Float, _ dstH: Float, _ colorRgba: UInt32) {
    let k = Kit.shared
    guard srcImg > 0, Int(srcImg) < k.images.count,
          let rec = k.images[Int(srcImg)], rec.tex != nil else { return }
    let a = Float(colorRgba & 0xFF) / 255 * k.alpha
    let color = SDL_FColor(r: 1, g: 1, b: 1, a: a)
    k.drawTexturedQuad(rec.tex, dstX, dstY, dstW, dstH, 0, 0, 1, 1, color)
}
