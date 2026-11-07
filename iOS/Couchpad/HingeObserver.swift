import SwiftUI
import UIKit

/// Reports whether a foldable (iPhone Duo) is half open, like a laptop: iOS 27.1's
/// `UIHingeInteraction` delivers the hinge's status to a view in the hierarchy. On any other
/// device, or an older iOS, the hinge is never reported and `partlyOpen` stays false.
struct HingeObserver: UIViewRepresentable {
    @Binding var partlyOpen: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        if #available(iOS 27.1, *) {
            let binding = $partlyOpen
            view.addInteraction(UIHingeInteraction { _, update in
                let partly = update.hinge?.status == .partiallyOpen
                if binding.wrappedValue != partly { binding.wrappedValue = partly }
            })
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
