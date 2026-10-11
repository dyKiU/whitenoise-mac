#if WN_EXPERIMENTAL_DEVICE_SYNC
    import SwiftUI

    struct PairingQRCodeSheet: View {
        let payload: String
        let close: () -> Void
        var body: some View {
            VStack(spacing: 16) {
                Text("Pairing QR code").font(.headline)
                QRCodeImageView(payload: payload)
                    .environment(\.colorScheme, .light)
                    .frame(width: 300, height: 300)
                    // Even the smallest (21-module) QR has >4 modules of white margin here.
                    // This is a dedicated quiet zone, independent of the sheet's outer padding.
                    .padding(64)
                    .background(Color.white)
                    .accessibilityLabel(Text("Pairing QR code"))
                Button(L10n.string("Close"), action: close)
            }
            .padding(24)
        }
    }
    #Preview {
        PairingQRCodeSheet(payload: "whitenoise-pairing:v1:AA==", close: {})
    }
#endif
