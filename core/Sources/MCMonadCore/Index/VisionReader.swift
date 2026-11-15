import CoreGraphics
import Vision

// AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).

/// The two things the index does with a capture's pixels: hash its strips
/// (`PixelTiles`) and read a part of it with Vision (the engine
/// `WindowPage.read` is given). Nothing here keeps a pixel or a word.
enum VisionReader {
    /// The capture's strip hashes, straight from its pixel buffer when it is
    /// 32-bit (any channel order), else from a 32-bit copy.
    static func tiles(of image: CGImage) -> PixelTiles? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        if image.bitsPerPixel == 32, image.bitsPerComponent == 8,
           let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data),
           CFDataGetLength(data) >= image.bytesPerRow * (h - 1) + w * 4 {
            return PixelTiles(pixels: UnsafeRawPointer(base), width: w, height: h, bytesPerRow: image.bytesPerRow)
        }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        return pixels.withUnsafeMutableBytes { buf -> PixelTiles? in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return PixelTiles(pixels: buf.baseAddress!, width: w, height: h, bytesPerRow: w * 4)
        }
    }

    /// Vision's lines in `sample` of `image`, in the sample's own pixels
    /// (top-left origin). Accurate recognition at retina scale: at 1× it
    /// lost a third of a page's words; here it kept 95–99%.
    static func recognise(_ image: CGImage, in sample: PixelRect) -> Result<[FoundLine], ReadFault> {
        guard let crop = image.cropping(to: CGRect(x: sample.x, y: sample.y, width: sample.w, height: sample.h)) else {
            return .failure(ReadFault(reason: "could not crop the capture"))
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0
        do {
            try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
        } catch {
            return .failure(ReadFault(reason: error.localizedDescription))
        }
        let w = Double(crop.width), h = Double(crop.height)
        return .success((request.results ?? []).compactMap { o -> FoundLine? in
            guard let best = o.topCandidates(1).first else { return nil }
            let b = o.boundingBox
            let x0 = Int((b.minX * w).rounded(.down)), x1 = Int((b.maxX * w).rounded(.up))
            let y0 = Int(((1 - b.maxY) * h).rounded(.down)), y1 = Int(((1 - b.minY) * h).rounded(.up))
            return FoundLine(rect: PixelRect(x: x0, y: y0, w: max(1, x1 - x0), h: max(1, y1 - y0)),
                             text: best.string, confidence: best.confidence)
        })
    }
}
