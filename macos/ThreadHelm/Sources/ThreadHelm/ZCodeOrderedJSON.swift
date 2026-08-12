//
//  ZCodeOrderedJSON.swift
//  ThreadHelm
//
//  模块职责：在语义修改 ZCode 配置时保留用户已有 JSON object 的 key 顺序。
//  原有 key 按原顺序写回，ThreadHelm 新增的事件和 hook 字段按显式顺序追加。
//

import Foundation

enum ZCodeOrderedJSON {
    static func data(
        withJSONObject object: [String: Any],
        preservingOrderFrom originalData: Data?
    ) throws -> Data {
        let template: ZCodeJSONOrderNode?
        if let originalData {
            var parser = ZCodeJSONOrderParser(data: originalData)
            template = try parser.parse()
        } else {
            template = nil
        }
        let text = try ZCodeJSONOrderWriter().encode(
            object,
            template: template,
            path: [],
            depth: 0
        )
        guard let data = text.data(using: .utf8) else {
            throw ZCodeHookConfigurationError.invalidConfig
        }
        return data
    }
}

private indirect enum ZCodeJSONOrderNode {
    case object([(key: String, value: ZCodeJSONOrderNode)])
    case array([ZCodeJSONOrderNode])
    case scalar(Any)

    var foundationValue: Any {
        switch self {
        case let .object(entries):
            return Dictionary(uniqueKeysWithValues: entries.map {
                ($0.key, $0.value.foundationValue)
            })
        case let .array(values):
            return values.map(\.foundationValue)
        case let .scalar(value):
            return value
        }
    }
}

private struct ZCodeJSONOrderParser {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func parse() throws -> ZCodeJSONOrderNode {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else {
            throw ZCodeHookConfigurationError.invalidConfig
        }
        return value
    }

    private mutating func parseValue() throws -> ZCodeJSONOrderNode {
        skipWhitespace()
        guard let byte = currentByte else {
            throw ZCodeHookConfigurationError.invalidConfig
        }
        switch byte {
        case 0x7B:
            return try parseObject()
        case 0x5B:
            return try parseArray()
        case 0x22:
            return .scalar(try parseString())
        case 0x74:
            try consumeLiteral("true")
            return .scalar(true)
        case 0x66:
            try consumeLiteral("false")
            return .scalar(false)
        case 0x6E:
            try consumeLiteral("null")
            return .scalar(NSNull())
        default:
            return .scalar(try parseNumber())
        }
    }

    private mutating func parseObject() throws -> ZCodeJSONOrderNode {
        try consume(0x7B)
        skipWhitespace()
        if consumeIfPresent(0x7D) {
            return .object([])
        }
        var entries: [(key: String, value: ZCodeJSONOrderNode)] = []
        var seenKeys: Set<String> = []
        while true {
            skipWhitespace()
            guard currentByte == 0x22 else {
                throw ZCodeHookConfigurationError.invalidConfig
            }
            let key = try parseString()
            guard seenKeys.insert(key).inserted else {
                throw ZCodeHookConfigurationError.invalidConfig
            }
            skipWhitespace()
            try consume(0x3A)
            let value = try parseValue()
            entries.append((key, value))
            skipWhitespace()
            if consumeIfPresent(0x7D) { break }
            try consume(0x2C)
        }
        return .object(entries)
    }

    private mutating func parseArray() throws -> ZCodeJSONOrderNode {
        try consume(0x5B)
        skipWhitespace()
        if consumeIfPresent(0x5D) {
            return .array([])
        }
        var values: [ZCodeJSONOrderNode] = []
        while true {
            values.append(try parseValue())
            skipWhitespace()
            if consumeIfPresent(0x5D) { break }
            try consume(0x2C)
        }
        return .array(values)
    }

    private mutating func parseString() throws -> String {
        let start = index
        try consume(0x22)
        while let byte = currentByte {
            if byte == 0x22 {
                index += 1
                let encoded = Data(bytes[start..<index])
                guard let decoded = try? JSONSerialization.jsonObject(
                    with: Data("[".utf8) + encoded + Data("]".utf8)
                ) as? [String], let value = decoded.first
                else {
                    throw ZCodeHookConfigurationError.invalidConfig
                }
                return value
            }
            if byte == 0x5C {
                index += 1
                guard currentByte != nil else {
                    throw ZCodeHookConfigurationError.invalidConfig
                }
            } else if byte < 0x20 {
                throw ZCodeHookConfigurationError.invalidConfig
            }
            index += 1
        }
        throw ZCodeHookConfigurationError.invalidConfig
    }

    private mutating func parseNumber() throws -> Any {
        let start = index
        while let byte = currentByte,
              byte == 0x2D || byte == 0x2B || byte == 0x2E
                || (0x30...0x39).contains(byte)
                || byte == 0x45 || byte == 0x65
        {
            index += 1
        }
        guard index > start,
              let value = try? JSONSerialization.jsonObject(
                  with: Data(bytes[start..<index]),
                  options: [.fragmentsAllowed]
              )
        else {
            throw ZCodeHookConfigurationError.invalidConfig
        }
        return value
    }

    private mutating func consumeLiteral(_ literal: String) throws {
        let literalBytes = Array(literal.utf8)
        guard index + literalBytes.count <= bytes.count,
              Array(bytes[index..<(index + literalBytes.count)])
                == literalBytes
        else {
            throw ZCodeHookConfigurationError.invalidConfig
        }
        index += literalBytes.count
    }

    private mutating func consume(_ expected: UInt8) throws {
        guard consumeIfPresent(expected) else {
            throw ZCodeHookConfigurationError.invalidConfig
        }
    }

    private mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
        guard currentByte == expected else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while let byte = currentByte,
              byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        {
            index += 1
        }
    }

    private var currentByte: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }
}

private struct ZCodeJSONOrderWriter {
    private let managedHookKeys = [
        "type",
        "command",
        "args",
        "timeoutMs",
        "statusMessage",
    ]

    func encode(
        _ value: Any,
        template: ZCodeJSONOrderNode?,
        path: [String],
        depth: Int
    ) throws -> String {
        if let object = value as? [String: Any] {
            return try encodeObject(
                object,
                template: template,
                path: path,
                depth: depth
            )
        }
        if let array = value as? [Any] {
            return try encodeArray(
                array,
                template: template,
                path: path,
                depth: depth
            )
        }
        return try encodeScalar(value)
    }

    private func encodeObject(
        _ object: [String: Any],
        template: ZCodeJSONOrderNode?,
        path: [String],
        depth: Int
    ) throws -> String {
        let originalEntries: [(key: String, value: ZCodeJSONOrderNode)]
        if case let .object(entries)? = template {
            originalEntries = entries
        } else {
            originalEntries = []
        }
        let originalKeys = originalEntries.map(\.key)
        let originalKeySet = Set(originalKeys)
        let preservedKeys = originalKeys.filter { object[$0] != nil }
        let appendedKeys = orderedAppendedKeys(
            object.keys.filter { !originalKeySet.contains($0) },
            path: path
        )
        let keys = preservedKeys + appendedKeys
        guard !keys.isEmpty else { return "{}" }

        let childTemplates = Dictionary(
            uniqueKeysWithValues: originalEntries.map { ($0.key, $0.value) }
        )
        let indentation = String(repeating: "  ", count: depth + 1)
        let closingIndentation = String(repeating: "  ", count: depth)
        let fields = try keys.map { key -> String in
            guard let child = object[key] else {
                throw ZCodeHookConfigurationError.invalidConfig
            }
            let encodedKey = try encodeScalar(key)
            let encodedChild = try encode(
                child,
                template: childTemplates[key],
                path: path + [key],
                depth: depth + 1
            )
            return indentation + encodedKey + ": " + encodedChild
        }
        return "{\n" + fields.joined(separator: ",\n")
            + "\n" + closingIndentation + "}"
    }

    private func encodeArray(
        _ array: [Any],
        template: ZCodeJSONOrderNode?,
        path: [String],
        depth: Int
    ) throws -> String {
        guard !array.isEmpty else { return "[]" }
        let originalValues: [ZCodeJSONOrderNode]
        if case let .array(values)? = template {
            originalValues = values
        } else {
            originalValues = []
        }
        let templates = matchedTemplates(
            for: array,
            originalValues: originalValues
        )
        let indentation = String(repeating: "  ", count: depth + 1)
        let closingIndentation = String(repeating: "  ", count: depth)
        let fields = try zip(array, templates).map { value, childTemplate in
            indentation + (try encode(
                value,
                template: childTemplate,
                path: path,
                depth: depth + 1
            ))
        }
        return "[\n" + fields.joined(separator: ",\n")
            + "\n" + closingIndentation + "]"
    }

    private func matchedTemplates(
        for values: [Any],
        originalValues: [ZCodeJSONOrderNode]
    ) -> [ZCodeJSONOrderNode?] {
        var unused = Set(originalValues.indices)
        return values.map { value in
            if let exact = unused.first(where: {
                jsonEqual(originalValues[$0].foundationValue, value)
            }) {
                unused.remove(exact)
                return originalValues[exact]
            }
            let candidates = unused.map { index in
                (index, similarity(originalValues[index], value))
            }
            guard let best = candidates.max(by: { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0 > rhs.0 : lhs.1 < rhs.1
            }), best.1 > 0
            else { return nil }
            unused.remove(best.0)
            return originalValues[best.0]
        }
    }

    private func similarity(_ node: ZCodeJSONOrderNode, _ value: Any) -> Int {
        if jsonEqual(node.foundationValue, value) { return 1_000 }
        switch node {
        case let .object(entries):
            guard let object = value as? [String: Any] else { return 0 }
            return entries.reduce(1) { score, entry in
                guard let child = object[entry.key] else { return score }
                return score + 4 + min(similarity(entry.value, child), 20)
            }
        case let .array(nodes):
            guard let values = value as? [Any] else { return 0 }
            let exactMatches = values.filter { value in
                nodes.contains { jsonEqual($0.foundationValue, value) }
            }.count
            return 1 + exactMatches * 10
        case .scalar:
            return 0
        }
    }

    private func orderedAppendedKeys<S: Sequence>(
        _ keys: S,
        path: [String]
    ) -> [String] where S.Element == String {
        let keys = Array(keys)
        let preferred: [String]
        if path == ["hooks", "events"] {
            preferred = ZCodeHookConfiguration.managedEvents
        } else if keys.allSatisfy({ managedHookKeys.contains($0) }) {
            preferred = managedHookKeys
        } else if keys.contains("events") {
            preferred = ["events"]
        } else if keys.contains("hooks") {
            preferred = ["hooks"]
        } else {
            preferred = []
        }
        let ranks = Dictionary(uniqueKeysWithValues: preferred.enumerated().map {
            ($0.element, $0.offset)
        })
        return keys.sorted { lhs, rhs in
            let lhsRank = ranks[lhs] ?? Int.max
            let rhsRank = ranks[rhs] ?? Int.max
            return lhsRank == rhsRank ? lhs < rhs : lhsRank < rhsRank
        }
    }

    private func encodeScalar(_ value: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(
                  withJSONObject: value,
                  options: [.fragmentsAllowed, .withoutEscapingSlashes]
              ), let text = String(data: data, encoding: .utf8)
        else {
            throw ZCodeHookConfigurationError.invalidConfig
        }
        return text
    }

    private func jsonEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        guard let lhsData = try? JSONSerialization.data(
            withJSONObject: lhs,
            options: [.fragmentsAllowed, .sortedKeys]
        ), let rhsData = try? JSONSerialization.data(
            withJSONObject: rhs,
            options: [.fragmentsAllowed, .sortedKeys]
        ) else { return false }
        return lhsData == rhsData
    }
}
