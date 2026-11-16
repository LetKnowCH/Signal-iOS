// SPDX-License-Identifier: AGPL-3.0-only

import CoreImage
import ImageIO
import SwiftUI
import Vision
import WebKit

enum WalletQRImage {
    static func payload(_ image: CGImage) -> Data? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: image)
        if (try? handler.perform([request])) != nil, let results = request.results, results.count == 1,
            let descriptor = results[0].barcodeDescriptor as? CIQRCodeDescriptor
        {
            return descriptor.errorCorrectedPayload
        }
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: CIImage(cgImage: image)) ?? []
        guard features.count == 1, let feature = features.first as? CIQRCodeFeature else { return nil }
        return feature.symbolDescriptor?.errorCorrectedPayload
    }

    static func render(_ encoded: String) async -> UIImage? {
        let raw = encoded.range(of: "base64,").map { encoded[$0.upperBound...] } ?? encoded[...]
        guard (1...2_000_000).contains(raw.utf8.count),
            let data = Data(base64Encoded: String(raw), options: .ignoreUnknownCharacters)
        else { return nil }
        let bytes: Data
        if let prefix = String(data: data.prefix(1024), encoding: .utf8), prefix.contains("<svg") {
            guard let rasterized = await renderSVG(data) else { return nil }
            bytes = rasterized
        } else {
            bytes = data
        }
        return await Task.detached(priority: .userInitiated) { renderBitmap(bytes) }.value
    }

    // WebKit renders SVG in image mode. The SVG cannot run scripts or load remote subresources.
    @MainActor private static func renderSVG(_ data: Data) async -> Data? {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: config)
        let draw = """
            const policy = document.createElement('meta');
            policy.httpEquiv = 'Content-Security-Policy';
            policy.content = "default-src 'none'; img-src data:";
            document.head.appendChild(policy);
            const image = new Image();
            image.src = 'data:image/svg+xml;base64,' + encoded;
            await image.decode();
            const width = image.naturalWidth, height = image.naturalHeight;
            if (!width || !height || width > 4096 || height > 4096) return null;
            const canvas = document.createElement('canvas');
            canvas.width = canvas.height = 768;
            const ctx = canvas.getContext('2d');
            ctx.fillStyle = 'white';
            ctx.fillRect(0, 0, 768, 768);
            const scale = 768 / Math.max(width, height);
            ctx.drawImage(image, (768-width*scale)/2, (768-height*scale)/2, width*scale, height*scale);
            return canvas.toDataURL('image/png').split(',')[1];
            """
        guard
            let png = try? await webView.callAsyncJavaScript(
                draw, arguments: ["encoded": data.base64EncodedString()],
                in: nil, contentWorld: .defaultClient) as? String
        else { return nil }
        return Data(base64Encoded: png)
    }

    private static func renderBitmap(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            (1...4096).contains(width), (1...4096).contains(height)
        else { return nil }
        guard let original = UIImage(data: data) else { return nil }
        let size = CGSize(width: 768, height: 768)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let scale = 768 / max(original.size.width, original.size.height)
        let rect = CGRect(
            x: (768 - original.size.width * scale) / 2, y: (768 - original.size.height * scale) / 2,
            width: original.size.width * scale, height: original.size.height * scale)
        let base = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.interpolationQuality = .none
            original.draw(in: rect)
        }
        guard let baseCG = base.cgImage, let originalPayload = payload(baseCG), let logo = UIImage(named: "letknow_bird")
        else { return base }
        for fraction in [0.16, 0.12] {
            let branded = renderer.image { _ in
                base.draw(at: .zero)
                let diameter = size.width * fraction
                let disc = CGRect(
                    x: (size.width - diameter) / 2, y: (size.height - diameter) / 2, width: diameter, height: diameter)
                UIColor.white.setFill()
                UIBezierPath(ovalIn: disc).fill()
                let badge = disc.insetBy(dx: diameter * 0.06, dy: diameter * 0.06)
                UIColor(red: 102 / 255, green: 41 / 255, blue: 133 / 255, alpha: 1).setFill()
                UIBezierPath(ovalIn: badge).fill()
                logo.draw(in: badge)
            }
            if let cg = branded.cgImage, payload(cg) == originalPayload { return branded }
        }
        return base
    }
}

struct WalletDepositQR: View {
    let encoded: String?
    let waiting: Bool
    var didRender: (UIImage?) -> Void = { _ in }
    @State private var image: UIImage?
    @State private var failed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            if !waiting && (failed || encoded == nil) {
                Text("QR code unavailable. Copy the wallet address below.")
            } else {
                Text(image == nil ? "Loading deposit QR code…" : "Scan to deposit").font(.footnote).foregroundStyle(
                    .secondary)
                ZStack {
                    Color.white
                    Image("wallet_deposit_placeholder").resizable().blur(radius: reduceMotion ? 0 : 2)
                        .opacity(image == nil ? 0.72 : 0).accessibilityHidden(true)
                    if let image {
                        Image(uiImage: image).resizable().interpolation(.none).scaledToFit().transition(.opacity)
                            .accessibilityLabel("Deposit QR code")
                    }
                }.frame(width: 208, height: 208)
            }
        }.frame(maxWidth: .infinity)
            .task(id: encoded) {
                image = nil
                didRender(nil)
                failed = false
                guard let encoded else { return }
                let value = await WalletQRImage.render(encoded)
                guard !Task.isCancelled else { return }
                didRender(value)
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) {
                    image = value
                    failed = value == nil
                }
            }
    }
}

struct WalletDestinationTag: View {
    let tag: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Text("Destination tag").font(.title2.bold())
                    Spacer()
                    Button("Close") { dismiss() }
                }
                if let filter = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data(tag.utf8)]),
                    let data = filter.outputImage
                {
                    let padded = data.extent.insetBy(dx: -4, dy: -4)
                    let qr = data.composited(over: CIImage(color: .white)).cropped(to: padded)
                    if let image = CIContext().createCGImage(qr, from: padded) {
                        Image(decorative: image, scale: 1).resizable().interpolation(.none).scaledToFit()
                            .frame(maxWidth: 280).accessibilityLabel("Destination tag QR code")
                    }
                }
                Text(verbatim: tag).font(.headline).textSelection(.enabled)
            }.padding(20)
        }
    }
}

struct WalletDepositShare: View {
    let name: String
    let deposit: MerchantWalletAPI.DepositAddress
    let image: UIImage?
    @Environment(\.dismiss) private var dismiss
    private enum Kind: String, Identifiable {
        case details, qr
        var id: Self { self }
    }
    @State private var selection: Kind?

    private var details: String {
        [
            name, deposit.network.map { "Network: " + $0 }, "Wallet address: " + deposit.address,
            deposit.address2.map { "Secondary address: " + $0 }, deposit.destinationTag.map { "Destination tag: " + $0 },
        ]
        .compactMap { $0 }.joined(separator: "\n")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Share deposit").font(.title2.bold())
                    Spacer()
                    Button("Close") { dismiss() }
                }
                Button("Share deposit details") { selection = .details }.frame(minHeight: 44)
                Button("Share QR code") { selection = .qr }.frame(minHeight: 44).disabled(image == nil)
            }.padding(20)
        }.sheet(item: $selection) { kind in
            if kind == .qr, let image { ShareSheet(items: [details, image]) } else { ShareSheet(items: [details]) }
        }
    }

    private struct ShareSheet: UIViewControllerRepresentable {
        let items: [Any]
        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: items, applicationActivities: nil)
        }
        func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
    }
}
