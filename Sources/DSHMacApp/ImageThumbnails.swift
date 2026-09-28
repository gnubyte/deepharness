import SwiftUI
import AppKit
import ImageIO
import DSHCore

/// Small JPEG copies of what a tool captured, for the transcript. The model
/// gets the full-size image; the UI only needs enough to recognise it, and a
/// long debugging session must not hold hundreds of full screenshots.
enum ImageThumbnails {
    static func make(from data: Data, maxEdge: Int = 720) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

struct EnlargedImage: Identifiable {
    let id = UUID()
    let data: Data
}

/// A row of screenshot thumbnails on a tool card.
struct ToolImageStrip: View {
    let images: [Data]
    @State private var enlarged: EnlargedImage?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, data in
                    if let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
                            .onTapGesture { enlarged = EnlargedImage(data: data) }
                            .help("Frame \(index + 1) of \(images.count) — click to enlarge")
                    }
                }
            }
        }
        .padding(.top, 6)
        .sheet(item: $enlarged) { item in
            VStack(spacing: 10) {
                if let image = NSImage(data: item.data) {
                    Image(nsImage: image).resizable().scaledToFit()
                }
                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        if let image = NSImage(data: item.data) { NSPasteboard.general.writeObjects([image]) }
                    }
                    Spacer()
                    Button("Done") { enlarged = nil }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(minWidth: 640, idealWidth: 900, maxWidth: 1400, minHeight: 420, idealHeight: 640, maxHeight: 1000)
        }
    }
}
