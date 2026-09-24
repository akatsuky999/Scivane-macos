import Foundation

/// 定位渲染器的静态资源。
///
/// 不用 SPM 的 `Bundle.module`：它写死了 `Scivane.app/Scivane_Scivane.bundle` 这个路径，
/// 和标准 .app 布局（资源在 Contents/Resources）对不上，找不到时还会直接 fatalError。
/// 这里按几个候选位置依次探测，打包运行和 `swift run` 开发都能命中。
enum WebResources {

    /// viewer.html 所在目录；WKWebView 需要它来授予同目录读权限。
    static let directory: URL? = {
        let fm = FileManager.default
        var candidates: [URL] = []

        // 1) 打包后的 .app：Contents/Resources/web/
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("web"))
            candidates.append(res.appendingPathComponent("Scivane_Scivane.bundle/Contents/Resources"))
            candidates.append(res.appendingPathComponent("Scivane_Scivane.bundle/Resources"))
        }

        // 2) swift run 开发时：可执行文件旁边的资源包
        let exeDir = Bundle.main.bundleURL
        candidates.append(exeDir.appendingPathComponent("Scivane_Scivane.bundle/Resources"))
        candidates.append(exeDir.appendingPathComponent("Scivane_Scivane.bundle/Contents/Resources"))

        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("viewer.html").path) }
    }()

    static var viewerHTML: URL? {
        directory?.appendingPathComponent("viewer.html")
    }
}
