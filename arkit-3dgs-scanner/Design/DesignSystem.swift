//
//  DesignSystem.swift
//  ARKit 3DGS Scanner — shared visual language
//
//  One set of tokens and components for every screen. The app is dark and 3D-first:
//  the camera feed or the point cloud fills the screen, and controls float above it on
//  dark glass. Keeping styles here stops the library, capture HUD and viewers drifting apart.
//

import SwiftUI

nonisolated enum DS {
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 22
        static let xl: CGFloat = 28
    }

    enum Size {
        /// Minimum touch target.
        static let control: CGFloat = 44
        static let primaryHeight: CGFloat = 52
        static let shutter: CGFloat = 78
        /// Floating panels and forms stay readable on iPad and in landscape.
        static let panelMaxWidth: CGFloat = 560
    }

    enum Palette {
        static let canvas = Color(red: 0.039, green: 0.043, blue: 0.051)
        static let surface = Color.white.opacity(0.06)
        static let surfaceRaised = Color.white.opacity(0.10)
        /// Opaque fill for disabled prominent controls, so content behind never shows through.
        static let disabledFill = Color(red: 0.15, green: 0.16, blue: 0.18)
        static let stroke = Color.white.opacity(0.10)
        static let textPrimary = Color.white
        static let textSecondary = Color.white.opacity(0.64)
        static let textTertiary = Color.white.opacity(0.40)
        /// Spatial cyan, also used by the processing screen and the asset catalog accent.
        static let accent = Color(red: 0.26, green: 0.91, blue: 0.94)
        /// Text and icons on accent fills (the accent is light, so white would lack contrast).
        static let onAccent = Color(red: 0.02, green: 0.10, blue: 0.12)
        static let record = Color(red: 1.00, green: 0.27, blue: 0.23)
        static let success = Color(red: 0.27, green: 0.85, blue: 0.55)
        static let warning = Color(red: 1.00, green: 0.72, blue: 0.25)
        static let danger = Color(red: 1.00, green: 0.38, blue: 0.36)
        static let info = Color(red: 0.45, green: 0.66, blue: 1.00)
    }

    /// Semantic tone for status pills, banners and badges.
    enum Tone {
        case neutral, accent, success, warning, danger, info
        var color: Color {
            switch self {
            case .neutral: return Palette.textSecondary
            case .accent: return Palette.accent
            case .success: return Palette.success
            case .warning: return Palette.warning
            case .danger: return Palette.danger
            case .info: return Palette.info
            }
        }
    }

    static let springy = Animation.spring(response: 0.32, dampingFraction: 0.82)
}

// MARK: - Surfaces

extension View {
    /// Opaque-looking card on the app canvas (lists, sheets, empty states).
    func dsCard(radius: CGFloat = DS.Radius.l, padding: CGFloat = DS.Space.m) -> some View {
        self.padding(padding)
            .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(DS.Palette.stroke, lineWidth: 0.5))
    }

    /// Floating panel over the camera or the 3D scene.
    func dsFloatingPanel(radius: CGFloat = DS.Radius.xl) -> some View {
        self.hudGlass(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    /// App-wide dark canvas behind scrolling content.
    func dsCanvas() -> some View {
        background(DS.Palette.canvas.ignoresSafeArea())
    }
}

// MARK: - Buttons

/// The one prominent action on a screen: accent capsule with pressed, hover, loading and
/// disabled states.
struct DSPrimaryButtonStyle: ButtonStyle {
    var fill = true
    var isLoading = false
    var tint: Color = DS.Palette.accent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: DS.Space.xs) {
            if isLoading { ProgressView().tint(DS.Palette.onAccent).controlSize(.small) }
            configuration.label.labelStyle(.titleAndIcon)
        }
        .font(.headline)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .foregroundStyle(isEnabled || isLoading ? DS.Palette.onAccent : DS.Palette.textTertiary)
        .padding(.horizontal, DS.Space.xl)
        .frame(minHeight: DS.Size.primaryHeight)
        .frame(maxWidth: fill ? .infinity : nil)
        .background(Capsule().fill(isEnabled || isLoading ? tint : DS.Palette.disabledFill))
        .contentShape(Capsule())
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .brightness(configuration.isPressed ? -0.08 : 0)
        .animation(DS.springy, value: configuration.isPressed)
        .hoverEffect(.lift)
    }
}

/// Secondary actions: dark glass capsule, quieter than the primary action.
struct DSSecondaryButtonStyle: ButtonStyle {
    var fill = false
    var tint: Color = DS.Palette.textPrimary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(tint.opacity(isEnabled ? 1 : 0.4))
            .padding(.horizontal, DS.Space.m)
            .frame(minHeight: DS.Size.control)
            .frame(maxWidth: fill ? .infinity : nil)
            .hudGlass(Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(DS.springy, value: configuration.isPressed)
            .hoverEffect(.highlight)
    }
}

/// Round glass icon button. `isSelected` shows toggles that are on.
struct DSIconButtonStyle: ButtonStyle {
    var isSelected = false
    var tint: Color = DS.Palette.accent
    var size: CGFloat = DS.Size.control
    /// Icon colour while not selected (e.g. danger for destructive actions).
    var foreground: Color = DS.Palette.textPrimary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(isSelected ? tint : foreground)
            .frame(width: size, height: size)
            .hudGlass(Circle(), tint: isSelected ? tint : nil)
            .contentShape(Circle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(DS.springy, value: configuration.isPressed)
            .animation(DS.springy, value: isSelected)
            .hoverEffect(.highlight)
    }
}

// MARK: - Status

/// Compact status capsule: tinted icon, short text, optional pulsing recording dot.
struct DSStatusPill: View {
    let text: String
    var symbol: String? = nil
    var tone: DS.Tone = .neutral
    var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 7) {
            if pulsing {
                Circle().fill(DS.Palette.record).frame(width: 8, height: 8)
                    .opacity(pulse ? 0.35 : 1)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(), value: pulse)
                    .onAppear { pulse = true }
            } else if let symbol {
                Image(systemName: symbol).font(.footnote.weight(.semibold))
                    .foregroundStyle(tone == .neutral ? DS.Palette.textPrimary : tone.color)
            }
            Text(text).font(.subheadline.weight(.semibold)).lineLimit(2)
        }
        .hudText()
        .multilineTextAlignment(.center)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .hudGlass(Capsule(), tint: tone == .neutral || tone == .accent ? nil : tone.color)
        .accessibilityElement(children: .combine)
    }
}

/// Icon + value pair for compact statistics rows.
struct DSMetric: View {
    let value: String
    let symbol: String
    var tone: DS.Tone = .neutral

    var body: some View {
        Label {
            Text(value).font(.caption.weight(.medium).monospacedDigit())
        } icon: {
            Image(systemName: symbol).font(.caption2.weight(.semibold))
                .foregroundStyle(tone == .neutral ? DS.Palette.textSecondary : tone.color)
        }
        .foregroundStyle(tone == .neutral ? DS.Palette.textPrimary : tone.color)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(DS.Palette.surfaceRaised, in: Capsule())
        .lineLimit(1)
    }
}

/// Circular determinate progress.
struct DSProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 4
    var tint: Color = DS.Palette.accent

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress.isFinite ? min(1, max(0, progress)) : 0)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.35), value: progress)
        }
    }
}

/// Transient confirmation or error banner shown at the top of an immersive screen.
struct DSToast: View {
    let text: String
    var symbol = "checkmark.circle.fill"
    var tone: DS.Tone = .success

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: symbol).foregroundStyle(tone.color)
            Text(text).font(.subheadline.weight(.semibold))
        }
        .hudText()
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
        .hudGlass(Capsule(), tint: tone.color)
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Selection and cards

/// One option of `DSSegmentedPicker`.
struct DSSegment<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    let symbol: String
    var id: Value { value }
}

/// Floating glass segmented control with a sliding accent selection.
struct DSSegmentedPicker<Value: Hashable>: View {
    let segments: [DSSegment<Value>]
    @Binding var selection: Value
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: DS.Space.xxs) {
            ForEach(segments) { segment in
                let selected = selection == segment.value
                Button {
                    withAnimation(DS.springy) { selection = segment.value }
                } label: {
                    Label(segment.title, systemImage: segment.symbol)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .foregroundStyle(selected ? DS.Palette.onAccent : DS.Palette.textPrimary)
                        .background {
                            if selected {
                                Capsule().fill(DS.Palette.accent)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(DS.Space.xxs)
        .hudGlass(Capsule())
    }
}

/// Library cards: slight press and pointer lift, no default button tint.
struct DSCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(DS.springy, value: configuration.isPressed)
            .hoverEffect(.lift)
    }
}

/// Wraps chips onto as many rows as needed instead of clipping or scrolling them.
struct DSFlowLayout: Layout {
    var spacing: CGFloat = DS.Space.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = Self.size(of: subviews[index], width: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(width: size.width, height: size.height))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    /// Ideal size, or the size wrapped to the row width for items wider than a row.
    private static func size(of subview: LayoutSubview, width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard width.isFinite, ideal.width > width else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = Self.size(of: subviews[index], width: width)
            let itemWidth = size.width
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + itemWidth > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + itemWidth
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
