// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). See LICENSE and NOTICE.
import UIKit

/// Presents the system share sheet for local files. `UIActivityViewController` hands share
/// extensions (LINE, Teams, Mail…) the file itself with its type from the extension (.zip),
/// whereas SwiftUI `ShareLink(item: URL)` offers a file URL that several extensions cannot
/// load — only AirDrop and Files accepted it.
@MainActor
enum SystemShare {
    static func present(_ files: [URL]) {
        guard !files.isEmpty,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController ?? scene.windows.first?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        let controller = UIActivityViewController(activityItems: files, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            // iPad: anchor at the bottom centre, where the action cards are.
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 120, width: 1, height: 1)
            popover.permittedArrowDirections = [.down]
        }
        top.present(controller, animated: true)
    }
}
