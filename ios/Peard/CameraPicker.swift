import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

/// Camera authorization (Requirement 13.1, 13.2).
enum CameraAuthorization {
    enum Result { case granted, denied }

    static func request() async -> Result {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .granted
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        default:
            return .denied
        }
    }
}

/// Camera capture. The square crop step (Requirement 13.3) comes after, in
/// `SquarePhotoEditor`, which does what `allowsEditing` did and then some —
/// so asking for it here as well would mean cropping the same photo twice.
struct CameraPicker: UIViewControllerRepresentable {
    /// Called with the confirmed image, or `nil` when the user cancels
    /// (Requirement 13.7).
    let completion: (UIImage?) -> Void

    /// Whether this device can take a picture at all. False on the simulator
    /// and on iPads without a camera, which is why the library route exists.
    static var canUseCamera: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let completion: (UIImage?) -> Void
        private var didFinish = false

        init(completion: @escaping (UIImage?) -> Void) {
            self.completion = completion
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard !didFinish else { return }
            didFinish = true
            let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            completion(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            guard !didFinish else { return }
            didFinish = true
            completion(nil)
        }
    }
}

/// The library, for devices with no camera.
///
/// `UIImagePickerController`'s own `.photoLibrary` used to serve this and now
/// aborts the process on iOS 26 — a crash that never fired on a phone, because
/// a phone always has a camera, and so sat in the one branch nobody reaches.
/// `PHPickerViewController` is the replacement Apple points at: it runs out of
/// process, which is why it needs no library permission and no usage
/// description to show somebody their own photos.
struct LibraryPicker: UIViewControllerRepresentable {
    let completion: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let completion: (UIImage?) -> Void
        private var didFinish = false

        init(completion: @escaping (UIImage?) -> Void) {
            self.completion = completion
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !didFinish else { return }
            didFinish = true

            guard
                let provider = results.first?.itemProvider,
                provider.canLoadObject(ofClass: UIImage.self)
            else {
                completion(nil)
                return
            }

            provider.loadObject(ofClass: UIImage.self) { object, _ in
                // Loading happens off the main thread, and everything the
                // completion touches is `@MainActor`.
                let image = object as? UIImage
                Task { @MainActor in self.completion(image) }
            }
        }
    }
}
