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
        case expiresAt = "expires_at"
    }
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
    let credits: [CodexResetCredit]
    let availableCount: Int

    private enum CodingKeys: String, CodingKey {
        case credits
        case availableCount = "available_count"
    }
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
    let candidatePaths: [String?] = [
        environment["CLAUDE_BIN"],
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
