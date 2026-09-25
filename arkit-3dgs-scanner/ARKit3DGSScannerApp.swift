//
//  ARKit3DGSScannerApp.swift
//  ARKit 3DGS Scanner
//
//  Created by 吳欣怡 on 2026/7/16.
//

import SwiftUI

@main
struct ARKit3DGSScannerApp: App {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.traditionalChinese.rawValue

    @ViewBuilder private var rootView: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--compact-height") {
            // Landscape arrangement on a Simulator that headless screenshots cannot rotate.
            content.environment(\.verticalSizeClass, .compact)
        } else { content }
        #else
        content
        #endif
    }

    @ViewBuilder private var content: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-fusion") {
            FusionProcessingView(progress: 0.67, stage: .fusing,
                detail: L10n.text("融合點雲… 176 / 399 幀"), frameCount: 399,
                startedAt: Date().addingTimeInterval(-42))
        } else if ProcessInfo.processInfo.arguments.contains("--preview-capture-controls") {
            CaptureControlsPreview()
        } else if ProcessInfo.processInfo.arguments.contains("--preview-review") {
            ReviewPanelPreview()
        } else if ProcessInfo.processInfo.arguments.contains("--preview-scanning") {
            ScanningPreview()
        } else { ContentView() }
        #else
        ContentView()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .environment(\.locale, AppLanguage.resolve(language).locale)
                // Dark, immersive chrome everywhere: the camera and 3D scenes set the tone.
                .preferredColorScheme(.dark)
                .tint(DS.Palette.accent)
        }
    }
}

#if DEBUG
/// UI-only inspection without starting an AR session or writing scan files.
private struct CaptureControlsPreview: View {
    @StateObject private var controller = CaptureController()
    var body: some View {
        HUDOverlay(controller: controller)
            .background(Color.black)
            .preferredColorScheme(.dark)
    }
}

/// UI-only inspection of the scanning HUD in its busiest state.
private struct ScanningPreview: View {
    @StateObject private var controller = CaptureController()
    var body: some View {
        HUDOverlay(controller: controller)
            .background(LinearGradient(colors: [Color(white: 0.35), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
            .onAppear { controller.previewScanningState() }
    }
}

/// UI-only inspection of the post-scan review panel over a synthetic point cloud.
private struct ReviewPanelPreview: View {
    @StateObject private var controller = CaptureController()
    @State private var reset = 0
    var body: some View {
        ZStack {
            if !controller.reviewPoints.isEmpty {
                ReviewPointCloudView(points: controller.reviewPoints, trajectory: controller.reviewTrajectory,
                                     resetCameraToken: reset)
                    .ignoresSafeArea()
            }
            HUDOverlay(controller: controller, onResetView: { reset += 1 }, onTrain: { _ in })
        }
        .background(Color.black)
        .onAppear { controller.previewReviewState() }
    }
}
#endif
