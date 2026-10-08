import Foundation

/// Locates the renderer's static resources. Not Bundle.module: it hard-codes
/// Scivane.app/Scivane_Scivane.bundle, which doesn't match a standard .app layout, and calls
/// fatalError when missing. Probes a few candidates instead, for both the app and `swift run`.
enum WebResources {

    /// WKWebView needs the directory to grant read access
    static let directory: URL? = {
        let fm = FileManager.default
        var candidates: [URL] = []

        // 1) packaged app: Contents/Resources/web/
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("web"))
            candidates.append(res.appendingPathComponent("Scivane_Scivane.bundle/Contents/Resources"))
            candidates.append(res.appendingPathComponent("Scivane_Scivane.bundle/Resources"))
        }

        // 2) swift run: the resource bundle next to the executable
        let exeDir = Bundle.main.bundleURL
        candidates.append(exeDir.appendingPathComponent("Scivane_Scivane.bundle/Resources"))
        candidates.append(exeDir.appendingPathComponent("Scivane_Scivane.bundle/Contents/Resources"))

        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("viewer.html").path) }
    }()

    static var viewerHTML: URL? {
        directory?.appendingPathComponent("viewer.html")
    }
}
