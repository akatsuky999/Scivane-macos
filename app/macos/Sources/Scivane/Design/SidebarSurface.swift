import AppKit
import SwiftUI

/// A single outline, with a wider crown for the native controls when only the rail is showing.
struct SidebarIslandShape: Shape {
  var bodyWidth: CGFloat

  var animatableData: CGFloat {
    get { bodyWidth }
    set { bodyWidth = newValue }
  }

  func path(in rect: CGRect) -> Path {
    let radius = SidebarMetrics.radius
    let body = min(bodyWidth, rect.width)
    let x = rect.minX, y = rect.minY, right = rect.maxX, bottom = rect.maxY
    let bodyRight = x + body
    let overhang = right - bodyRight
    let crownRadius = radius + min(2, overhang / 12)
    let shoulder = y + crownRadius
    let taper: CGFloat = 36
    var path = Path()
    path.move(to: CGPoint(x: x + radius, y: y))
    path.addLine(to: CGPoint(x: right - crownRadius, y: y))
    path.addCurve(to: CGPoint(x: right - crownRadius / 6, y: y + crownRadius / 6),
      control1: CGPoint(x: right - 2 * crownRadius / 3, y: y),
      control2: CGPoint(x: right - crownRadius / 3, y: y))
    path.addCurve(to: CGPoint(x: right, y: shoulder),
      control1: CGPoint(x: right, y: y + crownRadius / 3),
      control2: CGPoint(x: right, y: y + 2 * crownRadius / 3))
    if overhang > 0.5 {
      // Shared tangents and curvature ease the shoulder into the straight rail without a ledge.
      path.addCurve(to: CGPoint(x: right - overhang / 6, y: shoulder + taper / 3),
        control1: CGPoint(x: right, y: shoulder + taper / 9),
        control2: CGPoint(x: right, y: shoulder + 2 * taper / 9))
      path.addCurve(to: CGPoint(x: bodyRight + overhang / 6, y: shoulder + 2 * taper / 3),
        control1: CGPoint(x: right - overhang / 3, y: shoulder + 4 * taper / 9),
        control2: CGPoint(x: bodyRight + overhang / 3, y: shoulder + 5 * taper / 9))
      path.addCurve(to: CGPoint(x: bodyRight, y: shoulder + taper),
        control1: CGPoint(x: bodyRight, y: shoulder + 7 * taper / 9),
        control2: CGPoint(x: bodyRight, y: shoulder + 8 * taper / 9))
    }
    path.addLine(to: CGPoint(x: bodyRight, y: bottom - radius))
    path.addQuadCurve(to: CGPoint(x: bodyRight - radius, y: bottom), control: CGPoint(x: bodyRight, y: bottom))
    path.addLine(to: CGPoint(x: x + radius, y: bottom))
    path.addQuadCurve(to: CGPoint(x: x, y: bottom - radius), control: CGPoint(x: x, y: bottom))
    path.addLine(to: CGPoint(x: x, y: y + radius))
    path.addCurve(to: CGPoint(x: x + radius / 6, y: y + radius / 6),
      control1: CGPoint(x: x, y: y + 2 * radius / 3),
      control2: CGPoint(x: x, y: y + radius / 3))
    path.addCurve(to: CGPoint(x: x + radius, y: y),
      control1: CGPoint(x: x + radius / 3, y: y),
      control2: CGPoint(x: x + 2 * radius / 3, y: y))
    path.closeSubpath()
    return path
  }
}

private struct SidebarSurface: ViewModifier {
  let shape: SidebarIslandShape
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    content
      .background {
        ZStack {
          if reduceTransparency { shape.fill(Palette.sidebar) }
          else {
            WindowGlassBackdrop().clipShape(shape)
            shape.fill(Palette.glassTint.opacity(colorScheme == .light ? 0.30 : 0.52))
          }
        }
        .shadow(color: Palette.glassShadow, radius: 18, y: 8)
        .allowsHitTesting(false)
      }
      .overlay(shape.stroke(Palette.glassEdge, lineWidth: 1).allowsHitTesting(false))
  }
}

extension View {
  func sidebarSurface(shape: SidebarIslandShape) -> some View { modifier(SidebarSurface(shape: shape)) }
}
