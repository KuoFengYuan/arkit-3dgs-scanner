// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import SwiftUI
import UIKit

/// Full-bleed surface for Gaussian renders with orbit (one finger), pan (two fingers), pinch
/// zoom and double-tap reset. Reports its size in pixels so renders match the view.
struct GaussianViewport: UIViewRepresentable {
    let image: CGImage?
    var orientation: UIImage.Orientation = .up
    let onOrbit: (CGSize) -> Void
    let onPan: (CGSize, CGFloat) -> Void
    let onZoom: (CGFloat) -> Void
    let onReset: () -> Void
    let onInteraction: (Bool) -> Void
    let onSize: (CGSize) -> Void

    func makeUIView(context: Context) -> ViewportView {
        let view = ViewportView()
        view.coordinator = context.coordinator
        let orbit = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.orbit(_:)))
        orbit.minimumNumberOfTouches = 1
        orbit.maximumNumberOfTouches = 1
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        let reset = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.reset))
        reset.numberOfTapsRequired = 2
        for g in [orbit, pan, pinch, reset] as [UIGestureRecognizer] { g.delegate = context.coordinator; view.addGestureRecognizer(g) }
        view.isAccessibilityElement = true
        view.accessibilityTraits = [.image, .allowsDirectInteraction]
        return view
    }

    func updateUIView(_ view: ViewportView, context: Context) {
        context.coordinator.parent = self
        if let image {
            if view.imageView.image?.cgImage !== image || view.imageView.image?.imageOrientation != orientation {
                view.imageView.image = UIImage(cgImage: image, scale: 1, orientation: orientation)
            }
        } else { view.imageView.image = nil }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class ViewportView: UIView {
        let imageView = UIImageView()
        weak var coordinator: Coordinator?
        private var reported: CGSize = .zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            addSubview(imageView)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            imageView.frame = bounds
            let pixels = CGSize(width: bounds.width * traitCollection.displayScale, height: bounds.height * traitCollection.displayScale)
            if pixels != reported, pixels.width > 0, pixels.height > 0 {
                reported = pixels
                coordinator?.parent.onSize(pixels)
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: GaussianViewport
        init(parent: GaussianViewport) { self.parent = parent }

        private func phase(_ g: UIGestureRecognizer) {
            switch g.state {
            case .began: parent.onInteraction(true)
            case .ended, .cancelled, .failed: parent.onInteraction(false)
            default: break
            }
        }

        @objc func orbit(_ g: UIPanGestureRecognizer) {
            phase(g)
            let t = g.translation(in: g.view)
            parent.onOrbit(CGSize(width: t.x, height: t.y))
            g.setTranslation(.zero, in: g.view)
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            phase(g)
            let t = g.translation(in: g.view)
            parent.onPan(CGSize(width: t.x, height: t.y), g.view?.bounds.height ?? 1)
            g.setTranslation(.zero, in: g.view)
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            phase(g)
            parent.onZoom(g.scale)
            g.scale = 1
        }

        @objc func reset() { parent.onReset() }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer) || (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
        }
    }
}
