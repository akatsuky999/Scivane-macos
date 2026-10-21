import AppKit

/// How a note's words are set, in page points: the size range and its steps, the attributes, and the
/// layout that sizes the box and gives the page its glyphs. The page, the editor and the measurements
/// all lay the words out the same way, with TextKit and no padding, so a note wraps the same while it
/// is written and after.
enum NoteText {
  /// The backend refuses sizes outside the same bounds (NOTE_SIZES in projects/annotations.py).
  static let sizes: ClosedRange<CGFloat> = 4...144
  /// what the size buttons and ⌘⇧> / ⌘⇧< step through, as a word processor's size menu
  static let presets: [CGFloat] = [6, 8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 60, 72, 96, 120, 144]
  static let standard: CGFloat = 12
  /// the narrowest box, in sizes of its text: room for a character or two
  static let minimumWidth: CGFloat = 1.5

  static func clamped(_ size: CGFloat) -> CGFloat { min(max(size, sizes.lowerBound), sizes.upperBound) }

  /// to half a point, within the range: what dragging a corner settles on
  static func rounded(_ size: CGFloat) -> CGFloat { clamped((size * 2).rounded() / 2) }

  /// The next preset above or below; a size between two presets goes to the nearer one that way.
  static func step(_ size: CGFloat, up: Bool) -> CGFloat {
    let next = up ? presets.first { $0 > size + 0.01 } : presets.last { $0 < size - 0.01 }
    return next ?? (up ? sizes.upperBound : sizes.lowerBound)
  }

  static func label(_ size: CGFloat) -> String {
    size.rounded() == size ? String(Int(size)) : String(format: "%.1f", Double(size))
  }

  /// The system font, which falls back to PingFang for Chinese.
  static func attributes(size: CGFloat, color: NSColor) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.lineHeightMultiple = 1.08
    return [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: paragraph]
  }

  /// The height `body` takes wrapped at `width`: at least a line, with a little slack so the last line
  /// is never clipped.
  static func height(of body: String, size: CGFloat, width: CGFloat) -> CGFloat {
    ceil(max(layout(body, size: size, width: width).used.height, size * 1.2)) + 1
  }

  /// The width of the longest line of `body` unwrapped, with room for the caret after it.
  static func width(of body: String, size: CGFloat) -> CGFloat {
    max(ceil(layout(body, size: size, width: nil).used.width) + 2, size * minimumWidth)
  }

  /// Words laid out at a size and, unless `width` is nil, wrapped to it.
  struct Layout {
    /// what the lines take, from the top left
    let used: CGSize
    /// The glyphs as one path, x to the right and y down from the top left: drawn as shapes, they stay
    /// sharp at any zoom and cost no bitmap.
    let outlines: CGPath?
    /// false when a glyph has no outline (a colour emoji), and the words must be drawn as text
    let complete: Bool
  }

  static func layout(_ body: String, size: CGFloat, width: CGFloat?, outlines: Bool = false) -> Layout {
    let storage = NSTextStorage(string: body, attributes: attributes(size: size, color: .black))
    let manager = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    manager.ensureLayout(for: container)
    let used = manager.usedRect(for: container).size
    guard outlines else { return Layout(used: used, outlines: nil, complete: true) }

    let path = CGMutablePath()
    var complete = true
    manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { line, _, _, range, _ in
      for index in range.location..<NSMaxRange(range) {
        let property = manager.propertyForGlyph(at: index)
        if property.contains(.null) || property.contains(.controlCharacter) || manager.notShownAttribute(forGlyphAt: index) {
          continue
        }
        // the font the layout settled on for this character, PingFang for Chinese
        let character = manager.characterIndexForGlyph(at: index)
        guard let font = storage.attribute(.font, at: character, effectiveRange: nil) as? NSFont else { continue }
        var glyph = manager.cgGlyph(at: index)
        let at = manager.location(forGlyphAt: index)
        // glyphs are drawn up from their baseline; the layout runs down from the top
        var place = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: line.minX + at.x, ty: line.minY + at.y)
        if let outline = CTFontCreatePathForGlyph(font as CTFont, glyph, &place) {
          path.addPath(outline)
        } else {
          // a space has no outline and no extent; a bitmap glyph has an extent but no outline
          var extent = CGRect.zero
          CTFontGetBoundingRectsForGlyphs(font as CTFont, .horizontal, &glyph, &extent, 1)
          if extent.width > 0, extent.height > 0 { complete = false }
        }
      }
    }
    return Layout(used: used, outlines: path, complete: complete)
  }
}
