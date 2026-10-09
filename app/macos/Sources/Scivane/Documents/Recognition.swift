import Foundation

/// How a document is read into text: local OCR on this Mac, or a model card that can see images.
enum RecognitionEngine: Hashable {
  case local
  case model(provider: String)

  var provider: String? {
    if case .model(let provider) = self { return provider }
    return nil
  }

  /// The last choice, so the chooser opens where people left it.
  static var remembered: RecognitionEngine? {
    get {
      let defaults = UserDefaults.standard
      switch defaults.string(forKey: "recognitionEngine") {
      case "local": return .local
      case "model":
        return defaults.string(forKey: "recognitionProvider").map { .model(provider: $0) }
      default: return nil
      }
    }
    set {
      let defaults = UserDefaults.standard
      switch newValue {
      case .local?:
        defaults.set("local", forKey: "recognitionEngine")
      case .model(let provider)?:
        defaults.set("model", forKey: "recognitionEngine")
        defaults.set(provider, forKey: "recognitionProvider")
      case nil:
        defaults.removeObject(forKey: "recognitionEngine")
      }
    }
  }
}

/// Asks the user which engine to recognise a document with; shown as a sheet.
struct RecognitionRequest: Identifiable {
  let id = UUID()
  let job: DocumentJob.ID
}

/// Stable model error codes from the backend, phrased for people. One table for every place a
/// model call can fail in front of the user (Settings > Test, recognition), so they never disagree.
enum ModelFailure {
  static func describe(code: String?, message: String) -> UIText {
    switch code {
    case "NO_VISION":
      return UIText("这张模型卡看不到图片，换一张能看图的", "This model card can't see images — pick one that can")
    case "MISSING_CREDENTIAL":
      return UIText("还没填 API key", "No API key yet")
    case "INVALID_CREDENTIAL", "AUTH":
      return UIText("key 不对，或者没有这个模型的权限", "Wrong key, or no access to this model")
    case "RATE_LIMIT":
      return UIText("被限流了，等一会儿再试", "Rate-limited — try again in a moment")
    case "QUOTA":
      return UIText("配额用完了", "Out of quota")
    case "TIMEOUT", "TRANSPORT":
      return UIText("连不上厂商，检查网络或 base_url", "Can't reach the provider — check the network or base URL")
    case "NO_ADAPTER":
      return UIText("这个 provider 没有注册", "This provider isn't registered")
    default:
      // the backend's own wording, already in the language of the request
      return .verbatim(message.isEmpty ? L("未知错误", "Unknown error") : message)
    }
  }
}
