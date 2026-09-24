import Foundation

/// 后端从哪来。
///
/// 从前的答案是写死在代码里的一个开发机路径。在那台机器上永远对，
/// 在别人的机器上永远错 —— 而错的样子是「找不到后端脚本，请在设置里指定项目目录」，
/// 用户根本不知道要去哪找一个仓库。
///
/// 现在按这条链找，**第一个命中的算数**：
///   1. 显式覆盖：设置页填的目录，或环境变量 `SCIVANE_PROJECT_ROOT`
///   2. 本 App 包里的 `Contents/Resources/backend/`（带 `scivane-package.json`）
///   3. 开发源码：从可执行文件往上找 `app/macos/Package.swift` ——
///      与 `paths.py` 是**同一个标志物**，两边对「仓库长什么样」只有一种说法
///   4. 都没有 → **带名字地失败**，说清楚找过哪几处。绝不回落到某个人的路径。
struct InstallContext: Equatable {
    enum Layout: String {
        case package   // 安装包里的 backend/
        case source    // 源码树，root 是仓库根
    }

    enum Origin: String {
        case override  // 设置页或环境变量指定
        case bundle    // 本 App 包里自带
        case source    // 从可执行文件的位置认出来的源码树
    }

    let layout: Layout
    let origin: Origin
    /// 包目录（`…/Contents/Resources/backend`）或仓库根。
    let root: URL

    /// 启动脚本。两种形态是同一份脚本 —— 构建时从 `scripts/` 原样拷进包。
    var launcher: URL {
        root.appendingPathComponent(layout == .package ? "bin/start_backend.sh" : "scripts/start_backend.sh")
    }

    static let manifestName = "scivane-package.json"
    static let packageSchema = "scivane.package/1"
    /// 与 `services/reader/src/scivane_reader/paths.py` 的 `_MARKER` 相同。
    static let sourceMarker = "app/macos/Package.swift"

    struct Failure: Error, Equatable {
        /// 两种说法都存着：它会进后端状态、一直显示在侧栏与设置页，切换语言之后要跟着换。
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
            // 包里有清单但对不上：找对了地方，是包和 App 不匹配。继续往下找只会
            // 找到一个更让人困惑的答案（比如恰好旁边有个仓库）。
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

    /// 认一个目录：安装包、源码树，还是都不是（nil）。
    ///
    /// 有清单但 schema 或架构不认识时返回**失败**而不是 nil —— 把一个认不出的包
    /// 当成「这里没有包」，会让排查的人以为是路径错了。
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

    /// 从可执行文件往上找仓库根。`swift build` 的产物在 `<仓库>/app/macos/.build/…`，
    /// 没带后端的旧包在 `<仓库>/var/app/Scivane.app/…`，两者都能认出来。
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
