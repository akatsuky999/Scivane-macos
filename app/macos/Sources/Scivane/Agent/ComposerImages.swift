import AppKit
import ImageIO
import UniformTypeIdentifiers

/// An image attached to a question, already fitted to what providers accept: PNG or JPEG, the long
/// edge at most 2048 px, at most 3.75 MB (5 MB once base64-encoded, the strictest limit). Fitting
/// happens here, once, so the backend only checks.
struct ComposerImage: Identifiable, Equatable {
  let id = UUID()
  let data: Data
  let mediaType: String
  let width: Int
  let height: Int

  static let maxEdge = 2048
  static let maxBytes = 3_750_000
  /// the backend's limit per message
  static let perMessage = 8

  var thumbnail: NSImage? { NSImage(data: data) }

  /// From image bytes in any format ImageIO reads (HEIC, TIFF, screenshots...); nil when it isn't one.
  static func prepare(data: Data) -> ComposerImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
    else { return nil }
    let type = CGImageSourceGetType(source) as String?
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1

    // Already fine: send the exact bytes, so a screenshot keeps its pixels.
    if let type, let media = passthrough[type], max(width, height) <= maxEdge, data.count <= maxBytes,
      orientation == 1
    {
      return ComposerImage(data: data, mediaType: media, width: width, height: height)
    }

    // Re-encode, applying EXIF orientation (phone photos are often stored sideways).
    for edge in [min(maxEdge, max(width, height)), 1568] {
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: edge,
      ]
      guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
      }
      // PNG keeps text in screenshots sharp; photos come out far smaller as JPEG.
      for (format, quality) in [(UTType.png, 1.0), (UTType.jpeg, 0.85), (UTType.jpeg, 0.7)] {
        if let encoded = encode(image, as: format, quality: quality), encoded.count <= maxBytes {
          return ComposerImage(
            data: encoded, mediaType: format == .png ? "image/png" : "image/jpeg",
            width: image.width, height: image.height)
        }
      }
    }
    return nil
  }

  static func prepare(url: URL) -> ComposerImage? {
    guard isImage(url), let data = try? Data(contentsOf: url) else { return nil }
    return prepare(data: data)
  }

  static func isImage(_ url: URL) -> Bool {
    UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
  }

  /// Images on the pasteboard: image files copied in Finder, or image data (screenshots, browsers).
  static func fromPasteboard(_ pasteboard: NSPasteboard) -> [ComposerImage] {
    let urls = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []).filter(isImage)
    if !urls.isEmpty { return urls.compactMap(prepare(url:)) }
    for type in [NSPasteboard.PasteboardType.png, .tiff] {
      if let data = pasteboard.data(forType: type), let image = prepare(data: data) { return [image] }
    }
    return []
  }

  /// Whether a paste should become images rather than text: there is image data and no text.
  static func pasteboardHasOnlyImages(_ pasteboard: NSPasteboard) -> Bool {
    guard pasteboard.string(forType: .string) == nil else {
      // a copied file also carries its name as text
      return (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []).contains(where: isImage)
    }
    return pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil
      || (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []).contains(where: isImage)
  }

  private static let passthrough: [String: String] = [
    UTType.png.identifier: "image/png", UTType.jpeg.identifier: "image/jpeg",
  ]

  private static func encode(_ image: CGImage, as format: UTType, quality: Double) -> Data? {
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, format.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
  }

  static func == (lhs: ComposerImage, rhs: ComposerImage) -> Bool { lhs.id == rhs.id }
}

/// ⌘V with only an image on the pasteboard, while the composer has focus. A text field's own paste
/// takes text and drops image data, so the keystroke is caught before it gets there; anything else
/// passes through untouched.
@MainActor
final class ImagePasteMonitor {
  var active = false
  private var token: Any?

  func start(_ attach: @escaping ([ComposerImage]) -> Void) {
    guard token == nil else { return }
    token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.active,
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
        event.charactersIgnoringModifiers?.lowercased() == "v",
        ComposerImage.pasteboardHasOnlyImages(.general)
      else { return event }
      let images = ComposerImage.fromPasteboard(.general)
      guard !images.isEmpty else { return event }
      attach(images)
      return nil
    }
  }

  func stop() {
    if let token { NSEvent.removeMonitor(token) }
    token = nil
  }
}
