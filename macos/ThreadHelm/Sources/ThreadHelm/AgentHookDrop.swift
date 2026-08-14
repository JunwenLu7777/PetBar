//
//  AgentHookDrop.swift
//  ThreadHelm
//
//  模块职责：Cursor 等厂商 hook 进程可能继承沙箱，连不上
//  Application Support 里的 Unix socket。把未送达的脱敏 envelope
//  落到 ~/.cursor 下的 owner-only 文件，由常驻面板读取。
//

import Darwin
import Foundation

enum AgentHookDropContract {
    static let directoryName = "threadhelm-hook-drop"
}

func agentHookDropDirectoryURL(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
) -> URL {
    homeDirectory
        .appendingPathComponent(".cursor", isDirectory: true)
        .appendingPathComponent(
            AgentHookDropContract.directoryName,
            isDirectory: true
        )
        .standardizedFileURL
}

@discardableResult
func persistUndeliveredAgentHookEnvelope(
    _ envelope: AgentTransportEnvelope,
    directory: URL = agentHookDropDirectoryURL()
) -> Bool {
    guard let encoding = try? AgentTransportEncoder.encode(envelope),
          !encoding.wasReducedToMetadata,
          encoding.data.count <= AgentTransportContract.maximumSerializedBytes
    else { return false }
    let manager = FileManager.default
    do {
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(directory.path, S_IRWXU) == 0 else { return false }
        let fileURL = directory.appendingPathComponent(
            "\(envelope.eventID).json"
        )
        let stagingURL = directory.appendingPathComponent(
            ".\(envelope.eventID).json.staging"
        )
        try encoding.data.write(to: stagingURL, options: .atomic)
        guard chmod(stagingURL.path, S_IRUSR | S_IWUSR) == 0,
              rename(stagingURL.path, fileURL.path) == 0
        else {
            try? manager.removeItem(at: stagingURL)
            return false
        }
        return true
    } catch {
        return false
    }
}

func drainAgentHookDropInbox(
    directory: URL = agentHookDropDirectoryURL()
) -> [AgentTransportEnvelope] {
    let manager = FileManager.default
    guard let names = try? manager.contentsOfDirectory(atPath: directory.path)
    else { return [] }
    var envelopes: [AgentTransportEnvelope] = []
    for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
        let fileURL = directory.appendingPathComponent(name)
        defer { try? manager.removeItem(at: fileURL) }
        guard agentHookDropFileIsOwnerOnly(at: fileURL),
              let data = try? Data(contentsOf: fileURL),
              data.count <= AgentTransportContract.maximumSerializedBytes,
              let decoded = try? JSONDecoder().decode(
                  AgentTransportEnvelope.self,
                  from: data
              ),
              let encoding = try? AgentTransportEncoder.encode(decoded),
              !encoding.wasReducedToMetadata
        else { continue }
        envelopes.append(decoded)
    }
    return envelopes
}

private func agentHookDropFileIsOwnerOnly(at url: URL) -> Bool {
    var statBuffer = stat()
    return lstat(url.path, &statBuffer) == 0
        && statBuffer.st_uid == geteuid()
        && (statBuffer.st_mode & S_IFMT) == S_IFREG
        && (statBuffer.st_mode & S_IRWXG) == 0
        && (statBuffer.st_mode & S_IRWXO) == 0
        && (statBuffer.st_mode & (S_IRUSR | S_IWUSR)) == (S_IRUSR | S_IWUSR)
}
