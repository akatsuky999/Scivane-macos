import CoreGraphics

/// The box around a selected note or drawing and its handles, in page space. Sized in screen points at
/// the view's zoom, so the handles are the same size on screen at any zoom. What the sheet draws and
/// what a press is tested against both come from here.
struct Grips {
  enum Handle: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight, left, right

    var isSide: Bool { self == .left || self == .right }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft || self == .left }
    var isTop: Bool { self == .topLeft || self == .topRight }
  }

  /// the mark's own box
  let frame: CGRect
  /// the dashed box, a little outside the mark
  let box: CGRect
  let handles: [(handle: Handle, point: CGPoint)]
  /// page points per screen point
  private let unit: CGFloat

  /// screen points between a mark and its dashed box
  static let pad: CGFloat = 4
  /// a handle's radius on screen
  static let radius: CGFloat = 4
  /// how far from a handle's centre a press still takes it, on screen
  static let reach: CGFloat = 8

  /// `scale` is the view's: screen points per page point.
  init?(_ mark: PaperAnnotation, scale: CGFloat) {
    guard let frame = Self.frame(of: mark) else { return nil }
    self.init(frame: frame, sides: mark.note != nil, scale: scale)
  }

  /// Corners for any box; a note also gets its two sides, which change its width alone.
  init(frame: CGRect, sides: Bool, scale: CGFloat) {
    let unit = 1 / max(scale, 0.01)
    let box = frame.insetBy(dx: -Self.pad * unit, dy: -Self.pad * unit)
    self.frame = frame
    self.box = box
    self.unit = unit
    handles = Handle.allCases.filter { sides || !$0.isSide }.map { handle in
      let y = handle.isSide ? box.midY : (handle.isTop ? box.maxY : box.minY)
      return (handle, CGPoint(x: handle.isLeft ? box.minX : box.maxX, y: y))
    }
  }

  /// What a note or a drawing covers; nil for a drawing erased to nothing.
  static func frame(of mark: PaperAnnotation) -> CGRect? {
    if let note = mark.note { return note.rect }
    if let ink = mark.ink {
      let frame = InkGeometry.frame(of: ink)
      return frame.isNull ? nil : frame
    }
    return nil
  }

  /// The handle a press at `point` takes: the nearest within reach.
  func handle(at point: CGPoint) -> Handle? {
    let reach = Self.reach * unit
    return handles
      .map { ($0.handle, InkGeometry.distance($0.point, point)) }
      .filter { $0.1 <= reach }
      .min { $0.1 < $1.1 }?.0
  }

  /// The point of the mark's own box a handle stands for: a corner, or the middle of a side.
  func anchor(of handle: Handle) -> CGPoint {
    CGPoint(x: handle.isLeft ? frame.minX : frame.maxX,
            y: handle.isSide ? frame.midY : (handle.isTop ? frame.maxY : frame.minY))
  }
}

/// Moving and resizing a note or a drawing, in page space, kept on the page. Pure, so a gesture can show
/// every step and store only the last.
enum Reshape {
  /// The move by `offset`, cut short where `frame` would leave `page`.
  static func offset(_ offset: CGVector, keeping frame: CGRect, within page: CGRect) -> CGVector {
    func limit(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { min(max(value, low), max(low, high)) }
    return CGVector(dx: limit(offset.dx, page.minX - frame.minX, page.maxX - frame.maxX),
                    dy: limit(offset.dy, page.minY - frame.minY, page.maxY - frame.maxY))
  }

  static func moved(_ mark: PaperAnnotation, by offset: CGVector) -> PaperAnnotation {
    var copy = mark
    if let note = mark.note { copy.note?.rect = rounded(note.rect.offsetBy(dx: offset.dx, dy: offset.dy)) }
    if let ink = mark.ink { copy.ink?.strokes = InkGeometry.moved(ink.strokes, by: offset) }
    return copy
  }

  /// `mark` with the handle dragged so the point it stands for is at `target`. `free` lets a drawing's
  /// corner stretch it unevenly (Shift); otherwise it keeps its proportions.
  static func resized(_ mark: PaperAnnotation, _ handle: Grips.Handle, to target: CGPoint, within page: CGRect,
                      free: Bool) -> PaperAnnotation {
    var copy = mark
    if let note = mark.note { copy.note = resized(note, handle, to: target, within: page) }
    if let ink = mark.ink { copy.ink = resized(ink, handle, to: target, within: page, free: free) }
    return copy
  }

  /// A side changes the width and the words rewrap; a corner scales the note, its words and its width
  /// together, about the corner across from it. The height always follows the words.
  static func resized(_ note: PaperAnnotation.Note, _ handle: Grips.Handle, to target: CGPoint,
                      within page: CGRect) -> PaperAnnotation.Note {
    var out = note
    let rect = note.rect
    if handle.isSide {
      let narrowest = note.size * NoteText.minimumWidth
      if handle.isLeft {
        out.rect.origin.x = min(max(target.x, page.minX), rect.maxX - narrowest)
        out.rect.size.width = rect.maxX - out.rect.minX
      } else {
        out.rect.size.width = max(min(target.x, page.maxX) - rect.minX, narrowest)
      }
    } else {
      let anchor = CGPoint(x: handle.isLeft ? rect.maxX : rect.minX, y: handle.isTop ? rect.minY : rect.maxY)
      let corner = CGPoint(x: handle.isLeft ? rect.minX : rect.maxX, y: handle.isTop ? rect.maxY : rect.minY)
      var factor = projection(of: target, from: anchor, toward: corner)
      // the side that moves stays on the page
      let room = handle.isLeft ? anchor.x - page.minX : page.maxX - anchor.x
      if rect.width > 0 { factor = min(factor, room / rect.width) }
      out.size = NoteText.rounded(note.size * factor)
      let width = max(rect.width * out.size / note.size, out.size * NoteText.minimumWidth)
      out.rect.size.width = width
      out.rect.origin.x = handle.isLeft ? anchor.x - width : anchor.x
    }
    let height = NoteText.height(of: out.body, size: out.size, width: out.rect.width)
    out.rect.size.height = height
    // the edge across from the handle stays: the bottom for a top corner, the top otherwise
    out.rect.origin.y = handle.isTop ? rect.minY : rect.maxY - height
    // a note grown past the bottom of the page is lifted back onto it
    out.rect.origin.y = min(max(out.rect.minY, page.minY), max(page.minY, page.maxY - height))
    return rounded(out)
  }

  /// A corner scales the strokes about the corner across from it; the pen's width stays. `target` is for
  /// the corner of the drawing's frame, which takes in the pen's half width around the strokes.
  static func resized(_ ink: PaperAnnotation.Ink, _ handle: Grips.Handle, to target: CGPoint,
                      within page: CGRect, free: Bool) -> PaperAnnotation.Ink {
    let bounds = InkGeometry.bounds(of: ink.strokes)
    guard !bounds.isNull, !handle.isSide else { return ink }
    let half = ink.width / 2
    let target = CGPoint(x: target.x + (handle.isLeft ? half : -half), y: target.y + (handle.isTop ? -half : half))
    let page = page.insetBy(dx: half, dy: half)
    let anchor = CGPoint(x: handle.isLeft ? bounds.maxX : bounds.minX, y: handle.isTop ? bounds.minY : bounds.maxY)
    let corner = CGPoint(x: handle.isLeft ? bounds.minX : bounds.maxX, y: handle.isTop ? bounds.maxY : bounds.minY)
    // how far each side may go before leaving the page
    func room(_ anchor: CGFloat, _ corner: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
      if corner > anchor { return (high - anchor) / (corner - anchor) }
      if corner < anchor { return (low - anchor) / (corner - anchor) }
      return .infinity
    }
    let roomX = room(anchor.x, corner.x, page.minX, page.maxX)
    let roomY = room(anchor.y, corner.y, page.minY, page.maxY)
    // no smaller than a couple of points across, and never turned inside out
    let smallest: CGFloat = 2
    var x: CGFloat
    var y: CGFloat
    if free {
      x = bounds.width > 0 ? max((target.x - anchor.x) / (corner.x - anchor.x), smallest / bounds.width) : 1
      y = bounds.height > 0 ? max((target.y - anchor.y) / (corner.y - anchor.y), smallest / bounds.height) : 1
      x = min(x, roomX)
      y = min(y, roomY)
    } else {
      let factor = min(max(projection(of: target, from: anchor, toward: corner),
                           smallest / max(bounds.width, bounds.height)), roomX, roomY)
      x = factor
      y = factor
    }
    var out = ink
    out.strokes = InkGeometry.scaled(ink.strokes, about: anchor, x: x, y: y)
    return out
  }

  /// How far along the line from `anchor` through `corner` the target lies, as a multiple of that line:
  /// dragging a corner diagonally scales by how far it went, and a sideways wobble doesn't count.
  static func projection(of target: CGPoint, from anchor: CGPoint, toward corner: CGPoint) -> CGFloat {
    let dx = corner.x - anchor.x, dy = corner.y - anchor.y
    let length = dx * dx + dy * dy
    guard length > 0 else { return 1 }
    return max(((target.x - anchor.x) * dx + (target.y - anchor.y) * dy) / length, 0.02)
  }

  /// to 0.01 pt, as marks on the text are, so the stored file stays small and stable
  static func rounded(_ note: PaperAnnotation.Note) -> PaperAnnotation.Note {
    var copy = note
    copy.rect = rounded(note.rect)
    return copy
  }

  static func rounded(_ rect: CGRect) -> CGRect {
    func r(_ value: CGFloat) -> CGFloat { (value * 100).rounded() / 100 }
    return CGRect(x: r(rect.minX), y: r(rect.minY), width: r(rect.width), height: r(rect.height))
  }
}
