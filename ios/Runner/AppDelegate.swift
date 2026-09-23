import AVFoundation
import Flutter
import MediaPlayer
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var haptics: Haptics?
  private var volumeButtons: VolumeButtons?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    haptics = Haptics(messenger: engineBridge.applicationRegistrar.messenger())
    volumeButtons = VolumeButtons(messenger: engineBridge.applicationRegistrar.messenger())
  }
}

/// Counterpart of `lib/core/volume_buttons.dart`. iOS has no volume-button
/// events outside camera capture, so this watches the audio session's
/// outputVolume (the JPSVolumeButtonHandler approach): every press moves it one
/// step, which goes to Dart, and the volume is then set back so the phone's own
/// level stays put and a press at max/min still registers. The hidden
/// MPVolumeView keeps the system volume HUD away and its slider is the only
/// public way to set the volume.
private final class VolumeButtons {
  private let channel: FlutterMethodChannel
  private let session = AVAudioSession.sharedInstance()
  private var observation: NSKeyValueObservation?
  private var volumeView: MPVolumeView?
  private var baseVolume: Float = 0.5
  // Set when the phone sat at an end of the range and was moved to the middle;
  // put back on detach.
  private var userVolume: Float?
  // A route change (AirPods, CarPlay) changes outputVolume without a press.
  private var ignoreUntil = Date.distantPast
  private var wanted = false
  private var attached = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.nic.lgpower/volume_buttons", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "start":
        self.wanted = true
        if UIApplication.shared.applicationState == .active { self.attach() }
      case "stop":
        self.wanted = false
        self.detach()
      default:
        result(FlutterMethodNotImplemented)
        return
      }
      result(nil)
    }
    let center = NotificationCenter.default
    center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      guard let self = self, self.wanted else { return }
      self.attach()
    }
    // Inactive covers Control Center and the app switcher, where the buttons
    // should drive the phone again.
    center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      self?.detach()
    }
    center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
      guard let self = self, self.attached else { return }
      self.ignoreUntil = Date().addingTimeInterval(0.5)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        guard let self = self, self.attached else { return }
        self.rebase()
      }
    }
  }

  private func attach() {
    guard !attached, let window = keyWindow() else { return }
    do {
      // mixWithOthers so music already playing on the phone keeps playing.
      try session.setCategory(.playback, options: [.mixWithOthers])
      try session.setActive(true)
    } catch {
      return
    }
    let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 100, height: 40))
    // Fully transparent or hidden views don't count, and the HUD comes back.
    view.alpha = 0.01
    view.isUserInteractionEnabled = false
    window.addSubview(view)
    volumeView = view
    attached = true
    userVolume = nil
    // The slider only works once the view is in a window for a moment.
    ignoreUntil = Date().addingTimeInterval(0.3)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      guard let self = self, self.attached else { return }
      self.rebase()
    }
    observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
      guard let volume = change.newValue else { return }
      DispatchQueue.main.async { self?.volumeChanged(volume) }
    }
  }

  private func detach() {
    guard attached else { return }
    attached = false
    observation?.invalidate()
    observation = nil
    if let volume = userVolume {
      setVolume(volume)
      userVolume = nil
    }
    let view = volumeView
    volumeView = nil
    // Leave the view up until the restore above has landed, or the HUD shows.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      view?.removeFromSuperview()
    }
    try? session.setActive(false, options: .notifyOthersOnDeactivation)
  }

  // Presses at either end of the range don't change outputVolume, so keep
  // the phone away from both ends while listening.
  private func rebase() {
    let current = session.outputVolume
    if current > 0.9 || current < 0.1 {
      if userVolume == nil { userVolume = current }
      baseVolume = 0.5
      setVolume(0.5)
    } else {
      baseVolume = current
    }
  }

  private func volumeChanged(_ volume: Float) {
    guard attached, Date() >= ignoreUntil, abs(volume - baseVolume) > 0.001 else { return }
    channel.invokeMethod("press", arguments: volume > baseVolume ? "up" : "down")
    setVolume(baseVolume)
  }

  private func setVolume(_ value: Float) {
    guard let slider = volumeView?.subviews.compactMap({ $0 as? UISlider }).first else { return }
    slider.setValue(value, animated: false)
  }

  private func keyWindow() -> UIWindow? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    return windows.first { $0.isKeyWindow } ?? windows.first
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
