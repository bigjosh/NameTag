import Foundation
import FirebaseStorage
import UIKit

@Observable
final class StorageService {
    private let storage = Storage.storage()

    func uploadProfilePhoto(uid: String, image: UIImage) async throws -> String {
        // Resize image to max 500x500 to avoid memory issues and speed up upload
        let resized = resizeImage(image, maxDimension: 500)

        guard let data = resized.jpegData(compressionQuality: 0.7) else {
            throw StorageError.compressionFailed
        }

        let ref = storage.reference()
            .child(StoragePath.profilePhotos)
            .child(uid)
            .child("profile.jpg")

        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"

        // Use the completion-handler API wrapped in withCheckedThrowingContinuation
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StorageMetadata, Error>) in
            ref.putData(data, metadata: metadata) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: StorageError.uploadFailed)
                }
            }
        }

        let url = try await ref.downloadURL()
        return url.absoluteString
    }

    func deleteProfilePhoto(uid: String) async throws {
        let ref = storage.reference()
            .child(StoragePath.profilePhotos)
            .child(uid)
            .child("profile.jpg")
        // Ignore error if photo doesn't exist
        try? await ref.delete()
    }

    private func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension else { return image }

        let scale = maxDimension / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

enum StorageError: LocalizedError {
    case compressionFailed
    case uploadFailed

    var errorDescription: String? {
        switch self {
        case .compressionFailed:
            return "Failed to compress the image. Please try a different photo."
        case .uploadFailed:
            return "Failed to upload the photo. Please try again."
        }
    }
}
