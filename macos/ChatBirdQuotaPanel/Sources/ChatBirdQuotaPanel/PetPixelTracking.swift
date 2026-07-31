//
//  PetPixelTracking.swift
//  ChatBirdQuotaPanel
//
//  模块职责：屏幕截图中宠物可见像素的连通区域分析（BFS），从候选组件中
//  评分选出宠物本体并合并邻近碎片，用于视觉缩放探测。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

struct VisiblePixelSelection {
    let bounds: CGRect
    let totalVisiblePixels: Int
}

struct VisiblePixelComponent {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int
    var pixelCount: Int

    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
    var aspectRatio: Double { Double(width) / Double(height) }
    var bounds: CGRect {
        CGRect(x: minX, y: minY, width: width, height: height)
    }

    func union(_ other: VisiblePixelComponent) -> VisiblePixelComponent {
        VisiblePixelComponent(
            minX: min(minX, other.minX),
            minY: min(minY, other.minY),
            maxX: max(maxX, other.maxX),
            maxY: max(maxY, other.maxY),
            pixelCount: pixelCount + other.pixelCount
        )
    }
}

func mascotPixelSelection(
    imageWidth: Int,
    imageHeight: Int,
    isVisible: (_ x: Int, _ y: Int) -> Bool
) -> VisiblePixelSelection? {
    guard imageWidth > 0, imageHeight > 0 else { return nil }

    var mask = [UInt8](repeating: 0, count: imageWidth * imageHeight)
    var totalVisiblePixels = 0
    for y in 0..<imageHeight {
        for x in 0..<imageWidth where isVisible(x, y) {
            mask[y * imageWidth + x] = 1
            totalVisiblePixels += 1
        }
    }
    guard totalVisiblePixels > 0 else { return nil }

    var components: [VisiblePixelComponent] = []
    var queue: [Int] = []
    for start in mask.indices where mask[start] == 1 {
        mask[start] = 0
        queue.removeAll(keepingCapacity: true)
        queue.append(start)

        let startX = start % imageWidth
        let startY = start / imageWidth
        var component = VisiblePixelComponent(
            minX: startX,
            minY: startY,
            maxX: startX,
            maxY: startY,
            pixelCount: 0
        )
        var queueIndex = 0
        while queueIndex < queue.count {
            let index = queue[queueIndex]
            queueIndex += 1
            let x = index % imageWidth
            let y = index / imageWidth
            component.minX = min(component.minX, x)
            component.minY = min(component.minY, y)
            component.maxX = max(component.maxX, x)
            component.maxY = max(component.maxY, y)
            component.pixelCount += 1

            for neighborY in max(0, y - 1)...min(imageHeight - 1, y + 1) {
                for neighborX in max(0, x - 1)...min(imageWidth - 1, x + 1) {
                    let neighborIndex = neighborY * imageWidth + neighborX
                    guard mask[neighborIndex] == 1 else { continue }
                    mask[neighborIndex] = 0
                    queue.append(neighborIndex)
                }
            }
        }
        components.append(component)
    }

    let minimumMascotHeight = max(12, imageHeight / 16)
    let mascotCandidates = components.filter {
        $0.pixelCount >= 64
            && $0.width >= 8
            && $0.height >= minimumMascotHeight
            && $0.aspectRatio >= 0.20
            && $0.aspectRatio <= 2.10
    }
    guard let anchor = mascotCandidates.max(by: { left, right in
        func score(_ component: VisiblePixelComponent) -> Double {
            let bottomPosition = Double(component.maxY + 1) / Double(imageHeight)
            let heightShare = Double(component.height) / Double(imageHeight)
            let shapePenalty = abs(log(component.aspectRatio / 0.82)) * 0.20
            return bottomPosition * 5
                + heightShare * 4
                + log1p(Double(component.pixelCount)) / 10
                - shapePenalty
        }
        return score(left) < score(right)
    }) else { return nil }

    var mascot = anchor
    let horizontalJoinDistance = max(3, anchor.width / 8)
    let verticalJoinDistance = max(3, anchor.height / 12)
    for component in components where component.bounds != anchor.bounds {
        guard component.pixelCount >= 4,
              component.aspectRatio <= 2.40,
              component.maxY >= anchor.minY
        else { continue }

        let horizontalGap = max(
            0,
            max(mascot.minX - component.maxX - 1, component.minX - mascot.maxX - 1)
        )
        let verticalGap = max(
            0,
            max(mascot.minY - component.maxY - 1, component.minY - mascot.maxY - 1)
        )
        let joined = mascot.union(component)
        guard horizontalGap <= horizontalJoinDistance,
              verticalGap <= verticalJoinDistance,
              joined.width <= Int(Double(anchor.width) * 1.45),
              joined.height <= Int(Double(anchor.height) * 1.35)
        else { continue }
        mascot = joined
    }

    return VisiblePixelSelection(
        bounds: mascot.bounds,
        totalVisiblePixels: totalVisiblePixels
    )
}
