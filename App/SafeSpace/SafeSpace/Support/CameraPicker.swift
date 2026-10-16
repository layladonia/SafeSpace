import SwiftUI
import UIKit

/// Wraps the system camera screen. Requires "Privacy - Camera Usage Description"
/// (NSCameraUsageDescription) in the target's Info settings, or the app crashes
/// when the camera opens. Photos taken here are not saved to the photo library.
struct CameraPicker: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    /// False on the simulator and on devices without a camera.
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

extension UIImage {
    /// Full-quality JPEG with the pixels rotated upright, so the file needs no
    /// EXIF orientation. Redrawing with `imageRendererFormat` keeps the image's
    /// own color range, so a Display P3 camera photo stays P3.
    func uprightJPEGData() -> Data? {
        guard imageOrientation != .up else {
            return jpegData(compressionQuality: 1.0)
        }
        let renderer = UIGraphicsImageRenderer(size: size, format: imageRendererFormat)
        let upright = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
        return upright.jpegData(compressionQuality: 1.0)
    }
}
