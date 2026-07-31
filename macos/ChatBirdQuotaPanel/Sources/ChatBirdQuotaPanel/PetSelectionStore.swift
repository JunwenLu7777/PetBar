//
//  PetSelectionStore.swift
//  ChatBirdQuotaPanel
//
//  模块职责：读写 Codex config.toml 的 [desktop] 段，检测并设置
//  ChatBird 为当前选中的桌面宠物形象。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

enum PetSelectionStoreError: Error {
    case cannotEncodeUpdatedConfig
}

final class ChatBirdPetSelectionStore {
    private let configURL: URL

    init(configURL: URL? = nil) {
        if let configURL {
            self.configURL = configURL
            return
        }
        let environment = ProcessInfo.processInfo.environment
        let codexHome = environment["CODEX_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true).path
        self.configURL = URL(fileURLWithPath: codexHome, isDirectory: true)
            .appendingPathComponent("config.toml")
    }

    func chatBirdIsSelected() -> Bool {
        (try? chatBirdSelectionState()) ?? false
    }

    func chatBirdSelectionState() throws -> Bool {
        let text = try String(contentsOf: configURL, encoding: .utf8)
        var section = ""
        for rawLine in Self.logicalLines(in: text).map(\.body) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let sectionName = Self.parsedSectionName(in: line) {
                section = sectionName
                continue
            }
            guard section == "desktop",
                  let value = Self.selectedAvatarValue(in: rawLine)
            else {
                continue
            }
            return value == chatBirdPetAvatarID
        }
        return false
    }

    @discardableResult
    func selectChatBird() -> Bool {
        (try? selectChatBirdOrThrow()) ?? false
    }

    @discardableResult
    func selectChatBirdOrThrow() throws -> Bool {
        let original = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let updated = Self.updatingDesktopSelection(
            in: original,
            avatarID: chatBirdPetAvatarID
        )
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = updated.data(using: .utf8) else {
            throw PetSelectionStoreError.cannotEncodeUpdatedConfig
        }
        try data.write(to: configURL, options: .atomic)
        return try chatBirdSelectionState()
    }

    static func updatingDesktopSelection(in text: String, avatarID: String) -> String {
        let newline = preferredNewline(in: text)
        let selectionLine = "selected-avatar-id = \"\(avatarID)\""
        let lines = logicalLines(in: text)
        var output: [ConfigLine] = []
        var section = ""
        var desktopSeen = false
        var desktopSelectionWritten = false

        func appendSyntheticLine(_ body: String) {
            output.append(ConfigLine(body: body, newline: newline))
        }

        func appendDesktopSelectionIfNeeded() {
            guard section == "desktop", !desktopSelectionWritten else { return }
            appendSyntheticLine(selectionLine)
            desktopSelectionWritten = true
        }

        for rawLine in lines {
            let trimmed = rawLine.body.trimmingCharacters(in: .whitespaces)
            if let sectionName = Self.parsedSectionName(in: trimmed) {
                appendDesktopSelectionIfNeeded()
                section = sectionName
                if section == "desktop" {
                    desktopSeen = true
                    desktopSelectionWritten = false
                }
                output.append(rawLine)
                continue
            }

            if section == "desktop", Self.isSelectedAvatarLine(trimmed) {
                if !desktopSelectionWritten {
                    output.append(ConfigLine(
                        body: replacingSelectedAvatar(
                            in: rawLine.body,
                            with: avatarID
                        ),
                        newline: rawLine.newline
                    ))
                    desktopSelectionWritten = true
                }
                continue
            }
            output.append(rawLine)
        }

        appendDesktopSelectionIfNeeded()
        if !desktopSeen {
            if let last = output.last,
               !last.body.trimmingCharacters(in: .whitespaces).isEmpty {
                appendSyntheticLine("")
            }
            appendSyntheticLine("[desktop]")
            appendSyntheticLine(selectionLine)
        }
        return output.map { $0.body + $0.newline }.joined()
    }

    private struct ConfigLine {
        let body: String
        let newline: String
    }

    private static func preferredNewline(in text: String) -> String {
        if text.contains("\r\n") { return "\r\n" }
        if text.contains("\r") { return "\r" }
        return "\n"
    }

    private static func logicalLines(in text: String) -> [ConfigLine] {
        var lines: [ConfigLine] = []
        var current = ""
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.value == 13 || scalar.value == 10 {
                let newline: String
                let next = index + 1
                if scalar.value == 13,
                   next < scalars.count,
                   scalars[next].value == 10 {
                    newline = "\r\n"
                    index = next + 1
                } else {
                    newline = scalar.value == 13 ? "\r" : "\n"
                    index = next
                }
                lines.append(ConfigLine(body: current, newline: newline))
                current = ""
            } else {
                current.unicodeScalars.append(scalar)
                index += 1
            }
        }
        if !current.isEmpty || text.isEmpty || !text.hasSuffix("\n") && !text.hasSuffix("\r") {
            lines.append(ConfigLine(body: current, newline: ""))
        }
        return lines
    }

    private static func strippingComment(from line: String) -> String {
        var quote: Character?
        var escaped = false
        var result = ""
        for character in line {
            if escaped {
                result.append(character)
                escaped = false
                continue
            }
            if character == "\\", quote == "\"" {
                result.append(character)
                escaped = true
                continue
            }
            if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
                result.append(character)
                continue
            }
            if character == "#", quote == nil {
                break
            }
            result.append(character)
        }
        return result
    }

    private static func selectedAvatarValue(in line: String) -> String? {
        guard isSelectedAvatarLine(
            strippingComment(from: line).trimmingCharacters(in: .whitespaces)
        ),
              let equals = line.firstIndex(of: "=")
        else { return nil }
        var index = line.index(after: equals)
        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }
        guard index < line.endIndex,
              line[index] == "\"" || line[index] == "'"
        else { return nil }
        let quote = line[index]
        index = line.index(after: index)
        var value = ""
        var escaped = false
        while index < line.endIndex {
            let character = line[index]
            if escaped {
                value.append(character)
                escaped = false
            } else if character == "\\", quote == "\"" {
                escaped = true
            } else if character == quote {
                return value
            } else {
                value.append(character)
            }
            index = line.index(after: index)
        }
        return nil
    }

    private static func replacingSelectedAvatar(
        in line: String,
        with avatarID: String
    ) -> String {
        guard let equals = line.firstIndex(of: "=") else {
            return "selected-avatar-id = \"\(avatarID)\""
        }
        var valueStart = line.index(after: equals)
        while valueStart < line.endIndex, line[valueStart].isWhitespace {
            valueStart = line.index(after: valueStart)
        }
        var suffixStart = valueStart
        if valueStart < line.endIndex,
           line[valueStart] == "\"" || line[valueStart] == "'" {
            let quote = line[valueStart]
            var index = line.index(after: valueStart)
            var escaped = false
            while index < line.endIndex {
                let character = line[index]
                if escaped {
                    escaped = false
                } else if character == "\\", quote == "\"" {
                    escaped = true
                } else if character == quote {
                    suffixStart = line.index(after: index)
                    break
                }
                index = line.index(after: index)
            }
        } else if let comment = line[valueStart...].firstIndex(of: "#") {
            suffixStart = comment
        } else {
            suffixStart = line.endIndex
        }
        return "\(line[..<valueStart])\"\(avatarID)\"\(line[suffixStart...])"
    }

    private static func parsedSectionName(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["),
              let close = trimmed.firstIndex(of: "]")
        else { return nil }
        let trailing = trimmed[trimmed.index(after: close)...]
            .trimmingCharacters(in: .whitespaces)
        guard trailing.isEmpty || trailing.hasPrefix("#") else { return nil }
        return String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isSelectedAvatarLine(_ line: String) -> Bool {
        guard let equals = line.firstIndex(of: "=") else { return false }
        return line[..<equals].trimmingCharacters(in: .whitespaces) == "selected-avatar-id"
    }
}

@discardableResult
func selectChatBirdAtStartup(
    using store: ChatBirdPetSelectionStore,
    logError: (String) -> Void = { message in
        fputs("\(message)\n", stderr)
    }
) -> Bool {
    do {
        guard try store.selectChatBirdOrThrow() else {
            logError("无法在 Codex 中选中 ChatBird：写入后的配置未生效")
            return false
        }
        return true
    } catch {
        logError("无法在 Codex 中选中 ChatBird：\(error.localizedDescription)")
        return false
    }
}
