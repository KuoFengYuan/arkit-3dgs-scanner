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
        if ProcessInfo.processInfo.arguments.contains("--preview-fusion") {
            FusionProcessingView(progress: 0.67, stage: .fusing,
                detail: L10n.text("融合點雲… 176 / 399 幀"), frameCount: 399,
                startedAt: Date().addingTimeInterval(-42))
        } else if ProcessInfo.processInfo.arguments.contains("--preview-capture-controls") {
            CaptureControlsPreview()
        } else { ContentView() }
        #else
        ContentView()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .environment(\.locale, AppLanguage.resolve(language).locale)
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
#endif
