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

    @Test(arguments: [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua])
    func sharedTimestampsRefreshForDrawLocaleRatherThanRetainingCachedText(appearance: NSAppearance.Name) throws {
        let instant: Int64 = 1_791_815_405
        let locale = Locale(identifier: "en_US")
        let tokens = MarkdownDocumentFfi(
            blocks: [.paragraph(inlines: [.timestamp(unixSeconds: instant, style: .longDate)])],
            truncated: false, blankLinesBefore: Data())
        let native = MessageItem(
            id: "synthetic-timestamp", senderName: "Tester", body: "Synthetic timestamp",
            contentMarkdown: tokens, sentAt: Date(timeIntervalSince1970: 123), isOutgoing: false)
        let stale = MarkdownDisplayDocument(document: tokens).refreshingTimestamps(
            now: Date(), locale: Locale(identifier: "es_ES"), timeZone: .autoupdatingCurrent)
        let expectedText = MarkdownTimestampFormatter.text(
            unixSeconds: instant, style: .longDate, locale: locale, timeZone: .autoupdatingCurrent)
        let expectedDocument = MarkdownDisplayDocument(
            document: MarkdownDocumentFfi(
                blocks: [.paragraph(inlines: [.text(content: expectedText)])],
                truncated: false, blankLinesBefore: Data()))
        let expected = try rasterize(
            MarkdownMessageView(document: expectedDocument, fallbackText: expectedText).environment(\.locale, locale),
            in: appearance)
        let staleControl = MarkdownDisplayDocument(blocks: stale.blocks, truncated: stale.truncated)
        #expect(
            try rasterize(MarkdownMessageView(document: staleControl, fallbackText: "Synthetic timestamp"), in: appearance)
                != expected,
            "The cached Spanish text must distinguish a stale draw from the current locale")
        #expect(try rasterize(MarkdownMessageView(message: native).environment(\.locale, locale), in: appearance) == expected)
        #expect(
            try rasterize(
                MarkdownMessageView(document: stale, fallbackText: "Synthetic timestamp").environment(\.locale, locale),
                in: appearance) == expected)
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
