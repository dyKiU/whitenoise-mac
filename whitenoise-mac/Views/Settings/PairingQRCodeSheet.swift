#if WN_EXPERIMENTAL_DEVICE_SYNC
    import SwiftUI

    struct PairingQRCodeSheet: View {
        let payloads: [String]
        let close: () -> Void
        @State private var page = 0
        @State private var isPlaying = true
        var body: some View {
            VStack(spacing: 16) {
                Text("Pairing QR code").font(.headline)
                if payloads.indices.contains(page) {
                    QRCodeImageView(payload: payloads[page])
                        .environment(\.colorScheme, .light)
                        .frame(width: 300, height: 300)
                        // Even the smallest (21-module) QR has >4 modules of white margin here.
                        // This is a dedicated quiet zone, independent of the sheet's outer padding.
                        .padding(64)
                        .background(Color.white)
                        .accessibilityLabel(Text("Pairing QR code"))
                }
                if payloads.count > 1 {
                    Text("\(page + 1) / \(payloads.count)").monospacedDigit()
                    HStack {
                        Button(L10n.string("Back")) { page -= 1 }.disabled(page == 0)
                        Toggle(L10n.string("Play"), isOn: $isPlaying).toggleStyle(.switch)
                        Button(L10n.string("Next")) { page += 1 }.disabled(page >= payloads.count - 1)
                    }
                }
                Button(L10n.string("Close"), action: close)
            }
            .padding(24)
            .task(id: payloads) {
                page = 0
                guard payloads.count > 1 else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard !Task.isCancelled else { return }
                    if isPlaying { page = (page + 1) % payloads.count }
                }
            }
        }
    }
    #Preview {
        PairingQRCodeSheet(payloads: ["whitenoise-pairing:v1:AA=="], close: {})
    }
#endif
