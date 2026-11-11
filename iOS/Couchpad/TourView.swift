import SwiftUI

/// The controls the first-run tour points at. Each one publishes its bounds with
/// `.tourTarget(_:)`, wherever the current layout happens to put it, so the tour never
/// needs to know the layouts: a control that is not on screen has no anchor, and its step
/// is left out.
enum TourTarget: Hashable {
    case trackpad, status, screen, keyRow, keyboard, controller, mouse, settings
}

/// One card of the tour.
struct TourStep {
    let target: TourTarget
    let title: String
    let detail: String

    /// In the order they are shown. Steps whose control is missing right now (the screen
    /// button on Windows or while not connected, the controller button while not connected)
    /// are skipped, and the count only counts the ones that are there.
    static let all: [TourStep] = [
        TourStep(target: .trackpad, title: "Trackpad",
                 detail: "Slide a finger to move the pointer and tap to click. Two fingers scroll; a two-finger tap right-clicks."),
        TourStep(target: .status, title: "Connection",
                 detail: "Green means connected. Tap the dot to switch computers or see how the connection is doing."),
        TourStep(target: .screen, title: "Screen",
                 detail: "Shows the Mac's screen here on the trackpad. Touch it to work on it, pinch to zoom in."),
        TourStep(target: .keyRow, title: "Key row",
                 detail: "Shows or hides esc, tab, the modifier keys and F1–F12."),
        TourStep(target: .keyboard, title: "Keyboard",
                 detail: "Brings up the iPhone keyboard. What you type goes to the computer."),
        TourStep(target: .controller, title: "Controller",
                 detail: "Swaps in a stick and buttons for games. Each button shows its key; Settings changes them."),
        TourStep(target: .mouse, title: "Left and Right",
                 detail: "The mouse buttons. Hold one while you move the pointer to drag."),
        TourStep(target: .settings, title: "Settings",
                 detail: "Pointer and scroll speed, picture quality and your computers. The full gesture list and this tour are under About."),
    ]
}

/// Where the tour's controls are, as anchors: they resolve in whatever space the overlay
/// reads them in, and they follow the control through rotations and folds by themselves.
struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [TourTarget: Anchor<CGRect>] = [:]
    /// The first one wins: a target is only ever tagged once per layout, and if a view on its
    /// way out still reports one, the one already there is kept.
    static func reduce(value: inout [TourTarget: Anchor<CGRect>], nextValue: () -> [TourTarget: Anchor<CGRect>]) {
        value.merge(nextValue()) { first, _ in first }
    }
}

extension View {
    /// Marks this view as the control a tour step points at. `enabled` false publishes
    /// nothing but keeps the view's identity, for a view that is only sometimes the target
    /// (the picture's half of a half-open foldable, when the flat half has a trackpad).
    func tourTarget(_ target: TourTarget, enabled: Bool = true) -> some View {
        transformAnchorPreference(key: TourAnchorKey.self, value: .bounds) { targets, anchor in
            if enabled, targets[target] == nil { targets[target] = anchor }
        }
    }

    /// Draws the tour over this view while `step` is set (an index into `TourStep.all`),
    /// and hides this view from VoiceOver meanwhile. Applied at the root, after the
    /// layouts' own padding and safe-area handling: the overlay itself spans the whole
    /// window either way. `edges`: the safe-area edges the layouts draw into (the root's own
    /// `ignoresSafeArea`), where the card may go too.
    func tourOverlay(step: Binding<Int?>, extendingInto edges: Edge.Set) -> some View {
        accessibilityHidden(step.wrappedValue != nil)
            .overlayPreferenceValue(TourAnchorKey.self) { anchors in
                TourOverlay(step: step, anchors: anchors, edges: edges)
            }
    }
}

/// The dim layer with a hole around the current step's control, and the card beside it.
/// It takes every touch while it is up: nothing under it reacts, and a tap anywhere but on
/// the card's buttons moves on, like Next. (Except in the safe-area strips no layout draws
/// in, such as the Dynamic Island's side held sideways: SwiftUI hit-tests no deeper than
/// the root's content there, so a tap on the dim in them does nothing at all.)
private struct TourOverlay: View {
    @Binding var step: Int?
    let anchors: [TourTarget: Anchor<CGRect>]
    let edges: Edge.Set
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let current = step {
            // The space the layouts use (the window less the safe areas they leave alone, such
            // as the Dynamic Island's side held sideways): the card stays inside it.
            GeometryReader { layout in
                // One reader for the whole window, safe areas (and the Duo's status-bar panel)
                // included: the anchors resolve in its space, and the dim layer and the card
                // are drawn in the same one, so the hole cannot be offset by an inset.
                GeometryReader { proxy in
                    let area = Self.area(of: layout, in: proxy, extending: edges)
                    let rects = anchors.mapValues { proxy[$0] }
                    let present = TourStep.all.indices.filter { rects[TourStep.all[$0].target] != nil }
                    // The step on screen: the current one, or, if its control has gone (a
                    // disconnect, a rotation that changed the bar), the next one that is there.
                    let shown = present.first { $0 >= current }
                    let target = shown.map { TourStep.all[$0].target }
                    let hole = target.flatMap { target in rects[target].map { Self.hole(around: $0, for: target) } }
                    ZStack {
                        TourDim(hole: hole ?? .zero)
                            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                        // A hairline round the hole: the app is dark, and a dimmed black edge
                        // next to an undimmed black one barely shows where the hole is.
                        TourDim(hole: hole ?? .zero, ringOnly: true)
                            .stroke(Color.white.opacity(0.4), lineWidth: 1.5)
                        // The dim layer has a hole, which would let touches through to the
                        // control under it: this takes them all.
                        Color.clear.contentShape(Rectangle())
                        if let shown, let hole {
                            TourCardPlacement(hole: hole, inside: target == .trackpad, area: area) {
                                TourCard(step: TourStep.all[shown],
                                         number: (present.firstIndex(of: shown) ?? 0) + 1, count: present.count,
                                         last: present.last == shown,
                                         next: { advance(from: shown, present: present) },
                                         skip: end)
                            }
                            .id(shown)
                            .transition(.opacity)
                        }
                    }
                    .onTapGesture { advance(from: shown ?? current, present: present) }
                    .onChange(of: shown) { _, shown in
                        // Moved on by itself: the count and Next carry on from there.
                        if let shown, shown != step { step = shown }
                    }
                }
                .ignoresSafeArea()
            }
            .transition(.opacity)
        }
    }

    /// Where the layouts draw, in `window`'s space: `layout`'s frame, which is the safe part of
    /// the window (the root's `ignoresSafeArea` lets the content run past it without growing
    /// it), grown into the safe areas the content takes on `edges` (the Duo's empty panel,
    /// the bottom sideways). `layout.safeAreaInsets` are the insets that frame leaves out
    /// (62 pt each side on an iPhone 17 Pro sideways, 84 pt for the folded Duo's panel).
    static func area(of layout: GeometryProxy, in window: GeometryProxy, extending edges: Edge.Set) -> CGRect {
        let origin = window.frame(in: .global).origin
        var frame = layout.frame(in: .global).offsetBy(dx: -origin.x, dy: -origin.y)
        let insets = layout.safeAreaInsets
        if edges.contains(.leading) { frame.origin.x -= insets.leading; frame.size.width += insets.leading }
        if edges.contains(.trailing) { frame.size.width += insets.trailing }
        if edges.contains(.top) { frame.origin.y -= insets.top; frame.size.height += insets.top }
        if edges.contains(.bottom) { frame.size.height += insets.bottom }
        return frame
    }

    /// The hole: the control's bounds with a little air, the corners rounded like the
    /// control's own.
    static func hole(around rect: CGRect, for target: TourTarget) -> RoundedHole {
        let air: CGFloat = 5
        return RoundedHole(rect: rect.insetBy(dx: -air, dy: -air), radius: (target == .trackpad ? 16 : 10) + air)
    }

    private var animation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.25) }

    private func advance(from index: Int, present: [Int]) {
        withAnimation(animation) { step = present.first { $0 > index } }
    }

    private func end() {
        withAnimation(animation) { step = nil }
    }
}

private struct RoundedHole: Equatable {
    var rect: CGRect
    var radius: CGFloat
    static let zero = RoundedHole(rect: .zero, radius: 0)
}

/// The whole area with a rounded hole in it (filled even-odd). Animatable, so the hole
/// glides from one control to the next. `ringOnly` is the hole's outline alone.
private struct TourDim: Shape {
    var hole: RoundedHole
    var ringOnly = false

    var animatableData: AnimatablePair<CGRect.AnimatableData, CGFloat> {
        get { AnimatablePair(hole.rect.animatableData, hole.radius) }
        set { hole.rect.animatableData = newValue.first; hole.radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = ringOnly ? Path() : Path(rect.insetBy(dx: -1, dy: -1))
        if hole.rect.width > 0 {
            path.addRoundedRect(in: hole.rect, cornerSize: CGSize(width: hole.radius, height: hole.radius), style: .continuous)
        }
        return path
    }
}

/// Puts the card next to the hole: above or below it, whichever side has more room, centred
/// on it across and kept inside `area` (where the layouts draw) with 12 pt to spare. A hole as
/// big as a pane (the trackpad's) has the card centred inside it instead.
private struct TourCardPlacement: Layout {
    let hole: RoundedHole
    let inside: Bool
    /// In the same space as the hole: the overlay's, which is the window's.
    let area: CGRect

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let margin: CGFloat = 12
        let gap: CGFloat = 10
        let area = self.area.offsetBy(dx: bounds.minX, dy: bounds.minY).insetBy(dx: margin, dy: margin)
        let hole = self.hole.rect.offsetBy(dx: bounds.minX, dy: bounds.minY)
        let width = max(0, min(340, area.width))
        for card in subviews {
            var size = card.sizeThatFits(ProposedViewSize(width: width, height: nil))
            size.height = min(size.height, area.height)
            var y: CGFloat
            if inside {
                y = hole.midY - size.height / 2
            } else {
                let above = hole.minY - gap - area.minY
                let below = area.maxY - (hole.maxY + gap)
                y = above >= below ? hole.minY - gap - size.height : hole.maxY + gap
            }
            y = min(max(y, area.minY), area.maxY - size.height)
            let x = min(max(hole.midX - width / 2, area.minX), area.maxX - width)
            card.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: width, height: size.height))
        }
    }
}

/// The card: what the control is, a line or two on what it does, where the tour is, and
/// Skip / Next. Flat and opaque like the bar's buttons (no glass, no material). One stop
/// for VoiceOver, its buttons after it; everything under the tour is hidden meanwhile.
private struct TourCard: View {
    let step: TourStep
    let number: Int
    let count: Int
    let last: Bool
    let next: () -> Void
    let skip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title).font(.headline)
                Text(step.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            HStack(spacing: 12) {
                Text("\(number) of \(count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Step \(number) of \(count)")
                Spacer(minLength: 0)
                if !last {
                    Button("Skip", action: skip)
                }
                Button(last ? "Done" : "Next", action: next)
                    .buttonStyle(.borderedProminent)
                    .fontWeight(.semibold)
            }
        }
        .padding(16)
        // Tertiary rather than secondary: the trackpad step puts the card on the trackpad,
        // which is secondarySystemBackground itself.
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        // Larger text grows the card, up to a size that still fits a phone held sideways.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}
