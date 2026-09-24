import SwiftUI

// **入口已下架（2026-09-16）。** 这个视图现在没有任何调用方 —— 保留是因为
// 下架是产品决定而不是代码判决：真要把它放回去，只需要在 ContentView 里
// 接一个分支。**不要以为它是死代码顺手删掉**，也不要往它上面加新东西。
//

struct EmptyStateView: View {
  @ObservedObject var model: AppModel
  let isTargeted: Bool
  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 30)
      VStack(alignment: .leading, spacing: 0) {
        FolioDrawing().frame(width: 54, height: 64).padding(.bottom, 20)
        Text(isTargeted ? L("松开以打开", "Release to Open") : L("打开文档", "Open a Document"))
          .font(.system(size: 23, weight: .regular, design: .serif))
          .foregroundStyle(Palette.ink)
        Text(L("导入原稿，或打开已有的 Markdown", "Import an original, or open an existing Markdown file"))
          .font(.system(size: 12)).foregroundStyle(Palette.inkSoft)
          .padding(.top, 10)
        HStack(spacing: 10) {
          Button {
            model.openPanel()
          } label: {
            Label(L("导入 PDF", "Import PDF"), systemImage: "doc")
          }
          .buttonStyle(StudioButtonStyle(primary: true))
          Button {
            model.openPanel(markdown: true)
          } label: {
            Label(L("导入 Markdown", "Import Markdown"), systemImage: "text.alignleft")
          }
          .buttonStyle(StudioButtonStyle())
        }.padding(.top, 24)
        Text(L("PDF 先预览再识别，Markdown 即开即读", "PDFs are previewed before OCR; Markdown opens as is"))
          .font(.system(size: 10.5)).foregroundStyle(Palette.inkFaint).padding(.top, 12)
      }.frame(width: 400, alignment: .leading)
      Spacer(minLength: 40)
      HStack(spacing: 6) {
        Image(systemName: "lock").font(.system(size: 9))
        Text(L("仅在此 Mac 上处理", "Processed on this Mac only"))
        Text("·").padding(.horizontal, 4)
        Text(L("支持多文件拖入", "Drop several files at once"))
      }.font(.system(size: 10)).foregroundStyle(Palette.inkFaint)
        .padding(.bottom, 20)
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// 以书页的细线与留白呼应折页标志，避免展示卡片占据工作区。
private struct FolioDrawing: View {
  var body: some View {
    Canvas { context, size in
      let w = size.width
      let h = size.height
      var sheet = Path()
      sheet.move(to: CGPoint(x: w * 0.12, y: h * 0.14))
      sheet.addLine(to: CGPoint(x: w * 0.76, y: h * 0.05))
      sheet.addLine(to: CGPoint(x: w * 0.76, y: h * 0.84))
      sheet.addLine(to: CGPoint(x: w * 0.12, y: h * 0.94))
      sheet.closeSubpath()
      context.fill(sheet, with: .color(Palette.panel))
      context.stroke(sheet, with: .color(Palette.accent.opacity(0.65)), lineWidth: 0.8)
      var fold = Path()
      fold.move(to: CGPoint(x: w * 0.81, y: h * 0.16))
      fold.addLine(to: CGPoint(x: w * 0.88, y: h * 0.17))
      fold.addLine(to: CGPoint(x: w * 0.88, y: h * 0.95))
      fold.addLine(to: CGPoint(x: w * 0.29, y: h * 0.97))
      context.stroke(fold, with: .color(Palette.accent.opacity(0.35)), lineWidth: 0.8)
      for row in 0..<5 {
        let y = h * (0.40 + Double(row) * 0.065)
        var line = Path()
        line.move(to: CGPoint(x: w * 0.25, y: y))
        line.addLine(to: CGPoint(x: w * (row == 4 ? 0.47 : 0.63), y: y - h * 0.045))
        context.stroke(line, with: .color(Palette.accent.opacity(0.35)), lineWidth: 0.7)
      }
      context.draw(
        Text("L").font(.custom("Baskerville", size: 17)).foregroundColor(Palette.accent),
        at: CGPoint(x: w * 0.3, y: h * 0.28))
    }.accessibilityHidden(true)
  }
}
