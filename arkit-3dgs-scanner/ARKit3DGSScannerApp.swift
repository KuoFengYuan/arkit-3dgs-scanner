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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, AppLanguage.resolve(language).locale)
        }
    }
}
