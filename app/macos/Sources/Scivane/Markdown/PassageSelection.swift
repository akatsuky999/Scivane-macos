import AppKit
import Observation
import SwiftUI

// Selecting across the blocks of an answer.
//
// `.textSelection(.enabled)` makes every Text a selection island: a drag can't leave its paragraph,
// list item or table cell, so copying more than one block meant copying block by block. Here an
// answer is one passage. Each of its Texts carries a PassageText attribute (where it sits in reading
// order and what its characters copy as); the passage reads the laid-out lines of all of them from
// Text.LayoutKey, handles the mouse itself and draws the selection behind the glyphs. Rendering is
// untouched: with nothing selected nothing extra is drawn.
//
// The layout reader is attached only to the answer under the pointer or holding a selection. On
// every answer at once it multiplied the cost of each layout pass of a long conversation.
//
// Code blocks, display formulas and tables too wide to wrap are atoms: they scroll sideways or are
// images, so their characters can't be placed. A selection that spans one takes it whole; inside
// they keep their own text selection.

// MARK: - What a Text stands for

/// Where a unit sits in reading order: its block, then its place inside the block.
struct PassageOrder: Hashable, Comparable {
  var block: Int
  /// list item or table cell; 0 for a block that is one Text
  var slot = 0

  static func < (a: PassageOrder, b: PassageOrder) -> Bool {
    (a.block, a.slot) < (b.block, b.slot)
  }
}

/// How a unit joins the one before it when copied.
enum PassageJoint: Hashable {
  /// a block of its own: a blank line before it
  case block
  /// a list item: a line break
  case item
  /// a table cell: a tab within its row, a line break before a new row
  case cell(row: Int)
}

/// A link inside a text piece; offsets are relative to the piece.
struct PassageLink: Hashable {
  var range: Range<Int>
  var url: URL
}

/// One piece of a Text in layout order. Offsets count UTF-16 code units, as Text.Layout does.
struct PassagePiece: Hashable {
  enum Content: Hashable {
    /// the characters as shown, with their links
    case text(String, links: [PassageLink])
    /// an inline formula (an image glyph, a draft or its source): copies as LaTeX
    case formula(String)
  }

  var start: Int
  var length: Int
  var content: Content
}

/// The attribute on every Text of a passage.
struct PassageText: TextAttribute {
  var order: PassageOrder
  var joint: PassageJoint = .block
  /// copied before the unit when the selection takes it from its start, such as a list marker
  var prefix = ""
  var pieces: [PassagePiece] = []

  var length: Int { pieces.last.map { $0.start + $0.length } ?? 0 }

  init(order: PassageOrder, joint: PassageJoint = .block, prefix: String = "") {
    self.order = order
    self.joint = joint
    self.prefix = prefix
  }

  /// A Text built from one attributed string.
  init(_ string: AttributedString, order: PassageOrder, joint: PassageJoint = .block, prefix: String = "") {
    self.init(order: order, joint: joint, prefix: prefix)
    append(string)
  }

  mutating func append(_ string: AttributedString) {
    var links: [PassageLink] = []
    var offset = 0
    for run in string.runs {
      let count = String(string[run.range].characters).utf16.count
      if let url = run.link { links.append(PassageLink(range: offset..<offset + count, url: url)) }
      offset += count
    }
    pieces.append(PassagePiece(
      start: length, length: offset, content: .text(String(string.characters), links: links)))
  }

  /// An inline formula drawn as `length` characters: 1 for a typeset image.
  mutating func appendFormula(_ latex: String, length: Int) {
    pieces.append(PassagePiece(start: self.length, length: length, content: .formula(latex)))
  }

  /// The characters in `range` as text: formulas as `$LaTeX$`, once however much of them is taken.
  func copy(_ range: Range<Int>) -> String {
    var out = range.lowerBound == 0 ? prefix : ""
    for piece in pieces {
      let low = max(range.lowerBound, piece.start), high = min(range.upperBound, piece.start + piece.length)
      guard low < high else { continue }
      switch piece.content {
      case .text(let shown, _):
        let units = Array(shown.utf16)
        out += String(decoding: units[(low - piece.start)..<min(high - piece.start, units.count)], as: UTF16.self)
      case .formula(let latex):
        out += "$\(latex)$"
      }
    }
    return out
  }

  /// The unit as one string with formulas as object replacement characters, so offsets line up:
  /// what word boundaries are found in.
  var plain: String {
    pieces.map { piece -> String in
      switch piece.content {
      case .text(let shown, _): return shown
      case .formula: return String(repeating: "\u{FFFC}", count: piece.length)
      }
    }.joined()
  }

  func link(at offset: Int) -> URL? {
    for piece in pieces where piece.start <= offset && offset < piece.start + piece.length {
      guard case .text(_, let links) = piece.content else { return nil }
      return links.first { $0.range.contains(offset - piece.start) }?.url
    }
    return nil
  }
}

extension Text {
  /// Tags this Text as part of a passage; nil leaves it alone.
  func passage(_ text: PassageText?) -> Text {
    text.map { customAttribute($0) } ?? self
  }
}

// MARK: - Atoms

/// A block taken whole: its frame and what it copies as.
struct PassageAtom: Equatable {
  var order: PassageOrder
  var copy: String
  var bounds: Anchor<CGRect>
}

struct PassageAtomKey: PreferenceKey {
  static let defaultValue: [PassageAtom] = []
  static func reduce(value: inout [PassageAtom], nextValue: () -> [PassageAtom]) {
    value.append(contentsOf: nextValue())
  }
}

extension View {
  /// Takes part in a passage as a whole: selected when a selection spans it.
  func passageAtom(_ order: PassageOrder?, copy: @autoclosure @escaping () -> String) -> some View {
    modifier(PassageAtomMarker(order: order, copy: copy))
  }
}

private struct PassageAtomMarker: ViewModifier {
  let order: PassageOrder?
  let copy: () -> String
  /// frames are only reported while the passage reads them
  @Environment(\.passageActive) private var active

  func body(content: Content) -> some View {
    content.anchorPreference(key: PassageAtomKey.self, value: .bounds) { bounds in
      guard active, let order else { return [] }
      return [PassageAtom(order: order, copy: copy(), bounds: bounds)]
    }
  }
}

// MARK: - Environment

private struct PassageTextKey: EnvironmentKey { static let defaultValue = false }
private struct PassageActiveKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
  /// Text below is selected by the passage it is in, not by a selection field of its own.
  var passageText: Bool {
    get { self[PassageTextKey.self] }
    set { self[PassageTextKey.self] = newValue }
  }

  /// The passage is reading its layout: atoms report their frames.
  var passageActive: Bool {
    get { self[PassageActiveKey.self] }
    set { self[PassageActiveKey.self] = newValue }
  }
}

// MARK: - Geometry

/// A point between two characters of the passage. For an atom, 0 is before it and 1 after.
struct PassagePoint: Hashable, Comparable {
  var order: PassageOrder
  var offset: Int

  static func < (a: PassagePoint, b: PassagePoint) -> Bool {
    (a.order, a.offset) < (b.order, b.offset)
  }
}

/// Where the passage's characters are, in its own coordinates (top left origin).
struct PassageMap {
  struct Glyph {
    var char: Int
    var minX: CGFloat
    var maxX: CGFloat
  }

  struct Line {
    var unit: Int
    var top: CGFloat
    /// down to the next line of the same unit, so a band leaves no gap between its lines
    var bottom: CGFloat
    var start: Int
    var end: Int
    /// left to right
    var glyphs: [Glyph]
  }

  struct Unit {
    var text: PassageText
    var lines: Range<Int>
    var minX: CGFloat
    var maxX: CGFloat
  }

  struct Atom: Equatable {
    var order: PassageOrder
    var frame: CGRect
    var copy: String
  }

  var units: [Unit] = []
  var lines: [Line] = []
  var atoms: [Atom] = []

  /// Text.Layout.CharacterIndex keeps its offset out of the public interface, but the type is frozen
  /// with that one Int as its only field, so its layout is part of the ABI. Checked once anyway: if it
  /// ever changes, passages give up rather than select the wrong characters.
  static let indicesReadable =
    MemoryLayout<Text.Layout.CharacterIndex>.size == MemoryLayout<Int>.size
    && MemoryLayout<Text.Layout.CharacterIndex>.alignment == MemoryLayout<Int>.alignment

  private static func offset(_ index: Text.Layout.CharacterIndex) -> Int {
    unsafeBitCast(index, to: Int.self)
  }

  init() {}

  init(_ layouts: [Text.LayoutKey.AnchoredLayout], origins: [CGPoint]) {
    guard Self.indicesReadable else { return }
    var found: [(text: PassageText, lines: [Line])] = []
    var seen = Set<PassageOrder>()
    for (anchored, origin) in zip(layouts, origins) {
      var tag: PassageText?
      var lines: [Line] = []
      for line in anchored.layout {
        var glyphs: [Glyph] = []
        for run in line {
          guard let text = run[PassageText.self] else { continue }
          if tag == nil { tag = text }
          let chars = run.characterIndices
          for (n, index) in run.indices.enumerated() where n < chars.count {
            let box = run[index].typographicBounds.rect
            glyphs.append(Glyph(char: Self.offset(chars[n]), minX: origin.x + box.minX, maxX: origin.x + box.maxX))
          }
        }
        guard let first = glyphs.min(by: { $0.char < $1.char }) else { continue }
        let bounds = line.typographicBounds
        let baseline = origin.y + line.origin.y
        lines.append(Line(
          unit: 0, top: baseline - bounds.ascent, bottom: baseline + bounds.descent,
          start: lines.isEmpty ? 0 : first.char, end: 0, glyphs: glyphs.sorted { $0.minX < $1.minX }))
      }
      // the same Text measured twice reports twice; a unit counts once
      guard let tag, !lines.isEmpty, seen.insert(tag.order).inserted else { continue }
      found.append((tag, lines))
    }
    found.sort { $0.text.order < $1.text.order }
    for (text, unitLines) in found {
      let unit = units.count
      let first = lines.count
      for (n, var line) in unitLines.enumerated() {
        line.unit = unit
        if n + 1 < unitLines.count {
          line.end = unitLines[n + 1].start
          line.bottom = max(line.bottom, unitLines[n + 1].top)
        } else {
          line.end = text.length
        }
        lines.append(line)
      }
      let span = lines[first...]
      units.append(Unit(
        text: text, lines: first..<lines.count,
        minX: span.compactMap { $0.glyphs.first?.minX }.min() ?? 0,
        maxX: span.compactMap { $0.glyphs.last?.maxX }.max() ?? 0))
    }
  }

  var isEmpty: Bool { units.isEmpty && atoms.isEmpty }

  /// The band a line answers to: as wide as its unit, so a press after a short last line still lands.
  private func band(_ line: Line) -> CGRect {
    let unit = units[line.unit]
    return CGRect(x: unit.minX - 2, y: line.top, width: unit.maxX - unit.minX + 10, height: line.bottom - line.top)
  }

  var textBands: [CGRect] { lines.map(band) }

  /// Whether a press here starts a selection: on text, not on an atom or between blocks.
  func isText(at point: CGPoint) -> Bool {
    lines.contains { band($0).contains(point) }
  }

  func selectionContains(_ point: CGPoint, _ lower: PassagePoint, _ upper: PassagePoint) -> Bool {
    rects(lower, upper).contains { $0.insetBy(dx: -2, dy: -2).contains(point) }
  }

  // MARK: Point to position

  func point(at p: CGPoint) -> PassagePoint? {
    if let atom = atoms.first(where: { $0.frame.contains(p) }) {
      return PassagePoint(order: atom.order, offset: p.y < atom.frame.midY ? 0 : 1)
    }
    // the line under the point, or nearest above or below it; across table cells, the nearest one sideways
    func vertical(_ top: CGFloat, _ bottom: CGFloat) -> CGFloat {
      p.y < top ? top - p.y : (p.y > bottom ? p.y - bottom : 0)
    }
    func horizontal(_ minX: CGFloat, _ maxX: CGFloat) -> CGFloat {
      p.x < minX ? minX - p.x : (p.x > maxX ? p.x - maxX : 0)
    }
    var best: (distance: (CGFloat, CGFloat), line: Int?, atom: Int?)?
    for (n, line) in lines.enumerated() {
      let unit = units[line.unit]
      let distance = (vertical(line.top, line.bottom), horizontal(unit.minX, unit.maxX))
      if best == nil || distance < best!.distance { best = (distance, n, nil) }
    }
    for (n, atom) in atoms.enumerated() {
      let distance = (vertical(atom.frame.minY, atom.frame.maxY), horizontal(atom.frame.minX, atom.frame.maxX))
      if best == nil || distance < best!.distance { best = (distance, nil, n) }
    }
    if let atom = best?.atom {
      let frame = atoms[atom].frame
      return PassagePoint(order: atoms[atom].order, offset: p.y < frame.midY ? 0 : 1)
    }
    guard let index = best?.line else { return nil }
    let line = lines[index]
    return PassagePoint(order: units[line.unit].text.order, offset: offset(in: line, x: p.x))
  }

  private func offset(in line: Line, x: CGFloat) -> Int {
    for glyph in line.glyphs where x < (glyph.minX + glyph.maxX) / 2 {
      return max(glyph.char, line.start)
    }
    return line.end
  }

  private func unit(_ order: PassageOrder) -> Unit? {
    units.first { $0.text.order == order }
  }

  /// The character under the point: links open from here.
  func link(at p: CGPoint) -> URL? {
    for line in lines where band(line).contains(p) {
      guard let glyph = line.glyphs.first(where: { $0.minX <= p.x && p.x < $0.maxX }) else { continue }
      return units[line.unit].text.link(at: glyph.char)
    }
    return nil
  }

  /// The word around a point, as a double click takes it.
  func word(at point: PassagePoint) -> (PassagePoint, PassagePoint)? {
    guard let unit = unit(point.order) else { return nil }
    let plain = unit.text.plain
    let length = plain.utf16.count
    guard length > 0 else { return nil }
    let range = NSAttributedString(string: plain).doubleClick(at: min(point.offset, length - 1))
    return (PassagePoint(order: point.order, offset: range.location),
            PassagePoint(order: point.order, offset: range.location + range.length))
  }

  /// The whole unit around a point, as a triple click takes it.
  func whole(at point: PassagePoint) -> (PassagePoint, PassagePoint) {
    let length = unit(point.order)?.text.length ?? 1
    return (PassagePoint(order: point.order, offset: 0), PassagePoint(order: point.order, offset: length))
  }

  var start: PassagePoint? {
    [units.first.map { PassagePoint(order: $0.text.order, offset: 0) },
     atoms.map(\.order).min().map { PassagePoint(order: $0, offset: 0) }].compactMap { $0 }.min()
  }

  var end: PassagePoint? {
    [units.last.map { PassagePoint(order: $0.text.order, offset: $0.text.length) },
     atoms.map(\.order).max().map { PassagePoint(order: $0, offset: 1) }].compactMap { $0 }.max()
  }

  // MARK: Selection to rects and text

  private func span(of unit: Unit, _ lower: PassagePoint, _ upper: PassagePoint) -> Range<Int>? {
    let order = unit.text.order
    guard lower.order <= order, order <= upper.order else { return nil }
    let low = lower.order == order ? lower.offset : 0
    let high = upper.order == order ? upper.offset : unit.text.length
    return low < high ? low..<high : nil
  }

  private func takes(_ atom: Atom, _ lower: PassagePoint, _ upper: PassagePoint) -> Bool {
    lower <= PassagePoint(order: atom.order, offset: 0) && PassagePoint(order: atom.order, offset: 1) <= upper
  }

  /// Text highlight, line by line. A line the selection runs past reaches its unit's right edge, as in
  /// a text view.
  func rects(_ lower: PassagePoint, _ upper: PassagePoint) -> [CGRect] {
    var out: [CGRect] = []
    for unit in units {
      guard let range = span(of: unit, lower, upper) else { continue }
      let continues = upper.order > unit.text.order
      for index in unit.lines {
        let line = lines[index]
        let taken = line.glyphs.filter { range.contains($0.char) }
        guard let low = taken.map(\.minX).min(), var high = taken.map(\.maxX).max() else { continue }
        let last = index == unit.lines.upperBound - 1
        if range.upperBound > line.end || (last && continues) { high = max(high, unit.maxX) }
        out.append(CGRect(x: low, y: line.top, width: high - low, height: line.bottom - line.top))
      }
    }
    return out
  }

  func atomRects(_ lower: PassagePoint, _ upper: PassagePoint) -> [CGRect] {
    atoms.filter { takes($0, lower, upper) }.map(\.frame)
  }

  /// The selection as text: reading order, a blank line between blocks, a line break between list
  /// items and table rows, a tab between cells.
  func copy(_ lower: PassagePoint, _ upper: PassagePoint) -> String {
    var parts: [(order: PassageOrder, joint: PassageJoint, text: String)] = []
    for unit in units {
      guard let range = span(of: unit, lower, upper) else { continue }
      parts.append((unit.text.order, unit.text.joint, unit.text.copy(range)))
    }
    for atom in atoms where takes(atom, lower, upper) {
      parts.append((atom.order, .block, atom.copy))
    }
    parts.sort { $0.order < $1.order }
    var out = ""
    for (n, part) in parts.enumerated() {
      if n > 0 {
        let before = parts[n - 1]
        if part.order.block != before.order.block {
          out += "\n\n"
        } else if case .cell(let row) = part.joint, case .cell(let previous) = before.joint, row == previous {
          out += "\t"
        } else {
          out += "\n"
        }
      }
      out += part.text
    }
    return out
  }
}

// MARK: - State

/// One answer's selection. Anchor and focus equal is a caret: nothing shows, but a shift-click
/// extends from it, as in a text view.
@MainActor @Observable
final class PassageSelection: ObservableObject {
  private(set) var anchor: PassagePoint?
  private(set) var focus: PassagePoint?
  /// While the button is down or something is selected: keeps the layout reader once the pointer
  /// leaves. A caret alone doesn't.
  private(set) var holds = false
  @ObservationIgnored private var pressing = false
  /// the system's selection colour while this answer has keyboard focus, the inactive one otherwise
  var emphasized = true

  @ObservationIgnored private(set) var map = PassageMap()
  @ObservationIgnored private var mapKey: (layouts: [Text.LayoutKey.AnchoredLayout], origins: [CGPoint])?
  @ObservationIgnored weak var surface: PassageSurfaceView?

  var bounds: (lower: PassagePoint, upper: PassagePoint)? {
    guard let anchor, let focus, anchor != focus else { return nil }
    return (min(anchor, focus), max(anchor, focus))
  }

  func select(_ anchor: PassagePoint, _ focus: PassagePoint) {
    if self.anchor != anchor { self.anchor = anchor }
    if self.focus != focus { self.focus = focus }
    settle()
  }

  func selectAll() {
    guard let start = map.start, let end = map.end else { return }
    select(start, end)
  }

  /// The button went down or up.
  func press(_ down: Bool) {
    pressing = down
    settle()
  }

  func clear() {
    if anchor != nil { anchor = nil }
    if focus != nil { focus = nil }
    settle()
  }

  /// Set only on change: every write notifies, and the answer's modifier reads this.
  private func settle() {
    let held = pressing || bounds != nil
    if holds != held { holds = held }
  }

  var copied: String? {
    guard let bounds else { return nil }
    let text = map.copy(bounds.lower, bounds.upper)
    return text.isEmpty ? nil : text
  }

  /// Rebuilt only when the layout moved: drags redraw the highlight many times a second.
  func map(for layouts: [Text.LayoutKey.AnchoredLayout], origins: [CGPoint]) -> PassageMap {
    if let key = mapKey, key.origins == origins, key.layouts == layouts { return map }
    let atoms = map.atoms
    map = PassageMap(layouts, origins: origins)
    map.atoms = atoms
    mapKey = (layouts, origins)
    surface?.layoutChanged()
    return map
  }

  func setAtoms(_ atoms: [PassageMap.Atom]) {
    let atoms = atoms.sorted { $0.order < $1.order }
    guard atoms != map.atoms else { return }
    map.atoms = atoms
    surface?.layoutChanged()
  }
}

// MARK: - Views

extension View {
  /// Makes this answer one selectable passage while the pointer is over it or it holds a selection.
  func passageSelection(hovering: Bool, selection: PassageSelection) -> some View {
    modifier(PassageArea(hovering: hovering, selection: selection))
  }
}

private struct PassageArea: ViewModifier {
  let hovering: Bool
  let selection: PassageSelection

  func body(content: Content) -> some View {
    let passage = content.environment(\.passageText, true)
    if hovering || selection.holds {
      passage
        .environment(\.passageActive, true)
        .backgroundPreferenceValue(Text.LayoutKey.self) { layouts in
          GeometryReader { proxy in
            PassageBackdrop(map: selection.map(for: layouts, origins: layouts.map { proxy[$0.origin] }),
                            selection: selection)
          }
        }
        .overlayPreferenceValue(PassageAtomKey.self) { atoms in
          GeometryReader { proxy in
            PassageForeground(
              atoms: atoms.map { PassageMap.Atom(order: $0.order, frame: proxy[$0.bounds], copy: $0.copy) },
              selection: selection)
          }
        }
    } else {
      passage
    }
  }
}

private func selectionColor(_ emphasized: Bool) -> Color {
  Color(nsColor: emphasized ? .selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor)
}

/// The text highlight, behind the glyphs as a text view draws it.
private struct PassageBackdrop: View {
  let map: PassageMap
  let selection: PassageSelection

  var body: some View {
    if let bounds = selection.bounds {
      let color = selectionColor(selection.emphasized)
      Canvas { context, _ in
        for rect in map.rects(bounds.lower, bounds.upper) {
          context.fill(Path(rect), with: .color(color))
        }
      }
      .allowsHitTesting(false)
    }
  }
}

/// Atoms are opaque boxes or images: their highlight goes on top, translucent. The mouse is handled
/// here too, over the whole answer.
private struct PassageForeground: View {
  let atoms: [PassageMap.Atom]
  let selection: PassageSelection

  var body: some View {
    let _ = selection.setAtoms(atoms)
    ZStack(alignment: .topLeading) {
      if let bounds = selection.bounds {
        let color = selectionColor(selection.emphasized).opacity(0.45)
        ForEach(Array(selection.map.atomRects(bounds.lower, bounds.upper).enumerated()), id: \.offset) { _, rect in
          RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color)
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
        }
        .allowsHitTesting(false)
      }
      PassageEvents(selection: selection)
    }
  }
}

private struct PassageEvents: NSViewRepresentable {
  let selection: PassageSelection

  func makeNSView(context: Context) -> PassageSurfaceView {
    let view = PassageSurfaceView()
    view.selection = selection
    selection.surface = view
    return view
  }

  func updateNSView(_ view: PassageSurfaceView, context: Context) {
    view.selection = selection
    selection.surface = view
  }

  static func dismantleNSView(_ view: PassageSurfaceView, coordinator: ()) {
    view.stopWatching()
  }
}

/// Takes the pointer over the passage's text: presses, drags, clicks, keys and the menu. Wheel and
/// gesture events it doesn't handle go up the responder chain to the transcript's scroll view. Atoms
/// and the space between blocks aren't hit at all, so buttons and sideways scrolling there work as
/// before.
final class PassageSurfaceView: NSView, NSMenuItemValidation {
  var selection: PassageSelection?
  /// the word or unit a double or triple click took: dragging extends from its far side
  private var unit: (PassagePoint, PassagePoint)?
  private var dragged = false
  private var monitor: Any?
  private var observers: [NSObjectProtocol] = []

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  override func isAccessibilityElement() -> Bool { false }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let selection else { return nil }
    let local = convert(point, from: superview)
    if selection.map.isText(at: local) { return self }
    if let bounds = selection.bounds, selection.map.selectionContains(local, bounds.lower, bounds.upper) {
      return self
    }
    return nil
  }

  override func mouseDown(with event: NSEvent) {
    guard let selection else { return }
    window?.makeFirstResponder(self)
    let local = convert(event.locationInWindow, from: nil)
    guard let point = selection.map.point(at: local) else { return }
    dragged = false
    unit = nil
    selection.press(true)
    switch event.clickCount {
    case 2:
      if let word = selection.map.word(at: point) {
        unit = word
        selection.select(word.0, word.1)
      }
    case 3...:
      let whole = selection.map.whole(at: point)
      unit = whole
      selection.select(whole.0, whole.1)
    default:
      if event.modifierFlags.contains(.shift), let anchor = selection.anchor {
        selection.select(anchor, point)
      } else {
        selection.select(point, point)
      }
    }
    startWatching()
  }

  override func mouseDragged(with event: NSEvent) {
    guard let selection else { return }
    autoscroll(with: event)
    let local = convert(event.locationInWindow, from: nil)
    guard let point = selection.map.point(at: local) else { return }
    dragged = true
    if let (start, end) = unit {
      selection.select(point < start ? end : start, point < start ? point : max(point, end))
    } else if let anchor = selection.anchor {
      selection.select(anchor, point)
    }
  }

  override func mouseUp(with event: NSEvent) {
    guard let selection else { return }
    selection.press(false)
    guard !dragged, event.clickCount == 1, selection.bounds == nil else { return }
    // a plain click leaves a caret, and follows a link under it
    stopWatching()
    if let url = selection.map.link(at: convert(event.locationInWindow, from: nil)) {
      NSWorkspace.shared.open(url)
    }
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    menu.addItem(withTitle: L("拷贝", "Copy"), action: #selector(copy(_:)), keyEquivalent: "")
    menu.addItem(withTitle: L("全选", "Select All"), action: #selector(selectAll(_:)), keyEquivalent: "")
    menu.items.forEach { $0.target = self }
    return menu
  }

  @objc func copy(_ sender: Any?) {
    guard let text = selection?.copied else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  override func selectAll(_ sender: Any?) {
    selection?.selectAll()
    startWatching()
  }

  override func cancelOperation(_ sender: Any?) {
    clear()
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    if item.action == #selector(copy(_:)) { return selection?.bounds != nil }
    return true
  }

  override func becomeFirstResponder() -> Bool {
    selection?.emphasized = window?.isKeyWindow ?? true
    return true
  }

  override func resignFirstResponder() -> Bool {
    selection?.emphasized = false
    return true
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
    guard let window else {
      stopWatching()
      return
    }
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.selection?.emphasized = window.isKeyWindow && window.firstResponder === self
        }
      })
    }
  }

  override func resetCursorRects() {
    selection?.map.textBands.forEach { addCursorRect($0, cursor: .iBeam) }
  }

  /// The layout under the passage moved: the cursor bands follow it.
  func layoutChanged() {
    DispatchQueue.main.async { [weak self] in
      guard let self, let window = self.window else { return }
      window.invalidateCursorRects(for: self)
    }
  }

  private func clear() {
    selection?.clear()
    stopWatching()
  }

  /// A press anywhere off this passage's text clears the selection, as it does in a text view. A
  /// right click on the selection keeps it for the menu's Copy.
  private func startWatching() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self, let selection = self.selection, event.window === self.window else { return }
        let local = self.convert(event.locationInWindow, from: nil)
        let onText = selection.map.isText(at: local)
        let onSelection = selection.bounds.map { selection.map.selectionContains(local, $0.lower, $0.upper) } ?? false
        if event.type == .rightMouseDown ? !(onText || onSelection) : !onText {
          self.clear()
        }
      }
      return event
    }
  }

  func stopWatching() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }
}
