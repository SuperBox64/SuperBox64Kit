import KitABI

// MiniJSON: a tiny recursive-descent JSON parser, just for the .sks → JSON
// loader and the game's level data. We avoid Foundation's JSONSerialization
// because the WASI Foundation is large and we only need the trivially-typed
// result.
//
// Returns a typed `JSONValue` (no Foundation, no `Any`), so it compiles under
// Embedded Swift. Returns nil on parse failure.
public enum JSONValue {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
}

public extension JSONValue {
    var stringValue: String?  { if case .string(let s) = self { return s }; return nil }
    var doubleValue: Double?  { if case .number(let n) = self { return n }; return nil }
    var intValue:    Int?     { if case .number(let n) = self { return Int(n) }; return nil }
    var boolValue:   Bool?    { if case .bool(let b)   = self { return b }; return nil }
    var arrayValue:  [JSONValue]?          { if case .array(let a)  = self { return a }; return nil }
    var objectValue: [String: JSONValue]?  { if case .object(let o) = self { return o }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }
    subscript(_ key: String) -> JSONValue? { objectValue?[key] }
}

public func parseJSON(_ input: String) -> JSONValue? {
    var parser = JSONParser(chars: Array(input.unicodeScalars))
    parser.skipWhitespace()
    let value = parser.parseValue()
    parser.skipWhitespace()
    if !parser.atEnd { return nil }
    return value
}

private struct JSONParser {
    let chars: [Unicode.Scalar]
    var pos: Int = 0
    var atEnd: Bool { pos >= chars.count }

    mutating func skipWhitespace() {
        while pos < chars.count {
            let c = chars[pos]
            if c == " " || c == "\n" || c == "\t" || c == "\r" { pos += 1 } else { break }
        }
    }

    mutating func parseValue() -> JSONValue? {
        skipWhitespace()
        guard pos < chars.count else { return nil }
        let c = chars[pos]
        if c == "{" { return parseObject() }
        if c == "[" { return parseArray() }
        if c == "\"" { return parseString().map { .string($0) } }
        if c == "t" || c == "f" { return parseBool().map { .bool($0) } }
        if c == "n" { return parseNull() }
        return parseNumber().map { .number($0) }
    }

    mutating func parseObject() -> JSONValue? {
        pos += 1   // consume '{'
        var out: [String: JSONValue] = [:]
        skipWhitespace()
        if pos < chars.count, chars[pos] == "}" {
            pos += 1
            return .object(out)
        }
        while pos < chars.count {
            skipWhitespace()
            guard let key = parseString() else { return nil }
            skipWhitespace()
            guard pos < chars.count, chars[pos] == ":" else { return nil }
            pos += 1
            guard let v = parseValue() else { return nil }
            out[key] = v
            skipWhitespace()
            if pos < chars.count, chars[pos] == "," {
                pos += 1
                continue
            }
            if pos < chars.count, chars[pos] == "}" {
                pos += 1
                return .object(out)
            }
            return nil
        }
        return nil
    }

    mutating func parseArray() -> JSONValue? {
        pos += 1
        var out: [JSONValue] = []
        skipWhitespace()
        if pos < chars.count, chars[pos] == "]" {
            pos += 1
            return .array(out)
        }
        while pos < chars.count {
            guard let v = parseValue() else { return nil }
            out.append(v)
            skipWhitespace()
            if pos < chars.count, chars[pos] == "," {
                pos += 1
                continue
            }
            if pos < chars.count, chars[pos] == "]" {
                pos += 1
                return .array(out)
            }
            return nil
        }
        return nil
    }

    mutating func parseString() -> String? {
        guard pos < chars.count, chars[pos] == "\"" else { return nil }
        pos += 1
        var out = ""
        while pos < chars.count {
            let c = chars[pos]
            if c == "\"" {
                pos += 1
                return out
            }
            if c == "\\" {
                pos += 1
                if pos >= chars.count { return nil }
                let esc = chars[pos]
                pos += 1
                switch esc {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/":  out.append("/")
                case "b":  out.append("\u{08}")
                case "f":  out.append("\u{0C}")
                case "n":  out.append("\n")
                case "r":  out.append("\r")
                case "t":  out.append("\t")
                case "u":
                    // 4 hex digits → a UTF-16 code unit. Emoji (> U+FFFF) arrive as
                    // a surrogate PAIR (👾); a lone high surrogate is not a
                    // valid scalar (Unicode.Scalar returns nil → the char is dropped),
                    // which silently ate the fire emitter's escaped texture name.
                    // Combine a high+low surrogate pair into the real scalar.
                    if pos + 4 > chars.count { return nil }
                    var code: UInt32 = 0
                    for _ in 0..<4 {
                        let h = chars[pos]
                        pos += 1
                        let v = hexValue(h)
                        if v < 0 { return nil }
                        code = code * 16 + UInt32(v)
                    }
                    if code >= 0xD800 && code <= 0xDBFF,
                       pos + 6 <= chars.count, chars[pos] == "\\", chars[pos + 1] == "u" {
                        pos += 2
                        var lo: UInt32 = 0
                        for _ in 0..<4 {
                            let h = chars[pos]
                            pos += 1
                            let v = hexValue(h)
                            if v < 0 { return nil }
                            lo = lo * 16 + UInt32(v)
                        }
                        if lo >= 0xDC00 && lo <= 0xDFFF {
                            code = 0x10000 + ((code - 0xD800) << 10) + (lo - 0xDC00)
                        }
                    }
                    if let scalar = Unicode.Scalar(code) { out.append(Character(scalar)) }
                default: return nil
                }
                continue
            }
            out.append(Character(c))
            pos += 1
        }
        return nil
    }

    mutating func parseBool() -> Bool? {
        if matches("true")  { return true }
        if matches("false") { return false }
        return nil
    }
    mutating func parseNull() -> JSONValue? {
        if matches("null") { return .null }
        return nil
    }
    mutating func parseNumber() -> Double? {
        let start = pos
        if pos < chars.count, chars[pos] == "-" { pos += 1 }
        while pos < chars.count {
            let c = chars[pos]
            if (c >= "0" && c <= "9") || c == "." || c == "e" || c == "E" || c == "+" || c == "-" {
                pos += 1
            } else { break }
        }
        if pos == start { return nil }
        let str = String(String.UnicodeScalarView(chars[start..<pos]))
        return Double(str)
    }

    mutating func matches(_ literal: String) -> Bool {
        let lit = Array(literal.unicodeScalars)
        if pos + lit.count > chars.count { return false }
        for i in 0..<lit.count where chars[pos + i] != lit[i] { return false }
        pos += lit.count
        return true
    }
    func hexValue(_ s: Unicode.Scalar) -> Int {
        if s >= "0" && s <= "9" { return Int(s.value - 0x30) }
        if s >= "a" && s <= "f" { return Int(s.value - 0x61 + 10) }
        if s >= "A" && s <= "F" { return Int(s.value - 0x41 + 10) }
        return -1
    }
}
