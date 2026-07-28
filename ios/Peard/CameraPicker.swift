import AVFoundation
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

/// Camera capture with the square crop step (Requirement 13.3).
struct CameraPicker: UIViewControllerRepresentable {
    /// Called with the confirmed image, or `nil` when the user cancels
    /// (Requirement 13.7).
    let completion: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.cameraCaptureMode = .photo
        // `allowsEditing` presents the square crop step.
        picker.allowsEditing = true
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
