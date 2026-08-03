import SwiftUI
import Vision
import CoreImage

// ============================================================
// StickerBaker.swift — 把一张照片烤成贴纸。
//
// 烤一次，存成 PNG，以后每次贴都是现成图 —— 不在渲染时反复跑 Vision。
// 两步：
//   1. 主体提取（VNGenerateForegroundInstanceMaskRequest，iOS 17+，全程在设备上，不联网）
//   2. 套模切白边（膨胀 alpha 当底片刷白，原图叠上去）
// 白边比例跟内置素材烤制时用的是同一个数，两种贴纸才是一套的。
// 投影不烤进图，留给渲染层加，这样拖动时能让影子跟着变重。
// ============================================================

enum StickerBaker {
    /// 白边宽度占短边的比例；内置素材在 Mac 上也是按这个数烤的
    static let borderRatio: CGFloat = 0.038

    enum BakeError: Error { case noSubject, renderFailed }

    /// 完整流程：抠主体 → 加白边。抠不出主体就拿整张图套白边。
    static func bake(_ image: UIImage) async throws -> UIImage {
        let subject = (try? await liftSubject(image)) ?? nil
        guard let outlined = outline(subject ?? normalized(image)) else {
            throw BakeError.renderFailed
        }
        return outlined
    }

    /// 系统主体提取。相册里长按主体能把它拎出来的就是这个能力。
    static func liftSubject(_ image: UIImage) async throws -> UIImage? {
        guard let cg = normalized(image).cgImage else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try handler.perform([request])
        #if DEBUG
        print("[bake] results=\(request.results?.count ?? -1) instances=\(request.results?.first?.allInstances.count ?? -1)")
        #endif
        guard let result = request.results?.first,
              !result.allInstances.isEmpty else { return nil }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances,
                                                    from: handler,
                                                    croppedToInstancesExtent: true)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let out = context.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: out)
    }

    /// 模切白边：alpha 膨胀出一圈，整体刷白当底片，原图压在上面
    static func outline(_ image: UIImage, ratio: CGFloat? = nil) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let src = CIImage(cgImage: cg)
        let r = max(6, min(src.extent.width, src.extent.height) * (ratio ?? borderRatio))

        // 膨胀前先把半透明边缘拉硬，免得白边发虚
        let hardened = src.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 2.2)
        ])
        let plate = hardened
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: r])
            .applyingFilter("CIColorMatrix", parameters: [        // 形状留着，颜色全刷白
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0)
            ])

        let composed = src.composited(over: plate)
        let rect = composed.extent.intersection(
            src.extent.insetBy(dx: -r - 4, dy: -r - 4))
        guard !rect.isInfinite, !rect.isEmpty,
              let out = context.createCGImage(composed, from: rect) else { return nil }
        return UIImage(cgImage: out)
    }

    // 相机拍的图带 EXIF 旋转，先摆正再进 Vision，否则抠出来是躺着的
    private static func normalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let f = UIGraphicsImageRendererFormat.default()
        f.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: f).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private static let context = CIContext(options: [.useSoftwareRenderer: false])
}
