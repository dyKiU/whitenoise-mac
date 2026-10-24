#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Compression
    import CoreImage
    import CryptoKit
    import Foundation
    import ImageIO

    /// A bounded transport label only. The original SDK still authenticates every received packet.
    nonisolated enum PairingQRCode {
        /// Only a bounded transport format check; Core validates the actual attempt.
        static func isAutomaticBootstrap(_ bytes: Data) -> Bool {
            guard bytes.count <= 1024, let code = String(data: bytes, encoding: .utf8) else { return false }
            return code.hasPrefix("WNPAIR1:") || code.hasPrefix("WNPAIR2:")
        }

        static let prefix = "whitenoise-pairing:v1:"
        static let maximumTextBytes = 2200
        static let compressedPrefix = "whitenoise-pairing:v2:deflate:"
        static let maximumPacketBytes = 49_152
        static let maximumImageBytes = 4 * 1024 * 1024
        enum Failure: Error { case invalidPacket, tooLarge, unreadableImage, expired, conflictingTransfer }

        static func encode(_ bytes: Data) throws -> String {
            guard !bytes.isEmpty else { throw Failure.invalidPacket }
            guard bytes.count <= maximumPacketBytes else { throw Failure.tooLarge }
            let capacity = (maximumTextBytes - prefix.utf8.count) / 4 * 3
            if bytes.count <= capacity { return prefix + bytes.base64EncodedString() }
            let compressedCapacity = (maximumTextBytes - compressedPrefix.utf8.count) / 4 * 3
            return compressedPrefix + (try compressed(bytes, capacity: compressedCapacity)).base64EncodedString()
        }
        static let fragmentPrefix = "whitenoise-pairing:v3:part:"
        static let fragmentBytes = 1536
        static let maximumFrames = 32

        /// Transport integrity only; the original SDK still authenticates reconstructed bytes.
        static func encodePages(_ bytes: Data) throws -> [String] {
            do { return [try encode(bytes)] } catch Failure.tooLarge {
                guard !bytes.isEmpty, bytes.count <= maximumPacketBytes else { throw Failure.tooLarge }
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                let count = (bytes.count + fragmentBytes - 1) / fragmentBytes
                guard count >= 2, count <= maximumFrames else { throw Failure.tooLarge }
                return try (0..<count).map { ordinal in
                    let lower = ordinal * fragmentBytes
                    let part = bytes.subdata(in: lower..<min(lower + fragmentBytes, bytes.count))
                    let payload =
                        "\(fragmentPrefix)\(digest):\(bytes.count):\(ordinal):\(count):\(part.base64EncodedString())"
                    guard payload.utf8.count <= maximumTextBytes else { throw Failure.tooLarge }
                    return payload
                }
            }
        }

        private struct Fragment {
            let digest: String
            let totalBytes: Int
            let ordinal: Int
            let count: Int
            let bytes: Data
            init(_ payload: String) throws {
                guard payload.utf8.count <= maximumTextBytes, payload.hasPrefix(fragmentPrefix) else {
                    throw Failure.invalidPacket
                }
                let fields = payload.dropFirst(fragmentPrefix.count).split(
                    separator: ":", omittingEmptySubsequences: false)
                guard fields.count == 5 else { throw Failure.invalidPacket }
                let hash = String(fields[0])
                guard hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
                else { throw Failure.invalidPacket }
                func canonical(_ value: Substring) throws -> Int {
                    guard let number = Int(value), String(number) == value else { throw Failure.invalidPacket }
                    return number
                }
                let total = try canonical(fields[1])
                let index = try canonical(fields[2])
                let parts = try canonical(fields[3])
                guard total > 0, total <= maximumPacketBytes, parts >= 2, parts <= maximumFrames,
                    parts == (total + fragmentBytes - 1) / fragmentBytes, index >= 0, index < parts,
                    let body = Data(base64Encoded: String(fields[4])), body.base64EncodedString() == fields[4],
                    body.count == (index == parts - 1 ? total - fragmentBytes * (parts - 1) : fragmentBytes)
                else { throw Failure.invalidPacket }
                digest = hash
                totalBytes = total
                ordinal = index
                count = parts
                bytes = body
            }
        }

        struct FragmentAccumulator {
            private let deadline: ContinuousClock.Instant
            private var lastNow: ContinuousClock.Instant
            private var digest: String?
            private var byteCount = 0
            private var frameCount = 0
            private var parts: [Int: Data] = [:]
            private var completed = false
            private var retired = false
            var receivedFrameCount: Int { parts.count }
            var totalFrameCount: Int? { digest == nil ? nil : frameCount }

            init(now: ContinuousClock.Instant = ContinuousClock().now) {
                deadline = now + .seconds(120)
                lastNow = now
            }
            /// Reset is terminal. A fresh account/owner import creates a fresh accumulator.
            mutating func reset() {
                retired = true
                parts.removeAll()
                digest = nil
                byteCount = 0
                frameCount = 0
            }
            mutating func ingest(_ payload: String, now: ContinuousClock.Instant = ContinuousClock().now) throws
                -> String?
            {
                guard !retired, now >= lastNow, now < deadline else {
                    reset()
                    throw Failure.expired
                }
                lastNow = now
                if !payload.hasPrefix(fragmentPrefix) {
                    guard digest == nil, !completed else { throw Failure.conflictingTransfer }
                    let packet = try decode(payload)
                    completed = true
                    return packet
                }
                let fragment = try Fragment(payload)
                if let digest {
                    guard digest == fragment.digest, byteCount == fragment.totalBytes, frameCount == fragment.count
                    else { throw Failure.conflictingTransfer }
                } else {
                    guard !completed else { throw Failure.conflictingTransfer }
                    digest = fragment.digest
                    byteCount = fragment.totalBytes
                    frameCount = fragment.count
                }
                if let old = parts[fragment.ordinal] {
                    guard old == fragment.bytes else { throw Failure.conflictingTransfer }
                    return nil
                }
                guard !completed else { throw Failure.conflictingTransfer }
                parts[fragment.ordinal] = fragment.bytes
                guard parts.count == frameCount else { return nil }
                var packet = Data()
                packet.reserveCapacity(byteCount)
                for ordinal in 0..<frameCount {
                    guard let part = parts[ordinal] else { throw Failure.invalidPacket }
                    packet.append(part)
                }
                guard packet.count == byteCount,
                    SHA256.hash(data: packet).map({ String(format: "%02x", $0) }).joined() == digest
                else {
                    reset()
                    throw Failure.invalidPacket
                }
                completed = true
                return packet.base64EncodedString()
            }
        }

        static func decode(_ payload: String) throws -> String {
            guard payload.utf8.count <= maximumTextBytes else { throw Failure.tooLarge }
            let compressed = payload.hasPrefix(compressedPrefix)
            guard compressed || payload.hasPrefix(prefix) else { throw Failure.invalidPacket }
            let label = compressed ? compressedPrefix : prefix
            let encoded = String(payload.dropFirst(label.count))
            guard !encoded.isEmpty, let bytes = Data(base64Encoded: encoded), bytes.base64EncodedString() == encoded
            else { throw Failure.invalidPacket }
            return compressed ? try decompressed(bytes).base64EncodedString() : encoded
        }

        // Fixed output buffers bound allocation and refuse truncated decompression.
        private static func compressed(_ bytes: Data, capacity: Int) throws -> Data {
            var output = [UInt8](repeating: 0, count: capacity)
            let count = bytes.withUnsafeBytes { source in
                output.withUnsafeMutableBufferPointer { destination in
                    compression_encode_buffer(
                        destination.baseAddress!, capacity,
                        source.bindMemory(to: UInt8.self).baseAddress!, bytes.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard count > 0 else { throw Failure.tooLarge }
            return Data(output.prefix(count))
        }
        private static func decompressed(_ bytes: Data) throws -> Data {
            var output = [UInt8](repeating: 0, count: maximumPacketBytes + 1)
            let capacity = output.count
            let count = bytes.withUnsafeBytes { source in
                output.withUnsafeMutableBufferPointer { destination in
                    compression_decode_buffer(
                        destination.baseAddress!, capacity,
                        source.bindMemory(to: UInt8.self).baseAddress!, bytes.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard count > 0, count <= maximumPacketBytes else { throw Failure.tooLarge }
            return Data(output.prefix(count))
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
            try decode(readImagePayload(data))
        }
        /// Raw bounded purpose label for an owner-scoped multipart accumulator.
        static func readImagePayload(_ data: Data) throws -> String {
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
            if packet.hasPrefix(fragmentPrefix) { _ = try Fragment(packet) } else { _ = try decode(packet) }
            return packet
        }
    }
#endif
