//
//  QuotaModels.swift
//  ChatBirdQuotaPanel
//
//  模块职责：额度数据模型（限流窗口、重置额度、RPC 响应）、额度提供方
//  枚举与偏好存储，以及 Claude 可执行文件定位。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

struct RateLimitWindow: Decodable {
    let usedPercent: Int
    let windowDurationMins: Int64?
    let resetsAt: Int64?
}

struct SpendControlLimit: Decodable {
    let remainingPercent: Int
    let resetsAt: Int64
}

struct RateLimitSnapshot: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let individualLimit: SpendControlLimit?
}

struct RateLimitsResult: Decodable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
    let rateLimitResetCredits: CodexResetCreditsResponse?
}

enum CodexResetCreditStatus: Equatable, Decodable {
    case available
    case other(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = value == "available" ? .available : .other(value)
    }
}

struct CodexResetCredit: Equatable, Decodable {
    let id: String
    let status: CodexResetCreditStatus
    let expiresAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case status
        case expiresAt
        case legacyExpiresAt = "expires_at"
    }

    init(
        id: String,
        status: CodexResetCreditStatus,
        expiresAt: Date?
    ) {
        self.id = id
        self.status = status
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        status = try container.decode(CodexResetCreditStatus.self, forKey: .status)

        if let timestamp = try container.decodeIfPresent(Int64.self, forKey: .expiresAt) {
            expiresAt = Date(timeIntervalSince1970: TimeInterval(timestamp))
        } else {
            expiresAt = try Self.decodeLegacyExpiresAt(from: container)
        }
    }

    private static func decodeLegacyExpiresAt(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Date? {
        guard container.contains(.legacyExpiresAt) else { return nil }
        if let value = try? container.decode(String.self, forKey: .legacyExpiresAt) {
            if let date = Self.iso8601DateFormatter.date(from: value)
                ?? Self.fractionalISO8601DateFormatter.date(from: value)
            {
                return date
            }
            throw DecodingError.dataCorruptedError(
                forKey: .legacyExpiresAt,
                in: container,
                debugDescription: "expires_at must be an ISO8601 date string"
            )
        }
        return try container.decodeIfPresent(Date.self, forKey: .legacyExpiresAt)
    }

    private static let iso8601DateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fractionalISO8601DateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter
    }()
}

struct CodexResetCreditsSnapshot: Equatable {
    let credits: [CodexResetCredit]
    let reportedAvailableCount: Int
    let updatedAt: Date

    func availableCredits(at date: Date) -> [CodexResetCredit] {
        credits
            .filter { credit in
                credit.status == .available
                    && (credit.expiresAt.map { $0 > date } ?? true)
            }
            .sorted { lhs, rhs in
                switch (lhs.expiresAt, rhs.expiresAt) {
                case let (left?, right?):
                    if left != right { return left < right }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
                return lhs.id < rhs.id
            }
    }
}

struct CodexResetCreditsResponse: Decodable {
    let credits: [CodexResetCredit]?
    let availableCount: Int

    private enum CodingKeys: String, CodingKey {
        case credits
        case availableCount
        case legacyAvailableCount = "available_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        credits = try container.decodeIfPresent([CodexResetCredit].self, forKey: .credits)
        if let count = try container.decodeIfPresent(Int.self, forKey: .availableCount) {
            availableCount = count
        } else {
            availableCount = try container.decode(Int.self, forKey: .legacyAvailableCount)
        }
    }
}

func makeCodexResetCreditsSnapshot(
    from response: RateLimitsResult,
    now: Date = Date()
) -> CodexResetCreditsSnapshot? {
    guard let summary = response.rateLimitResetCredits,
          summary.availableCount >= 0
    else { return nil }
    return CodexResetCreditsSnapshot(
        credits: summary.credits ?? [],
        reportedAvailableCount: summary.availableCount,
        updatedAt: now
    )
}

struct RPCError: Decodable {
    let message: String
}

struct RPCResponse: Decodable {
    let id: Int?
    let result: RateLimitsResult?
    let error: RPCError?
}

enum QuotaProvider: String, CaseIterable {
    case codex
    case claudeCode

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claudeCode:
            return "Claude Code"
        }
    }

    var summaryRowName: String {
        switch self {
        case .codex:
            return "周额度"
        case .claudeCode:
            return "5 小时"
        }
    }

    var summaryWindowName: String {
        switch self {
        case .codex:
            return "周"
        case .claudeCode:
            return "5h"
        }
    }

    var iconResourceName: String {
        switch self {
        case .codex:
            return "ProviderIcon-codex"
        case .claudeCode:
            return "ProviderIcon-claude"
        }
    }

    var fallbackSymbolName: String {
        switch self {
        case .codex:
            return "sparkles"
        case .claudeCode:
            return "terminal"
        }
    }
}

func quotaProviders(claudeCodeAvailable: Bool) -> [QuotaProvider] {
    claudeCodeAvailable ? QuotaProvider.allCases : [.codex]
}

func resolvedQuotaProvider(
    preferred: QuotaProvider,
    availableProviders: [QuotaProvider]
) -> QuotaProvider {
    if availableProviders.contains(preferred) {
        return preferred
    }
    if availableProviders.contains(.codex) {
        return .codex
    }
    return availableProviders.first ?? .codex
}

func locateClaudeExecutable(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    isExecutableFile: (String) -> Bool = {
        FileManager.default.isExecutableFile(atPath: $0)
    }
) -> URL? {
    let pathCandidates = executablePaths(
        named: "claude",
        pathEnvironment: environment["PATH"]
    )
    let candidatePaths: [String?] = [
        environment["CLAUDE_BIN"],
    ] + pathCandidates.map(Optional.some) + [
        homeDirectory.appendingPathComponent(".local/bin/claude").path,
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]
    let candidates: [String] = candidatePaths.compactMap { path -> String? in
        guard let path, !path.isEmpty else { return nil }
        return path
    }
    return candidates.first(where: isExecutableFile)
        .map(URL.init(fileURLWithPath:))
}

func locateCodexExecutable(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    isExecutableFile: (String) -> Bool = {
        FileManager.default.isExecutableFile(atPath: $0)
    }
) -> URL? {
    let pathCandidates = executablePaths(
        named: "codex",
        pathEnvironment: environment["PATH"]
    )
    let candidatePaths: [String?] = [
        environment["CODEX_BIN"],
    ] + pathCandidates.map(Optional.some) + [
        homeDirectory.appendingPathComponent(".local/bin/codex").path,
        homeDirectory
            .appendingPathComponent(".codex/packages/standalone/current/bin/codex")
            .path,
        homeDirectory
            .appendingPathComponent("Applications/Codex.app/Contents/Resources/codex")
            .path,
        homeDirectory
            .appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex")
            .path,
        "/Applications/Codex.app/Contents/Resources/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
    ]
    let candidates = candidatePaths.compactMap { path -> String? in
        guard let path, !path.isEmpty else { return nil }
        return path
    }
    return candidates.first(where: isExecutableFile)
        .map(URL.init(fileURLWithPath:))
}

private func executablePaths(
    named executableName: String,
    pathEnvironment: String?
) -> [String] {
    guard let pathEnvironment, !pathEnvironment.isEmpty else { return [] }
    return pathEnvironment
        .split(separator: ":", omittingEmptySubsequences: true)
        .map {
            URL(fileURLWithPath: String($0), isDirectory: true)
                .appendingPathComponent(executableName)
                .path
        }
}

final class QuotaProviderPreference {
    private let defaults: UserDefaults
    private let key = "selected-quota-provider"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedProvider: QuotaProvider {
        get {
            guard let rawValue = defaults.string(forKey: key),
                  let provider = QuotaProvider(rawValue: rawValue)
            else { return .codex }
            return provider
        }
        set {
            defaults.set(newValue.rawValue, forKey: key)
        }
    }
}

struct QuotaRow: Equatable {
    let name: String
    let remainingPercent: Int
    let resetsAt: Date?
    let resetDescription: String?

    init(
        name: String,
        remainingPercent: Int,
        resetsAt: Date?,
        resetDescription: String? = nil
    ) {
        self.name = name
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
    }
}
