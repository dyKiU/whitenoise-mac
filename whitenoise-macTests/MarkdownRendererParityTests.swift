import AppKit
import MarmotKit
import SwiftUI
import Testing

@testable import whitenoise_mac

@Suite(.serialized) @MainActor struct MarkdownRendererParityTests {
    @Test(arguments: [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua])
    func sourceAttestedAndNativeTextUseTheSameRenderer(appearance: NSAppearance.Name) throws {
        let tokens = MarkdownDocumentFfi(
            blocks: [.paragraph(inlines: [.text(content: "Synthetic text")])],
            truncated: false, blankLinesBefore: Data())
        let native = MessageItem(
            id: "synthetic", senderName: "Tester", body: "Synthetic text",
            contentMarkdown: tokens, sentAt: Date(timeIntervalSince1970: 123), isOutgoing: false)
        let nativeImage = try rasterize(MarkdownMessageView(message: native), in: appearance)
        let sharedImage = try rasterize(
            MarkdownMessageView(document: MarkdownDisplayDocument(document: tokens), fallbackText: "Synthetic text"),
            in: appearance)
        #expect(nativeImage == sharedImage)
    }

    @Test func sourceAttestedFallbackMatchesNativeTextWithoutTokens() throws {
        let native = MessageItem(
            id: "synthetic", senderName: "Tester", body: "Synthetic fallback",
            sentAt: Date(timeIntervalSince1970: 123), isOutgoing: false)
        #expect(
            try rasterize(MarkdownMessageView(message: native), in: .aqua)
                == rasterize(MarkdownMessageView(document: nil, fallbackText: "Synthetic fallback"), in: .aqua))
    }

    private func rasterize(_ view: some View, in appearance: NSAppearance.Name) throws -> Data {
        let scheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme).frame(width: 360))
        renderer.scale = 2
        var image: NSImage?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance { image = renderer.nsImage }
        let tiff = try #require(image?.tiffRepresentation)
        let pixels = try #require(NSBitmapImageRep(data: tiff))
        return try #require(pixels.representation(using: .png, properties: [:]))
    }
}
