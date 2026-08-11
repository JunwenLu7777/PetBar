//
//  GlobalHotKey.swift
//  ChatBirdQuotaPanel
//
//  模块职责：注册不依赖当前显示器或菜单栏可见性的全局显示/隐藏快捷键。
//

import AppKit
import Carbon

let chatBirdVisibilityHotKeyKeyEquivalent = "b"
let chatBirdVisibilityHotKeyModifierMask: NSEvent.ModifierFlags = [
    .command,
    .option,
]
let chatBirdVisibilityHotKeyDisplayName = "⌥⌘B"

private let chatBirdVisibilityHotKeySignature: OSType = 0x43425652 // CBVR

final class ChatBirdVisibilityHotKey {
    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private let action: () -> Void

    init?(action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var installedHandler: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handleChatBirdVisibilityHotKey,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &installedHandler
        )
        guard handlerStatus == noErr, let installedHandler else {
            return nil
        }
        eventHandlerRef = installedHandler

        var hotKeyID = EventHotKeyID(
            signature: chatBirdVisibilityHotKeySignature,
            id: 1
        )
        var registeredHotKey: EventHotKeyRef?
        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_B),
            UInt32(cmdKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )
        guard registrationStatus == noErr, let registeredHotKey else {
            RemoveEventHandler(installedHandler)
            eventHandlerRef = nil
            return nil
        }
        hotKeyRef = registeredHotKey
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    fileprivate func invoke() {
        DispatchQueue.main.async { [weak self] in
            self?.action()
        }
    }
}

private func handleChatBirdVisibilityHotKey(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else {
        return OSStatus(eventNotHandledErr)
    }
    Unmanaged<ChatBirdVisibilityHotKey>
        .fromOpaque(userData)
        .takeUnretainedValue()
        .invoke()
    return noErr
}
