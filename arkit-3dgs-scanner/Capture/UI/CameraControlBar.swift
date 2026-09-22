//
//  CameraControlBar.swift
//  fable — 相機設定：具名控制項與自適應滑桿
//

import SwiftUI

struct CameraControlBar: View {
    @ObservedObject var controls: CameraControls
    /// 掃描中不給調 —— 中途改曝光會讓前後幀成像不一致，等於自己製造外觀不一致
    let enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(CameraControls.Item.allCases) { item in
                DisclosureGroup(isExpanded: Binding(
                    get: { controls.expanded == item },
                    set: { expanded in
                        if expanded { controls.syncFromDevice() }
                        controls.expanded = expanded ? item : nil
                    })) {
                    slider(for: item)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(item.label, systemImage: item.symbol)
                        Text(valueText(item)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            Button {
                controls.resetAll()
                controls.expanded = nil
            } label: {
                Label(L10n.text("重設相機參數"), systemImage: "arrow.uturn.backward")
                    .frame(minHeight: 44)
            }
            .disabled(!controls.hasManualOverride)
        }
        .disabled(!enabled)
    }

    // MARK: - 展開的滑桿

    @ViewBuilder
    private func slider(for item: CameraControls.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch item {
            case .ev:
                Slider(value: $controls.ev, in: controls.evRange) { _ in controls.applyEV() }
                    .onChange(of: controls.ev) { _, _ in controls.applyEV() }
            case .shutter:
                Slider(value: $controls.shutterSec, in: controls.shutterRange) { editing in
                    if editing { controls.shutterManual = true }
                    controls.applyExposure()
                }
                .onChange(of: controls.shutterSec) { _, _ in
                    controls.shutterManual = true; controls.applyExposure()
                }
            case .iso:
                Slider(value: $controls.iso, in: controls.isoRange) { editing in
                    if editing { controls.isoManual = true }
                    controls.applyExposure()
                }
                .onChange(of: controls.iso) { _, _ in
                    controls.isoManual = true; controls.applyExposure()
                }
            case .wb:
                Slider(value: $controls.kelvin, in: controls.kelvinRange) { editing in
                    if editing { controls.wbManual = true }
                    controls.applyWhiteBalance()
                }
                .onChange(of: controls.kelvin) { _, _ in
                    controls.wbManual = true; controls.applyWhiteBalance()
                }
            case .focus:
                Slider(value: $controls.lensPosition, in: 0...1) { editing in
                    if editing { controls.focusManual = true }
                    controls.applyFocus()
                }
                .onChange(of: controls.lensPosition) { _, _ in
                    controls.focusManual = true; controls.applyFocus()
                }
            }
            if item == .shutter {
                Text(L10n.text("較長曝光會增加運動模糊風險"))
                    .font(.caption2).foregroundStyle(.white.opacity(0.6))
            }
        }
        .tint(.cyan)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.label)
        .padding(.vertical, 10)
    }

    private func valueText(_ item: CameraControls.Item) -> String {
        switch item {
        case .ev:      String(format: "%+.1f EV", controls.ev)
        case .shutter: controls.shutterManual
                        ? "1/\(Int((1 / controls.shutterSec).rounded()))s" : L10n.text("自動")
        case .iso:     controls.isoManual ? "\(Int(controls.iso))" : L10n.text("自動")
        case .wb:      controls.wbManual ? "\(Int(controls.kelvin))K" : L10n.text("自動")
        case .focus:   controls.focusManual
                        ? String(format: "%.2f", controls.lensPosition) : L10n.text("自動")
        }
    }
}
