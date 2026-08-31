//
//  AntigravityQuotaClient.swift
//  ThreadHelm
//
//  模块职责：读取 Antigravity CLI（agy）的额度。
//
//  取数走 `agy -p "/quota"`。这条与 Claude 那边的 `/usage` 是同一个路子
//  ——把斜杠命令交给非交互式打印模式——但便宜得多：agy 直接输出制表符
//  分隔的四行纯文本，不带任何终端控制序列，所以不需要 openpty，也不需要
//  剥 ANSI。
//
//  实测输出（agy 1.1.22）：
//
//      Gemini Models\tWeekly Limit Remaining\t84%\t2026-09-05T06:10:03Z
//      Gemini Models\tFive Hour Limit Remaining\t10%\t2026-08-30T14:56:07Z
//      Claude and GPT models\tWeekly Limit Remaining\t100%\t2026-09-06T14:44:52Z
//      Claude and GPT models\tFive Hour Limit Remaining\t100%\t2026-08-30T19:44:52Z
//
//  列义：模型组、窗口、**剩余**百分比、重置时刻（ISO8601）。剩余而非
//  已用，与 QuotaRow.remainingPercent 同向，不需要做 100 - x 的换算。
//

import Foundation

enum AntigravityQuotaError: LocalizedError {
    case antigravityNotFound
    case authenticationRequired
    case launchFailed
    case captureFailed
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .antigravityNotFound:
            return "没有找到 Antigravity"
        case .authenticationRequired:
            return "Antigravity 尚未登录"
        case .launchFailed:
            return "无法启动 Antigravity"
        case .captureFailed:
            return "Antigravity 暂未返回额度"
        case .parseFailed:
            return "无法识别 Antigravity 额度"
        }
    }
}

struct AntigravityQuotaSnapshot: Equatable {
    let rows: [QuotaRow]
}

enum AntigravityQuotaParser {
    /// 模型组在行名里的短写。原文 "Claude and GPT models" 太长，摘要行放
    /// 不下；"Gemini Models" 是主力，短写成 Gemini。
    private static let groupAliases: [(match: String, alias: String)] = [
        ("gemini", "Gemini"),
        ("claude and gpt", "Claude·GPT"),
    ]

    private static let windowAliases: [(match: String, alias: String)] = [
        ("five hour", "5 小时"),
        ("weekly", "周额度"),
    ]

    static func requiresAuthentication(_ rawText: String) -> Bool {
        let clean = rawText.lowercased()
        return [
            "not logged in",
            "not signed in",
            "please log in",
            "please login",
            "authentication required",
            "login required",
            "run /login",
            "no credentials",
        ].contains(where: clean.contains)
    }

    static func parse(_ rawText: String) throws -> AntigravityQuotaSnapshot {
        var rows: [QuotaRow] = []
        for line in rawText.split(whereSeparator: \.isNewline) {
            if let row = quotaRow(from: String(line)) {
                rows.append(row)
            }
        }
        guard !rows.isEmpty else { throw AntigravityQuotaError.parseFailed }
        // 排序把 5 小时窗口顶到前面：摘要位只取第一行，而当下压力看的是
        // 短窗口。同窗口内保持 agy 给的模型组次序（Gemini 在前）。
        let fiveHourFirst = rows.filter { $0.name.contains("5 小时") }
        let rest = rows.filter { !$0.name.contains("5 小时") }
        return AntigravityQuotaSnapshot(rows: fiveHourFirst + rest)
    }

    /// 一行拆四列。列数不对就整行跳过——agy 在额度前后可能打别的提示，
    /// 把它们硬解析成额度行只会显示出假数字。
    private static func quotaRow(from line: String) -> QuotaRow? {
        let columns = line
            .components(separatedBy: "\t")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard columns.count == 4 else { return nil }

        let group = alias(for: columns[0], in: groupAliases)
        let window = alias(for: columns[1], in: windowAliases)
        guard let group, let window else { return nil }
        guard let percent = percentage(from: columns[2]) else { return nil }

        return QuotaRow(
            name: "\(group) \(window)",
            remainingPercent: percent,
            resetsAt: resetDate(from: columns[3])
        )
    }

    /// 认不出的模型组或窗口一律放弃这一行，而不是原样透传。agy 后端加一
    /// 组模型时，透传会把一串英文原文塞进中文面板；放弃则只是少一行，
    /// 而且 parse 全空时会明确报错，不至于悄悄显示成「额度正常」。
    private static func alias(
        for value: String,
        in table: [(match: String, alias: String)]
    ) -> String? {
        let normalized = value.lowercased()
        return table.first { normalized.contains($0.match) }?.alias
    }

    private static func percentage(from value: String) -> Int? {
        let digits = value.prefix { $0.isNumber }
        guard !digits.isEmpty, let percent = Int(digits) else { return nil }
        return min(100, max(0, percent))
    }

    private static func resetDate(from value: String) -> Date? {
        iso8601DateFormatter.date(from: value)
            ?? fractionalISO8601DateFormatter.date(from: value)
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

final class AntigravityQuotaClient {
    /// `/quota` 是一次服务端往返，实测两三秒返回。给到 20 秒是为了容忍
    /// 网络抖动，同时不至于把面板的刷新周期整个卡住。
    private static let timeout: TimeInterval = 20
    private static let maximumOutputBytes = 65_536

    func fetch(
        completion: @escaping (Result<AntigravityQuotaSnapshot, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            completion(self.fetchSynchronously())
        }
    }

    private func fetchSynchronously()
        -> Result<AntigravityQuotaSnapshot, Error>
    {
        guard let executableURL = locateAntigravityExecutable() else {
            return .failure(AntigravityQuotaError.antigravityNotFound)
        }
        let rawText: String
        do {
            rawText = try captureQuotaText(from: executableURL)
        } catch let error as AntigravityQuotaError {
            return .failure(error)
        } catch {
            return .failure(AntigravityQuotaError.captureFailed)
        }
        if AntigravityQuotaParser.requiresAuthentication(rawText) {
            return .failure(AntigravityQuotaError.authenticationRequired)
        }
        do {
            return .success(try AntigravityQuotaParser.parse(rawText))
        } catch {
            return .failure(AntigravityQuotaError.parseFailed)
        }
    }

    private func captureQuotaText(from executableURL: URL) throws -> String {
        let process = Process()
        process.executableURL = executableURL
        // --print-timeout 比我们自己的收割超时短一点，让 agy 先自己收手：
        // 它退出得干净，而被我们杀掉会在它那边留下半截会话记录。
        process.arguments = [
            "-p", "/quota",
            "--print-timeout", "15s",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // 额度查询不该继承调用方的工作目录：agy 会把不认识的目录当成新
        // 工作区，在 `~/.gemini` 下留一条只为查额度而生的会话记录。
        process.currentDirectoryURL = FileManager.default
            .homeDirectoryForCurrentUser

        do {
            try process.run()
        } catch {
            throw AntigravityQuotaError.launchFailed
        }

        let capture = captureProcessOutput(
            process: process,
            output: output.fileHandleForReading,
            timeout: Self.timeout,
            maximumOutputBytes: Self.maximumOutputBytes
        )
        guard capture.termination == .exited
            || capture.termination == .outputClosed,
            let text = String(data: capture.data, encoding: .utf8)
        else {
            throw AntigravityQuotaError.captureFailed
        }
        return text
    }
}
