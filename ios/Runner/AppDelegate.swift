import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var haptics: Haptics?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    haptics = Haptics(messenger: engineBridge.applicationRegistrar.messenger())
  }
}

/// Counterpart of `lib/core/haptics.dart`. The generators live for the whole
/// app and are re-prepared after each play: UIKit only reliably fires a
/// generator that is still alive and warmed up when the tick is requested.
private final class Haptics {
  private let light = UIImpactFeedbackGenerator(style: .light)
  private let medium = UIImpactFeedbackGenerator(style: .medium)
  private let heavy = UIImpactFeedbackGenerator(style: .heavy)
  private let selection = UISelectionFeedbackGenerator()
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.nic.lgpower/haptics", binaryMessenger: messenger)
    prepareAll()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self, call.method == "play" else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.arguments as? String {
      case "light":
        self.light.impactOccurred()
        self.light.prepare()
      case "medium":
        self.medium.impactOccurred()
        self.medium.prepare()
      case "heavy":
        self.heavy.impactOccurred()
        self.heavy.prepare()
      case "selection":
        self.selection.selectionChanged()
        self.selection.prepare()
      default:
        result(FlutterError(code: "bad_kind", message: "Unknown haptic kind", details: nil))
        return
      }
      result(nil)
    }
  }

  private func prepareAll() {
    light.prepare()
    medium.prepare()
    heavy.prepare()
    selection.prepare()
  }
}
