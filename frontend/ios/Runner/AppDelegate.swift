import AuthenticationServices
import CryptoKit
import Flutter
import Security
import UIKit
import UserNotifications
import WidgetKit

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let endpoint = URL(string: "https://spacetime.gravitas.cool/api/notifications/ios")!
  private let defaults = UserDefaults.standard
  private lazy var service: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 8
    return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
  }()
  private var push: FlutterMethodChannel?
  private var credential: String?
  private var apnsToken: String?
  private var inFlight: String?
  private var pendingOpen: [AnyHashable: Any]?
  private var auth: ASWebAuthenticationSession?
  private var calendarWidgets: FlutterMethodChannel?
  private var calendarNavigationReady = false
  private var pendingCalendarLink: [String: String]?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: "cool.gravitas/apns", binaryMessenger: controller.binaryMessenger)
      push = channel
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self else { result(nil); return }
        switch call.method {
        case "bind":
          let next = call.arguments as? String
          if self.credential != next || self.apnsToken == nil {
            self.credential = next
            self.registerForPush()
          } else {
            self.sendRegistration()
          }
          result(nil)
        case "unbind":
          self.unbind(result)
        case "takeOpen":
          result(self.pendingOpen)
          self.pendingOpen = nil
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      let authChannel = FlutterMethodChannel(name: "cool.gravitas.spacetime/auth", binaryMessenger: controller.binaryMessenger)
      authChannel.setMethodCallHandler { [weak self] call, result in
        guard let self else { result(nil); return }
        self.handleAuthentication(call, result: result)
      }
      let widgetChannel = FlutterMethodChannel(
        name: "com.jeethsuresh.spacetime/widgets", binaryMessenger: controller.binaryMessenger
      )
      calendarWidgets = widgetChannel
      widgetChannel.setMethodCallHandler { [weak self] call, result in
        guard let self else { result(nil); return }
        switch call.method {
        case "publish":
          self.publishCalendarWidget(call.arguments, result: result)
        case "takeCalendarLink":
          self.calendarNavigationReady = true
          result(self.pendingCalendarLink)
          self.pendingCalendarLink = nil
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    if let url = launchOptions?[.url] as? URL {
      pendingCalendarLink = calendarLink(url)
    }
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ application: UIApplication, open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    guard let link = calendarLink(url) else {
      return super.application(application, open: url, options: options)
    }
    if calendarNavigationReady {
      calendarWidgets?.invokeMethod("openCalendar", arguments: link)
    } else {
      pendingCalendarLink = link
    }
    return true
  }

  private func calendarLink(_ url: URL) -> [String: String]? {
    guard url.scheme == "spacetime", url.host == "calendar", url.path.isEmpty,
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
          let date = items.first(where: { $0.name == "date" })?.value,
          date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
          let view = items.first(where: { $0.name == "view" })?.value,
          ["Daily", "Weekly"].contains(view) else { return nil }
    return ["date": date, "view": view]
  }

  private func publishCalendarWidget(_ arguments: Any?, result: FlutterResult) {
    guard let snapshot = arguments as? String,
          let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.jeethsuresh.spacetime"
          ) else {
      result(FlutterError(code: "widget_storage_unavailable", message: nil, details: nil))
      return
    }
    let file = directory.appendingPathComponent("calendar-widget.json")
    let data = Data(snapshot.utf8)
    do {
      if (try? Data(contentsOf: file)) != data {
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        WidgetCenter.shared.reloadAllTimelines()
      }
      result(nil)
    } catch {
      result(FlutterError(code: "widget_storage_failed", message: nil, details: nil))
    }
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    registerForPush()
  }

  private func registerForPush() {
    guard credential != nil else { return }
    UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
      DispatchQueue.main.async {
        guard let self, self.credential != nil else { return }
        switch settings.authorizationStatus {
        case .notDetermined:
          UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            DispatchQueue.main.async {
              if granted && self.credential != nil { UIApplication.shared.registerForRemoteNotifications() }
            }
          }
        case .authorized, .provisional, .ephemeral:
          UIApplication.shared.registerForRemoteNotifications()
          self.sendRegistration()
        default:
          if self.defaults.string(forKey: "apns.binding") != nil {
            self.removeBinding(self.credential) { _ in }
          }
        }
      }
    }
  }

  override func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    apnsToken = deviceToken.map { String(format: "%02x", $0) }.joined()
    sendRegistration()
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  private func sendRegistration() {
    guard let credential, let token = apnsToken,
          let environment = Bundle.main.object(forInfoDictionaryKey: "APNSEnvironment") as? String else { return }
    let bytes = Data((credential + "\u{0}" + token + "\u{0}" + environment).utf8)
    let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    guard fingerprint != inFlight, fingerprint != defaults.string(forKey: "apns.binding") else { return }
    inFlight = fingerprint
    send("PUT", credential: credential, data: ["token": token, "environment": environment]) { [weak self] status in
      guard let self, self.inFlight == fingerprint else { return }
      self.inFlight = nil
      if status == 204 { self.defaults.set(fingerprint, forKey: "apns.binding") }
    }
  }

  private func unbind(_ result: @escaping FlutterResult) {
    let previous = credential
    credential = nil
    removeBinding(previous, result)
  }

  private func removeBinding(_ previous: String?, _ result: @escaping FlutterResult) {
    apnsToken = nil
    inFlight = nil
    pendingOpen = nil
    defaults.removeObject(forKey: "apns.binding")
    UIApplication.shared.unregisterForRemoteNotifications()
    UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    guard let previous else { result(nil); return }
    send("DELETE", credential: previous, data: [:]) { _ in result(nil) }
  }

  private func send(_ method: String, credential: String, data: [String: Any], completion: @escaping (Int?) -> Void) {
    var installation = defaults.string(forKey: "apns.installation")
    if installation == nil {
      var bytes = [UInt8](repeating: 0, count: 32)
      guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        completion(nil)
        return
      }
      installation = bytes.map { String(format: "%02x", $0) }.joined()
      defaults.set(installation, forKey: "apns.installation")
    }
    let generation = defaults.integer(forKey: "apns.generation") + 1
    defaults.set(generation, forKey: "apns.generation")
    var body = data
    body["installation"] = installation
    body["generation"] = generation
    var request = URLRequest(url: endpoint)
    if method == "DELETE" { request.timeoutInterval = 4 }
    request.httpMethod = method
    request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("1", forHTTPHeaderField: "X-Gravitas-CSRF")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    service.dataTask(with: request) { _, response, _ in
      let status = (response as? HTTPURLResponse)?.statusCode
      DispatchQueue.main.async { completion(status) }
    }.resume()
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let data = response.notification.request.content.userInfo
    if let subject = data["subject"] as? String,
       let payload = data["payload"] as? [AnyHashable: Any], payload["subject"] as? String == subject {
      pendingOpen = payload
      push?.invokeMethod("opened", arguments: nil)
    }
    completionHandler()
  }
}

extension AppDelegate: ASWebAuthenticationPresentationContextProviding {
  private func handleAuthentication(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "cancel" {
      auth?.cancel()
      auth = nil
      result(nil)
      return
    }
    guard call.method == "begin", let value = call.arguments as? String, let url = URL(string: value),
          url.scheme == "https", url.host == "spacetime.gravitas.cool", url.path == "/auth/gravitas/start" else {
      result(FlutterError(code: "invalid_authentication_request", message: nil, details: nil))
      return
    }
    auth?.cancel()
    let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "cool.gravitas.spacetime") { callback, _ in
      DispatchQueue.main.async { result(callback?.absoluteString) }
    }
    session.presentationContextProvider = self
    auth = session
    if !session.start() {
      auth = nil
      result(FlutterError(code: "authentication_unavailable", message: nil, details: nil))
    }
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    window ?? ASPresentationAnchor()
  }
}
