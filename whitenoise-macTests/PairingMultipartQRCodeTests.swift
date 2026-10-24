#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    #if !PAIRING_QR_STANDALONE_TESTS
        import Testing
        @testable import whitenoise_mac
        @MainActor struct PairingMultipartQRCodeTests {
            @Test func boundedMultipartTransportContract() throws {
                #expect(try PairingMultipartQRContractChecks.run() == 10)
            }
        }
    #else
        @main enum PairingMultipartQRStandaloneTests {
            static func main() throws {
                let count = try PairingMultipartQRContractChecks.run()
                print("{\"passed\":\(count),\"failed\":0}")
            }
        }
    #endif

    /// The same checks execute against the actual codec in the app and standalone native lane.
    enum PairingMultipartQRContractChecks {
        enum Failure: Error { case contract }
        static func check(_ condition: Bool) throws { if !condition { throw Failure.contract } }
        static func refused(_ operation: () throws -> Void) throws {
            do { try operation() } catch is PairingQRCode.Failure { return }
            throw Failure.contract
        }
        static func randomBytes(_ count: Int) -> Data {
            var state: UInt64 = 0x1234_5678_9ABC_DEF1
            return Data(
                (0..<count).map { _ in
                    state ^= state << 13
                    state ^= state >> 7
                    state ^= state << 17
                    return UInt8(truncatingIfNeeded: state)
                })
        }
        static func changed(_ frame: String, field: Int, value: String) -> String {
            var fields = frame.dropFirst(PairingQRCode.fragmentPrefix.count).split(
                separator: ":", omittingEmptySubsequences: false
            ).map(String.init)
            fields[field] = value
            return PairingQRCode.fragmentPrefix + fields.joined(separator: ":")
        }
        static func run() throws -> Int {
            let now = ContinuousClock().now
            let small = Data(repeating: 9, count: 128)
            let compressed = Data(repeating: 7, count: 2016)
            try check(try PairingQRCode.encodePages(small) == [PairingQRCode.encode(small)])
            try check(try PairingQRCode.encodePages(compressed) == [PairingQRCode.encode(compressed)])
            let bytes = randomBytes(4678)
            let pages = try PairingQRCode.encodePages(bytes)
            try check(pages.count == 4 && pages.allSatisfy { $0.utf8.count <= 2200 })
            var reordered = PairingQRCode.FragmentAccumulator(now: now)
            var restored: String?
            for frame in pages.reversed() {
                restored = try reordered.ingest(frame, now: now)
                try check(try reordered.ingest(frame, now: now) == nil)
            }
            try check(restored == bytes.base64EncodedString())
            try check(reordered.receivedFrameCount == 4 && reordered.totalFrameCount == 4)

            var conflict = PairingQRCode.FragmentAccumulator(now: now)
            _ = try conflict.ingest(pages[0], now: now)
            try refused {
                _ = try conflict.ingest(
                    changed(pages[0], field: 4, value: Data(repeating: 1, count: 1536).base64EncodedString()), now: now)
            }
            try refused {
                _ = try conflict.ingest(changed(pages[1], field: 0, value: String(repeating: "a", count: 64)), now: now)
            }
            for frame in pages.dropFirst() { restored = try conflict.ingest(frame, now: now) }
            try check(restored == bytes.base64EncodedString())

            var corrupt = PairingQRCode.FragmentAccumulator(now: now)
            for frame in pages.dropLast() {
                _ = try corrupt.ingest(changed(frame, field: 0, value: String(repeating: "0", count: 64)), now: now)
            }
            try refused {
                _ = try corrupt.ingest(
                    changed(pages.last!, field: 0, value: String(repeating: "0", count: 64)), now: now)
            }
            try check(corrupt.receivedFrameCount == 0)

            for (field, value) in [(1, "04678"), (1, "49153"), (2, "00"), (2, "-1"), (3, "33"), (3, "0"), (4, "AB==")] {
                var invalid = PairingQRCode.FragmentAccumulator(now: now)
                try refused { _ = try invalid.ingest(changed(pages[0], field: field, value: value), now: now) }
                try check(invalid.receivedFrameCount == 0)
            }
            var invalid = PairingQRCode.FragmentAccumulator(now: now)
            try refused { _ = try invalid.ingest(String(repeating: "a", count: 2201), now: now) }
            try refused { _ = try PairingQRCode.decode(pages[0]) }

            let maximum = randomBytes(49152)
            let maximumPages = try PairingQRCode.encodePages(maximum)
            try check(maximumPages.count == 32 && maximumPages.allSatisfy { $0.utf8.count <= 2200 })
            var full = PairingQRCode.FragmentAccumulator(now: now)
            for frame in maximumPages { restored = try full.ingest(frame, now: now) }
            try check(restored == maximum.base64EncodedString())
            try refused { _ = try PairingQRCode.encodePages(randomBytes(49153)) }

            var expiry = PairingQRCode.FragmentAccumulator(now: now)
            _ = try expiry.ingest(pages[0], now: now + .seconds(119))
            try refused { _ = try expiry.ingest(pages[1], now: now + .seconds(120)) }
            try check(expiry.receivedFrameCount == 0)
            try refused { _ = try expiry.ingest(pages[0], now: now) }

            var retired = PairingQRCode.FragmentAccumulator(now: now)
            _ = try retired.ingest(pages[0], now: now)
            retired.reset()
            try check(retired.receivedFrameCount == 0 && retired.totalFrameCount == nil)
            try refused { _ = try retired.ingest(pages[0], now: now) }

            var backwards = PairingQRCode.FragmentAccumulator(now: now)
            _ = try backwards.ingest(pages[0], now: now + .seconds(1))
            try refused { _ = try backwards.ingest(pages[1], now: now) }
            var mixed = PairingQRCode.FragmentAccumulator(now: now)
            _ = try mixed.ingest(pages[0], now: now)
            try refused { _ = try mixed.ingest(PairingQRCode.encode(small), now: now) }
            return 10
        }
    }
#endif
