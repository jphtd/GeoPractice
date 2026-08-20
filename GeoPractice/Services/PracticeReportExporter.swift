import Photos
import SwiftUI
import UIKit

enum PracticeReportExportError: LocalizedError {
    case renderingFailed
    case photoAccessDenied

    var errorDescription: String? {
        switch self {
        case .renderingFailed:
            "无法生成练习结果图片，请稍后重试。"
        case .photoAccessDenied:
            "没有添加照片的权限。请在系统设置中允许 GeoBeat 添加照片。"
        }
    }
}

@MainActor
enum PracticeReportExporter {
    static func render<Content: View>(
        size: CGSize = CGSize(width: 540, height: 675),
        scale: CGFloat = 2,
        @ViewBuilder content: () -> Content
    ) throws -> UIImage {
        let renderer = ImageRenderer(content: content())
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = scale
        guard let image = renderer.uiImage else {
            throw PracticeReportExportError.renderingFailed
        }
        return image
    }

    static func saveToPhotoLibrary(_ image: UIImage) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PracticeReportExportError.photoAccessDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }
}
