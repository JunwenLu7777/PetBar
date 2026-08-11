//
//  PetWindowLocator.swift
//  ChatBirdQuotaPanel
//
//  模块职责：宠物窗口定位器——基于 CGWindow 列表与 Codex 持久化状态
//  文件的多策略定位（mascot effect 配对、泛用窗口评分、可视像素探针、
//  存档回退），并输出面板缩放与可见区域。含缩放自测。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

func shouldUseStoredPetPosition(
    overlayOpen: Bool?,
    allowClosedOverlay: Bool
) -> Bool {
    allowClosedOverlay || overlayOpen != false
}

final class PetWindowLocator {
    private struct NamedWindow {
        let id: CGWindowID
        let rect: CGRect
        let name: String
        let layer: Int
    }

    private struct MascotEffectWindowPair {
        let effect: NamedWindow
        let anchor: NamedWindow
    }

    private struct StoredMascotMetrics {
        let left: CGFloat
        let top: CGFloat
        let width: CGFloat
        let height: CGFloat
        let topPadding: CGFloat
        let source: String
    }

    private struct StoredOverlayLocation {
        let rect: CGRect
        let mascot: StoredMascotMetrics?
        let isPrimary: Bool
    }

    private struct MatchedMascotMetrics {
        let metrics: StoredMascotMetrics
        let referenceSize: CGSize
    }

    private var cachedWindowID: CGWindowID?
    private var cachedMascotMetrics: StoredMascotMetrics?
    private var cachedOverlaySize: CGSize?
    private var cachedVisualMetrics: StoredMascotMetrics?
    private var cachedVisualOverlaySize: CGSize?
    private var cachedVisualWindowID: CGWindowID?
    private var cachedMascotEffectWindowID: CGWindowID?
    private var cachedMascotAnchorWindowID: CGWindowID?
    private var lastMascotEffectDiscoveryAt: CFAbsoluteTime = 0
    private var lastVisualProbeAt: CFAbsoluteTime = 0
    private var lastOverlayStateReadAt: CFAbsoluteTime = 0
    private var lastOverlayStateFileSignature: OverlayStateFileSignature?
    private var storedOverlayLocations: [StoredOverlayLocation] = []
    private(set) var overlayOpen: Bool?

    func locate() -> LocatedPet? {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastOverlayStateReadAt >= overlayStateRefreshInterval {
            lastOverlayStateReadAt = now
            refreshStoredOverlayState()
        }

        if let effectID = cachedMascotEffectWindowID,
           let anchorID = cachedMascotAnchorWindowID,
           let effectWindow = windowInfo(including: effectID),
           let anchorWindow = windowInfo(including: anchorID),
           let effect = namedWindow(from: effectWindow),
           let anchor = namedWindow(from: anchorWindow),
           let location = makeMascotEffectLocation(effectRect: effect.rect, anchorRect: anchor.rect)
        {
            return location
        }
        cachedMascotEffectWindowID = nil
        cachedMascotAnchorWindowID = nil

        var discoveredWindows: [[String: Any]]?
        if shouldDiscoverMascotEffectWindows(
            now: now,
            lastDiscoveryAt: lastMascotEffectDiscoveryAt,
            hasCachedGenericWindow: cachedWindowID != nil
        ) {
            lastMascotEffectDiscoveryAt = now
            let options: CGWindowListOption = [
                .optionOnScreenOnly,
                .excludeDesktopElements,
            ]
            discoveredWindows = CGWindowListCopyWindowInfo(
                options,
                kCGNullWindowID
            ) as? [[String: Any]]
            if let discoveredWindows,
               let location = cacheMascotEffectLocation(in: discoveredWindows)
            {
                return location
            }
        }

        if let cachedWindowID,
           let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, cachedWindowID) as? [[String: Any]],
           let window = windows.first,
           let candidate = candidate(from: window),
           let location = makeLocation(from: candidate.rect, windowID: cachedWindowID)
        {
            return location
        }

        cachedWindowID = nil
        let windows: [[String: Any]]
        if let discoveredWindows {
            windows = discoveredWindows
        } else {
            let options: CGWindowListOption = [
                .optionOnScreenOnly,
                .excludeDesktopElements,
            ]
            lastMascotEffectDiscoveryAt = now
            guard let currentWindows = CGWindowListCopyWindowInfo(
                options,
                kCGNullWindowID
            ) as? [[String: Any]] else {
                return storedOverlayLocation()
            }
            windows = currentWindows
        }

        if let location = cacheMascotEffectLocation(in: windows) {
            return location
        }

        let candidates: [(id: CGWindowID, rect: CGRect, score: Double)] = windows.compactMap { window in
            guard let number = window[kCGWindowNumber as String] as? NSNumber,
                  let candidate = candidate(from: window)
            else { return nil }
            return (number.uint32Value, candidate.rect, candidate.score)
        }

        guard let best = candidates.min(by: { $0.score < $1.score }) else {
            return storedOverlayLocation()
        }
        cachedWindowID = best.id
        return makeLocation(from: best.rect, windowID: best.id) ?? storedOverlayLocation()
    }

    private func cacheMascotEffectLocation(
        in windows: [[String: Any]]
    ) -> LocatedPet? {
        guard let pair = mascotEffectWindowPair(in: windows),
              let location = makeMascotEffectLocation(
                  effectRect: pair.effect.rect,
                  anchorRect: pair.anchor.rect
              )
        else { return nil }
        cachedWindowID = nil
        cachedMascotEffectWindowID = pair.effect.id
        cachedMascotAnchorWindowID = pair.anchor.id
        return location
    }

    func locateSavedState(
        allowClosedOverlay: Bool = false,
        preferredDisplayID: CGDirectDisplayID? = nil
    ) -> LocatedPet? {
        refreshStoredOverlayState()
        return storedOverlayLocation(
            allowClosedOverlay: allowClosedOverlay,
            preferredDisplayID: preferredDisplayID
        )
    }

    private func windowInfo(including windowID: CGWindowID) -> [String: Any]? {
        (CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]])?
            .first
    }

    private func namedWindow(from window: [String: Any]) -> NamedWindow? {
        guard let number = window[kCGWindowNumber as String] as? NSNumber,
              let ownerName = window[kCGWindowOwnerName as String] as? String,
              let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
              layer >= 0,
              layer < 50,
              let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
              alpha > 0.05,
              let rawBounds = window[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: rawBounds)
        else { return nil }

        let normalizedOwner = ownerName.lowercased()
        guard normalizedOwner.contains("codex") || normalizedOwner.contains("chatgpt") else {
            return nil
        }
        return NamedWindow(
            id: number.uint32Value,
            rect: rect,
            name: window[kCGWindowName as String] as? String ?? "",
            layer: layer
        )
    }

    private func mascotEffectWindowPair(
        in windows: [[String: Any]]
    ) -> MascotEffectWindowPair? {
        let named = windows.compactMap(namedWindow(from:))
        let effects = named.filter {
            isMascotEffectWindow(name: $0.name, layer: $0.layer, rect: $0.rect)
        }
        let anchors = named.filter {
            isMascotAnchorWindow(name: $0.name, layer: $0.layer, rect: $0.rect)
        }

        return effects.flatMap { effect in
            anchors.compactMap { anchor -> (MascotEffectWindowPair, CGFloat)? in
                guard mascotEffectPetGeometry(
                    effectRect: effect.rect,
                    anchorRect: anchor.rect
                ) != nil else { return nil }
                return (
                    MascotEffectWindowPair(effect: effect, anchor: anchor),
                    hypot(effect.rect.midX - anchor.rect.midX, effect.rect.minY - anchor.rect.minY)
                )
            }
        }
        .min(by: { $0.1 < $1.1 })?
        .0
    }

    private func makeMascotEffectLocation(
        effectRect: CGRect,
        anchorRect: CGRect
    ) -> LocatedPet? {
        guard let geometry = mascotEffectPetGeometry(
            effectRect: effectRect,
            anchorRect: anchorRect
        ),
        let convertedEffect = convertToAppKit(effectRect),
        let convertedVisible = convertToAppKit(geometry.visibleRect),
        convertedEffect.1 == convertedVisible.1
        else { return nil }

        return LocatedPet(
            overlayRect: convertedEffect.0,
            visibleRect: convertedVisible.0,
            panelScale: geometry.scale,
            screen: convertedEffect.1,
            source: "window-mascot-effect"
        )
    }

    private func makeLocation(from quartzRect: CGRect, windowID: CGWindowID) -> LocatedPet? {
        guard let converted = convertToAppKit(quartzRect) else { return nil }
        let visualMetrics = currentVisualMetrics(
            windowID: windowID,
            overlayRect: quartzRect
        )

        if let matched = bestStoredMetrics(matching: quartzRect),
           let quartzMetrics = scaledMetrics(matched.metrics, from: matched.referenceSize, to: quartzRect.size),
           let appMetrics = scaledMetrics(quartzMetrics, from: quartzRect.size, to: converted.0.size)
        {
            cachedMascotMetrics = quartzMetrics
            cachedOverlaySize = quartzRect.size
            if let visualMetrics,
               let appVisualMetrics = scaledMetrics(
                   visualMetrics,
                   from: quartzRect.size,
                   to: converted.0.size
               )
            {
                return LocatedPet(
                    overlayRect: converted.0,
                    visibleRect: visibleRect(in: converted.0, metrics: appVisualMetrics),
                    panelScale: reconciledPanelScale(
                        anchorMetrics: quartzMetrics,
                        visualMetrics: visualMetrics
                    ),
                    screen: converted.1,
                    source: "window-visual-probe"
                )
            }
            return LocatedPet(
                overlayRect: converted.0,
                visibleRect: visibleRect(in: converted.0, metrics: appMetrics),
                panelScale: panelScale(for: quartzMetrics),
                screen: converted.1,
                source: "window-\(quartzMetrics.source)"
            )
        }

        // Keep the last verified relative anchor during the few milliseconds
        // between the live window moving and Codex persisting its new bounds.
        if let cachedMascotMetrics,
           let cachedOverlaySize,
           let quartzMetrics = scaledMetrics(cachedMascotMetrics, from: cachedOverlaySize, to: quartzRect.size),
           let appMetrics = scaledMetrics(quartzMetrics, from: quartzRect.size, to: converted.0.size)
        {
            self.cachedMascotMetrics = quartzMetrics
            self.cachedOverlaySize = quartzRect.size
            if let visualMetrics,
               let appVisualMetrics = scaledMetrics(
                   visualMetrics,
                   from: quartzRect.size,
                   to: converted.0.size
               )
            {
                return LocatedPet(
                    overlayRect: converted.0,
                    visibleRect: visibleRect(in: converted.0, metrics: appVisualMetrics),
                    panelScale: reconciledPanelScale(
                        anchorMetrics: quartzMetrics,
                        visualMetrics: visualMetrics
                    ),
                    screen: converted.1,
                    source: "window-visual-probe-cached-anchor"
                )
            }
            return LocatedPet(
                overlayRect: converted.0,
                visibleRect: visibleRect(in: converted.0, metrics: appMetrics),
                panelScale: panelScale(for: quartzMetrics),
                screen: converted.1,
                source: "window-cached-anchor"
            )
        }

        if let visualMetrics,
           let appVisualMetrics = scaledMetrics(
               visualMetrics,
               from: quartzRect.size,
               to: converted.0.size
           )
        {
            return LocatedPet(
                overlayRect: converted.0,
                visibleRect: visibleRect(in: converted.0, metrics: appVisualMetrics),
                panelScale: visualPanelScale(for: visualMetrics),
                screen: converted.1,
                source: "window-visual-probe-only"
            )
        }

        return nil
    }

    private func refreshStoredOverlayState() {
        let stateURL: URL
        if let override = ProcessInfo.processInfo.environment["CHATBIRD_CODEX_STATE_FILE"],
           !override.isEmpty
        {
            stateURL = URL(fileURLWithPath: override)
        } else {
            stateURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/.codex-global-state.json")
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: stateURL.path)
        let signature = attributes.flatMap(OverlayStateFileSignature.init(attributes:))
        if !overlayStateNeedsReload(
            previous: lastOverlayStateFileSignature,
            current: signature
        ) {
            return
        }
        guard let data = try? Data(contentsOf: stateURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        lastOverlayStateFileSignature = signature

        let containers: [[String: Any]] = [
            root,
            root["electron-persisted-atom-state"] as? [String: Any],
            root["state"] as? [String: Any],
            root["settings"] as? [String: Any],
        ].compactMap { $0 }
        guard let container = containers.first(where: {
            $0["electron-avatar-overlay-bounds"] is [String: Any]
        }) else {
            storedOverlayLocations = []
            return
        }
        overlayOpen = container["electron-avatar-overlay-open"] as? Bool
        guard let overlay = container["electron-avatar-overlay-bounds"] as? [String: Any] else {
            storedOverlayLocations = []
            return
        }

        var locations: [StoredOverlayLocation] = []

        func addEntry(_ entry: [String: Any], isPrimary: Bool = false) {
            guard let x = entry["x"] as? NSNumber,
                  let y = entry["y"] as? NSNumber
            else { return }

            // Some Codex builds update x/y and placement immediately but omit
            // width, height and mascot while the overlay is on an external
            // display. Retain that current-display entry with the canonical
            // reference size; it will be scaled against the live Quartz window.
            let width = (entry["width"] as? NSNumber)?.doubleValue ?? 356
            let height = (entry["height"] as? NSNumber)?.doubleValue ?? 320
            guard width > 0, height > 0 else { return }

            let rect = CGRect(
                x: x.doubleValue,
                y: y.doubleValue,
                width: width,
                height: height
            )
            let mascot = mascotMetrics(from: entry, overlayRect: rect)
                ?? centeredFallbackMetrics(for: rect.size)
            locations.append(StoredOverlayLocation(rect: rect, mascot: mascot, isPrimary: isPrimary))
        }

        // The root entry is the most recently active display and is the best fallback.
        addEntry(overlay, isPrimary: true)
        if let byDisplayID = overlay["byDisplayId"] as? [String: Any] {
            for value in byDisplayID.values {
                if let entry = value as? [String: Any] {
                    addEntry(entry)
                }
            }
        }
        // Older Codex releases sometimes only retain a resolution-keyed copy.
        if let byResolution = overlay["byResolution"] as? [String: Any] {
            for value in byResolution.values {
                if let entry = value as? [String: Any] {
                    addEntry(entry)
                }
            }
        }

        storedOverlayLocations = locations
    }

    private func centeredFallbackMetrics(for overlaySize: CGSize) -> StoredMascotMetrics {
        let width = min(canonicalPetSpriteSize.width, overlaySize.width)
        let height = min(canonicalPetSpriteSize.height, overlaySize.height)
        return StoredMascotMetrics(
            left: max(0, (overlaySize.width - width) / 2),
            top: petSpriteTopPaddingInsideAnchor,
            width: width,
            height: height,
            topPadding: petSpriteTopPaddingInsideAnchor,
            source: "state-centered-fallback"
        )
    }

    private func mascotMetrics(
        from entry: [String: Any],
        overlayRect: CGRect
    ) -> StoredMascotMetrics? {
        if let mascot = entry["mascot"] as? [String: Any],
           let left = mascot["left"] as? NSNumber,
           let top = mascot["top"] as? NSNumber,
           let width = mascot["width"] as? NSNumber
        {
            let derivedHeight = width.doubleValue * 177 / 163
            let height = (mascot["height"] as? NSNumber)?.doubleValue ?? derivedHeight
            let mascotScale = normalizedPanelScale(
                CGFloat(width.doubleValue) / canonicalPetSpriteSize.width
            )
            let metrics = StoredMascotMetrics(
                left: CGFloat(left.doubleValue),
                top: CGFloat(top.doubleValue),
                width: CGFloat(width.doubleValue),
                height: CGFloat(height),
                topPadding: petSpriteTopPaddingInsideAnchor * mascotScale,
                source: "state-mascot"
            )
            if metricsAreValid(metrics, for: overlayRect.size) { return metrics }
        }

        // Compatibility with Codex builds that persisted only an absolute
        // anchor rectangle instead of relative `mascot` metrics.
        if let anchor = entry["anchor"] as? [String: Any],
           let x = anchor["x"] as? NSNumber,
           let y = anchor["y"] as? NSNumber,
           let width = anchor["width"] as? NSNumber,
           let height = anchor["height"] as? NSNumber
        {
            let anchorScale = normalizedPanelScale(
                CGFloat(width.doubleValue) / canonicalPetSpriteSize.width
            )
            let metrics = StoredMascotMetrics(
                left: CGFloat(x.doubleValue - overlayRect.minX),
                top: CGFloat(y.doubleValue - overlayRect.minY),
                width: CGFloat(width.doubleValue),
                height: CGFloat(height.doubleValue),
                topPadding: petSpriteTopPaddingInsideAnchor * anchorScale,
                source: "state-anchor"
            )
            if metricsAreValid(metrics, for: overlayRect.size) { return metrics }
        }
        return nil
    }

    private func metricsAreValid(_ metrics: StoredMascotMetrics, for size: CGSize) -> Bool {
        metrics.left.isFinite
            && metrics.top.isFinite
            && metrics.width.isFinite
            && metrics.height.isFinite
            && metrics.topPadding.isFinite
            && metrics.width >= 24
            && metrics.height >= 40
            && metrics.left >= -2
            && metrics.top >= -2
            && metrics.left + metrics.width <= size.width + 2
            && metrics.top + metrics.height <= size.height + 2
    }

    private func scaledMetrics(
        _ metrics: StoredMascotMetrics,
        from referenceSize: CGSize,
        to liveSize: CGSize
    ) -> StoredMascotMetrics? {
        guard referenceSize.width > 0,
              referenceSize.height > 0,
              liveSize.width > 0,
              liveSize.height > 0
        else { return nil }

        let scaleX = liveSize.width / referenceSize.width
        let scaleY = liveSize.height / referenceSize.height
        guard scaleX.isFinite,
              scaleY.isFinite,
              scaleX >= 0.20,
              scaleX <= 8,
              scaleY >= 0.20,
              scaleY <= 8,
              abs(log(scaleX / scaleY))
                <= maximumStoredOverlayAspectDistortion
        else { return nil }

        let scaled = StoredMascotMetrics(
            left: metrics.left * scaleX,
            top: metrics.top * scaleY,
            width: metrics.width * scaleX,
            height: metrics.height * scaleY,
            topPadding: metrics.topPadding * scaleY,
            source: metrics.source
        )
        return metricsAreValid(scaled, for: liveSize) ? scaled : nil
    }

    private func bestStoredMetrics(matching liveRect: CGRect) -> MatchedMascotMetrics? {
        let matches = storedOverlayLocations.compactMap { stored -> (MatchedMascotMetrics, Double)? in
            guard let metrics = stored.mascot else { return nil }
            let scaleX = liveRect.width / stored.rect.width
            let scaleY = liveRect.height / stored.rect.height
            guard scaleX.isFinite,
                  scaleY.isFinite,
                  scaleX >= 0.20,
                  scaleX <= 8,
                  scaleY >= 0.20,
                  scaleY <= 8,
                  abs(log(scaleX / scaleY))
                    <= maximumStoredOverlayAspectDistortion,
                  scaledMetrics(metrics, from: stored.rect.size, to: liveRect.size) != nil
            else { return nil }

            // Electron display IDs are not guaranteed to equal CGDirectDisplayID.
            // Match the live Quartz rectangle to the nearest persisted rectangle
            // instead; this remains stable across Retina scale and monitor order.
            let centerDistance = hypot(stored.rect.midX - liveRect.midX, stored.rect.midY - liveRect.midY)
            let primaryBonus = stored.isPrimary ? -1.0 : 0.0
            let uniformityPenalty = abs(log(scaleX / scaleY)) * 2_000
            let scalePenalty = abs(log(scaleX)) * 4
            let score = Double(uniformityPenalty + scalePenalty + centerDistance * 0.08) + primaryBonus
            return (
                MatchedMascotMetrics(metrics: metrics, referenceSize: stored.rect.size),
                score
            )
        }
        return matches.min(by: { $0.1 < $1.1 })?.0
    }

    private func panelScale(for metrics: StoredMascotMetrics) -> CGFloat {
        let widthScale = metrics.width / canonicalPetSpriteSize.width
        let heightScale = metrics.height / canonicalPetSpriteSize.height
        guard widthScale.isFinite,
              heightScale.isFinite,
              widthScale > 0,
              heightScale > 0
        else { return 1 }

        // Use both axes so a temporarily rounded Electron window dimension
        // cannot make the panel pulse by one pixel while ChatBird is zooming.
        return normalizedPanelScale(sqrt(widthScale * heightScale))
    }

    private func visualScaleCandidates(
        for metrics: StoredMascotMetrics
    ) -> [(scale: CGFloat, distortion: CGFloat)] {
        guard metrics.width.isFinite,
              metrics.height.isFinite,
              metrics.width > 0,
              metrics.height > 0
        else { return [] }

        let candidates = petFrameVisiblePixelSizes.compactMap { frameSize
            -> (scale: CGFloat, distortion: CGFloat)? in
            let expectedWidth = frameSize.width
                * canonicalPetSpriteSize.width / petAtlasFrameSize.width
            let expectedHeight = frameSize.height
                * canonicalPetSpriteSize.height / petAtlasFrameSize.height
            let widthScale = metrics.width / expectedWidth
            let heightScale = metrics.height / expectedHeight
            guard widthScale.isFinite,
                  heightScale.isFinite,
                  widthScale > 0,
                  heightScale > 0
            else { return nil }
            return (
                normalizedPanelScale(sqrt(widthScale * heightScale)),
                abs(log(widthScale / heightScale))
            )
        }
        guard let bestDistortion = candidates.map(\.distortion).min(),
              bestDistortion <= 0.15
        else { return [] }
        // One-pixel antialiasing differences matter at very small scales. Keep
        // all atlas frames whose aspect fit is within 2% of the best match.
        return candidates.filter { $0.distortion <= bestDistortion + 0.02 }
    }

    private func visualPanelScale(for metrics: StoredMascotMetrics) -> CGFloat {
        let scales = visualScaleCandidates(for: metrics)
            .map(\.scale)
            .sorted()
        guard !scales.isEmpty else { return 1 }
        return scales[scales.count / 2]
    }

    private func reconciledPanelScale(
        anchorMetrics: StoredMascotMetrics,
        visualMetrics: StoredMascotMetrics
    ) -> CGFloat {
        let anchorScale = panelScale(for: anchorMetrics)
        let candidates = visualScaleCandidates(for: visualMetrics)
        guard let visualScale = candidates.min(by: {
            abs(log($0.scale / anchorScale)) < abs(log($1.scale / anchorScale))
        })?.scale else { return anchorScale }
        guard anchorScale > 0, visualScale > 0 else { return anchorScale }

        // Ordinary sprite rows vary slightly in visible height. Keep the
        // persisted anchor scale for that small variation, but trust the real
        // pixels when Codex shrinks the rendered pet inside a stale anchor.
        let relativeDifference = abs(log(visualScale / anchorScale))
        return relativeDifference > visualScaleTolerance ? visualScale : anchorScale
    }

    private func visibleRect(in overlayRect: NSRect, metrics: StoredMascotMetrics) -> NSRect {
        let visibleHeight = max(1, metrics.height - metrics.topPadding)
        return NSRect(
            x: overlayRect.minX + metrics.left,
            y: overlayRect.maxY - metrics.top - metrics.height,
            width: metrics.width,
            height: visibleHeight
        )
    }

    private func storedOverlayLocation(
        allowClosedOverlay: Bool = false,
        preferredDisplayID: CGDirectDisplayID? = nil
    ) -> LocatedPet? {
        guard shouldUseStoredPetPosition(
            overlayOpen: overlayOpen,
            allowClosedOverlay: allowClosedOverlay
        ) else { return nil }

        let sourcePrefix = overlayOpen == false ? "saved-closed" : "saved"
        let candidates = storedOverlayLocations.compactMap { stored
            -> (stored: StoredOverlayLocation, location: LocatedPet)? in
            guard let mascot = stored.mascot,
                  let converted = convertToAppKit(stored.rect),
                  let appMetrics = scaledMetrics(
                      mascot,
                      from: stored.rect.size,
                      to: converted.0.size
                  )
            else { return nil }
            return (
                stored,
                LocatedPet(
                    overlayRect: converted.0,
                    visibleRect: visibleRect(
                        in: converted.0,
                        metrics: appMetrics
                    ),
                    panelScale: panelScale(for: mascot),
                    screen: converted.1,
                    source: "\(sourcePrefix)-\(mascot.source)"
                )
            )
        }
        let selected = preferredDisplayID.flatMap { displayID in
            candidates.first {
                dynamicIslandDisplayID(for: $0.location.screen) == displayID
            }
        } ?? candidates.first(where: { $0.stored.isPrimary }) ?? candidates.first
        guard let selected, let mascot = selected.stored.mascot else {
            return nil
        }
        cachedMascotMetrics = mascot
        cachedOverlaySize = selected.stored.rect.size
        return selected.location
    }

    private func currentVisualMetrics(
        windowID: CGWindowID,
        overlayRect: CGRect
    ) -> StoredMascotMetrics? {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastVisualProbeAt >= 0.12 {
            lastVisualProbeAt = now
            if let metrics = probeVisibleMascotMetrics(
                windowID: windowID,
                overlaySize: overlayRect.size
            ) {
                cachedVisualMetrics = metrics
                cachedVisualOverlaySize = overlayRect.size
                cachedVisualWindowID = windowID
                return metrics
            }
        }

        // A live pixel probe can occasionally fail while macOS is compositing
        // the transparent Electron overlay. The persisted mascot rectangle may
        // already be stale after a move, so keep the last verified pixels for
        // this exact window ID until a newer successful probe replaces them.
        guard cachedVisualWindowID == windowID,
              let cachedVisualMetrics,
              let cachedVisualOverlaySize
        else { return nil }
        return scaledMetrics(
            cachedVisualMetrics,
            from: cachedVisualOverlaySize,
            to: overlayRect.size
        )
    }

    private func probeVisibleMascotMetrics(
        windowID: CGWindowID,
        overlaySize: CGSize
    ) -> StoredMascotMetrics? {
        // Never trigger the macOS Screen Recording consent dialog just to
        // position this companion panel. Pixel probing is an optional accuracy
        // enhancement only when the user has already granted that permission.
        guard CGPreflightScreenCaptureAccess() else { return nil }
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming]
        ), image.width >= 80, image.height >= 80,
        let data = image.dataProvider?.data,
        let bytes = CFDataGetBytePtr(data)
        else { return nil }

        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        let bytesPerRow = image.bytesPerRow
        guard bytesPerPixel >= 4,
              overlaySize.width > 0,
              overlaySize.height > 0
        else { return nil }

        guard let selection = mascotPixelSelection(
            imageWidth: image.width,
            imageHeight: image.height,
            isVisible: { x, y in
                let offset = y * bytesPerRow + x * bytesPerPixel
                for channel in 0..<min(bytesPerPixel, 4)
                    where bytes[offset + channel] > 20
                {
                    return true
                }
                return false
            }
        ) else { return nil }

        let totalPixels = image.width * image.height
        guard selection.totalVisiblePixels >= 64,
              selection.totalVisiblePixels < Int(Double(totalPixels) * 0.80)
        else { return nil }

        // Window captures use backing pixels on Retina displays. Width is
        // always complete even when macOS clips transparent rows, so use it as
        // the uniform backing scale for both axes.
        let backingScale = CGFloat(image.width) / overlaySize.width
        guard backingScale.isFinite, backingScale > 0 else { return nil }
        let metrics = StoredMascotMetrics(
            left: selection.bounds.minX / backingScale,
            top: selection.bounds.minY / backingScale,
            width: selection.bounds.width / backingScale,
            height: selection.bounds.height / backingScale,
            topPadding: 0,
            source: "visual-pixels"
        )
        return metricsAreValid(metrics, for: overlaySize) ? metrics : nil
    }

    private func candidate(from window: [String: Any]) -> (rect: CGRect, score: Double)? {
        guard let ownerName = window[kCGWindowOwnerName as String] as? String,
              let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
              layer >= 0,
              layer < 50,
              let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
              alpha > 0.05,
              let rawBounds = window[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: rawBounds),
              bounds.width >= 160,
              bounds.width <= 900,
              bounds.height >= 120,
              bounds.height <= 1_000
        else { return nil }

        let normalizedOwner = ownerName.lowercased()
        guard normalizedOwner.contains("codex") || normalizedOwner.contains("chatgpt") else {
            return nil
        }

        let name = window[kCGWindowName as String] as? String ?? ""
        let normalizedName = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // Dedicated Codex pet surfaces have independent geometry contracts.
        // Treating one as the legacy overlay can cache its large composition
        // bounds and permanently inflate the panel before the mascot pair
        // becomes available.
        guard !normalizedName.hasPrefix("codex pet ") else { return nil }

        var score = Double(abs(bounds.width - 356) + abs(bounds.height - 320) * 0.35)
        score += Double(abs(layer - 3) * 50)
        if name == "ChatGPT" || name == "Codex" { score -= 80 }

        if let distance = storedOverlayLocations.map({ stored in
            hypot(bounds.midX - stored.rect.midX, bounds.midY - stored.rect.midY)
        }).min() {
            score += Double(distance * 0.08)
        }
        return (bounds, score)
    }

    private func convertToAppKit(_ quartzRect: CGRect) -> (NSRect, NSScreen)? {
        let center = CGPoint(x: quartzRect.midX, y: quartzRect.midY)

        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            guard displayBounds.contains(center) || displayBounds.intersects(quartzRect) else {
                continue
            }

            guard displayBounds.width > 0, displayBounds.height > 0 else { continue }
            let scaleX = screen.frame.width / displayBounds.width
            let scaleY = screen.frame.height / displayBounds.height
            let x = screen.frame.minX + (quartzRect.minX - displayBounds.minX) * scaleX
            let y = screen.frame.maxY
                - (quartzRect.minY - displayBounds.minY) * scaleY
                - quartzRect.height * scaleY
            return (
                NSRect(
                    x: x,
                    y: y,
                    width: quartzRect.width * scaleX,
                    height: quartzRect.height * scaleY
                ),
                screen
            )
        }
        return nil
    }

    func scalingSelfTest() -> Bool {
        let baseSize = CGSize(width: 356, height: 320)
        let base = StoredMascotMetrics(
            left: 165,
            top: 8,
            width: 163,
            height: 177,
            topPadding: petSpriteTopPaddingInsideAnchor,
            source: "self-test"
        )
        func testWindow(
            name: String,
            layer: Int,
            bounds: CGRect
        ) -> [String: Any] {
            [
                kCGWindowOwnerName as String: "ChatGPT",
                kCGWindowLayer as String: NSNumber(value: layer),
                kCGWindowAlpha as String: NSNumber(value: 1),
                kCGWindowBounds as String: bounds.dictionaryRepresentation,
                kCGWindowName as String: name,
            ]
        }
        let genericOverlay = testWindow(
            name: "ChatGPT",
            layer: 3,
            bounds: CGRect(x: 0, y: 0, width: 356, height: 320)
        )
        let compositionSurface = testWindow(
            name: "Codex Pet Composition Surface",
            layer: 3,
            bounds: CGRect(x: 0, y: 0, width: 768, height: 912)
        )
        let mascotEffect = testWindow(
            name: "Codex Pet Mascot Effect",
            layer: 2,
            bounds: CGRect(x: 0, y: 0, width: 172, height: 179)
        )
        guard candidate(from: genericOverlay) != nil,
              candidate(from: compositionSurface) == nil,
              candidate(from: mascotEffect) == nil
        else { return false }

        let centeredFallback = centeredFallbackMetrics(for: baseSize)
        guard abs(centeredFallback.left + centeredFallback.width / 2 - baseSize.width / 2) <= 0.01,
              let scaledFallback = scaledMetrics(
                  centeredFallback,
                  from: baseSize,
                  to: CGSize(width: 408, height: 400)
              ),
              abs(scaledFallback.left + scaledFallback.width / 2 - 204) <= 0.01,
              scaledMetrics(
                  centeredFallback,
                  from: baseSize,
                  to: CGSize(width: 768, height: 912)
              ) == nil,
              shouldDiscoverMascotEffectWindows(
                  now: 10,
                  lastDiscoveryAt: 9.9,
                  hasCachedGenericWindow: false
              ),
              !shouldDiscoverMascotEffectWindows(
                  now: 10,
                  lastDiscoveryAt: 9.9,
                  hasCachedGenericWindow: true
              ),
              shouldDiscoverMascotEffectWindows(
                  now: 10,
                  lastDiscoveryAt: 9.5,
                  hasCachedGenericWindow: true
              )
        else { return false }
        for factor in [0.25, 0.5, 1.0, 1.25, 2.0, 3.0] as [CGFloat] {
            let liveSize = CGSize(width: baseSize.width * factor, height: baseSize.height * factor)
            guard let scaled = scaledMetrics(base, from: baseSize, to: liveSize),
                  abs(scaled.left - base.left * factor) <= 0.01,
                  abs(scaled.top - base.top * factor) <= 0.01,
                  abs(scaled.width - base.width * factor) <= 0.01,
                  abs(scaled.height - base.height * factor) <= 0.01,
                  abs(scaled.topPadding - base.topPadding * factor) <= 0.01,
                  abs(panelScale(for: scaled) - factor) <= 0.01
            else { return false }
        }
        guard scaledMetrics(
            base,
            from: baseSize,
            to: CGSize(width: baseSize.width * 2, height: baseSize.height * 0.5)
        ) == nil else { return false }

        // The Electron overlay may retain its old transparent bounds while
        // the pet itself is zoomed inside them. In that case the visible
        // pixels, not the stale anchor, must drive the whole panel scale.
        let visualCases: [(
            anchor: CGFloat,
            visual: CGFloat,
            expected: CGFloat,
            frame: NSSize
        )] = [
            (1.0, 0.4, 0.4, NSSize(width: 182, height: 196)),
            (1.0, 0.7, 0.7, NSSize(width: 182, height: 196)),
            (0.5, 0.5, 0.5, NSSize(width: 182, height: 196)),
            (1.0, 0.94, 1.0, NSSize(width: 182, height: 196)),
            (1.0, 1.0, 1.0, NSSize(width: 121, height: 190)),
            (1.0, 0.4, 0.4, NSSize(width: 121, height: 190)),
        ]
        for test in visualCases {
            let anchor = StoredMascotMetrics(
                left: 0,
                top: 0,
                width: canonicalPetSpriteSize.width * test.anchor,
                height: canonicalPetSpriteSize.height * test.anchor,
                topPadding: 0,
                source: "self-test-anchor"
            )
            let visual = StoredMascotMetrics(
                left: 0,
                top: 0,
                width: test.frame.width * canonicalPetSpriteSize.width
                    / petAtlasFrameSize.width * test.visual,
                height: test.frame.height * canonicalPetSpriteSize.height
                    / petAtlasFrameSize.height * test.visual,
                topPadding: 0,
                source: "self-test-visual"
            )
            guard abs(reconciledPanelScale(anchorMetrics: anchor, visualMetrics: visual)
                - test.expected) <= 0.01
            else { return false }
        }
        return true
    }
}
