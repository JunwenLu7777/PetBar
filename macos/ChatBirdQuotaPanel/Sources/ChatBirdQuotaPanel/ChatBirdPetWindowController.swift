import AppKit
import CoreGraphics
import Foundation

let chatBirdPetWindowSize = NSSize(width: 122, height: 112)

func defaultChatBirdPetFrame(
    visibleFrame: NSRect,
    petSize: NSSize = chatBirdPetWindowSize
) -> NSRect {
    NSRect(
        x: visibleFrame.maxX - petSize.width - 28,
        y: visibleFrame.minY + 28,
        width: petSize.width,
        height: petSize.height
    )
}

func clampedChatBirdPetFrame(
    _ frame: NSRect,
    visibleFrame: NSRect
) -> NSRect {
    let width = min(frame.width, visibleFrame.width)
    let height = min(frame.height, visibleFrame.height)
    return NSRect(
        x: min(
            max(frame.minX, visibleFrame.minX),
            visibleFrame.maxX - width
        ),
        y: min(
            max(frame.minY, visibleFrame.minY),
            visibleFrame.maxY - height
        ),
        width: width,
        height: height
    )
}

final class ChatBirdPetPositionPreference {
    private let defaults: UserDefaults
    private let key = "chatbird-pet-origin"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var origin: NSPoint? {
        get {
            guard let values = defaults.array(forKey: key), values.count == 2,
                  let x = values[0] as? NSNumber,
                  let y = values[1] as? NSNumber
            else { return nil }
            return NSPoint(x: x.doubleValue, y: y.doubleValue)
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: key)
                return
            }
            defaults.set([newValue.x, newValue.y], forKey: key)
        }
    }
}

func chatBirdPetAnimationFrames(bundle: Bundle = .main) -> [NSImage] {
    guard let url = bundle.url(
        forResource: "ChatBirdPetSpritesheet",
        withExtension: "webp"
    ), let sheet = NSImage(contentsOf: url) else { return [] }

    var proposedRect = NSRect(
        origin: .zero,
        size: NSSize(width: 1_536, height: 2_288)
    )
    guard let image = sheet.cgImage(
        forProposedRect: &proposedRect,
        context: nil,
        hints: nil
    ) else { return [] }

    let columns = 8
    let rows = 13
    let cellWidth = image.width / columns
    let cellHeight = image.height / rows
    return (0..<7).compactMap { column in
        let rect = CGRect(
            x: column * cellWidth,
            y: 0,
            width: cellWidth,
            height: cellHeight
        )
        guard let cropped = image.cropping(to: rect) else { return nil }
        let frame = NSImage(
            cgImage: cropped,
            size: NSSize(width: cellWidth, height: cellHeight)
        )
        frame.isTemplate = false
        frame.accessibilityDescription = "ChatBird 桌面宠物"
        return frame
    }
}

private final class ChatBirdPetView: NSView {
    var onClick: (() -> Void)?
    var onMove: (() -> Void)?
    var onDragEnded: (() -> Void)?

    private let frames: [NSImage]
    private var frameIndex = 0
    private var animationTimer: Timer?

    init(frame frameRect: NSRect, bundle: Bundle = .main) {
        frames = chatBirdPetAnimationFrames(bundle: bundle)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("ChatBird 桌面宠物")
        setAccessibilityHelp("点击打开宠物面板；拖动可移动 ChatBird")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        animationTimer?.invalidate()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !frames.isEmpty else {
            drawFallbackPet()
            return
        }
        NSGraphicsContext.current?.imageInterpolation = .high
        frames[frameIndex].draw(
            in: bounds.insetBy(dx: 2, dy: 1),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else {
            super.mouseDown(with: event)
            return
        }
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        var dragged = false

        while let next = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) {
            let currentMouse = NSEvent.mouseLocation
            switch next.type {
            case .leftMouseDragged:
                if !dragged {
                    dragged = hypot(
                        currentMouse.x - startMouse.x,
                        currentMouse.y - startMouse.y
                    ) >= 3
                }
                guard dragged else { continue }
                window.setFrameOrigin(NSPoint(
                    x: startOrigin.x + currentMouse.x - startMouse.x,
                    y: startOrigin.y + currentMouse.y - startMouse.y
                ))
                onMove?()
            case .leftMouseUp:
                if dragged {
                    onDragEnded?()
                } else {
                    onClick?()
                }
                return
            default:
                continue
            }
        }
    }

    func setAnimating(_ enabled: Bool) {
        animationTimer?.invalidate()
        animationTimer = nil
        guard enabled, frames.count > 1 else { return }
        let timer = Timer(timeInterval: 0.72, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            self.frameIndex = (self.frameIndex + 1) % self.frames.count
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func drawFallbackPet() {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 64,
            weight: .semibold
        )
        let image = NSImage(
            systemSymbolName: "bird.fill",
            accessibilityDescription: "ChatBird 桌面宠物"
        )?.withSymbolConfiguration(configuration)
        image?.isTemplate = true
        image?.draw(
            in: bounds.insetBy(dx: 20, dy: 18),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    }
}

final class ChatBirdPetWindowController {
    var onClick: (() -> Void)?
    var onMove: (() -> Void)?

    private let panel: NSPanel
    private let petView: ChatBirdPetView
    private let positionPreference: ChatBirdPetPositionPreference
    private(set) var isEnabled = false

    init(
        positionPreference: ChatBirdPetPositionPreference =
            ChatBirdPetPositionPreference(),
        bundle: Bundle = .main
    ) {
        self.positionPreference = positionPreference
        petView = ChatBirdPetView(
            frame: NSRect(origin: .zero, size: chatBirdPetWindowSize),
            bundle: bundle
        )
        panel = NSPanel(
            contentRect: petView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = petView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
        ]

        petView.onClick = { [weak self] in self?.onClick?() }
        petView.onMove = { [weak self] in self?.onMove?() }
        petView.onDragEnded = { [weak self] in
            self?.finishDragging()
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            show()
        } else {
            petView.setAnimating(false)
            panel.orderOut(nil)
        }
    }

    func show() {
        guard isEnabled,
              let screen = preferredScreen(for: positionPreference.origin)
        else { return }
        let requestedFrame: NSRect
        if let origin = positionPreference.origin {
            requestedFrame = NSRect(origin: origin, size: chatBirdPetWindowSize)
        } else {
            requestedFrame = defaultChatBirdPetFrame(
                visibleFrame: screen.visibleFrame
            )
        }
        let frame = clampedChatBirdPetFrame(
            requestedFrame,
            visibleFrame: screen.visibleFrame
        )
        panel.setFrame(frame, display: true)
        positionPreference.origin = frame.origin
        petView.setAnimating(true)
        panel.orderFrontRegardless()
    }

    func screenParametersDidChange() {
        guard isEnabled else { return }
        show()
        onMove?()
    }

    func locatedPet() -> LocatedPet? {
        guard isEnabled, panel.isVisible,
              let screen = panel.screen
                ?? dynamicIslandScreenContaining(point: panel.frame.center)
        else { return nil }
        return LocatedPet(
            overlayRect: panel.frame,
            visibleRect: panel.frame.insetBy(dx: 4, dy: 2),
            panelScale: 1,
            screen: screen,
            source: "chatbird-app-pet"
        )
    }

    func frameForSelfTest() -> NSRect { panel.frame }

    private func finishDragging() {
        guard let screen = dynamicIslandScreenContaining(
            point: panel.frame.center
        ) ?? dynamicIslandScreenContaining(point: NSEvent.mouseLocation)
        else { return }
        let frame = clampedChatBirdPetFrame(
            panel.frame,
            visibleFrame: screen.visibleFrame
        )
        panel.setFrame(frame, display: true)
        positionPreference.origin = frame.origin
        onMove?()
    }

    private func preferredScreen(for origin: NSPoint?) -> NSScreen? {
        if let origin {
            let rect = NSRect(origin: origin, size: chatBirdPetWindowSize)
            if let screen = NSScreen.screens.first(where: {
                $0.visibleFrame.intersects(rect)
            }) {
                return screen
            }
        }
        return dynamicIslandScreenContaining(point: NSEvent.mouseLocation)
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

private extension NSRect {
    var center: NSPoint {
        NSPoint(x: midX, y: midY)
    }
}
