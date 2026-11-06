import Foundation

/// The small TOML subset `action.toml` needs: key/value pairs, `[tables]`,
/// strings (basic and literal), integers, floats, booleans, arrays and comments.
public enum TOMLValue: Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var int: Int? { if case .int(let i) = self { return i }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [TOMLValue]? { if case .array(let a) = self { return a }; return nil }
    public var table: [String: TOMLValue]? { if case .table(let t) = self { return t }; return nil }
    public var stringArray: [String]? { array?.compactMap(\.string) }
}

public struct TOMLError: Error, CustomStringConvertible, Equatable {
    public var line: Int
    public var message: String
    public var description: String { "line \(line): \(message)" }
}

public enum TOML {
    public static func parse(_ text: String) throws -> [String: TOMLValue] {
        var p = Parser(Array(text.unicodeScalars))
        return try p.document()
    }
}

private struct Parser {
    let s: [Unicode.Scalar]
    var i = 0
    var line = 1

    init(_ s: [Unicode.Scalar]) { self.s = s }

    var atEnd: Bool { i >= s.count }
    var cur: Unicode.Scalar? { atEnd ? nil : s[i] }

    func fail(_ m: String) -> TOMLError { TOMLError(line: line, message: m) }

    mutating func advance() {
        if s[i] == "\n" { line += 1 }
        i += 1
    }

    mutating func skipSpaces() { while let c = cur, c == " " || c == "\t" { advance() } }

    mutating func skipComment() {
        if cur == "#" { while let c = cur, c != "\n" { advance() } }
    }

    /// Skips whitespace, newlines and comments (used inside arrays and between lines).
    mutating func skipBlank() {
        while let c = cur {
            if c == " " || c == "\t" || c == "\n" || c == "\r" { advance() }
            else if c == "#" { skipComment() }
            else { break }
        }
    }

    mutating func endOfLine() throws {
        skipSpaces(); skipComment()
        if cur == "\r" { advance() }
        if let c = cur, c != "\n" { throw fail("unexpected “\(c)” after value") }
    }

    mutating func document() throws -> [String: TOMLValue] {
        var root: [String: TOMLValue] = [:]
        var tablePath: [String] = []
        while true {
            skipBlank()
            guard let c = cur else { break }
            if c == "[" {
                advance()
                if cur == "[" { throw fail("arrays of tables are not supported") }
                var path: [String] = []
                repeat {
                    skipSpaces()
                    path.append(try key())
                    skipSpaces()
                    if cur == "." { advance(); continue }
                    break
                } while true
                guard cur == "]" else { throw fail("expected ]") }
                advance()
                try endOfLine()
                if Parser.get(root, path) != nil { throw fail("table [\(path.joined(separator: "."))] defined twice") }
                try Parser.set(&root, path, .table([:]), line: line)
                tablePath = path
                continue
            }
            var path = tablePath
            path.append(try key())
            skipSpaces()
            while cur == "." { advance(); skipSpaces(); path.append(try key()); skipSpaces() }
            guard cur == "=" else { throw fail("expected =") }
            advance()
            skipSpaces()
            let v = try value()
            if Parser.get(root, path) != nil { throw fail("key “\(path.joined(separator: "."))” defined twice") }
            try Parser.set(&root, path, v, line: line)
            try endOfLine()
        }
        return root
    }

    static func get(_ t: [String: TOMLValue], _ path: [String]) -> TOMLValue? {
        var cur: TOMLValue = .table(t)
        for k in path {
            guard let next = cur.table?[k] else { return nil }
            cur = next
        }
        return cur
    }

    static func set(_ t: inout [String: TOMLValue], _ path: [String], _ v: TOMLValue, line: Int) throws {
        if path.count == 1 { t[path[0]] = v; return }
        var sub: [String: TOMLValue]
        switch t[path[0]] {
        case nil: sub = [:]
        case .table(let x)?: sub = x
        default: throw TOMLError(line: line, message: "“\(path[0])” is not a table")
        }
        try set(&sub, Array(path.dropFirst()), v, line: line)
        t[path[0]] = .table(sub)
    }

    mutating func key() throws -> String {
        if cur == "\"" { return try basicString() }
        if cur == "'" { return try literalString() }
        var k = ""
        while let c = cur, CharacterSet.alphanumerics.contains(c) || c == "_" || c == "-" {
            k.unicodeScalars.append(c); advance()
        }
        if k.isEmpty { throw fail("expected a key") }
        return k
    }

    mutating func value() throws -> TOMLValue {
        guard let c = cur else { throw fail("expected a value") }
        switch c {
        case "\"": return .string(try basicString())
        case "'": return .string(try literalString())
        case "[": return try arrayValue()
        case "{": return try inlineTable()
        default: return try scalar()
        }
    }

    mutating func basicString() throws -> String {
        advance() // opening quote
        if cur == "\"" && i + 1 < s.count && s[i + 1] == "\"" { advance(); advance(); return try multilineBasic() }
        var out = ""
        while true {
            guard let c = cur else { throw fail("unterminated string") }
            if c == "\n" { throw fail("newline in string") }
            advance()
            if c == "\"" { return out }
            if c == "\\" { out.unicodeScalars.append(try escape()) } else { out.unicodeScalars.append(c) }
        }
    }

    mutating func multilineBasic() throws -> String {
        if cur == "\n" { advance() }
        var out = ""
        while true {
            guard let c = cur else { throw fail("unterminated string") }
            if c == "\"" && i + 2 < s.count && s[i + 1] == "\"" && s[i + 2] == "\"" {
                advance(); advance(); advance(); return out
            }
            advance()
            if c == "\\" { out.unicodeScalars.append(try escape()) } else { out.unicodeScalars.append(c) }
        }
    }

    mutating func escape() throws -> Unicode.Scalar {
        guard let e = cur else { throw fail("bad escape") }
        advance()
        switch e {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        case "\"": return "\""
        case "\\": return "\\"
        case "u", "U":
            let n = e == "u" ? 4 : 8
            var hex = ""
            for _ in 0..<n { guard let h = cur else { throw fail("bad unicode escape") }; hex.unicodeScalars.append(h); advance() }
            guard let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) else { throw fail("bad unicode escape") }
            return u
        default: throw fail("unknown escape \\\(e)")
        }
    }

    mutating func literalString() throws -> String {
        advance()
        var out = ""
        while true {
            guard let c = cur else { throw fail("unterminated string") }
            if c == "\n" { throw fail("newline in string") }
            advance()
            if c == "'" { return out }
            out.unicodeScalars.append(c)
        }
    }

    mutating func arrayValue() throws -> TOMLValue {
        advance()
        var items: [TOMLValue] = []
        while true {
            skipBlank()
            if cur == "]" { advance(); return .array(items) }
            items.append(try value())
            skipBlank()
            if cur == "," { advance(); continue }
            if cur == "]" { advance(); return .array(items) }
            throw fail("expected , or ] in array")
        }
    }

    mutating func inlineTable() throws -> TOMLValue {
        advance()
        var t: [String: TOMLValue] = [:]
        skipSpaces()
        if cur == "}" { advance(); return .table(t) }
        while true {
            skipSpaces()
            let k = try key()
            skipSpaces()
            guard cur == "=" else { throw fail("expected =") }
            advance(); skipSpaces()
            t[k] = try value()
            skipSpaces()
            if cur == "," { advance(); continue }
            if cur == "}" { advance(); return .table(t) }
            throw fail("expected , or } in inline table")
        }
    }

    mutating func scalar() throws -> TOMLValue {
        var tok = ""
        while let c = cur, !(c == "," || c == "]" || c == "}" || c == " " || c == "\t" || c == "\n" || c == "\r" || c == "#") {
            tok.unicodeScalars.append(c); advance()
        }
        if tok == "true" { return .bool(true) }
        if tok == "false" { return .bool(false) }
        let clean = tok.replacingOccurrences(of: "_", with: "")
        if let n = Int(clean) { return .int(n) }
        if let d = Double(clean) { return .double(d) }
        throw fail(tok.isEmpty ? "expected a value" : "can't read value “\(tok)”")
    }
}
