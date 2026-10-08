import Foundation

/// Where the backend comes from. The first match wins:
///   1. explicit override: the Settings field or SCIVANE_PROJECT_ROOT
///   2. Contents/Resources/backend/ in this app bundle (with scivane-package.json)
///   3. a source tree, found by walking up from the executable to app/macos/Package.swift (the
///      same marker as paths.py)
///   4. otherwise, fail and name every place that was tried; never fall back to a fixed path
struct InstallContext: Equatable {
    enum Layout: String {
        case package   // backend/ inside an installed app
        case source    // source tree; root is the repository root
    }

    enum Origin: String {
        case override  // Settings or environment variable
        case bundle    // bundled with this app
        case source    // source tree found from the executable's location
    }

    let layout: Layout
    let origin: Origin
    /// the bundle's backend directory or the repository root
    let root: URL

    /// The same script in both layouts; the build copies it from scripts/ unchanged.
    var launcher: URL {
        root.appendingPathComponent(layout == .package ? "bin/start_backend.sh" : "scripts/start_backend.sh")
    }

    static let manifestName = "scivane-package.json"
    static let packageSchema = "scivane.package/1"
    /// must match _MARKER in paths.py
    static let sourceMarker = "app/macos/Package.swift"

    struct Failure: Error, Equatable {
        /// shown in the sidebar and Settings, so it must follow a language switch
        let text: UIText
        init(_ text: UIText) { self.text = text }
        var message: String { text.text }
    }

    static func resolve(override: URL?, bundle: URL, executable: URL?) -> Result<InstallContext, Failure> {
        if let override {
            let dir = override.standardizedFileURL
            switch classify(dir) {
            case .success(let layout?):
                return .success(InstallContext(layout: layout, origin: .override, root: dir))
            case .success(nil):
                return .failure(Failure(UIText(
                    "指定的后端位置既不是安装包也不是源码树：\(dir.path)\n在设置里清空这一项即可恢复自动定位。",
                    "The backend location you set is neither an installed package nor a source tree: \(dir.path)\n"
                        + "Clear it in Settings to go back to automatic detection.")))
            case .failure(let failure):
                return .failure(failure)
            }
        }

        let packaged = bundle.appendingPathComponent("Contents/Resources/backend").standardizedFileURL
        switch classify(packaged) {
        case .success(.package?):
            return .success(InstallContext(layout: .package, origin: .bundle, root: packaged))
        case .failure(let failure):
            // A manifest that doesn't match means the right place but the wrong bundle. Searching on would
            // only find a more confusing answer, such as a repository next to it.
            return .failure(failure)
        default:
            break
        }

        if let executable, let repo = sourceRoot(above: executable) {
            return .success(InstallContext(layout: .source, origin: .source, root: repo))
        }

        return .failure(Failure(UIText("""
            找不到后端。
              App 包里没有：\(packaged.path)
              也不在源码树里运行（从 \(executable?.path ?? "可执行文件") 往上没有 \(sourceMarker)）
            """, """
            Can't find the backend.
              Not in the app bundle: \(packaged.path)
              Not running from a source tree either (no \(sourceMarker) above \(executable?.path ?? "the executable"))
            """)))
    }

    /// Classify a directory as a bundle, a source tree, or neither (nil).
    ///
    /// An unknown schema or architecture is a failure, not nil: treating an unrecognised bundle as
    /// "no bundle here" would send whoever debugs it after the wrong path.
    static func classify(_ dir: URL) -> Result<Layout?, Failure> {
        let manifest = dir.appendingPathComponent(manifestName)
        if let data = try? Data(contentsOf: manifest) {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(Failure(UIText("后端清单读不懂：\(manifest.path)",
                                               "Can't read the backend manifest: \(manifest.path)")))
            }
            let schema = json["schema"] as? String
            guard schema == packageSchema else {
                return .failure(Failure(UIText(
                    "后端包的格式是 \(schema ?? "（缺失）")，这个版本的 App 只认 \(packageSchema)：\(dir.path)",
                    "The backend package has format \(schema ?? "(missing)"); "
                        + "this version of the app only reads \(packageSchema): \(dir.path)")))
            }
            let arch = json["arch"] as? String
            guard arch == "arm64" else {
                return .failure(Failure(UIText(
                    "后端包是 \(arch ?? "（缺失）") 架构的，Scivane 只支持 arm64：\(dir.path)",
                    "The backend package is built for \(arch ?? "(missing)"); Scivane supports arm64 only: \(dir.path)")))
            }
            return .success(.package)
        }
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(sourceMarker).path) {
            return .success(.source)
        }
        return .success(nil)
    }

    /// `swift build` output lives under <repo>/app/macos/.build/ and older bundles without a backend
    /// under <repo>/var/app/Scivane.app/; both are recognised.
    private static func sourceRoot(above executable: URL) -> URL? {
        var dir = executable.deletingLastPathComponent().standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(sourceMarker).path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            if parent.path == dir.path || dir.path == "/" { return nil }
            dir = parent
        }
    }
}
