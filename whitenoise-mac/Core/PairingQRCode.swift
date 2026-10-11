#if WN_EXPERIMENTAL_DEVICE_SYNC
    import CoreImage
    import Foundation
    import ImageIO

    /// A bounded transport label only. The original SDK still authenticates every received packet.
    nonisolated enum PairingQRCode {
        static let prefix = "whitenoise-pairing:v1:"
        static let maximumTextBytes = 2200
        static let maximumImageBytes = 4 * 1024 * 1024
        enum Failure: Error { case invalidPacket, tooLarge, unreadableImage }

        static func encode(_ bytes: Data) throws -> String {
            guard !bytes.isEmpty else { throw Failure.invalidPacket }
            // Bound before allocating base64. QR M capacity is lower than the native wire bound.
            guard bytes.count <= (maximumTextBytes - prefix.utf8.count) / 4 * 3 else { throw Failure.tooLarge }
            let payload = prefix + bytes.base64EncodedString()
            guard payload.utf8.count <= maximumTextBytes else { throw Failure.tooLarge }
            return payload
        }
        static func decode(_ payload: String) throws -> String {
            guard payload.utf8.count <= maximumTextBytes else { throw Failure.tooLarge }
            guard payload.hasPrefix(prefix) else { throw Failure.invalidPacket }
            let encoded = String(payload.dropFirst(prefix.count))
            guard !encoded.isEmpty, let bytes = Data(base64Encoded: encoded), bytes.base64EncodedString() == encoded
            else { throw Failure.invalidPacket }
            return encoded
        }
        static func imageData(at url: URL) throws -> Data {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw Failure.unreadableImage }
            guard let size = values.fileSize, size <= maximumImageBytes else { throw Failure.tooLarge }
            let file = try FileHandle(forReadingFrom: url)
            let data: Data
            do {
                data = try file.read(upToCount: maximumImageBytes + 1) ?? Data()
                try file.close()
            } catch {
                // Preserve the original read failure; deinit also releases this local descriptor.
                try? file.close()
                throw error
            }
            guard data.count <= maximumImageBytes else { throw Failure.tooLarge }
            return data
        }
        static func readImage(_ data: Data) throws -> String {
            guard data.count <= maximumImageBytes else { throw Failure.tooLarge }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                CGImageSourceGetCount(source) == 1,
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
            else { throw Failure.unreadableImage }
            guard width.intValue > 0, height.intValue > 0, width.intValue <= 4096, height.intValue <= 4096
            else { throw Failure.tooLarge }
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                let detector = CIDetector(
                    ofType: CIDetectorTypeQRCode, context: CIContext(),
                    options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
            else { throw Failure.unreadableImage }
            let packets = detector.features(in: CIImage(cgImage: image)).compactMap {
                ($0 as? CIQRCodeFeature)?.messageString
            }
            guard packets.count == 1, let packet = packets.first else { throw Failure.invalidPacket }
            return try decode(packet)
        }
    }
#endif
