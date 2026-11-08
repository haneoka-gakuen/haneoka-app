import SwiftRs
import Tauri
import UIKit
import WebKit

struct BarsArgs: Decodable {
  let color: String?
  let dark: Bool?
}

/// The page stays below the status bar and its area shows the page's bar
/// colour, as on Android.
class DevicePlugin: Plugin {
  weak var webview: WKWebView?

  @objc public override func load(webview: WKWebView) {
    self.webview = webview
    DispatchQueue.main.async {
      guard let parent = webview.superview else { return }
      webview.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        webview.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor),
        webview.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        webview.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
        webview.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
      ])
    }
  }

  @objc public func systemBars(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(BarsArgs.self)
    DispatchQueue.main.async {
      if let hex = args.color, let color = UIColor(hex: hex) {
        self.webview?.superview?.backgroundColor = color
        self.webview?.backgroundColor = color
      }
      invoke.resolve()
    }
  }
}

extension UIColor {
  convenience init?(hex: String) {
    let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
    self.init(
      red: CGFloat((number >> 16) & 0xff) / 255,
      green: CGFloat((number >> 8) & 0xff) / 255,
      blue: CGFloat(number & 0xff) / 255,
      alpha: 1)
  }
}

@_cdecl("init_plugin_haneoka_device")
func initPlugin() -> Plugin {
  return DevicePlugin()
}
