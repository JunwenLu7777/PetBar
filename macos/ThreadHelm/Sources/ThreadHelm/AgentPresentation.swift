//
//  AgentPresentation.swift
//  ThreadHelm
//
//  模块职责：从注册表元数据生成来源名称、颜色、图标和导航文案，UI 不分厂商。
//

import AppKit
import Foundation

struct AgentColorComponents: Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    var color: NSColor {
        NSColor(
            calibratedRed: red,
            green: green,
            blue: blue,
            alpha: 1
        )
    }
}

struct AgentPresentation: Equatable {
    let id: AgentID
    let displayName: String
    let shortName: String
    let iconResourceName: String
    let fallbackSymbolName: String
    let brandColor: AgentColorComponents
}

private let agentIconImageCache = NSCache<NSString, NSImage>()

func agentPresentation(
    for id: AgentID,
    registry: AgentRegistry = .builtIn
) -> AgentPresentation {
    if let metadata = registry.metadata(for: id) {
        return AgentPresentation(
            id: id,
            displayName: metadata.displayName,
            shortName: metadata.shortName,
            iconResourceName: metadata.iconResourceName,
            fallbackSymbolName: metadata.fallbackSymbolName,
            brandColor: metadata.brandColor
        )
    }
    let readableName = id.rawValue.isEmpty ? "未知 Agent" : id.rawValue
    return AgentPresentation(
        id: id,
        displayName: readableName,
        shortName: readableName,
        iconResourceName: "",
        fallbackSymbolName: "puzzlepiece.extension",
        brandColor: AgentColorComponents(red: 0.58, green: 0.62, blue: 0.70)
    )
}

func agentIconImage(
    for id: AgentID,
    bundle: Bundle = .main,
    registry: AgentRegistry = .builtIn
) -> NSImage? {
    let presentation = agentPresentation(for: id, registry: registry)
    let cacheKey = "\(bundle.bundleURL.path)#agent#\(id.rawValue)" as NSString
    if let cached = agentIconImageCache.object(forKey: cacheKey) {
        return cached
    }
    let resourceImage = presentation.iconResourceName.isEmpty
        ? nil
        : bundle.url(
            forResource: presentation.iconResourceName,
            withExtension: "svg"
        ).flatMap(NSImage.init(contentsOf:))
    let image = resourceImage ?? NSImage(
        systemSymbolName: presentation.fallbackSymbolName,
        accessibilityDescription: presentation.displayName
    )
    image?.isTemplate = resourceImage == nil
    image?.accessibilityDescription = presentation.displayName
    if let image {
        agentIconImageCache.setObject(image, forKey: cacheKey)
    }
    return image
}

func agentTaskOpenButtonTitle(for item: TaskProgressItem) -> String {
    guard item.canOpen else { return "仅查看状态" }
    if item.source == .claudeCode {
        return "回到终端"
    }
    let presentation = agentPresentation(for: item.source)
    return "打开 \(presentation.shortName)"
}

func taskSourceFilterName(_ filter: TaskSourceFilter) -> String {
    filter.agentID.map { agentPresentation(for: $0).shortName } ?? "全部"
}
