import KitABI

public enum SKLabelHorizontalAlignmentMode { case center, left, right }
public enum SKLabelVerticalAlignmentMode { case baseline, center, top, bottom }

public final class SKLabelNode: SKNode {
    var _text: String = "" { didSet { fontHandleNeedsRebind = true; _widthDirty = true } }
    // Apple's SKLabelNode.text is optional; back it with a non-optional _text so
    // the render path stays simple and the game's `if let l = label.text` /
    // `label.text? += "x"` compile.
    public var text: String? { get { _text } set { _text = newValue ?? "" } }
    public var fontSize: CGFloat = 32 { didSet { if fontSize != oldValue { _widthDirty = true } } }
    public var fontColor: SKColor? = .white
    public var fontName: String = "JetBrainsMono-Bold" { didSet { fontHandleNeedsRebind = true; _widthDirty = true } }
    public var horizontalAlignmentMode: SKLabelHorizontalAlignmentMode = .center
    public var verticalAlignmentMode: SKLabelVerticalAlignmentMode = .baseline
    public var numberOfLines: Int = 1
    public var preferredMaxLayoutWidth: CGFloat = 0
    public var lineBreakMode: Int = 0
    public var attributedText: String? = nil
    public var color: SKColor = .white
    public var colorBlendFactor: CGFloat = 0
    public var blendMode: SKBlendMode = .alpha

    // Cached font handle (looked up once from fontName via font_by_name, then
    // reused across frames). Reset when fontName changes; recomputed lazily
    // because asset preloading is asynchronous and an early init() may run
    // before the font face has registered.
    private var cachedFontHandle: Int32 = 0
    private var fontHandleNeedsRebind: Bool = true

    // Cached glyph-run width (txt_width). Static labels — every building/car/tree
    // emoji and HUD string — never change text/font/size, so this measures ONCE and
    // is reused, instead of the 2-3 txt_width calls per label per frame (measuredWidth
    // + frame + draw) that made frame time scale with on-screen object count.
    private var _cachedWidth: Int32 = 0
    private var _widthDirty: Bool = true

    private func rawWidth() -> Int32 {
        if _widthDirty {
            if _text.isEmpty {
                _cachedWidth = 0
                _widthDirty = false
            } else {
                let px = Int32(fontSize)
                let font = resolvedFontHandle()
                var w: Int32 = 0
                withUTF8Ptr(_text) { p, n in w = txt_width(font, p, n, px, 0) }
                // A zero width on non-empty text means the font face hasn't registered
                // yet (async asset load); stay dirty and retry next frame so we never
                // cache a stale 0 and mis-align the label.
                if w > 0 { _cachedWidth = w; _widthDirty = false }
            }
        }
        return _cachedWidth
    }

    // Cull radius for the world pass: ~3× the font size comfortably covers a
    // single emoji glyph or short HUD run without a per-frame text measure.
    override var _cullExtent: CGFloat { fontSize * 3 }

    public init(attributedText: String) {
        self._text = attributedText
        super.init()
    }
    public override init() { super.init() }
    public init(text: String) {
        self._text = text
        super.init()
    }
    public init(fontNamed name: String) {
        self.fontName = name
        super.init()
    }

    // Deep copy (SKNode.copy override). The base SKNode.copy() builds a plain
    // SKNode and copies none of the label's text/font state, so a copied label
    // would render NOTHING and `node.copy() as! SKSpriteNode` subtrees that hold
    // a label child (UFO Emoji's bomb 🧨 / monkey-laser 🍌, which live as label
    // children of an otherwise-empty sprite) would lose their only visible
    // content. Override so the clone is a real SKLabelNode carrying every field.
    public override func copy() -> SKNode {
        let l = SKLabelNode()
        l.position = position; l.zPosition = zPosition; l.zRotation = zRotation
        l.xScale = xScale; l.yScale = yScale; l.alpha = alpha
        l.name = name; l.isHidden = isHidden; l.speed = speed
        l._text = _text
        l.fontSize = fontSize
        l.fontName = fontName
        l.fontColor = fontColor
        l.horizontalAlignmentMode = horizontalAlignmentMode
        l.verticalAlignmentMode = verticalAlignmentMode
        l.numberOfLines = numberOfLines
        l.preferredMaxLayoutWidth = preferredMaxLayoutWidth
        l.lineBreakMode = lineBreakMode
        l.attributedText = attributedText
        l.color = color
        l.colorBlendFactor = colorBlendFactor
        l.blendMode = blendMode
        if let b = physicsBody { l.physicsBody = b._clone() }
        for c in children { l.addChild(c.copy()) }
        return l
    }

    // Resolve the font handle through font_by_name, retrying until the asset
    // loader has registered it (preload races scene init; first frame may see
    // handle 0, second frame the real one).
    private func resolvedFontHandle() -> Int32 {
        if !fontHandleNeedsRebind && cachedFontHandle != 0 { return cachedFontHandle }
        let h = withUTF8Ptr(fontName) { font_by_name($0, $1) }
        if h > 0 {
            cachedFontHandle = h
            fontHandleNeedsRebind = false
        }
        return h
    }

    // Measured bounding box in the PARENT's coordinate space, honoring the
    // alignment modes the way SpriteKit does (draw() uses the same -w/2 / 0 / -w
    // rule). Consumers position sibling nodes off a label's frame (the HUD's
    // water-gun ammo dots + crop overlay), so the zero-size rect SKNode returns
    // would stack them on top of the label.
    public override var frame: CGRect {
        // Frame is in the parent's coordinate space, so fold in the node's own
        // scale (Apple does this). A supersampled label (big fontSize, setScale
        // 1/N) must report its true on-screen size or frame-based hit-tests miss.
        let w = measuredWidth() * abs(xScale)
        let h = fontSize * abs(yScale)
        let minX: CGFloat
        switch horizontalAlignmentMode {
        case .center: minX = position.x - w / 2
        case .left:   minX = position.x
        case .right:  minX = position.x - w
        }
        let minY: CGFloat
        switch verticalAlignmentMode {
        case .center:            minY = position.y - h / 2
        case .top:               minY = position.y - h
        case .bottom, .baseline: minY = position.y
        }
        return CGRect(x: minX, y: minY, width: w, height: h)
    }

    // Public glyph-run width measurement so consumers can position a
    // sibling node (caret, divider, etc.) at the end of the text without
    // duplicating the txt_width call.
    public func measuredWidth() -> CGFloat { CGFloat(rawWidth()) }

    override func draw(alpha: CGFloat) {
        guard !_text.isEmpty, let c = fontColor else { return }
        let px = Int32(fontSize)
        let font = resolvedFontHandle()
        let w = Float(rawWidth())   // cached: no per-frame re-measure
        let x: Float
        switch horizontalAlignmentMode {
        case .center: x = -w / 2
        case .left:   x = 0
        case .right:  x = -w
        }
        // Let Canvas2D pick the textBaseline directly so the y anchor matches what
        // each alignment mode means visually. Emojis don't sit dead centre in the
        // em-box; textBaseline='middle' uses the actual glyph centre, which is what
        // SpriteKit's .center alignment promises.
        let baselineMode: Int32
        switch verticalAlignmentMode {
        case .baseline: baselineMode = 0       // alphabetic
        case .center:   baselineMode = 1       // middle
        case .top:      baselineMode = 2
        case .bottom:   baselineMode = 3
        }
        gfx_set_alpha(Float(alpha))
        gfx_save()
        gfx_scale(1, -1)  // un-flip: text must not be mirrored
        gfx_set_text_baseline(baselineMode)
        withUTF8Ptr(_text) { p, n in gfx_draw_text(font, p, n, x, 0, px, c.rgba, 0) }
        gfx_set_text_baseline(2)               // restore default 'top'
        gfx_restore()
    }
}


