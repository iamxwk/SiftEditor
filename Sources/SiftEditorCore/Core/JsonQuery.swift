import Foundation

/// 一个轻量级查询，可立即查找  / JSON（jmespath 的一个实用子集）。纯逻辑，与 UI 无关。
///
/// 对应语法：
/// - 字段 / 点 path: `a.b.c`，带引号 `"a b".c`
/// - 数组索引（允许负值）：`a[0]`, `a[-1]`
/// - 投影通配符：数组 `a[*].b`，对象值 `a.*`
/// - 筛选条件：`a[?k == 'v']`（比较 `== != < <= > >=`。右侧为 `'文字列'` / 数值 / `true`/`false`/`null`）
/// - 标识：空字符串 / `@`（整个文档）
///
/// 不支持（需在调用方解决）：管道 `|`、函数 `length(@)`、切片 `[1:3]`，
/// 展平 `[]`，多选 `[a,b]`。嵌套投影是近似的（聚焦于一个层级）。
enum JsonQuery {
    struct QueryError: Error { let message: String }

    /// 根据 JSON 值（`Any` 或 `JSONSerialization`）评估表达式。
    /// - Returns: 匹配值。JSON 的 null 为 `NSNull`。没有匹配项为 `NSNull`（符合 jmespath 标准）。
    /// - Throws: 语法错误：`QueryError`。
    static func evaluate(_ expression: String, on root: Any) throws -> Any {
        let steps = try parse(expression)
        var current: Projected = .single(root)
        for step in steps { current = apply(step, to: current) }
        return current.materialized
    }

    /// 该程序解析并评估字符串  / JSON，然后将结果格式化为文本，整个过程在一个不间断的过程中完成。
    /// - Returns: 格式化结果文本。无效的 JSON / 语法错误为 `QueryError`。
    static func run(_ expression: String, onJSONText text: String) throws -> String {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw QueryError(message: "invalid JSON")
        }
        let result = try evaluate(expression, on: root)
        return prettyResult(result)
    }

    /// 将结果值显示为文本。对象/数组使用 `JsonFormatter` 缩进，标量保持不变。
    static func prettyResult(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let s = value as? String { return s }   // 字符串应直接写入，无需加引号。
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "\(value)" }
        return JsonFormatter.pretty(text) ?? text
    }

    // MARK: - 中间评估表达式

    /// 在投影期间（通配符/过滤器之后），数组逐元素映射。
    private enum Projected {
        case single(Any)
        case projection([Any])

        /// 继续查看最终结果。投影结果被分组到一个数组中。
        var materialized: Any {
            switch self {
            case .single(let v): return v
            case .projection(let arr): return arr
            }
        }
    }

    // MARK: - 步骤

    private enum Step {
        case field(String)
        case index(Int)
        case arrayWildcard          // [*]
        case objectWildcard         // .*
        case filter(Comparison)     // [?lhs op rhs]
    }

    private struct Comparison {
        let lhsPath: [Step]
        let op: String
        let rhs: Operand
    }

    private enum Operand {
        case literal(Any)           // 'str' / 数値 / true / false / null
        case path([Step])           // 元素相对 path
    }

    // MARK: - 適用

    private static func apply(_ step: Step, to current: Projected) -> Projected {
        switch current {
        case .single(let v):
            return applyToSingle(step, v)
        case .projection(let arr):
            // 在投影期间，它映射到每个元素并丢弃 null（无匹配项）（符合 jmespath 标准）。
            var out: [Any] = []
            for el in arr {
                let r = applyToSingle(step, el)
                switch r {
                case .single(let rv):
                    if !(rv is NSNull) { out.append(rv) }
                case .projection(let rarr):
                    out.append(contentsOf: rarr)   // 嵌套投影通过展平进行近似。
                }
            }
            return .projection(out)
        }
    }

    private static func applyToSingle(_ step: Step, _ value: Any) -> Projected {
        switch step {
        case .field(let name):
            if let obj = value as? [String: Any] { return .single(obj[name] ?? NSNull()) }
            return .single(NSNull())
        case .index(let i):
            guard let arr = value as? [Any] else { return .single(NSNull()) }
            let idx = i < 0 ? arr.count + i : i
            return .single((idx >= 0 && idx < arr.count) ? arr[idx] : NSNull())
        case .arrayWildcard:
            guard let arr = value as? [Any] else { return .projection([]) }
            return .projection(arr)
        case .objectWildcard:
            guard let obj = value as? [String: Any] else { return .projection([]) }
            // 对象值。顺序无法保证，但可用于投影目的。
            return .projection(Array(obj.values))
        case .filter(let cmp):
            guard let arr = value as? [Any] else { return .projection([]) }
            return .projection(arr.filter { matches(cmp, element: $0) })
        }
    }

    // MARK: - 过滤器比较

    private static func matches(_ cmp: Comparison, element: Any) -> Bool {
        let lhs = (try? evaluateSteps(cmp.lhsPath, on: element)) ?? NSNull()
        let rhs: Any
        switch cmp.rhs {
        case .literal(let v): rhs = v
        case .path(let p):    rhs = (try? evaluateSteps(p, on: element)) ?? NSNull()
        }
        switch cmp.op {
        case "==": return jsonEqual(lhs, rhs)
        case "!=": return !jsonEqual(lhs, rhs)
        case "<", "<=", ">", ">=":
            guard let a = numeric(lhs), let b = numeric(rhs) else { return false }
            switch cmp.op {
            case "<":  return a < b
            case "<=": return a <= b
            case ">":  return a > b
            default:   return a >= b
            }
        default: return false
        }
    }

    private static func evaluateSteps(_ steps: [Step], on value: Any) throws -> Any {
        var current: Projected = .single(value)
        for s in steps { current = apply(s, to: current) }
        return current.materialized
    }

    private static func numeric(_ v: Any) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    private static func jsonEqual(_ a: Any, _ b: Any) -> Bool {
        if a is NSNull && b is NSNull { return true }
        if let x = a as? String, let y = b as? String { return x == y }
        if let x = numeric(a), let y = numeric(b) { return x == y }
        if let x = a as? Bool, let y = b as? Bool { return x == y }
        // 由于  NSNumber 也包含 Bool，因此 bool 与上述 numeric 出现 0/1 匹配是可以接受的。
        return false
    }

    // MARK: - 珀斯

    private static func parse(_ expression: String) throws -> [Step] {
        let expr = expression.trimmingCharacters(in: .whitespaces)
        if expr.isEmpty || expr == "@" { return [] }
        let chars = Array(expr)
        var i = 0
        let n = chars.count
        var steps: [Step] = []
        while i < n {
            let c = chars[i]
            if c == "." { i += 1; continue }        // 分隔符
            if c == "*" { steps.append(.objectWildcard); i += 1; continue }
            if c == "[" {
                let (step, next) = try parseBracket(chars, i)
                steps.append(step); i = next; continue
            }
            // 字段（带引号的 or 元素）
            let (name, next) = parseFieldName(chars, i)
            if name.isEmpty { throw QueryError(message: "unexpected '\(c)'") }
            steps.append(.field(name)); i = next
        }
        return steps
    }

    private static func parseFieldName(_ chars: [Character], _ start: Int) -> (String, Int) {
        var i = start
        let n = chars.count
        if chars[i] == "\"" {
            var name = ""; i += 1
            while i < n, chars[i] != "\"" {
                if chars[i] == "\\" && i + 1 < n { i += 1 }
                name.append(chars[i]); i += 1
            }
            i += 1   // 关闭
            return (name, i)
        }
        var name = ""
        while i < n {
            let c = chars[i]
            if c == "." || c == "[" || c == "*" { break }
            name.append(c); i += 1
        }
        return (name, i)
    }

    private static func parseBracket(_ chars: [Character], _ start: Int) throws -> (Step, Int) {
        var i = start + 1   // '[' 后跟
        let n = chars.count
        guard i < n else { throw QueryError(message: "unterminated '['") }
        if chars[i] == "*" {
            i += 1
            try expect(chars, &i, "]")
            return (.arrayWildcard, i)
        }
        if chars[i] == "?" {
            i += 1
            // 直到对应的“]”为止（忽略引号内的内容）。
            var body = ""
            while i < n {
                let c = chars[i]
                if c == "'" {
                    body.append(c); i += 1
                    while i < n, chars[i] != "'" { body.append(chars[i]); i += 1 }
                    if i < n { body.append(chars[i]); i += 1 }   // 关闭
                    continue
                }
                if c == "]" { break }
                body.append(c); i += 1
            }
            try expect(chars, &i, "]")
            return (.filter(try parseComparison(body)), i)
        }
        // 整数索引（允许负值）。
        var num = ""
        if i < n, chars[i] == "-" { num.append("-"); i += 1 }
        while i < n, chars[i].isNumber { num.append(chars[i]); i += 1 }
        guard let idx = Int(num) else { throw QueryError(message: "invalid index") }
        try expect(chars, &i, "]")
        return (.index(idx), i)
    }

    private static func expect(_ chars: [Character], _ i: inout Int, _ c: Character) throws {
        guard i < chars.count, chars[i] == c else { throw QueryError(message: "expected '\(c)'") }
        i += 1
    }

    private static func parseComparison(_ body: String) throws -> Comparison {
        // 搜索顶层（引号外）比较运算符。较长的运算符应优先列出。
        let ops = ["==", "!=", "<=", ">=", "<", ">"]
        let chars = Array(body)
        var i = 0
        let n = chars.count
        var inQuote = false
        while i < n {
            let c = chars[i]
            if c == "'" { inQuote.toggle(); i += 1; continue }
            if !inQuote {
                for op in ops where matchOp(chars, i, op) {
                    let lhs = String(chars[0..<i]).trimmingCharacters(in: .whitespaces)
                    let rhs = String(chars[(i + op.count)...]).trimmingCharacters(in: .whitespaces)
                    return Comparison(lhsPath: try parse(lhs), op: op, rhs: try parseOperand(rhs))
                }
            }
            i += 1
        }
        throw QueryError(message: "filter needs a comparator")
    }

    private static func matchOp(_ chars: [Character], _ i: Int, _ op: String) -> Bool {
        let o = Array(op)
        guard i + o.count <= chars.count else { return false }
        for k in 0..<o.count where chars[i + k] != o[k] { return false }
        return true
    }

    private static func parseOperand(_ s: String) throws -> Operand {
        if s.hasPrefix("'") && s.hasSuffix("'") && s.count >= 2 {
            return .literal(String(s.dropFirst().dropLast()))
        }
        if s == "true" { return .literal(true) }
        if s == "false" { return .literal(false) }
        if s == "null" { return .literal(NSNull()) }
        if let d = Double(s) { return .literal(d) }
        // 否则，元素相对 path。
        return .path(try parse(s))
    }
}
