// GLSL fragment subset for SKShader/SKLightNode parity on the native SDL3
// backend. No GPU shader path exists in SDL_Render, so the source compiles
// to Swift closures once and evaluates per pixel into an area-capped buffer
// that upscales onto the target (same trade as the blur/shadow passes).
// Mirrors the web runtime's preamble: v_tex_coord, v_color_mix, u_texture,
// u_time, gl_FragCoord, SKDefaultShading(), gl_FragColor.
import CSDL3

// MARK: - values

struct ShVec {
    var x: Float = 0
    var y: Float = 0
    var z: Float = 0
    var w: Float = 0

    subscript(_ i: Int) -> Float {
        get {
            if i == 0 { return x }
            if i == 1 { return y }
            if i == 2 { return z }
            return w
        }
        set {
            if i == 0 { x = newValue } else if i == 1 { y = newValue } else if i == 2 { z = newValue } else { w = newValue }
        }
    }

    static func splat(_ v: Float) -> ShVec { ShVec(x: v, y: v, z: v, w: v) }
}

enum ShType {
    case f
    case i
    case b
    case v2
    case v3
    case v4
    case sampler
    case none

    var lanes: Int {
        switch self {
        case .v2: return 2
        case .v3: return 3
        case .v4: return 4
        default: return 1
        }
    }
}

enum ShFlow {
    case normal
    case brk
    case cont
    case ret
}

final class ShCtx {
    var slots: [ShVec] = []
    var texcoord = ShVec()
    var colormix = ShVec()
    var fragcoord = ShVec()
    var time: Float = 0
    var frag = ShVec()
    var ret = ShVec()
    var sample: (Int, Float, Float) -> ShVec = { _, _, _ in ShVec() }
}

typealias ShExpr = (ShCtx) -> ShVec
typealias ShStmt = (ShCtx) -> ShFlow

final class ShProgram {
    var run: ShStmt? = nil
    var globalInit: [ShStmt] = []
    var slotCount = 0
    var store: [ShVec] = []
    var uniformIndex: [String: (slot: Int, type: ShType, count: Int)] = [:]
    var samplerIndex: [String: Int] = [:]
    var samplerImgs: [Int32] = []
}

// MARK: - compiler

final class ShCompiler {
    struct Tok {
        var s: String
        var num: Float
        var isNum: Bool
        init(_ s: String) {
            self.s = s
            num = 0
            isNum = false
        }
        init(num: Float) {
            s = ""
            self.num = num
            isNum = true
        }
    }

    struct LV {
        var slot: Int
        var swz: [Int]?
    }

    struct SVal {
        var eval: ShExpr
        var type: ShType
        var lv: LV? = nil
        var sampler: Int = -1
        var arrBase: Int = -1
        var arrCount: Int = 0
        var arrType: ShType = .none
    }

    struct Fn {
        var paramSlots: [Int]
        var ret: ShType
        var body: ShStmt
    }

    var toks: [Tok] = []
    var pos = 0
    var failed = false
    let prog = ShProgram()
    var scopes: [[String: (slot: Int, type: ShType, count: Int)]] = [[:]]
    var fns: [String: Fn] = [:]
    var nextSampler = 1
    var macros: [String: [Tok]] = [:]

    static func compile(_ src: String) -> ShProgram? {
        let c = ShCompiler()
        c.seed()
        c.lex(src)
        c.parseTop()
        guard !c.failed, let m = c.fns["main"] else { return nil }
        c.prog.run = m.body
        c.prog.store = [ShVec](repeating: ShVec(), count: max(1, c.prog.slotCount))
        c.prog.samplerImgs = [Int32](repeating: 0, count: c.nextSampler)
        return c.prog
    }

    func seed() {
        scopes[0]["v_tex_coord"] = (-2, .v2, 1)
        scopes[0]["v_color_mix"] = (-3, .v4, 1)
        scopes[0]["gl_FragCoord"] = (-4, .v4, 1)
        scopes[0]["u_time"] = (-5, .f, 1)
        scopes[0]["gl_FragColor"] = (-1, .v4, 1)
        scopes[0]["_outColor"] = (-1, .v4, 1)
        prog.samplerIndex["u_texture"] = 0
    }

    // MARK: - lexing

    func str(_ slice: ArraySlice<UInt8>) -> String {
        var a = Array(slice)
        a.append(0)
        return a.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    func tokenize(_ b: [UInt8]) -> [Tok] {
        var out: [Tok] = []
        var i = 0
        func isAl(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
        func isDig(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
        let twos = ["==", "!=", "<=", ">=", "&&", "||", "+=", "-=", "*=", "/=", "++", "--"]
        while i < b.count {
            let c = b[i]
            if c == 32 || c == 9 || c == 10 || c == 13 {
                i += 1
                continue
            }
            if isAl(c) {
                var j = i
                while j < b.count, isAl(b[j]) || isDig(b[j]) { j += 1 }
                out.append(Tok(str(b[i..<j])))
                i = j
                continue
            }
            if isDig(c) || (c == 46 && i + 1 < b.count && isDig(b[i + 1])) {
                var j = i
                while j < b.count, isDig(b[j]) { j += 1 }
                if j < b.count, b[j] == 46 {
                    j += 1
                    while j < b.count, isDig(b[j]) { j += 1 }
                }
                if j < b.count, b[j] == 101 || b[j] == 69 {
                    var k = j + 1
                    if k < b.count, b[k] == 43 || b[k] == 45 { k += 1 }
                    if k < b.count, isDig(b[k]) {
                        j = k
                        while j < b.count, isDig(b[j]) { j += 1 }
                    }
                }
                var v: Float = 0
                str(b[i..<j]).withCString { v = Float(SDL_strtod($0, nil)) }
                out.append(Tok(num: v))
                if j < b.count, b[j] == 102 || b[j] == 70 { j += 1 }
                i = j
                continue
            }
            if i + 1 < b.count {
                let two = str(b[i...(i + 1)])
                var hit = false
                for t in twos where t == two {
                    hit = true
                    break
                }
                if hit {
                    out.append(Tok(two))
                    i += 2
                    continue
                }
            }
            out.append(Tok(str(b[i...i])))
            i += 1
        }
        return out
    }

    func lex(_ src: String) {
        let bytes = Array(src.utf8)
        var stripped: [UInt8] = []
        stripped.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 47, i + 1 < bytes.count, bytes[i + 1] == 42 {
                i += 2
                while i + 1 < bytes.count, !(bytes[i] == 42 && bytes[i + 1] == 47) { i += 1 }
                i = min(bytes.count, i + 2)
                stripped.append(32)
                continue
            }
            if bytes[i] == 47, i + 1 < bytes.count, bytes[i + 1] == 47 {
                while i < bytes.count, bytes[i] != 10 { i += 1 }
                continue
            }
            stripped.append(bytes[i])
            i += 1
        }
        var body: [UInt8] = []
        var line: [UInt8] = []
        func flushLine() {
            var t = 0
            while t < line.count, line[t] == 32 || line[t] == 9 { t += 1 }
            if t < line.count, line[t] == 35 {
                let lt = tokenize(Array(line[(t + 1)...]))
                if lt.count >= 2, lt[0].s == "define", !lt[1].isNum {
                    macros[lt[1].s] = Array(lt[2...])
                }
            } else {
                body.append(contentsOf: line)
                body.append(10)
            }
            line = []
        }
        for c in stripped {
            if c == 10 { flushLine() } else { line.append(c) }
        }
        flushLine()
        var raw = tokenize(body)
        var depth = 0
        while depth < 4 {
            var changed = false
            var expanded: [Tok] = []
            expanded.reserveCapacity(raw.count)
            for t in raw {
                if !t.isNum, let m = macros[t.s] {
                    expanded.append(contentsOf: m)
                    changed = true
                } else {
                    expanded.append(t)
                }
            }
            raw = expanded
            if !changed { break }
            depth += 1
        }
        toks = raw
    }

    // MARK: - token helpers

    func peek() -> String {
        if pos < toks.count, !toks[pos].isNum { return toks[pos].s }
        return ""
    }

    func accept(_ s: String) -> Bool {
        if peek() == s {
            pos += 1
            return true
        }
        return false
    }

    func expect(_ s: String) {
        if !accept(s) { failed = true }
    }

    func ident() -> String {
        guard pos < toks.count, !toks[pos].isNum, !toks[pos].s.isEmpty else {
            failed = true
            return ""
        }
        let first = Array(toks[pos].s.utf8)[0]
        guard (first >= 65 && first <= 90) || (first >= 97 && first <= 122) || first == 95 else {
            failed = true
            return ""
        }
        let s = toks[pos].s
        pos += 1
        return s
    }

    func skipQual() {
        while true {
            let p = peek()
            if p == "highp" || p == "mediump" || p == "lowp" || p == "in" || p == "out" || p == "inout" || p == "const" {
                pos += 1
            } else {
                return
            }
        }
    }

    func typeFor(_ s: String) -> ShType? {
        switch s {
        case "float": return .f
        case "int": return .i
        case "bool": return .b
        case "vec2": return .v2
        case "vec3": return .v3
        case "vec4": return .v4
        default: return nil
        }
    }

    func parseTypeName(allowVoid: Bool) -> ShType? {
        skipQual()
        let s = peek()
        if s == "void" {
            if !allowVoid { return nil }
            pos += 1
            return ShType.none
        }
        if let t = typeFor(s) {
            pos += 1
            return t
        }
        return nil
    }

    func isTypeStart() -> Bool {
        let p = peek()
        if typeFor(p) != nil { return true }
        return p == "const" || p == "highp" || p == "mediump" || p == "lowp"
    }

    // MARK: - scopes

    func pushScope() { scopes.append([:]) }
    func popScope() { scopes.removeLast() }

    func declare(_ name: String, _ type: ShType, count: Int = 1) -> Int {
        let slot = prog.slotCount
        prog.slotCount += count
        scopes[scopes.count - 1][name] = (slot, type, count)
        return slot
    }

    func lookup(_ name: String) -> (slot: Int, type: ShType, count: Int)? {
        var i = scopes.count - 1
        while i >= 0 {
            if let e = scopes[i][name] { return e }
            i -= 1
        }
        return nil
    }

    func readSlot(_ slot: Int) -> ShExpr {
        if slot >= 0 { return { c in c.slots[slot] } }
        switch slot {
        case -1: return { c in c.frag }
        case -2: return { c in c.texcoord }
        case -3: return { c in c.colormix }
        case -4: return { c in c.fragcoord }
        default: return { c in ShVec.splat(c.time) }
        }
    }

    func writeSlot(_ slot: Int) -> (ShCtx, ShVec) -> Void {
        if slot >= 0 { return { c, v in c.slots[slot] = v } }
        if slot == -1 { return { c, v in c.frag = v } }
        failed = true
        return { _, _ in }
    }

    func storeClosure(_ lv: LV) -> (ShCtx, ShVec) -> Void {
        let w = writeSlot(lv.slot)
        if let swz = lv.swz {
            let r = readSlot(lv.slot)
            return { c, v in
                var cur = r(c)
                var k = 0
                for j in swz {
                    cur[j] = v[k]
                    k += 1
                }
                w(c, cur)
            }
        }
        return w
    }

    // MARK: - top level

    func parseTop() {
        var guardN = 0
        while pos < toks.count, !failed {
            guardN += 1
            if guardN > 100000 {
                failed = true
                return
            }
            if accept(";") { continue }
            if accept("precision") {
                while pos < toks.count, !accept(";") { pos += 1 }
                continue
            }
            if accept("uniform") {
                parseUniformDecl()
                continue
            }
            let p = peek()
            if p == "varying" || p == "attribute" {
                while pos < toks.count, !accept(";") { pos += 1 }
                continue
            }
            if p == "in" || p == "out" {
                let save = pos
                pos += 1
                if parseTypeName(allowVoid: false) != nil, !ident().isEmpty, accept(";") {
                    failed = false
                    continue
                }
                pos = save
                failed = true
                return
            }
            skipQual()
            guard let rt = parseTypeName(allowVoid: true) else {
                failed = true
                return
            }
            let name = ident()
            if failed { return }
            if accept("(") {
                parseFunction(rt, name)
            } else {
                parseGlobalDecl(rt, name)
            }
        }
    }

    func parseUniformDecl() {
        skipQual()
        if accept("sampler2D") {
            let name = ident()
            if prog.samplerIndex[name] == nil {
                prog.samplerIndex[name] = nextSampler
                nextSampler += 1
            }
            expect(";")
            return
        }
        guard let t = parseTypeName(allowVoid: false) else {
            failed = true
            return
        }
        while !failed {
            let name = ident()
            var count = 1
            if accept("[") {
                if pos < toks.count, toks[pos].isNum {
                    count = max(1, Int(toks[pos].num))
                    pos += 1
                } else {
                    failed = true
                }
                expect("]")
            }
            let slot = prog.slotCount
            prog.slotCount += count
            scopes[0][name] = (slot, t, count)
            prog.uniformIndex[name] = (slot, t, count)
            if accept(",") { continue }
            expect(";")
            return
        }
    }

    func parseGlobalDecl(_ t: ShType, _ firstName: String) {
        var name = firstName
        while !failed {
            let slot = declareGlobal(name, t)
            if accept("=") {
                let e = parseAssign().eval
                let w = writeSlot(slot)
                prog.globalInit.append { c in
                    w(c, e(c))
                    return .normal
                }
            }
            if accept(",") {
                name = ident()
                continue
            }
            expect(";")
            return
        }
    }

    func declareGlobal(_ name: String, _ type: ShType) -> Int {
        let slot = prog.slotCount
        prog.slotCount += 1
        scopes[0][name] = (slot, type, 1)
        return slot
    }

    func parseFunction(_ rt: ShType, _ name: String) {
        pushScope()
        var paramSlots: [Int] = []
        if !accept(")") {
            if accept("void") {
                expect(")")
            } else {
                while !failed {
                    skipQual()
                    guard let pt = parseTypeName(allowVoid: false) else {
                        failed = true
                        break
                    }
                    let pn = ident()
                    paramSlots.append(declare(pn, pt))
                    if accept(",") { continue }
                    expect(")")
                    break
                }
            }
        }
        expect("{")
        let body = parseBlock()
        popScope()
        if failed { return }
        fns[name] = Fn(paramSlots: paramSlots, ret: rt, body: body)
    }

    // MARK: - statements

    func parseBlock() -> ShStmt {
        var stmts: [ShStmt] = []
        pushScope()
        var guardN = 0
        while !failed, pos < toks.count, peek() != "}" {
            stmts.append(parseStmt())
            guardN += 1
            if guardN > 100000 { failed = true }
        }
        expect("}")
        popScope()
        let arr = stmts
        return { c in
            for s in arr {
                let f = s(c)
                switch f {
                case .normal: break
                default: return f
                }
            }
            return .normal
        }
    }

    func parseStmt() -> ShStmt {
        if failed { return { _ in .normal } }
        if accept("{") { return parseBlock() }
        if accept("if") {
            expect("(")
            let cond = parseExpr().eval
            expect(")")
            let thenS = parseStmt()
            var elseS: ShStmt? = nil
            if accept("else") { elseS = parseStmt() }
            let e2 = elseS
            return { c in
                if cond(c).x != 0 { return thenS(c) }
                if let e = e2 { return e(c) }
                return .normal
            }
        }
        if accept("for") {
            pushScope()
            expect("(")
            var initS: ShStmt = { _ in .normal }
            if accept(";") {
            } else if isTypeStart() {
                initS = parseLocalDecl()
            } else {
                let e = parseExpr().eval
                expect(";")
                initS = { c in
                    _ = e(c)
                    return .normal
                }
            }
            var cond: ShExpr = { _ in ShVec.splat(1) }
            if !accept(";") {
                cond = parseExpr().eval
                expect(";")
            }
            var incE: ShExpr? = nil
            if peek() != ")" { incE = parseExpr().eval }
            expect(")")
            let body = parseStmt()
            popScope()
            let inc = incE
            return { c in
                _ = initS(c)
                var n = 0
                while cond(c).x != 0 {
                    let f = body(c)
                    switch f {
                    case .ret: return .ret
                    case .brk: return .normal
                    default: break
                    }
                    _ = inc?(c)
                    n += 1
                    if n > 65536 { break }
                }
                return .normal
            }
        }
        if accept("while") {
            expect("(")
            let cond = parseExpr().eval
            expect(")")
            let body = parseStmt()
            return { c in
                var n = 0
                while cond(c).x != 0 {
                    let f = body(c)
                    switch f {
                    case .ret: return .ret
                    case .brk: return .normal
                    default: break
                    }
                    n += 1
                    if n > 65536 { break }
                }
                return .normal
            }
        }
        if accept("return") {
            if accept(";") { return { _ in .ret } }
            let e = parseExpr().eval
            expect(";")
            return { c in
                c.ret = e(c)
                return .ret
            }
        }
        if accept("break") {
            expect(";")
            return { _ in .brk }
        }
        if accept("continue") {
            expect(";")
            return { _ in .cont }
        }
        if accept("discard") {
            expect(";")
            return { c in
                c.frag = ShVec()
                return .ret
            }
        }
        if isTypeStart() { return parseLocalDecl() }
        let e = parseExpr().eval
        expect(";")
        return { c in
            _ = e(c)
            return .normal
        }
    }

    func parseLocalDecl() -> ShStmt {
        skipQual()
        guard let t = parseTypeName(allowVoid: false) else {
            failed = true
            return { _ in .normal }
        }
        var inits: [ShStmt] = []
        while !failed {
            let name = ident()
            if accept("[") {
                failed = true
                return { _ in .normal }
            }
            let slot = declare(name, t)
            if accept("=") {
                let e = parseAssign().eval
                let w = writeSlot(slot)
                inits.append { c in
                    w(c, e(c))
                    return .normal
                }
            }
            if accept(",") { continue }
            expect(";")
            break
        }
        let arr = inits
        return { c in
            for s in arr { _ = s(c) }
            return .normal
        }
    }

    // MARK: - expressions

    func parseExpr() -> SVal { parseAssign() }

    func zeroVal() -> SVal { SVal(eval: { _ in ShVec() }, type: .f) }

    func parseAssign() -> SVal {
        if failed { return zeroVal() }
        let lhs = parseTernary()
        let op = peek()
        guard op == "=" || op == "+=" || op == "-=" || op == "*=" || op == "/=" else { return lhs }
        guard let lv = lhs.lv else {
            failed = true
            return zeroVal()
        }
        pos += 1
        let rhs = parseAssign()
        let store = storeClosure(lv)
        if op == "=" {
            let lanes = lhs.type.lanes
            let rScalar = rhs.type.lanes == 1 && lanes > 1
            let re = rhs.eval
            return SVal(eval: { c in
                var v = re(c)
                if rScalar { v = ShVec.splat(v.x) }
                store(c, v)
                return v
            }, type: lhs.type)
        }
        let kind: Int
        switch op {
        case "+=": kind = 0
        case "-=": kind = 1
        case "*=": kind = 2
        default: kind = 3
        }
        let combined = makeArith(kind, lhs, rhs)
        let ce = combined.eval
        return SVal(eval: { c in
            let v = ce(c)
            store(c, v)
            return v
        }, type: lhs.type)
    }

    func parseTernary() -> SVal {
        let c0 = parseOr()
        if accept("?") {
            let a = parseAssign()
            expect(":")
            let b = parseAssign()
            let (ce, ae, be) = (c0.eval, a.eval, b.eval)
            return SVal(eval: { c in ce(c).x != 0 ? ae(c) : be(c) }, type: a.type)
        }
        return c0
    }

    func parseOr() -> SVal {
        var l = parseAnd()
        while accept("||") {
            let r = parseAnd()
            let (le, re) = (l.eval, r.eval)
            l = SVal(eval: { c in ShVec.splat((le(c).x != 0 || re(c).x != 0) ? 1 : 0) }, type: .b)
        }
        return l
    }

    func parseAnd() -> SVal {
        var l = parseEq()
        while accept("&&") {
            let r = parseEq()
            let (le, re) = (l.eval, r.eval)
            l = SVal(eval: { c in ShVec.splat((le(c).x != 0 && re(c).x != 0) ? 1 : 0) }, type: .b)
        }
        return l
    }

    func parseEq() -> SVal {
        var l = parseRel()
        while true {
            let eq = peek() == "=="
            if !eq, peek() != "!=" { return l }
            pos += 1
            let r = parseRel()
            let n = max(l.type.lanes, r.type.lanes)
            let (le, re) = (l.eval, r.eval)
            l = SVal(eval: { c in
                let a = le(c)
                let b = re(c)
                var same = true
                var i = 0
                while i < n {
                    if a[i] != b[i] {
                        same = false
                        break
                    }
                    i += 1
                }
                return ShVec.splat(same == eq ? 1 : 0)
            }, type: .b)
        }
    }

    func parseRel() -> SVal {
        var l = parseAddSub()
        while true {
            let op = peek()
            guard op == "<" || op == ">" || op == "<=" || op == ">=" else { return l }
            pos += 1
            let r = parseAddSub()
            let (le, re) = (l.eval, r.eval)
            let kind: Int
            switch op {
            case "<": kind = 0
            case ">": kind = 1
            case "<=": kind = 2
            default: kind = 3
            }
            l = SVal(eval: { c in
                let a = le(c).x
                let b = re(c).x
                let t: Bool
                switch kind {
                case 0: t = a < b
                case 1: t = a > b
                case 2: t = a <= b
                default: t = a >= b
                }
                return ShVec.splat(t ? 1 : 0)
            }, type: .b)
        }
    }

    func parseAddSub() -> SVal {
        var l = parseMulDiv()
        while true {
            let op = peek()
            guard op == "+" || op == "-" else { return l }
            pos += 1
            let r = parseMulDiv()
            l = makeArith(op == "+" ? 0 : 1, l, r)
        }
    }

    func parseMulDiv() -> SVal {
        var l = parseUnary()
        while true {
            let op = peek()
            guard op == "*" || op == "/" else { return l }
            pos += 1
            let r = parseUnary()
            l = makeArith(op == "*" ? 2 : 3, l, r)
        }
    }

    func makeArith(_ kind: Int, _ a: SVal, _ b: SVal) -> SVal {
        let aS = a.type.lanes == 1 && b.type.lanes > 1
        let bS = b.type.lanes == 1 && a.type.lanes > 1
        let rt = a.type.lanes >= b.type.lanes ? a.type : b.type
        let (ae, be) = (a.eval, b.eval)
        return SVal(eval: { c in
            var va = ae(c)
            var vb = be(c)
            if aS { va = ShVec.splat(va.x) }
            if bS { vb = ShVec.splat(vb.x) }
            switch kind {
            case 0: return ShVec(x: va.x + vb.x, y: va.y + vb.y, z: va.z + vb.z, w: va.w + vb.w)
            case 1: return ShVec(x: va.x - vb.x, y: va.y - vb.y, z: va.z - vb.z, w: va.w - vb.w)
            case 2: return ShVec(x: va.x * vb.x, y: va.y * vb.y, z: va.z * vb.z, w: va.w * vb.w)
            default: return ShVec(x: va.x / vb.x, y: va.y / vb.y, z: va.z / vb.z, w: va.w / vb.w)
            }
        }, type: rt)
    }

    func parseUnary() -> SVal {
        if accept("-") {
            let v = parseUnary()
            let e = v.eval
            return SVal(eval: { c in
                let a = e(c)
                return ShVec(x: -a.x, y: -a.y, z: -a.z, w: -a.w)
            }, type: v.type)
        }
        if accept("!") {
            let v = parseUnary()
            let e = v.eval
            return SVal(eval: { c in ShVec.splat(e(c).x != 0 ? 0 : 1) }, type: .b)
        }
        if accept("+") { return parseUnary() }
        if peek() == "++" || peek() == "--" {
            let inc = accept("++")
            if !inc { _ = accept("--") }
            let v = parsePostfix()
            guard let lv = v.lv else {
                failed = true
                return zeroVal()
            }
            let store = storeClosure(lv)
            let e = v.eval
            let d: Float = inc ? 1 : -1
            return SVal(eval: { c in
                let nv = ShVec.splat(e(c).x + d)
                store(c, nv)
                return nv
            }, type: v.type)
        }
        return parsePostfix()
    }

    func swzIndex(_ ch: UInt8) -> Int? {
        switch ch {
        case 120, 114, 115: return 0
        case 121, 103, 116: return 1
        case 122, 98, 112: return 2
        case 119, 97, 113: return 3
        default: return nil
        }
    }

    func lanesType(_ n: Int) -> ShType {
        switch n {
        case 2: return .v2
        case 3: return .v3
        case 4: return .v4
        default: return .f
        }
    }

    func parsePostfix() -> SVal {
        var v = parsePrimary()
        var guardN = 0
        while !failed {
            guardN += 1
            if guardN > 10000 {
                failed = true
                break
            }
            if accept(".") {
                let name = ident()
                var idxs: [Int] = []
                var ok = !name.isEmpty && name.utf8.count <= 4
                for ch in name.utf8 {
                    if let i = swzIndex(ch) {
                        idxs.append(i)
                    } else {
                        ok = false
                        break
                    }
                }
                guard ok else {
                    failed = true
                    break
                }
                let e = v.eval
                let list = idxs
                var lv: LV? = nil
                if let base = v.lv, base.swz == nil { lv = LV(slot: base.slot, swz: list) }
                v = SVal(eval: { c in
                    let a = e(c)
                    var o = ShVec()
                    var k = 0
                    for j in list {
                        o[k] = a[j]
                        k += 1
                    }
                    return o
                }, type: lanesType(list.count), lv: lv)
                continue
            }
            if accept("[") {
                let idx = parseExpr().eval
                expect("]")
                if v.arrBase >= 0 {
                    let base = v.arrBase
                    let count = v.arrCount
                    v = SVal(eval: { c in
                        var i = Int(idx(c).x)
                        if i < 0 { i = 0 }
                        if i >= count { i = count - 1 }
                        return c.slots[base + i]
                    }, type: v.arrType)
                } else {
                    let e = v.eval
                    let n = v.type.lanes
                    v = SVal(eval: { c in
                        var i = Int(idx(c).x)
                        if i < 0 { i = 0 }
                        if i >= n { i = n - 1 }
                        return ShVec.splat(e(c)[i])
                    }, type: .f)
                }
                continue
            }
            if peek() == "++" || peek() == "--" {
                let inc = accept("++")
                if !inc { _ = accept("--") }
                guard let lv = v.lv else {
                    failed = true
                    break
                }
                let store = storeClosure(lv)
                let e = v.eval
                let d: Float = inc ? 1 : -1
                v = SVal(eval: { c in
                    let old = e(c)
                    store(c, ShVec.splat(old.x + d))
                    return old
                }, type: v.type)
                continue
            }
            break
        }
        return v
    }

    func parsePrimary() -> SVal {
        if failed { return zeroVal() }
        if pos < toks.count, toks[pos].isNum {
            let n = toks[pos].num
            pos += 1
            return SVal(eval: { _ in ShVec.splat(n) }, type: .f)
        }
        if accept("(") {
            let v = parseExpr()
            expect(")")
            return SVal(eval: v.eval, type: v.type)
        }
        if accept("true") { return SVal(eval: { _ in ShVec.splat(1) }, type: .b) }
        if accept("false") { return SVal(eval: { _ in ShVec() }, type: .b) }
        let name = ident()
        if failed { return zeroVal() }
        if peek() == "(" {
            pos += 1
            var args: [SVal] = []
            if !accept(")") {
                while !failed {
                    args.append(parseAssign())
                    if accept(",") { continue }
                    expect(")")
                    break
                }
            }
            return makeCall(name, args)
        }
        if let sIdx = prog.samplerIndex[name] {
            return SVal(eval: { _ in ShVec() }, type: .sampler, sampler: sIdx)
        }
        guard let entry = lookup(name) else {
            failed = true
            return zeroVal()
        }
        if entry.count > 1 {
            var v = zeroVal()
            v.arrBase = entry.slot
            v.arrCount = entry.count
            v.arrType = entry.type
            return v
        }
        return SVal(eval: readSlot(entry.slot), type: entry.type, lv: LV(slot: entry.slot, swz: nil))
    }

    // MARK: - calls

    func map1(_ a: SVal, _ f: @escaping (Float) -> Float) -> SVal {
        let e = a.eval
        return SVal(eval: { c in
            let v = e(c)
            return ShVec(x: f(v.x), y: f(v.y), z: f(v.z), w: f(v.w))
        }, type: a.type)
    }

    func map2(_ a: SVal, _ b: SVal, _ f: @escaping (Float, Float) -> Float) -> SVal {
        let aS = a.type.lanes == 1 && b.type.lanes > 1
        let bS = b.type.lanes == 1 && a.type.lanes > 1
        let rt = a.type.lanes >= b.type.lanes ? a.type : b.type
        let (ae, be) = (a.eval, b.eval)
        return SVal(eval: { c in
            var va = ae(c)
            var vb = be(c)
            if aS { va = ShVec.splat(va.x) }
            if bS { vb = ShVec.splat(vb.x) }
            return ShVec(x: f(va.x, vb.x), y: f(va.y, vb.y), z: f(va.z, vb.z), w: f(va.w, vb.w))
        }, type: rt)
    }

    func map3(_ a: SVal, _ b: SVal, _ d: SVal, _ f: @escaping (Float, Float, Float) -> Float) -> SVal {
        var rt = a.type
        if b.type.lanes > rt.lanes { rt = b.type }
        if d.type.lanes > rt.lanes { rt = d.type }
        let n = rt.lanes
        let aS = a.type.lanes == 1 && n > 1
        let bS = b.type.lanes == 1 && n > 1
        let dS = d.type.lanes == 1 && n > 1
        let (ae, be, de) = (a.eval, b.eval, d.eval)
        return SVal(eval: { c in
            var va = ae(c)
            var vb = be(c)
            var vd = de(c)
            if aS { va = ShVec.splat(va.x) }
            if bS { vb = ShVec.splat(vb.x) }
            if dS { vd = ShVec.splat(vd.x) }
            return ShVec(x: f(va.x, vb.x, vd.x), y: f(va.y, vb.y, vd.y), z: f(va.z, vb.z, vd.z), w: f(va.w, vb.w, vd.w))
        }, type: rt)
    }

    func dotN(_ a: SVal, _ b: SVal) -> SVal {
        let n = max(a.type.lanes, b.type.lanes)
        let (ae, be) = (a.eval, b.eval)
        return SVal(eval: { c in
            let va = ae(c)
            let vb = be(c)
            var s: Float = 0
            var i = 0
            while i < n {
                s += va[i] * vb[i]
                i += 1
            }
            return ShVec.splat(s)
        }, type: .f)
    }

    func makeCall(_ name: String, _ args: [SVal]) -> SVal {
        if failed { return zeroVal() }
        if let t = typeFor(name) {
            return makeConstructor(t, args)
        }
        switch name {
        case "SKDefaultShading":
            return SVal(eval: { c in
                let t = c.sample(0, c.texcoord.x, c.texcoord.y)
                let m = c.colormix
                return ShVec(x: t.x * m.x, y: t.y * m.y, z: t.z * m.z, w: t.w * m.w)
            }, type: .v4)
        case "texture", "texture2D", "textureLod":
            guard args.count >= 2, args[0].sampler >= 0 else {
                failed = true
                return zeroVal()
            }
            let idx = args[0].sampler
            let uvE = args[1].eval
            return SVal(eval: { c in
                let uv = uvE(c)
                return c.sample(idx, uv.x, uv.y)
            }, type: .v4)
        case "sin": return arity1(args) { self.map1($0) { SDL_sinf($0) } }
        case "cos": return arity1(args) { self.map1($0) { SDL_cosf($0) } }
        case "tan": return arity1(args) { self.map1($0) { SDL_tanf($0) } }
        case "asin": return arity1(args) { self.map1($0) { SDL_asinf($0) } }
        case "acos": return arity1(args) { self.map1($0) { SDL_acosf($0) } }
        case "atan":
            if args.count == 2 { return map2(args[0], args[1]) { SDL_atan2f($0, $1) } }
            return arity1(args) { self.map1($0) { SDL_atanf($0) } }
        case "pow":
            guard args.count == 2 else {
                failed = true
                return zeroVal()
            }
            return map2(args[0], args[1]) { SDL_powf($0, $1) }
        case "exp": return arity1(args) { self.map1($0) { SDL_expf($0) } }
        case "log": return arity1(args) { self.map1($0) { SDL_logf($0) } }
        case "exp2": return arity1(args) { self.map1($0) { SDL_powf(2, $0) } }
        case "log2": return arity1(args) { self.map1($0) { SDL_logf($0) / 0.6931472 } }
        case "sqrt": return arity1(args) { self.map1($0) { SDL_sqrtf($0) } }
        case "inversesqrt": return arity1(args) { self.map1($0) { 1 / SDL_sqrtf($0) } }
        case "abs": return arity1(args) { self.map1($0) { SDL_fabsf($0) } }
        case "sign": return arity1(args) { self.map1($0) { $0 > 0 ? 1 : ($0 < 0 ? -1 : 0) } }
        case "floor": return arity1(args) { self.map1($0) { SDL_floorf($0) } }
        case "ceil": return arity1(args) { self.map1($0) { SDL_ceilf($0) } }
        case "fract": return arity1(args) { self.map1($0) { $0 - SDL_floorf($0) } }
        case "radians": return arity1(args) { self.map1($0) { $0 * Float.pi / 180 } }
        case "degrees": return arity1(args) { self.map1($0) { $0 * 180 / Float.pi } }
        case "mod":
            guard args.count == 2 else {
                failed = true
                return zeroVal()
            }
            return map2(args[0], args[1]) { x, y in x - y * SDL_floorf(x / y) }
        case "min":
            guard args.count == 2 else {
                failed = true
                return zeroVal()
            }
            return map2(args[0], args[1]) { $0 < $1 ? $0 : $1 }
        case "max":
            guard args.count == 2 else {
                failed = true
                return zeroVal()
            }
            return map2(args[0], args[1]) { $0 > $1 ? $0 : $1 }
        case "clamp":
            guard args.count == 3 else {
                failed = true
                return zeroVal()
            }
            return map3(args[0], args[1], args[2]) { x, lo, hi in x < lo ? lo : (x > hi ? hi : x) }
        case "mix":
            guard args.count == 3 else {
                failed = true
                return zeroVal()
            }
            return map3(args[0], args[1], args[2]) { a, b, t in a + (b - a) * t }
        case "step":
            guard args.count == 2 else {
                failed = true
                return zeroVal()
            }
            return map2(args[0], args[1]) { e, x in x < e ? 0 : 1 }
        case "smoothstep":
            guard args.count == 3 else {
                failed = true
                return zeroVal()
            }
            return map3(args[0], args[1], args[2]) { e0, e1, x in
                var t = (x - e0) / (e1 - e0)
                if t < 0 { t = 0 }
                if t > 1 { t = 1 }
                return t * t * (3 - 2 * t)
            }
        case "length":
            guard args.count == 1 else {
                failed = true
                return zeroVal()
            }
            let d = dotN(args[0], args[0]).eval
            return SVal(eval: { c in ShVec.splat(SDL_sqrtf(d(c).x)) }, type: .f)
        case "distance":
            guard args.count == 2 else {
                failed = true
                return zeroVal()
            }
            let diff = makeArith(1, args[0], args[1])
            let d = dotN(diff, diff).eval
            return SVal(eval: { c in ShVec.splat(SDL_sqrtf(d(c).x)) }, type: .f)
        case "dot":
            guard args.count == 2 else {
                failed = true
                return zeroVal()
            }
            return dotN(args[0], args[1])
        case "cross":
            guard args.count == 2 else {
                failed = true
                return zeroVal()
            }
            let (ae, be) = (args[0].eval, args[1].eval)
            return SVal(eval: { c in
                let a = ae(c)
                let b = be(c)
                return ShVec(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x, w: 0)
            }, type: .v3)
        case "normalize":
            guard args.count == 1 else {
                failed = true
                return zeroVal()
            }
            let n = args[0].type.lanes
            let e = args[0].eval
            return SVal(eval: { c in
                let v = e(c)
                var s: Float = 0
                var i = 0
                while i < n {
                    s += v[i] * v[i]
                    i += 1
                }
                let len = SDL_sqrtf(s)
                if len < 0.000001 { return ShVec() }
                return ShVec(x: v.x / len, y: v.y / len, z: v.z / len, w: v.w / len)
            }, type: args[0].type)
        case "reflect":
            guard args.count == 2 else {
                failed = true
                return zeroVal()
            }
            let n = max(args[0].type.lanes, args[1].type.lanes)
            let (ie, ne) = (args[0].eval, args[1].eval)
            return SVal(eval: { c in
                let iv = ie(c)
                let nv = ne(c)
                var d: Float = 0
                var k = 0
                while k < n {
                    d += iv[k] * nv[k]
                    k += 1
                }
                let s = 2 * d
                return ShVec(x: iv.x - s * nv.x, y: iv.y - s * nv.y, z: iv.z - s * nv.z, w: iv.w - s * nv.w)
            }, type: args[0].type)
        default:
            guard let fn = fns[name], fn.paramSlots.count == args.count else {
                failed = true
                return zeroVal()
            }
            let argEs = args.map { $0.eval }
            let slots = fn.paramSlots
            let body = fn.body
            return SVal(eval: { c in
                var vals: [ShVec] = []
                vals.reserveCapacity(argEs.count)
                for e in argEs { vals.append(e(c)) }
                var i = 0
                for s in slots {
                    c.slots[s] = vals[i]
                    i += 1
                }
                let f = body(c)
                switch f {
                case .ret: return c.ret
                default: return ShVec()
                }
            }, type: fn.ret)
        }
    }

    func arity1(_ args: [SVal], _ f: (SVal) -> SVal) -> SVal {
        guard args.count == 1 else {
            failed = true
            return zeroVal()
        }
        return f(args[0])
    }

    func makeConstructor(_ t: ShType, _ args: [SVal]) -> SVal {
        guard !args.isEmpty else {
            failed = true
            return zeroVal()
        }
        if t.lanes == 1 {
            let e = args[0].eval
            if t == .i {
                return SVal(eval: { c in ShVec.splat(SDL_truncf(e(c).x)) }, type: .i)
            }
            return SVal(eval: { c in ShVec.splat(e(c).x) }, type: t)
        }
        if args.count == 1, args[0].type.lanes == 1 {
            let e = args[0].eval
            return SVal(eval: { c in ShVec.splat(e(c).x) }, type: t)
        }
        let parts = args.map { ($0.eval, $0.type.lanes) }
        return SVal(eval: { c in
            var out = ShVec()
            var k = 0
            for (e, n) in parts {
                let v = e(c)
                var i = 0
                while i < n, k < 4 {
                    out[k] = v[i]
                    k += 1
                    i += 1
                }
            }
            return out
        }, type: t)
    }
}

// MARK: - sampling

func shBilinear(_ w: Int, _ h: Int, _ px: [UInt8], _ u: Float, _ v: Float) -> ShVec {
    if w <= 0 || h <= 0 { return ShVec() }
    let fx = u * Float(w) - 0.5
    let fy = (1 - v) * Float(h) - 0.5
    let x0 = Int(SDL_floorf(fx))
    let y0 = Int(SDL_floorf(fy))
    let tx = fx - Float(x0)
    let ty = fy - Float(y0)
    func at(_ x: Int, _ y: Int) -> ShVec {
        var cx = x
        var cy = y
        if cx < 0 { cx = 0 }
        if cx > w - 1 { cx = w - 1 }
        if cy < 0 { cy = 0 }
        if cy > h - 1 { cy = h - 1 }
        let o = (cy * w + cx) * 4
        return ShVec(x: Float(px[o]) / 255, y: Float(px[o + 1]) / 255, z: Float(px[o + 2]) / 255, w: Float(px[o + 3]) / 255)
    }
    let p00 = at(x0, y0)
    let p10 = at(x0 + 1, y0)
    let p01 = at(x0, y0 + 1)
    let p11 = at(x0 + 1, y0 + 1)
    func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
    return ShVec(
        x: lerp(lerp(p00.x, p10.x, tx), lerp(p01.x, p11.x, tx), ty),
        y: lerp(lerp(p00.y, p10.y, tx), lerp(p01.y, p11.y, tx), ty),
        z: lerp(lerp(p00.z, p10.z, tx), lerp(p01.z, p11.z, tx), ty),
        w: lerp(lerp(p00.w, p10.w, tx), lerp(p01.w, p11.w, tx), ty)
    )
}

// MARK: - kit integration

extension Kit {
    func cpuPixelsFor(_ img: Int32) -> (w: Int32, h: Int32, px: [UInt8])? {
        if img <= 0 { return nil }
        if let c = cpuPixels[img] { return c }
        guard Int(img) < images.count, let rec = images[Int(img)], let tex = rec.tex, rec.w > 0, rec.h > 0 else { return nil }
        guard let tmp = SDL_CreateTexture(renderer, targetFormat, SDL_TEXTUREACCESS_TARGET, rec.w, rec.h) else { return nil }
        _ = SDL_SetTextureBlendMode(tmp, SDL_BLENDMODE_NONE)
        let prev = SDL_GetRenderTarget(renderer)
        _ = SDL_SetRenderTarget(renderer, tmp)
        _ = SDL_SetRenderDrawColorFloat(renderer, 0, 0, 0, 0)
        _ = SDL_RenderClear(renderer)
        _ = SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_NONE)
        _ = SDL_RenderTexture(renderer, tex, nil, nil)
        var rect = SDL_Rect(x: 0, y: 0, w: rec.w, h: rec.h)
        let surfOpt = SDL_RenderReadPixels(renderer, &rect)
        _ = SDL_SetRenderTarget(renderer, prev)
        _ = SDL_SetTextureBlendMode(tex, currentBlend())
        SDL_DestroyTexture(tmp)
        guard let raw = surfOpt else { return nil }
        var surf = raw
        if raw.pointee.format != SDL_PIXELFORMAT_ABGR8888 {
            guard let conv = SDL_ConvertSurface(raw, SDL_PIXELFORMAT_ABGR8888) else {
                SDL_DestroySurface(raw)
                return nil
            }
            SDL_DestroySurface(raw)
            surf = conv
        }
        guard let base = surf.pointee.pixels else {
            SDL_DestroySurface(surf)
            return nil
        }
        let p = base.assumingMemoryBound(to: UInt8.self)
        let pitch = Int(surf.pointee.pitch)
        let rowBytes = Int(rec.w) * 4
        var out = [UInt8](repeating: 0, count: Int(rec.h) * rowBytes)
        for y in 0..<Int(rec.h) {
            for x in 0..<rowBytes {
                out[y * rowBytes + x] = p[y * pitch + x]
            }
        }
        SDL_DestroySurface(surf)
        let entry = (w: rec.w, h: rec.h, px: out)
        cpuPixels[img] = entry
        return entry
    }

    // A premultiplied (rgb *= a) copy of an image's base pixels, cached, with LINEAR
    // scaling. The SCREEN blend (gfx_set_blend(3)) draws THIS instead of the straight-
    // alpha texture: with ONE_MINUS_SRC_COLOR a straight-alpha texel keeps full RGB at
    // its transparent edge (hard disc/ring that never fades to zero), but a
    // premultiplied texel's RGB -> 0 as alpha -> 0, so screen contributes nothing there
    // — the soft fade-to-zero bloom Apple SpriteKit / Canvas produce. SDL bilinear-
    // upscales this small texture to the particle footprint, exactly like Canvas
    // drawImage from the 22px source (no blocky re-raster, no rings).
    func premultipliedTex(_ img: Int32) -> UnsafeMutablePointer<SDL_Texture>? {
        if let cached = premultTex[img] { return cached }
        guard let cp = cpuPixelsFor(img) else { premultTex[img] = .some(nil); return nil }
        var px = cp.px
        var i = 0
        while i + 3 < px.count {
            let a = Int(px[i + 3])
            px[i]     = UInt8(Int(px[i])     * a / 255)
            px[i + 1] = UInt8(Int(px[i + 1]) * a / 255)
            px[i + 2] = UInt8(Int(px[i + 2]) * a / 255)
            i += 4
        }
        let tex = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STATIC, cp.w, cp.h)
        px.withUnsafeMutableBytes { raw in
            var rect = SDL_Rect(x: 0, y: 0, w: cp.w, h: cp.h)
            _ = SDL_UpdateTexture(tex, &rect, raw.baseAddress, cp.w * 4)
        }
        _ = SDL_SetTextureScaleMode(tex, SDL_SCALEMODE_LINEAR)
        premultTex[img] = .some(tex)
        return tex
    }

    func shaderPass(_ prog: ShProgram, _ srcImg: Int32, _ dx: Float, _ dy: Float, _ dw: Float, _ dh: Float, _ time: Float, _ rgba: UInt32) {
        guard dw > 0.5, dh > 0.5, let main = prog.run else { return }
        if !prog.samplerImgs.isEmpty { prog.samplerImgs[0] = srcImg }
        var texW: [Int] = []
        var texH: [Int] = []
        var texPx: [[UInt8]] = []
        for img in prog.samplerImgs {
            if let t = cpuPixelsFor(img) {
                texW.append(Int(t.w))
                texH.append(Int(t.h))
                texPx.append(t.px)
            } else {
                texW.append(0)
                texH.append(0)
                texPx.append([])
            }
        }
        let maxArea: Float = 16384
        let area = dw * dh
        let scale = area > maxArea ? SDL_sqrtf(maxArea / area) : 1
        let ew = max(1, Int(dw * scale))
        let eh = max(1, Int(dh * scale))
        let ctx = ShCtx()
        ctx.slots = prog.store
        ctx.time = time
        ctx.colormix = ShVec(
            x: Float((rgba >> 24) & 0xFF) / 255,
            y: Float((rgba >> 16) & 0xFF) / 255,
            z: Float((rgba >> 8) & 0xFF) / 255,
            w: Float(rgba & 0xFF) / 255
        )
        let tw = texW
        let th = texH
        let tp = texPx
        ctx.sample = { idx, u, v in
            guard idx >= 0, idx < tw.count else { return ShVec() }
            return shBilinear(tw[idx], th[idx], tp[idx], u, v)
        }
        for st in prog.globalInit { _ = st(ctx) }
        var out = [UInt8](repeating: 0, count: ew * eh * 4)
        let few = Float(ew)
        let feh = Float(eh)
        for py in 0..<eh {
            for px in 0..<ew {
                ctx.texcoord = ShVec(x: (Float(px) + 0.5) / few, y: 1 - (Float(py) + 0.5) / feh)
                ctx.fragcoord = ShVec(x: (Float(px) + 0.5) * dw / few, y: (feh - Float(py) - 0.5) * dh / feh, z: 0, w: 1)
                ctx.frag = ShVec()
                _ = main(ctx)
                let o = (py * ew + px) * 4
                var r = ctx.frag.x
                var g = ctx.frag.y
                var b = ctx.frag.z
                var a = ctx.frag.w
                if r < 0 { r = 0 }
                if r > 1 { r = 1 }
                if g < 0 { g = 0 }
                if g > 1 { g = 1 }
                if b < 0 { b = 0 }
                if b > 1 { b = 1 }
                if a < 0 { a = 0 }
                if a > 1 { a = 1 }
                out[o] = UInt8(r * 255)
                out[o + 1] = UInt8(g * 255)
                out[o + 2] = UInt8(b * 255)
                out[o + 3] = UInt8(a * 255)
            }
        }
        guard let tex = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STATIC, Int32(ew), Int32(eh)) else { return }
        _ = out.withUnsafeBufferPointer { SDL_UpdateTexture(tex, nil, $0.baseAddress, Int32(ew * 4)) }
        _ = SDL_SetTextureScaleMode(tex, SDL_SCALEMODE_LINEAR)
        drawTexturedQuad(tex, dx, dy, dw, dh, 0, 0, 1, 1, SDL_FColor(r: 1, g: 1, b: 1, a: alpha))
        retireTexture(tex)
    }

    func ensureLightingShader() -> ShProgram? {
        if lightingState == 2 { return nil }
        if lightingState == 1 { return shaderProgs[Int(lightingShaderId)] }
        let src = """
uniform sampler2D u_normal;
uniform vec4 u_ambient;
uniform vec4 u_lightPositions[8];
uniform vec4 u_lightColors[8];
uniform int u_lightCount;
void main() {
  vec4 base = SKDefaultShading();
  vec3 normal = vec3(0.0, 0.0, 1.0);
  vec4 nm = texture(u_normal, v_tex_coord);
  if (nm.a > 0.001) { normal = normalize(nm.xyz * 2.0 - 1.0); }
  vec3 accum = u_ambient.rgb * base.rgb;
  for (int i = 0; i < 8; i++) {
    if (i >= u_lightCount) break;
    vec3 toLight = vec3(u_lightPositions[i].xy - gl_FragCoord.xy, u_lightPositions[i].z);
    float dist = length(toLight);
    vec3 dir = normalize(toLight);
    float diff = max(dot(normal, dir), 0.0);
    float fall = 1.0 / (1.0 + u_lightColors[i].a * dist);
    accum += base.rgb * u_lightColors[i].rgb * diff * fall * u_lightPositions[i].w;
  }
  gl_FragColor = vec4(accum, base.a);
}
"""
        guard let prog = ShCompiler.compile(src) else {
            lightingState = 2
            return nil
        }
        shaderProgs.append(prog)
        lightingShaderId = Int32(shaderProgs.count - 1)
        lightingState = 1
        return prog
    }
}

// MARK: - shader abi

@_cdecl("gfx_shader_compile")
func gfx_shader_compile(_ src: UnsafePointer<CChar>?, _ len: Int32) -> Int32 {
    let k = Kit.shared
    let text = k.cString(src, len)
    guard let prog = ShCompiler.compile(text) else { return 0 }
    k.shaderProgs.append(prog)
    return Int32(k.shaderProgs.count - 1)
}

@_cdecl("gfx_shader_release")
func gfx_shader_release(_ sh: Int32) {
    let k = Kit.shared
    guard sh > 0, Int(sh) < k.shaderProgs.count else { return }
    if sh == k.lightingShaderId { return }
    k.shaderProgs[Int(sh)] = nil
}

func shProgFor(_ sh: Int32) -> ShProgram? {
    let k = Kit.shared
    guard sh > 0, Int(sh) < k.shaderProgs.count else { return nil }
    return k.shaderProgs[Int(sh)]
}

@_cdecl("gfx_shader_set_uniform_f")
func gfx_shader_set_uniform_f(_ sh: Int32, _ name: UnsafePointer<CChar>?, _ nlen: Int32, _ v: Float) {
    let k = Kit.shared
    guard let prog = shProgFor(sh), let u = prog.uniformIndex[k.cString(name, nlen)] else { return }
    prog.store[u.slot] = ShVec.splat(v)
}

@_cdecl("gfx_shader_set_uniform_v2")
func gfx_shader_set_uniform_v2(_ sh: Int32, _ name: UnsafePointer<CChar>?, _ nlen: Int32, _ x: Float, _ y: Float) {
    let k = Kit.shared
    guard let prog = shProgFor(sh), let u = prog.uniformIndex[k.cString(name, nlen)] else { return }
    prog.store[u.slot] = ShVec(x: x, y: y, z: 0, w: 0)
}

@_cdecl("gfx_shader_set_uniform_v3")
func gfx_shader_set_uniform_v3(_ sh: Int32, _ name: UnsafePointer<CChar>?, _ nlen: Int32, _ x: Float, _ y: Float, _ z: Float) {
    let k = Kit.shared
    guard let prog = shProgFor(sh), let u = prog.uniformIndex[k.cString(name, nlen)] else { return }
    prog.store[u.slot] = ShVec(x: x, y: y, z: z, w: 0)
}

@_cdecl("gfx_shader_set_uniform_v4")
func gfx_shader_set_uniform_v4(_ sh: Int32, _ name: UnsafePointer<CChar>?, _ nlen: Int32, _ x: Float, _ y: Float, _ z: Float, _ w: Float) {
    let k = Kit.shared
    guard let prog = shProgFor(sh), let u = prog.uniformIndex[k.cString(name, nlen)] else { return }
    prog.store[u.slot] = ShVec(x: x, y: y, z: z, w: w)
}

@_cdecl("gfx_shader_set_uniform_t")
func gfx_shader_set_uniform_t(_ sh: Int32, _ name: UnsafePointer<CChar>?, _ nlen: Int32, _ img: Int32) {
    let k = Kit.shared
    guard let prog = shProgFor(sh), let idx = prog.samplerIndex[k.cString(name, nlen)] else { return }
    guard idx >= 0, idx < prog.samplerImgs.count else { return }
    prog.samplerImgs[idx] = img
}

@_cdecl("gfx_shader_draw")
func gfx_shader_draw(_ sh: Int32, _ srcImg: Int32, _ dx: Float, _ dy: Float, _ dw: Float, _ dh: Float, _ time: Float, _ rgba: UInt32) {
    let k = Kit.shared
    guard let prog = shProgFor(sh) else {
        gfx_draw_image(srcImg, 0, 0, -1, -1, dx, dy, dw, dh, 0xFFFFFFFF)
        return
    }
    k.shaderPass(prog, srcImg, dx, dy, dw, dh, time, rgba)
}

@_cdecl("gfx_lighting_draw")
func gfx_lighting_draw(_ srcImg: Int32, _ normalImg: Int32, _ lights: UnsafePointer<Float>?, _ lightCount: Int32,
                       _ dx: Float, _ dy: Float, _ dw: Float, _ dh: Float, _ rgba: UInt32) {
    let k = Kit.shared
    guard let prog = k.ensureLightingShader() else { return }
    if let idx = prog.samplerIndex["u_normal"], idx < prog.samplerImgs.count {
        prog.samplerImgs[idx] = normalImg
    }
    let n = max(0, min(8, Int(lightCount)))
    if let posU = prog.uniformIndex["u_lightPositions"], let colU = prog.uniformIndex["u_lightColors"], let lights {
        for i in 0..<n {
            let b = i * 8
            prog.store[posU.slot + i] = ShVec(x: lights[b], y: lights[b + 1], z: 0, w: lights[b + 2])
            prog.store[colU.slot + i] = ShVec(x: lights[b + 4], y: lights[b + 5], z: lights[b + 6], w: lights[b + 7])
        }
    }
    if let cntU = prog.uniformIndex["u_lightCount"] {
        prog.store[cntU.slot] = ShVec.splat(Float(n))
    }
    if let ambU = prog.uniformIndex["u_ambient"] {
        prog.store[ambU.slot] = ShVec(x: 0.2, y: 0.2, z: 0.2, w: 1)
    }
    k.shaderPass(prog, srcImg, dx, dy, dw, dh, 0, rgba)
}
