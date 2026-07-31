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
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return false
        }
        var section = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let sectionName = Self.sectionName(in: line) {
                section = sectionName
                continue
            }
            guard section == "desktop", Self.isSelectedAvatarLine(line),
                  let quoteStart = line.firstIndex(of: "\"")
            else { continue }
            let remainder = line[line.index(after: quoteStart)...]
            guard let quoteEnd = remainder.firstIndex(of: "\"") else { continue }
            return String(remainder[..<quoteEnd]) == chatBirdPetAvatarID
        }
        return false
    }

    @discardableResult
    func selectChatBird() -> Bool {
        do {
            let original = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
            let updated = Self.updatingDesktopSelection(in: original, avatarID: chatBirdPetAvatarID)
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard let data = updated.data(using: .utf8) else { return false }
            try data.write(to: configURL, options: .atomic)
            return chatBirdIsSelected()
        } catch {
            return false
        }
    }

    static func updatingDesktopSelection(in text: String, avatarID: String) -> String {
        let selectionLine = "selected-avatar-id = \"\(avatarID)\""
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        var output: [String] = []
        var section = ""
        var desktopSeen = false
        var desktopSelectionWritten = false

        func appendDesktopSelectionIfNeeded() {
            guard section == "desktop", !desktopSelectionWritten else { return }
            output.append(selectionLine)
            desktopSelectionWritten = true
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if let sectionName = sectionName(in: trimmed) {
                appendDesktopSelectionIfNeeded()
                section = sectionName
                if section == "desktop" {
                    desktopSeen = true
                    desktopSelectionWritten = false
                }
                output.append(rawLine)
                continue
            }

            if (section.isEmpty || section == "desktop"), isSelectedAvatarLine(trimmed) {
                if section == "desktop", !desktopSelectionWritten {
                    output.append(selectionLine)
                    desktopSelectionWritten = true
                }
                continue
            }
            output.append(rawLine)
        }

        appendDesktopSelectionIfNeeded()
        if !desktopSeen {
            if let last = output.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                output.append("")
            }
            output.append("[desktop]")
            output.append(selectionLine)
        }
        return output.joined(separator: "\n") + "\n"
    }

    private static func sectionName(in line: String) -> String? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        return String(line[line.index(after: line.startIndex)..<close])
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isSelectedAvatarLine(_ line: String) -> Bool {
        guard let equals = line.firstIndex(of: "=") else { return false }
        return line[..<equals].trimmingCharacters(in: .whitespaces) == "selected-avatar-id"
    }
}
