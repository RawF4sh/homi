import AVFoundation
import Flutter
import RoomPlan
import UIKit
import simd

@MainActor
final class BathroomScanPlatform {
  private static var request: BathroomScanRequest?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "safe_at_home/bathroom_scan", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "capabilities": result(capabilities())
      case "start": start(call.arguments, result: result)
      case "cancel":
        guard let scanID = requestID(call.arguments) else {
          result(failure("scan_failed", "The scan request is invalid.")); return
        }
        request?.cancel(scanID: scanID)
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  static func capabilities() -> [String: Any] {
    var reason = "unsupported_os"
    var supported = false
    var depthSupported = false
    if #available(iOS 16.0, *) {
      #if targetEnvironment(simulator)
        reason = "simulator"
      #else
        if RoomCaptureSession.isSupported {
          depthSupported = true
          let status = AVCaptureDevice.authorizationStatus(for: .video)
          supported = status != .denied && status != .restricted
          reason = supported ? "available" : "permission_denied"
        } else {
          reason = "unsupported_device"
        }
      #endif
    }
    return ["supported": supported, "source": "roomplan", "reason": reason,
      "depthSupported": depthSupported]
  }

  private static func requestID(_ arguments: Any?) -> String? {
    guard let args = arguments as? [String: Any], args.count == 1,
      let value = args["scanId"] as? String, BathroomScanGeometry.validScanID(value) else { return nil }
    return value
  }

  private static func start(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let scanID = requestID(arguments) else {
      result(failure("scan_failed", "The scan request is invalid.")); return
    }
    guard request == nil else {
      result(failure("scan_busy", "Another bathroom scan is already open.")); return
    }
    let available = capabilities()
    guard available["supported"] as? Bool == true else {
      let denied = available["reason"] as? String == "permission_denied"
      result(failure(denied ? "scan_permission_denied" : "scan_unavailable",
        denied ? "Allow camera access in Settings to scan your bathroom."
          : "Room scanning requires a supported LiDAR device with iOS 16 or later.")); return
    }
    let pending = BathroomScanRequest(scanID: scanID) { value in
      request = nil
      result(value)
    }
    request = pending
    pending.begin(authorization: AVCaptureDevice.authorizationStatus(for: .video),
      requestPermission: { callback in
        AVCaptureDevice.requestAccess(for: .video) { granted in
          DispatchQueue.main.async { callback(granted) }
        }
      }, present: { [weak pending] in
        guard let pending else { return }
        if let failure = BathroomScanReadiness.failure(applicationState: UIApplication.shared.applicationState,
          authorization: AVCaptureDevice.authorizationStatus(for: .video), thermalState: ProcessInfo.processInfo.thermalState) {
          pending.complete(failure); return
        }
        guard #available(iOS 16.0, *),
          let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
          let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
          pending.complete(failure("scan_interrupted", "Return to the app and start the scan again.")); return
        }
        var presenter = root
        while let shown = presenter.presentedViewController { presenter = shown }
        guard presenter.viewIfLoaded?.window != nil, !presenter.isBeingDismissed,
          !presenter.isBeingPresented else {
          pending.complete(failure("scan_unavailable", "Close the current screen and try scanning again.")); return
        }
        let controller = BathroomRoomCaptureController(scanID: scanID) { [weak pending] value in
          pending?.complete(value)
        }
        pending.stopCapture = { [weak controller] completion in
          guard let controller else { completion(); return }
          controller.stopAndDismiss(completion: completion)
        }
        controller.modalPresentationStyle = .fullScreen
        controller.isModalInPresentation = true
        presenter.present(controller, animated: true)
      })
  }

  static func failure(_ code: String, _ message: String) -> FlutterError {
    FlutterError(code: code, message: message, details: nil)
  }
}

@MainActor
final class BathroomScanRequest {
  let scanID: String
  private(set) var completed = false
  private var completion: FlutterResult?
  var stopCapture: ((@escaping () -> Void) -> Void)?

  init(scanID: String, completion: @escaping FlutterResult) {
    self.scanID = scanID; self.completion = completion
  }

  func begin(authorization: AVAuthorizationStatus,
    requestPermission: (@escaping (Bool) -> Void) -> Void, present: @escaping () -> Void) {
    guard !completed else { return }
    switch authorization {
    case .authorized: present()
    case .notDetermined:
      requestPermission { [weak self] granted in
        guard let self, !self.completed else { return }
        if granted { present() }
        else { self.permissionDenied() }
      }
    default: permissionDenied()
    }
  }

  private func permissionDenied() {
    complete(BathroomScanPlatform.failure("scan_permission_denied", "Allow camera access in Settings to scan your bathroom."))
  }

  func cancel(scanID: String) {
    guard self.scanID == scanID else { return }
    complete(BathroomScanPlatform.failure("scan_cancelled", "The bathroom scan was cancelled."))
  }

  func complete(_ value: Any?) {
    guard !completed else { return }
    completed = true
    let callback = completion
    completion = nil
    let stop = stopCapture
    stopCapture = nil
    if let stop { stop { callback?(value) } }
    else { callback?(value) }
  }
}

final class BathroomScanLifecycle: @unchecked Sendable {
  enum Phase { case ready, scanning, processing, stopping, finished }
  enum ProcessingDecision { case allow, ignore, failed, unexpectedStop }
  private let lock = NSLock()
  private var storedPhase = Phase.ready
  private var processingClaimed = false

  var phase: Phase {
    lock.lock(); defer { lock.unlock() }
    return storedPhase
  }

  func start() -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard storedPhase == .ready else { return false }
    storedPhase = .scanning
    return true
  }

  func requestProcessing() -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard storedPhase == .scanning else { return false }
    storedPhase = .processing
    return true
  }

  func claimProcessing(succeeded: Bool) -> ProcessingDecision {
    lock.lock(); defer { lock.unlock() }
    guard storedPhase != .finished && storedPhase != .stopping else { return .ignore }
    guard succeeded else {
      storedPhase = .stopping
      return .failed
    }
    guard storedPhase == .processing else {
      storedPhase = .stopping
      return .unexpectedStop
    }
    guard !processingClaimed else { return .ignore }
    processingClaimed = true
    return .allow
  }

  var mayAcceptResult: Bool {
    lock.lock(); defer { lock.unlock() }
    return storedPhase == .processing && processingClaimed
  }

  @discardableResult
  func finish() -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard storedPhase != .finished else { return false }
    storedPhase = .finished
    return true
  }
}

@MainActor
enum BathroomScanReadiness {
  static func failure(applicationState: UIApplication.State, authorization: AVAuthorizationStatus,
    thermalState: ProcessInfo.ThermalState) -> FlutterError? {
    guard applicationState == .active else {
      return BathroomScanPlatform.failure("scan_interrupted", "Return to the app and start the scan again.")
    }
    guard authorization == .authorized else {
      return BathroomScanPlatform.failure("scan_permission_denied", "Allow camera access in Settings to scan your bathroom.")
    }
    guard thermalState == .nominal || thermalState == .fair else {
      return BathroomScanPlatform.failure("scan_interrupted", "Let your device cool before starting another scan.")
    }
    return nil
  }
}

@MainActor
final class BathroomScanIdleTimerLease {
  private let read: () -> Bool
  private let write: (Bool) -> Void
  private var previousValue: Bool?

  init(read: @escaping () -> Bool, write: @escaping (Bool) -> Void) {
    self.read = read; self.write = write
  }

  func acquire() {
    guard previousValue == nil else { return }
    previousValue = read()
    write(true)
  }

  func release() {
    guard let previousValue else { return }
    self.previousValue = nil
    write(previousValue)
  }
}

@MainActor
final class BathroomScanCaptureLayout: UIView {
  let captureScroll = UIScrollView()
  let heading = UILabel()

  init(camera: UIView, status: UILabel, cancelButton: UIButton, finishButton: UIButton) {
    super.init(frame: .zero)
    heading.text = "Scan your bathroom"
    heading.font = .preferredFont(forTextStyle: .title2)
    heading.adjustsFontForContentSizeCategory = true
    heading.numberOfLines = 0
    heading.accessibilityTraits = .header
    status.text = "Move slowly and follow the camera guidance. Stay on a safe, clear path. Scan only this bathroom."
    status.font = .preferredFont(forTextStyle: .body)
    status.adjustsFontForContentSizeCategory = true
    status.numberOfLines = 0
    for label in [heading, status] {
      label.setContentCompressionResistancePriority(.required, for: .vertical)
    }
    for (button, title) in [(cancelButton, "Cancel scan"), (finishButton, "Finish scan")] {
      button.setTitle(title, for: .normal)
      button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
      button.titleLabel?.adjustsFontForContentSizeCategory = true
      button.titleLabel?.numberOfLines = 1
      button.titleLabel?.adjustsFontSizeToFitWidth = true
      button.titleLabel?.minimumScaleFactor = 0.5
      button.titleLabel?.textAlignment = .center
      button.setContentCompressionResistancePriority(.required, for: .vertical)
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
    }
    cancelButton.accessibilityIdentifier = "bathroom-scan-cancel"
    finishButton.accessibilityIdentifier = "bathroom-scan-finish"
    let introduction = UIStackView(arrangedSubviews: [heading, status])
    introduction.axis = .vertical; introduction.spacing = 8
    let captureContent = UIStackView(arrangedSubviews: [introduction, camera])
    captureContent.axis = .vertical; captureContent.spacing = 12
    captureContent.translatesAutoresizingMaskIntoConstraints = false
    captureScroll.addSubview(captureContent)
    captureScroll.alwaysBounceVertical = false
    captureScroll.isDirectionalLockEnabled = true
    let preferredCameraHeight = camera.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.55)
    preferredCameraHeight.priority = .defaultLow
    let preferredContentHeight = captureContent.heightAnchor.constraint(equalTo: captureScroll.frameLayoutGuide.heightAnchor)
    preferredContentHeight.priority = .defaultHigh
    NSLayoutConstraint.activate([
      captureContent.leadingAnchor.constraint(equalTo: captureScroll.contentLayoutGuide.leadingAnchor),
      captureContent.trailingAnchor.constraint(equalTo: captureScroll.contentLayoutGuide.trailingAnchor),
      captureContent.topAnchor.constraint(equalTo: captureScroll.contentLayoutGuide.topAnchor),
      captureContent.bottomAnchor.constraint(equalTo: captureScroll.contentLayoutGuide.bottomAnchor),
      captureContent.widthAnchor.constraint(equalTo: captureScroll.frameLayoutGuide.widthAnchor),
      captureContent.heightAnchor.constraint(greaterThanOrEqualTo: captureScroll.frameLayoutGuide.heightAnchor),
      camera.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
      preferredContentHeight,
    ])
    let controls = UIStackView(arrangedSubviews: [cancelButton, finishButton])
    controls.axis = .vertical; controls.spacing = 4
    let stack = UIStackView(arrangedSubviews: [captureScroll, controls])
    stack.axis = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      captureScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
      preferredCameraHeight,
    ])
    camera.setContentHuggingPriority(.defaultLow, for: .vertical)
  }

  required init?(coder: NSCoder) { fatalError("Storyboard construction is not supported") }
}

enum BathroomScanGeometry {
  enum Invalid: Error { case geometry, limit, empty }
  static let maximumElements = 256
  static let maximumBytes = 512 * 1024

  static func validScanID(_ value: String) -> Bool {
    value.utf8.count == 36 && value.range(of: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-4[0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$",
      options: .regularExpression) != nil
  }

  static func element(id: String, kind: String, nativeCategory: String,
    dimensions: [Double], transform: [Double], confidence: String) throws -> [String: Any] {
    let kinds: Set<String> = ["wall", "door", "opening", "window", "floor", "bathtub", "toilet", "sink", "storage", "furniture", "unknown"]
    guard !id.isEmpty, id.utf8.count <= 80, kinds.contains(kind), !nativeCategory.isEmpty,
      nativeCategory.utf8.count <= 64, ["low", "medium", "high", "unknown"].contains(confidence),
      dimensions.count == 3, dimensions.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 30 }),
      dimensions.filter({ $0 > 0 }).count >= 2,
      transform.count == 16, transform.allSatisfy({ $0.isFinite }),
      [3, 7, 11].allSatisfy({ abs(transform[$0]) <= 0.0001 }), abs(transform[15] - 1) <= 0.0001,
      [12, 13, 14].allSatisfy({ abs(transform[$0]) <= 50 }) else { throw Invalid.geometry }
    let axes = (0..<3).map { column in SIMD3<Double>(transform[column * 4], transform[column * 4 + 1], transform[column * 4 + 2]) }
    guard axes.allSatisfy({ abs(simd_length($0) - 1) <= 0.01 }),
      abs(simd_dot(axes[0], axes[1])) <= 0.01,
      abs(simd_dot(axes[0], axes[2])) <= 0.01,
      abs(simd_dot(axes[1], axes[2])) <= 0.01,
      abs(simd_dot(simd_cross(axes[0], axes[1]), axes[2]) - 1) <= 0.03 else { throw Invalid.geometry }
    let origin = SIMD3<Double>(transform[12], transform[13], transform[14])
    for x in [-dimensions[0] / 2, dimensions[0] / 2] {
      for y in [-dimensions[1] / 2, dimensions[1] / 2] {
        for z in [-dimensions[2] / 2, dimensions[2] / 2] {
          let corner = origin + axes[0] * x + axes[1] * y + axes[2] * z
          guard abs(corner.x) <= 50, abs(corner.y) <= 50, abs(corner.z) <= 50 else { throw Invalid.geometry }
        }
      }
    }
    return ["id": id, "kind": kind, "nativeCategory": nativeCategory,
      "dimensions": dimensions, "transform": transform, "classificationConfidence": confidence]
  }

  static func scene(scanID: String, capturedAt: Date, elements: [[String: Any]],
    warnings: Set<String>, truncated: Bool, sourceVersion: String) throws -> [String: Any] {
    guard validScanID(scanID), !elements.isEmpty else { throw Invalid.empty }
    guard elements.count <= maximumElements, warnings.count <= 16,
      sourceVersion.utf8.count <= 80 else { throw Invalid.limit }
    let allowed: Set<String> = ["curved_surfaces_approximated", "geometry_omitted", "depth_unavailable", "depth_partial", "tracking_limited", "count_limit"]
    guard warnings.isSubset(of: allowed) else { throw Invalid.geometry }
    let date = ISO8601DateFormatter()
    date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    date.timeZone = TimeZone(secondsFromGMT: 0)
    let value: [String: Any] = ["schemaVersion": 1, "scanId": scanID,
      "source": "roomplan", "sourceVersion": sourceVersion, "capturedAt": date.string(from: capturedAt),
      "units": "m", "coordinateSystem": "right_handed_y_up", "coverage": "partial",
      "truncated": truncated, "warnings": warnings.sorted(), "elements": elements, "points": [[Double]]()]
    let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    guard bytes.count <= maximumBytes else { throw Invalid.limit }
    return value
  }
}

@available(iOS 16.0, *)
@MainActor
private final class BathroomRoomCaptureController: UIViewController, RoomCaptureViewDelegate {
  private nonisolated let lifecycle = BathroomScanLifecycle()
  private let idleTimer = BathroomScanIdleTimerLease(read: { UIApplication.shared.isIdleTimerDisabled },
    write: { UIApplication.shared.isIdleTimerDisabled = $0 })
  private let scanID: String
  private let completion: FlutterResult
  private var captureView: RoomCaptureView?
  private var deadline: Timer?
  private var observers: [NSObjectProtocol] = []
  private let status = UILabel()
  private let finishButton = UIButton(type: .system)

  init(scanID: String, completion: @escaping FlutterResult) {
    self.scanID = scanID; self.completion = completion
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("Storyboard construction is not supported") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let camera = RoomCaptureView(frame: .zero)
    camera.delegate = self
    captureView = camera
    let cancel = UIButton(type: .system)
    cancel.addTarget(self, action: #selector(cancelScan), for: .touchUpInside)
    finishButton.addTarget(self, action: #selector(finishScan), for: .touchUpInside)
    let layout = BathroomScanCaptureLayout(camera: camera, status: status, cancelButton: cancel, finishButton: finishButton)
    layout.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(layout)
    NSLayoutConstraint.activate([
      layout.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      layout.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
      layout.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      layout.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
    ])
    for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.fail("scan_interrupted", "The scan was interrupted. Start again when you are ready.")
        }
      })
    }
    observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
      object: nil, queue: .main) { [weak self] _ in
        if ProcessInfo.processInfo.thermalState == .critical || ProcessInfo.processInfo.thermalState == .serious {
          Task { @MainActor [weak self] in
            self?.fail("scan_interrupted", "Let your device cool before starting another scan.")
          }
        }
      })
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard lifecycle.phase == .ready else { return }
    if let failure = BathroomScanReadiness.failure(applicationState: UIApplication.shared.applicationState,
      authorization: AVCaptureDevice.authorizationStatus(for: .video), thermalState: ProcessInfo.processInfo.thermalState) {
      complete(failure); return
    }
    guard lifecycle.start() else { return }
    idleTimer.acquire()
    var configuration = RoomCaptureSession.Configuration()
    configuration.isCoachingEnabled = true
    captureView?.captureSession.run(configuration: configuration)
    setDeadline(seconds: 180, message: "This scan reached its three-minute limit. Start a shorter bathroom scan.")
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if lifecycle.phase != .finished { fail("scan_interrupted", "The scan closed before it was reviewed. Please scan again.") }
  }

  override func didReceiveMemoryWarning() {
    super.didReceiveMemoryWarning()
    fail("scan_interrupted", "The device needs more memory. Close other apps and try scanning again.")
  }

  private func setDeadline(seconds: TimeInterval, message: String) {
    deadline?.invalidate()
    let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
      Task { @MainActor [weak self] in self?.fail("scan_limit", message) }
    }
    deadline = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  @objc private func cancelScan() {
    fail("scan_cancelled", "The bathroom scan was cancelled.")
  }

  @objc private func finishScan() {
    guard lifecycle.requestProcessing() else { return }
    finishButton.isEnabled = false
    status.text = "Preparing the simplified 3D room. You will review and confirm it next."
    UIAccessibility.post(notification: .announcement, argument: status.text)
    setDeadline(seconds: 30, message: "The room could not be prepared in time. Start a shorter scan.")
    captureView?.captureSession.stop()
  }

  nonisolated func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
    switch lifecycle.claimProcessing(succeeded: error == nil) {
    case .allow: return true
    case .ignore: return false
    case .failed:
      Task { @MainActor [weak self] in
        self?.fail("scan_failed", "Room scanning could not finish. Move to a clear, well-lit area and try again.")
      }
    case .unexpectedStop:
      Task { @MainActor [weak self] in
        self?.fail("scan_interrupted", "The scan stopped unexpectedly. Start the bathroom scan again.")
      }
    }
    return false
  }

  nonisolated func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
    let succeeded = error == nil
    Task { @MainActor [weak self] in
      self?.accept(processedResult, succeeded: succeeded)
    }
  }

  private func accept(_ processedResult: CapturedRoom, succeeded: Bool) {
    guard lifecycle.mayAcceptResult else { return }
    guard succeeded else {
      fail("scan_failed", "The room model could not be prepared. Please try again."); return
    }
    do {
      let payload = try geometry(processedResult)
      complete(payload)
    } catch BathroomScanGeometry.Invalid.empty {
      fail("scan_failed", "No usable room geometry was found. Scan the walls and fixtures again.")
    } catch BathroomScanGeometry.Invalid.limit {
      fail("scan_limit", "This room model is too large. Scan only one bathroom.")
    } catch {
      fail("scan_failed", "The room geometry could not be safely read. Please scan again.")
    }
  }

  private func geometry(_ room: CapturedRoom) throws -> [String: Any] {
    var elements: [[String: Any]] = []
    var warnings = Set<String>()
    var truncated = false
    func add(id: UUID, kind: String, native: String, dimensions: SIMD3<Float>,
      transform: simd_float4x4, confidence: CapturedRoom.Confidence) {
      guard elements.count < BathroomScanGeometry.maximumElements else {
        truncated = true; warnings.insert("count_limit"); return
      }
      let categoryConfidence: String
      switch confidence {
      case .high: categoryConfidence = "high"
      case .medium: categoryConfidence = "medium"
      case .low: categoryConfidence = "low"
      @unknown default: categoryConfidence = "unknown"
      }
      let matrix = (0..<4).flatMap { column in (0..<4).map { row in Double(transform[column][row]) } }
      do {
        elements.append(try BathroomScanGeometry.element(id: id.uuidString.lowercased(), kind: kind,
          nativeCategory: native, dimensions: [Double(dimensions.x), Double(dimensions.y), Double(dimensions.z)],
          transform: matrix, confidence: categoryConfidence))
      } catch {
        warnings.insert("geometry_omitted"); truncated = true
      }
    }
    func surfaces(_ values: [CapturedRoom.Surface], kind: String) {
      for surface in values {
        if surface.curve != nil { warnings.insert("curved_surfaces_approximated") }
        add(id: surface.identifier, kind: kind, native: kind, dimensions: surface.dimensions,
          transform: surface.transform, confidence: surface.confidence)
      }
    }
    surfaces(room.walls, kind: "wall")
    surfaces(room.doors, kind: "door")
    surfaces(room.openings, kind: "opening")
    surfaces(room.windows, kind: "window")
    if #available(iOS 17.0, *) { surfaces(room.floors, kind: "floor") }
    for object in room.objects {
      let kind: String
      let native: String
      switch object.category {
      case .bathtub: kind = "bathtub"; native = "bathtub"
      case .toilet: kind = "toilet"; native = "toilet"
      case .sink: kind = "sink"; native = "sink"
      case .storage: kind = "storage"; native = "storage"
      case .refrigerator: kind = "furniture"; native = "refrigerator"
      case .stove: kind = "furniture"; native = "stove"
      case .bed: kind = "furniture"; native = "bed"
      case .washerDryer: kind = "furniture"; native = "washerDryer"
      case .oven: kind = "furniture"; native = "oven"
      case .dishwasher: kind = "furniture"; native = "dishwasher"
      case .table: kind = "furniture"; native = "table"
      case .sofa: kind = "furniture"; native = "sofa"
      case .chair: kind = "furniture"; native = "chair"
      case .fireplace: kind = "unknown"; native = "fireplace"
      case .television: kind = "furniture"; native = "television"
      case .stairs: kind = "unknown"; native = "stairs"
      @unknown default: kind = "unknown"; native = "unknown"
      }
      add(id: object.identifier, kind: kind, native: native, dimensions: object.dimensions,
        transform: object.transform, confidence: object.confidence)
    }
    return try BathroomScanGeometry.scene(scanID: scanID, capturedAt: Date(), elements: elements,
      warnings: warnings, truncated: truncated, sourceVersion: "RoomPlan / iOS " + UIDevice.current.systemVersion)
  }

  private func fail(_ code: String, _ message: String) {
    complete(BathroomScanPlatform.failure(code, message))
  }

  private func complete(_ value: Any?) {
    guard lifecycle.finish() else { return }
    stop()
    completion(value)
  }

  private func stop() {
    lifecycle.finish()
    idleTimer.release()
    deadline?.invalidate(); deadline = nil
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
    captureView?.delegate = nil
    captureView?.captureSession.stop()
    captureView?.captureSession.arSession.pause()
  }

  func stopAndDismiss(completion: @escaping () -> Void) {
    stop()
    if presentingViewController != nil {
      dismiss(animated: false, completion: completion)
    } else { completion() }
  }
}
