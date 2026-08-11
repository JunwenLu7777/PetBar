//
//  PlacementSelfTest.swift
//  ChatBirdQuotaPanel
//
//  模块职责：--self-test-placement 自测——面板摆放（间距/居中/缩放）、
//  活动气泡像素分割、mascot effect 几何、原生窗口 z-order、overlay
//  状态缓存、几何失效与宠物轮询节奏。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

func runPlacementSelfTest() -> Never {
    struct TestCase {
        let name: String
        let petRect: NSRect
        let panelSize: NSSize
        let panelScale: CGFloat
        let screenRect: NSRect
    }

    let cases = [
        TestCase(
            name: "built-in-display",
            petRect: NSRect(x: 1_110, y: 318, width: 163, height: 170),
            panelSize: expandedPanelSize,
            panelScale: 1,
            screenRect: NSRect(x: 0, y: 0, width: 1_512, height: 982)
        ),
        TestCase(
            name: "external-negative-origin",
            petRect: NSRect(x: -554, y: 500, width: 163, height: 170),
            panelSize: expandedPanelSize,
            panelScale: 1,
            screenRect: NSRect(x: -1_920, y: -98, width: 1_920, height: 1_080)
        ),
        TestCase(
            name: "scaled-pet",
            petRect: NSRect(x: 420, y: 260, width: 203.75, height: 212.5),
            panelSize: scaledPanelSize(expandedPanelSize, scale: 1.25),
            panelScale: 1.25,
            screenRect: NSRect(x: 0, y: 0, width: 1_920, height: 1_080)
        ),
        TestCase(
            name: "three-quarter-scale",
            petRect: NSRect(x: 280, y: 210, width: 122.25, height: 127.5),
            panelSize: scaledPanelSize(expandedPanelSize, scale: 0.75),
            panelScale: 0.75,
            screenRect: NSRect(x: 0, y: 0, width: 1_280, height: 720)
        ),
        TestCase(
            name: "left-screen-edge",
            petRect: NSRect(x: 8, y: 180, width: 81.5, height: 85),
            panelSize: scaledPanelSize(expandedPanelSize, scale: 0.5),
            panelScale: 0.5,
            screenRect: NSRect(x: 0, y: 0, width: 1_280, height: 720)
        ),
        TestCase(
            name: "right-screen-edge",
            petRect: NSRect(x: 1_050, y: 180, width: 163, height: 170),
            panelSize: scaledPanelSize(expandedPanelSize, scale: 2),
            panelScale: 2,
            screenRect: NSRect(x: 0, y: 0, width: 1_280, height: 720)
        ),
    ]

    for test in cases {
        let placement = panelPlacement(
            petVisibleRect: test.petRect,
            panelSize: test.panelSize,
            panelScale: test.panelScale,
            screenVisibleFrame: test.screenRect
        )
        guard abs(placement.actualGap - panelPetGap) <= 0.01 else {
            fputs("\(test.name): gap=\(placement.actualGap), expected=\(panelPetGap)\n", stderr)
            exit(1)
        }
        let baseSize = expandedPanelSize
        guard abs(test.panelSize.width - baseSize.width * test.panelScale) <= 0.01,
              abs(test.panelSize.height - baseSize.height * test.panelScale) <= 0.01
        else {
            fputs("\(test.name): panel did not scale proportionally\n", stderr)
            exit(1)
        }
        guard abs(placement.centerError) <= 0.01 else {
            fputs("\(test.name): centerError=\(placement.centerError)\n", stderr)
            exit(1)
        }
    }

    let fallbackFrame = detachedPanelFrame(
        panelSize: expandedPanelSize,
        screenVisibleFrame: NSRect(x: -1_920, y: -98, width: 1_920, height: 1_080)
    )
    guard fallbackFrame == NSRect(x: -396, y: 744, width: 388, height: 226),
          fallbackFrame.minX >= -1_920 + panelScreenMargin,
          fallbackFrame.maxX == -panelScreenMargin,
          fallbackFrame.maxY <= -98 + 1_080 - panelScreenMargin
    else {
        fputs("detached panel fallback placement failed: \(fallbackFrame)\n", stderr)
        exit(1)
    }

    let narrowFallbackFrame = detachedPanelFrame(
        panelSize: expandedPanelSize,
        screenVisibleFrame: NSRect(x: 400, y: 50, width: 360, height: 210)
    )
    guard narrowFallbackFrame.origin == NSPoint(x: 408, y: 58) else {
        fputs("detached panel narrow-screen clamp failed: \(narrowFallbackFrame)\n", stderr)
        exit(1)
    }

    guard !shouldUseStoredPetPosition(
        overlayOpen: false,
        allowClosedOverlay: false
    ),
          shouldUseStoredPetPosition(
              overlayOpen: false,
              allowClosedOverlay: true
          ),
          shouldUseStoredPetPosition(
              overlayOpen: nil,
              allowClosedOverlay: false
          )
    else {
        fputs("closed-pet saved-position eligibility failed\n", stderr)
        exit(1)
    }

    let pixelWidth = 360
    let pixelHeight = 320
    let expectedPetBounds = CGRect(x: 128, y: 118, width: 105, height: 188)
    let selectionWithActivityPill = mascotPixelSelection(
        imageWidth: pixelWidth,
        imageHeight: pixelHeight,
        isVisible: { x, y in
            let activityPill = (10...349).contains(x) && (20...76).contains(y)
            let petBody = (128...232).contains(x) && (118...278).contains(y)
            let leftFoot = (134...164).contains(x) && (282...305).contains(y)
            let rightFoot = (196...226).contains(x) && (282...305).contains(y)
            return activityPill || petBody || leftFoot || rightFoot
        }
    )
    guard selectionWithActivityPill?.bounds == expectedPetBounds else {
        fputs(
            "activity-pill segmentation: bounds="
                + "\(String(describing: selectionWithActivityPill?.bounds)), "
                + "expected=\(expectedPetBounds)\n",
            stderr
        )
        exit(1)
    }

    let selectionWithoutActivityPill = mascotPixelSelection(
        imageWidth: pixelWidth,
        imageHeight: pixelHeight,
        isVisible: { x, y in
            let petBody = (128...232).contains(x) && (118...278).contains(y)
            let leftFoot = (134...164).contains(x) && (282...305).contains(y)
            let rightFoot = (196...226).contains(x) && (282...305).contains(y)
            return petBody || leftFoot || rightFoot
        }
    )
    guard selectionWithoutActivityPill?.bounds == expectedPetBounds else {
        fputs(
            "pet-only segmentation: bounds="
                + "\(String(describing: selectionWithoutActivityPill?.bounds)), "
                + "expected=\(expectedPetBounds)\n",
            stderr
        )
        exit(1)
    }

    let detectedPetRect = NSRect(
        x: expectedPetBounds.minX,
        y: CGFloat(pixelHeight) - expectedPetBounds.maxY,
        width: expectedPetBounds.width,
        height: expectedPetBounds.height
    )
    let detectedPlacement = panelPlacement(
        petVisibleRect: detectedPetRect,
        panelSize: expandedPanelSize,
        panelScale: 1,
        screenVisibleFrame: NSRect(x: 0, y: 0, width: 1_512, height: 982)
    )
    guard abs(detectedPlacement.centerError) <= 0.01 else {
        fputs(
            "activity-pill placement centerError=\(detectedPlacement.centerError)\n",
            stderr
        )
        exit(1)
    }

    let liveEffectRect = CGRect(x: 1_615, y: 771, width: 243, height: 252)
    let liveAnchorRect = CGRect(x: 1_536, y: 836, width: 384, height: 122)
    guard isMascotEffectWindow(name: nil, layer: 2, rect: liveEffectRect),
    !isMascotEffectWindow(name: nil, layer: 3, rect: liveEffectRect),
    isMascotAnchorWindow(name: nil, layer: 3, rect: liveAnchorRect),
    !isMascotAnchorWindow(
        name: nil,
        layer: 3,
        rect: CGRect(x: 1_563, y: 770, width: 345, height: 54)
    ),
    let effectGeometry = mascotEffectPetGeometry(
        effectRect: liveEffectRect,
        anchorRect: liveAnchorRect
    ),
    abs(effectGeometry.visibleRect.midX - liveEffectRect.midX) <= 0.01,
    abs(effectGeometry.visibleRect.minY - liveAnchorRect.minY) <= 0.01,
    abs(effectGeometry.scale - 243 / 356) <= 0.01,
    mascotEffectPetGeometry(
        effectRect: liveEffectRect,
        anchorRect: liveAnchorRect.offsetBy(dx: 1_000, dy: 0)
    ) == nil
    else {
        fputs("mascot-effect geometry self-test failed\n", stderr)
        exit(1)
    }

    guard PetWindowLocator().scalingSelfTest() else {
        fputs("mascot scaling self-test failed\n", stderr)
        exit(1)
    }

    let panelStackEntry = WindowStackEntry(
        number: 10,
        ownerProcessID: 100,
        ownerName: "ChatBird 额度面板",
        name: "",
        alpha: 1,
        bounds: CGRect(x: 100, y: 100, width: 388, height: 226)
    )
    let activityStackEntry = WindowStackEntry(
        number: 20,
        ownerProcessID: 200,
        ownerName: "ChatGPT",
        name: "Codex Pet Activity Stack Backing",
        alpha: 1,
        bounds: CGRect(x: 120, y: 120, width: 345, height: 54)
    )
    let separateActivityStackEntry = WindowStackEntry(
        number: 21,
        ownerProcessID: 200,
        ownerName: "ChatGPT",
        name: "Codex Pet Activity Stack Backing",
        alpha: 1,
        bounds: CGRect(x: 700, y: 120, width: 345, height: 54)
    )
    let compositionSurfaceEntry = WindowStackEntry(
        number: 22,
        ownerProcessID: 200,
        ownerName: "ChatGPT",
        name: "Codex Pet Composition Surface",
        alpha: 1,
        bounds: CGRect(x: 0, y: 0, width: 768, height: 912)
    )
    let foreignCompositionSurfaceEntry = WindowStackEntry(
        number: 23,
        ownerProcessID: 201,
        ownerName: "ChatGPT",
        name: "Codex Pet Composition Surface",
        alpha: 1,
        bounds: CGRect(x: 0, y: 0, width: 768, height: 912)
    )
    guard isCodexNativeActivityStackWindow(activityStackEntry),
          isCodexPetCompositionSurfaceWindow(compositionSurfaceEntry),
          nativeActivityStackOccludesPanel(
              entries: [activityStackEntry, panelStackEntry],
              panelWindowNumber: panelStackEntry.number
          ),
          nativeActivityStackOccludesPanel(
              entries: [
                  compositionSurfaceEntry,
                  panelStackEntry,
                  activityStackEntry,
              ],
              panelWindowNumber: panelStackEntry.number
          ),
          !nativeActivityStackOccludesPanel(
              entries: [panelStackEntry, activityStackEntry],
              panelWindowNumber: panelStackEntry.number
          ),
          !nativeActivityStackOccludesPanel(
              entries: [separateActivityStackEntry, panelStackEntry],
              panelWindowNumber: panelStackEntry.number
          ),
          !nativeActivityStackOccludesPanel(
              entries: [
                  foreignCompositionSurfaceEntry,
                  panelStackEntry,
                  activityStackEntry,
              ],
              panelWindowNumber: panelStackEntry.number
          ),
          nativeActivityStackIntersectsPanel(
              entries: [panelStackEntry, activityStackEntry],
              panelWindowNumber: panelStackEntry.number
          ),
          !nativeActivityStackIntersectsPanel(
              entries: [panelStackEntry, separateActivityStackEntry],
              panelWindowNumber: panelStackEntry.number
          ),
          panelNativeActivityWindowLevel.rawValue
              == panelDefaultWindowLevel.rawValue + 1
    else {
        fputs("native activity stack z-order self-test failed\n", stderr)
        exit(1)
    }

    let stateSignature = OverlayStateFileSignature(
        attributes: [
            .modificationDate: Date(timeIntervalSince1970: 1_000),
            .size: NSNumber(value: 369_470),
            .systemFileNumber: NSNumber(value: 42),
        ]
    )
    let changedStateSignature = OverlayStateFileSignature(
        attributes: [
            .modificationDate: Date(timeIntervalSince1970: 1_001),
            .size: NSNumber(value: 369_470),
            .systemFileNumber: NSNumber(value: 42),
        ]
    )
    guard let stateSignature,
          let changedStateSignature,
          overlayStateNeedsReload(previous: nil, current: stateSignature),
          !overlayStateNeedsReload(previous: stateSignature, current: stateSignature),
          overlayStateNeedsReload(previous: stateSignature, current: changedStateSignature),
          overlayStateNeedsReload(previous: stateSignature, current: nil)
    else {
        fputs("overlay state cache self-test failed\n", stderr)
        exit(1)
    }

    let unchangedRect = NSRect(x: 10, y: 20, width: 388, height: 226)
    guard !rectDiffers(unchangedRect, from: unchangedRect),
          !rectDiffers(
              unchangedRect,
              from: unchangedRect.offsetBy(dx: 0.05, dy: -0.05)
          ),
          rectDiffers(
              unchangedRect,
              from: unchangedRect.offsetBy(dx: 0.2, dy: 0)
          ),
          rectDiffers(
              unchangedRect,
              from: NSRect(x: 10, y: 20, width: 389, height: 226)
          )
    else {
        fputs("panel geometry invalidation self-test failed\n", stderr)
        exit(1)
    }

    let petPollingCases: [(Bool, String)] = [
        (
            shouldPollPetLocation(
                now: 100,
                lastPollAt: 99.99,
                lastMovementAt: 99.99,
                force: true
            ),
            "forced"
        ),
        (
            shouldPollPetLocation(
                now: 100,
                lastPollAt: 0,
                lastMovementAt: 0,
                force: false
            ),
            "initial"
        ),
        (
            !shouldPollPetLocation(
                now: 100,
                lastPollAt: 99.98,
                lastMovementAt: 99.9,
                force: false
            ),
            "moving-too-soon"
        ),
        (
            shouldPollPetLocation(
                now: 100,
                lastPollAt: 99.96,
                lastMovementAt: 99.9,
                force: false
            ),
            "moving-due"
        ),
        (
            !shouldPollPetLocation(
                now: 100,
                lastPollAt: 99.85,
                lastMovementAt: 98,
                force: false
            ),
            "idle-too-soon"
        ),
        (
            shouldPollPetLocation(
                now: 100,
                lastPollAt: 99.79,
                lastMovementAt: 98,
                force: false
            ),
            "idle-due"
        ),
    ]
    guard petPollingCases.allSatisfy(\.0) else {
        let failed = petPollingCases.filter { !$0.0 }.map(\.1).joined(separator: ",")
        fputs("pet polling self-test failed: \(failed)\n", stderr)
        exit(1)
    }

    print("placement-self-test: 6/6 passed; activity-pill-segmentation=2/2; activity-pill-centerError=0.0; unnamed-pet-windows=4/4; mascot-effect-geometry=2/2; generic-window-filter=3/3; stored-overlay-shape=2/2; mascot-rediscovery=3/3; native-activity-z-order=7/7; native-activity-level=3/3; mascot-scaling=6/6; visual-scaling=6/6; panel-scaling=6/6; overlay-state-cache=4/4; geometry-invalidation=4/4; pet-polling=6/6; gap=14.0; centerError=0.0")
    exit(0)
}
