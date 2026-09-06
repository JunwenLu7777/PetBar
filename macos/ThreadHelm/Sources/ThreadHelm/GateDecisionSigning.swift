//
//  GateDecisionSigning.swift
//  ThreadHelm
//
//  模块职责：审批闸门 200 响应的 Ed25519 签名与校验。
//
//  威胁模型：面板下线的窗口里（崩溃、更新重启、启动竞态），本机任何
//  uid 的进程都能抢绑 127.0.0.1:27841。hook 会把令牌和完整 payload
//  POST 给「占用该端口的任何进程」，所以令牌在这个方向上没有防御力
//  ——攻击者在请求里就拿到了令牌，也能原样代答一份合法形状的 allow。
//  唯一出路是非对称签名：面板持私钥对裁决体签名，hook 只认带有效
//  签名的响应。同 uid 的攻击者不在模型内（它能改的东西包括面板本体）。
//
//  密钥生命周期：私钥（0600）与公钥（0644）都挂在 owner-only 的
//  Application Support/ThreadHelm 下。面板启动时确保密钥对存在；hook
//  端以「公钥文件存在」作为强制校验的开关——面板升级重启的间隙里
//  公钥已经落盘，新 hook 照样强制校验旧面板的签名？不：旧面板不会
//  签名，因此强约束只能是「公钥在 ⇒ 必须有有效签名」。公钥第一次
//  落盘只发生在新面板启动时，之后永久存在；旧面板时代（公钥从未
//  存在过）接受无签名响应。公钥若存在而私钥加载失败，把公钥一并
//  撤掉，维持「公钥在 ⇒ 面板会签名」的不变式，否则闸门会被自己的
//  密钥故障卡死。
//

import CryptoKit
import Darwin
import Foundation

enum GateDecisionSigning {
    static let signatureHeader = "X-ThreadHelm-Decision-Signature"

    static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/ThreadHelm",
                isDirectory: true
            )
    }

    static func privateKeyURL(directory: URL = directoryURL) -> URL {
        directory.appendingPathComponent("permission-gate-signing.key")
    }

    static func publicKeyURL(
        directory: URL = GateDecisionSigning.directoryURL
    ) -> URL {
        directory.appendingPathComponent("permission-gate-signing.pub")
    }

    /// 面板启动时调用。返回可用的签名私钥；拿不到就撤掉公钥（若在），
    /// 让 hook 端回到「不强制校验」的兼容态。
    static func ensureSigningKey(
        directory: URL = directoryURL,
        fileManager: FileManager = .default
    ) -> Curve25519.Signing.PrivateKey? {
        // 目录必须是 owner-only：公私钥同目录，目录放宽等于把私钥送人。
        if fileManager.fileExists(atPath: directory.path) {
            chmod(directory.path, S_IRWXU)
        } else {
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                fputs(
                    "gate-decision-signing: 无法创建密钥目录："
                        + "\(error.localizedDescription)\n",
                    stderr
                )
                removePublicKeyIfPresent(directory: directory, fileManager: fileManager)
                return nil
            }
        }

        let key: Curve25519.Signing.PrivateKey?
        if let data = try? Data(contentsOf: privateKeyURL(directory: directory)),
           data.count == 32,
           let loaded = try? Curve25519.Signing.PrivateKey(
               rawRepresentation: data
           ) {
            key = loaded
        } else {
            let fresh = Curve25519.Signing.PrivateKey()
            let raw = fresh.rawRepresentation
            // 以 0600 直接创建私钥文件，杜绝 0644 窗口。
            try? fileManager.removeItem(at: privateKeyURL(directory: directory))
            guard fileManager.createFile(
                atPath: privateKeyURL(directory: directory).path,
                contents: raw,
                attributes: [.posixPermissions: 0o600]
            ) else {
                fputs("gate-decision-signing: 私钥写盘失败\n", stderr)
                removePublicKeyIfPresent(directory: directory, fileManager: fileManager)
                return nil
            }
            key = fresh
        }

        guard let key,
              publishPublicKey(
                  key,
                  directory: directory,
                  fileManager: fileManager
              )
        else {
            removePublicKeyIfPresent(directory: directory, fileManager: fileManager)
            return nil
        }
        return key
    }

    /// 服务端对裁决体签名。私钥不可用时返回 nil——hook 端只在没有
    /// 公钥文件的部署上接受无签名响应（见 verify 侧的不变式）。
    static func sign(
        _ body: Data,
        privateKey: Curve25519.Signing.PrivateKey?
    ) -> String? {
        guard let privateKey,
              let signature = try? privateKey.signature(for: body)
        else { return nil }
        return signature.base64EncodedString()
    }

    private static func publishPublicKey(
        _ privateKey: Curve25519.Signing.PrivateKey,
        directory: URL,
        fileManager: FileManager
    ) -> Bool {
        let publicKey = privateKey.publicKey.rawRepresentation
        let url = publicKeyURL(directory: directory)
        if let existing = try? Data(contentsOf: url), existing == publicKey {
            return true
        }
        try? fileManager.removeItem(at: url)
        return fileManager.createFile(
            atPath: url.path,
            contents: publicKey,
            attributes: [.posixPermissions: 0o644]
        )
    }

    private static func removePublicKeyIfPresent(
        directory: URL,
        fileManager: FileManager
    ) {
        try? fileManager.removeItem(at: publicKeyURL(directory: directory))
    }
}

/// hook 端的校验。不变式：公钥文件在 ⇒ 200 裁决响应必须带有效签名，
/// 否则按「没拿到裁决」处理（各家的兜底语义接管）；公钥文件不在 ⇒
/// 接受无签名响应（旧面板兼容态）。
enum GateDecisionSignatureVerifier {
    static func loadPublicKey(
        directory: URL = GateDecisionSigning.directoryURL
    ) -> Curve25519.Signing.PublicKey? {
        guard let data = try? Data(
            contentsOf: GateDecisionSigning.publicKeyURL(directory: directory)
        ), data.count == 32
        else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }

    static func isAuthentic(
        body: Data,
        signatureHeaderValue: String?,
        publicKey: Curve25519.Signing.PublicKey? = loadPublicKey()
    ) -> Bool {
        guard let publicKey else { return true }
        guard let header = signatureHeaderValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !header.isEmpty,
              let signature = Data(base64Encoded: header)
        else { return false }
        return publicKey.isValidSignature(signature, for: body)
    }

    /// URLSession 的 allHeaderFields 大小写保持原样，做一次不区分大小
    /// 写的取值，避免依赖 CFNetwork 内部的归一化行为。
    static func signatureHeaderValue(
        from response: HTTPURLResponse
    ) -> String? {
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String,
                  key.caseInsensitiveCompare(
                      GateDecisionSigning.signatureHeader
                  ) == .orderedSame,
                  let value = value as? String
            else { continue }
            return value
        }
        return nil
    }
}
