import SwiftUI

/// The shared-element zoom between a photo thumbnail and the full-screen viewer
/// (#424). iOS 18 draws the thumbnail growing into the viewer and shrinking back
/// on dismiss; on iOS 17 (the deployment target) both modifiers are no-ops and
/// the cover uses its standard presentation — so the feature is purely additive.
///
/// Two halves that must agree on `id` and `namespace`:
/// - `photoZoomSource` marks the thumbnail the transition grows from;
/// - `photoZoomDestination` marks the presented viewer it grows into.
extension View {
    /// Mark a thumbnail as the source of the zoom for `id`.
    @ViewBuilder
    func photoZoomSource(id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// Mark the presented viewer as the destination of the zoom for `id`.
    @ViewBuilder
    func photoZoomDestination(id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}
