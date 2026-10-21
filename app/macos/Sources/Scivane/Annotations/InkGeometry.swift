import CoreGraphics

/// The geometry of pen strokes, apart from any view: smoothing what the pointer reported, erasing, hit
/// testing, and whether a new stroke belongs with the last drawing. Everything is in page space.
enum InkGeometry {
  /// points closer than this to the one kept before them add nothing but bytes
  static let minStep: CGFloat = 0.6
  /// strokes drawn this soon after the last one, this close to it, in the same pen, are one drawing:
  /// a word written in several strokes is undone, recoloured and deleted as one
  static let mergeWindow: Double = 10
  static let mergeDistance: CGFloat = 50

  /// The pointer's points made into a stroke: two rounds of corner cutting (Chaikin), then thinned
  /// and rounded to 0.01 pt so the stored file stays small and stable. Nil for a click without a drag.
  static func stroke(from points: [CGPoint]) -> [CGPoint]? {
    let raw = thinned(points)
    guard raw.count >= 2, length(of: raw) >= 1 else { return nil }
    var smooth = raw
    for _ in 0..<2 { smooth = chaikin(smooth) }
    return thinned(smooth).map { CGPoint(x: round($0.x), y: round($0.y)) }
  }

  static func chaikin(_ points: [CGPoint]) -> [CGPoint] {
    guard points.count > 2 else { return points }
    var out = [points[0]]
    for (a, b) in zip(points, points.dropFirst()) {
      out.append(CGPoint(x: a.x * 0.75 + b.x * 0.25, y: a.y * 0.75 + b.y * 0.25))
      out.append(CGPoint(x: a.x * 0.25 + b.x * 0.75, y: a.y * 0.25 + b.y * 0.75))
    }
    out.append(points[points.count - 1])
    return out
  }

  static func thinned(_ points: [CGPoint]) -> [CGPoint] {
    guard var last = points.first else { return [] }
    var out = [last]
    for point in points.dropFirst() where distance(point, last) >= minStep {
      out.append(point)
      last = point
    }
    // the stroke ends where the pointer was released, in place of kept points too close to it
    if let end = points.last, out.last != end {
      while out.count > 1, distance(end, out[out.count - 1]) < minStep { out.removeLast() }
      if end != out[0] { out.append(end) }
    }
    return out
  }

  // MARK: - Erasing

  /// The strokes with what lies within `radius` of `center` taken out; a stroke the eraser crosses
  /// becomes two. Nil when nothing was touched.
  static func erase(_ strokes: [[CGPoint]], around center: CGPoint, radius: CGFloat) -> [[CGPoint]]? {
    erase(strokes, from: center, to: center, radius: radius)
  }

  /// The strokes with what the eraser swept between two pointer samples taken out: a quick drag
  /// reports points far apart, and only rubbing at each of them would leave the ink between standing.
  static func erase(_ strokes: [[CGPoint]], from start: CGPoint, to end: CGPoint, radius: CGFloat) -> [[CGPoint]]? {
    let swept = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                       width: abs(end.x - start.x), height: abs(end.y - start.y)).insetBy(dx: -radius, dy: -radius)
    var changed = false
    var out: [[CGPoint]] = []
    for stroke in strokes {
      guard bounds(of: [stroke]).intersects(swept) else {
        out.append(stroke)
        continue
      }
      // segments longer than the eraser could pass it with both ends outside
      var pieces: [[CGPoint]] = []
      var run: [CGPoint] = []
      var touched = false
      for point in densified(stroke, step: radius / 2) {
        if distance(toSegment: point, start, end) <= radius {
          touched = true
          if run.count >= 2 { pieces.append(run) }
          run = []
        } else {
          run.append(point)
        }
      }
      if run.count >= 2 { pieces.append(run) }
      if touched {
        changed = true
        out += pieces.map(thinned).filter { $0.count >= 2 }
      } else {
        out.append(stroke)
      }
    }
    return changed ? out : nil
  }

  static func densified(_ stroke: [CGPoint], step: CGFloat) -> [CGPoint] {
    guard step > 0, let first = stroke.first else { return stroke }
    var out = [first]
    for (a, b) in zip(stroke, stroke.dropFirst()) {
      let pieces = Int((distance(a, b) / step).rounded(.up))
      if pieces > 1 {
        for i in 1..<pieces {
          let t = CGFloat(i) / CGFloat(pieces)
          out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
      }
      out.append(b)
    }
    return out
  }

  // MARK: - Moving and scaling

  /// The strokes moved by `offset`, to 0.01 pt.
  static func moved(_ strokes: [[CGPoint]], by offset: CGVector) -> [[CGPoint]] {
    strokes.map { $0.map { CGPoint(x: round($0.x + offset.dx), y: round($0.y + offset.dy)) } }
  }

  /// The strokes stretched about `anchor` by `x` across and `y` up, to 0.01 pt.
  static func scaled(_ strokes: [[CGPoint]], about anchor: CGPoint, x: CGFloat, y: CGFloat) -> [[CGPoint]] {
    strokes.map { stroke in
      stroke.map { CGPoint(x: round(anchor.x + ($0.x - anchor.x) * x), y: round(anchor.y + ($0.y - anchor.y) * y)) }
    }
  }

  /// A smooth curve through the points, each mapped by `transform`: through the midpoints, with the
  /// points themselves as control points, so it doesn't overshoot.
  static func path(through points: [CGPoint], _ transform: CGAffineTransform = .identity) -> CGPath {
    let path = CGMutablePath()
    guard let first = points.first?.applying(transform) else { return path }
    path.move(to: first)
    guard points.count > 2 else {
      path.addLine(to: (points.last ?? first).applying(transform))
      return path
    }
    for i in 1..<(points.count - 1) {
      let control = points[i].applying(transform), next = points[i + 1].applying(transform)
      path.addQuadCurve(to: CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2), control: control)
    }
    path.addLine(to: points[points.count - 1].applying(transform))
    return path
  }

  // MARK: - Measuring

  /// What a drawing covers: its strokes with the pen's half width around them.
  static func frame(of ink: PaperAnnotation.Ink) -> CGRect {
    let box = bounds(of: ink.strokes)
    return box.isNull ? .null : box.insetBy(dx: -ink.width / 2, dy: -ink.width / 2)
  }

  /// Whether `point` is on the drawing, `slop` beyond the stroke's own half width.
  static func hits(_ strokes: [[CGPoint]], width: CGFloat, at point: CGPoint, slop: CGFloat) -> Bool {
    let reach = width / 2 + slop
    for stroke in strokes where bounds(of: [stroke]).insetBy(dx: -reach, dy: -reach).contains(point) {
      if stroke.count == 1, distance(stroke[0], point) <= reach { return true }
      for (a, b) in zip(stroke, stroke.dropFirst()) where distance(toSegment: point, a, b) <= reach {
        return true
      }
    }
    return false
  }

  static func bounds(of strokes: [[CGPoint]]) -> CGRect {
    var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
    for stroke in strokes {
      for p in stroke {
        minX = min(minX, p.x); minY = min(minY, p.y)
        maxX = max(maxX, p.x); maxY = max(maxY, p.y)
      }
    }
    guard minX <= maxX else { return .null }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  /// the gap between two boxes, zero when they touch
  static func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let dx = max(0, max(a.minX - b.maxX, b.minX - a.maxX))
    let dy = max(0, max(a.minY - b.maxY, b.minY - a.maxY))
    return hypot(dx, dy)
  }

  static func length(of stroke: [CGPoint]) -> CGFloat {
    zip(stroke, stroke.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
  }

  static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

  static func distance(toSegment p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let squared = dx * dx + dy * dy
    guard squared > 0 else { return distance(p, a) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / squared))
    return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
  }

  private static func round(_ value: CGFloat) -> CGFloat { (value * 100).rounded() / 100 }
}
