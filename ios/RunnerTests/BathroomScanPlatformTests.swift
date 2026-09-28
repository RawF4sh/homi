import AVFoundation
import Flutter
import UIKit
import XCTest
@testable import Runner

@MainActor
final class BathroomScanPlatformTests: XCTestCase {
  private let scanID = "1a063c5b-e72e-4aac-a70d-6b6148174451"
  private let secondID = "3620d5cd-9507-4fa0-ae3a-826155162191"
  private let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

  private func element(dimensions: [Double] = [2.5, 2.4, 0], transform: [Double]? = nil) throws -> [String: Any] {
    try BathroomScanGeometry.element(id: "wall-1", kind: "wall", nativeCategory: "wall",
      dimensions: dimensions, transform: transform ?? identity, confidence: "medium")
  }

  func testSimulatorNeverClaimsLiDARCapability() {
    #if targetEnvironment(simulator)
      let value = BathroomScanPlatform.capabilities()
      XCTAssertEqual(value["supported"] as? Bool, false)
      XCTAssertEqual(value["source"] as? String, "roomplan")
      if #available(iOS 16.0, *) { XCTAssertEqual(value["reason"] as? String, "simulator") }
      else { XCTAssertEqual(value["reason"] as? String, "unsupported_os") }
    #endif
  }

  func testOnlyBoundedUUIDv4RequestIDsAreAccepted() {
    XCTAssertTrue(BathroomScanGeometry.validScanID(scanID))
    XCTAssertTrue(BathroomScanGeometry.validScanID(scanID.uppercased()))
    XCTAssertFalse(BathroomScanGeometry.validScanID("../../scan"))
    XCTAssertFalse(BathroomScanGeometry.validScanID("1a063c5b-e72e-1aac-a70d-6b6148174451"))
    XCTAssertFalse(BathroomScanGeometry.validScanID("1a063c5b-e72e-4aac-770d-6b6148174451"))
    XCTAssertFalse(BathroomScanGeometry.validScanID(scanID + "\n"))
  }

  func testPlanarDimensionsRetainZeroThicknessAndClassificationConfidence() throws {
    let value = try element()
    XCTAssertEqual(value["dimensions"] as? [Double], [2.5, 2.4, 0])
    XCTAssertEqual(value["classificationConfidence"] as? String, "medium")
    XCTAssertNil(value["accuracy"])
  }

  func testNonFiniteOutOfRangeAndDegenerateSizesAreRejected() throws {
    let invalid: [[Double]] = [[Double.nan, 2, 0], [2, Double.infinity, 0], [-1, 2, 0], [30.01, 2, 0], [0, 2, 0]]
    for dimensions in invalid {
      XCTAssertThrowsError(try element(dimensions: dimensions))
    }
    XCTAssertNoThrow(try element(dimensions: [30, 30, 0]))
  }

  func testColumnMajorPoseRetainsRotationAndTranslationWithoutInventedBounds() throws {
    let transform: [Double] = [0, 0, -1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 4, 1.2, -3, 1]
    let value = try element(transform: transform)
    XCTAssertEqual(value["transform"] as? [Double], transform)
    XCTAssertEqual(value["dimensions"] as? [Double], [2.5, 2.4, 0])
  }

  func testNonRigidReflectedOrUnboundedTransformsAreRejected() {
    for (index, value) in [(0, 2.0), (0, -1.0), (3, 0.1), (12, 50.01), (13, Double.infinity), (15, 0.0)] {
      var transform = identity; transform[index] = value
      XCTAssertThrowsError(try element(transform: transform))
    }
    XCTAssertThrowsError(try element(transform: [1, 2, 3]))
    var edge = identity; edge[12] = 49
    XCTAssertThrowsError(try element(transform: edge), "World corners must also remain inside the scene bound")
  }

  func testGeometryPayloadHasOnlyAllowlistedGeometryAndPartialCoverage() throws {
    let value = try BathroomScanGeometry.scene(scanID: scanID, capturedAt: Date(timeIntervalSince1970: 0),
      elements: [try element()], warnings: ["curved_surfaces_approximated"], truncated: false, sourceVersion: "RoomPlan / iOS test")
    XCTAssertEqual(Set(value.keys), ["schemaVersion", "scanId", "source", "sourceVersion", "capturedAt", "units",
      "coordinateSystem", "coverage", "truncated", "warnings", "elements", "points"])
    XCTAssertEqual(value["coverage"] as? String, "partial")
    XCTAssertEqual(value["source"] as? String, "roomplan")
    XCTAssertEqual(value["capturedAt"] as? String, "1970-01-01T00:00:00.000Z")
    XCTAssertEqual(value["points"] as? [[Double]], [])
    XCTAssertLessThan(try JSONSerialization.data(withJSONObject: value).count, BathroomScanGeometry.maximumBytes)
  }

  func testEmptyOrOverCapacityModelsAreRejectedAndTruncationIsExplicit() throws {
    let one = try element()
    XCTAssertThrowsError(try BathroomScanGeometry.scene(scanID: scanID, capturedAt: Date(), elements: [],
      warnings: [], truncated: false, sourceVersion: "test"))
    XCTAssertThrowsError(try BathroomScanGeometry.scene(scanID: scanID, capturedAt: Date(),
      elements: Array(repeating: one, count: 257), warnings: [], truncated: false, sourceVersion: "test"))
    XCTAssertThrowsError(try BathroomScanGeometry.scene(scanID: scanID, capturedAt: Date(), elements: [one],
      warnings: ["unreviewed-warning"], truncated: false, sourceVersion: "test"))
    let value = try BathroomScanGeometry.scene(scanID: scanID, capturedAt: Date(), elements: [one],
      warnings: ["geometry_omitted", "count_limit"], truncated: true, sourceVersion: "test")
    XCTAssertEqual(value["truncated"] as? Bool, true)
    XCTAssertEqual(value["warnings"] as? [String], ["count_limit", "geometry_omitted"])
  }

  func testCancelBeforePermissionReplyNeverPresentsCameraOrCompletesTwice() {
    var permission: ((Bool) -> Void)?
    var presentations = 0
    var answers: [Any?] = []
    let request = BathroomScanRequest(scanID: scanID) { answers.append($0) }
    request.begin(authorization: .notDetermined, requestPermission: { permission = $0 }, present: { presentations += 1 })
    request.cancel(scanID: scanID)
    permission?(true)
    request.complete(["late": true])
    XCTAssertEqual(presentations, 0)
    XCTAssertEqual(answers.count, 1)
    XCTAssertEqual((answers[0] as? FlutterError)?.code, "scan_cancelled")
  }

  func testOldScopedCancellationCannotCancelNewRequest() {
    var answers: [Any?] = []
    let request = BathroomScanRequest(scanID: secondID) { answers.append($0) }
    request.cancel(scanID: scanID)
    XCTAssertFalse(request.completed)
    XCTAssertTrue(answers.isEmpty)
    request.complete("new-result")
    XCTAssertEqual(answers[0] as? String, "new-result")
  }

  func testDeniedPermissionDoesNotPresentAndReportsRecoverableCode() {
    var answer: Any?
    var presentations = 0
    let request = BathroomScanRequest(scanID: scanID) { answer = $0 }
    request.begin(authorization: .denied, requestPermission: { _ in XCTFail("Do not re-prompt a denied permission") },
      present: { presentations += 1 })
    XCTAssertEqual(presentations, 0)
    XCTAssertEqual((answer as? FlutterError)?.code, "scan_permission_denied")
  }

  func testCompletionWaitsForCameraDismissalAndIgnoresLateInterruption() {
    var dismissed: (() -> Void)?
    var stopCount = 0
    var answers: [Any?] = []
    let request = BathroomScanRequest(scanID: scanID) { answers.append($0) }
    request.stopCapture = { callback in stopCount += 1; dismissed = callback }
    request.complete("geometry")
    request.cancel(scanID: scanID)
    XCTAssertTrue(answers.isEmpty)
    XCTAssertEqual(stopCount, 1)
    dismissed?()
    XCTAssertEqual(answers.count, 1)
    XCTAssertEqual(answers[0] as? String, "geometry")
  }

  func testRoomProcessingRequiresAnExplicitFinishAndRejectsUnexpectedStops() {
    let lifecycle = BathroomScanLifecycle()
    XCTAssertFalse(lifecycle.requestProcessing())
    XCTAssertFalse(lifecycle.mayAcceptResult)
    XCTAssertTrue(lifecycle.start())
    XCTAssertFalse(lifecycle.start())
    XCTAssertTrue(lifecycle.requestProcessing())
    XCTAssertFalse(lifecycle.requestProcessing())
    XCTAssertEqual(lifecycle.claimProcessing(succeeded: true), .allow)
    XCTAssertTrue(lifecycle.mayAcceptResult)
    XCTAssertEqual(lifecycle.claimProcessing(succeeded: true), .ignore)
  }

  func testUnexpectedStopCannotBeTurnedIntoSuccessfulProcessingByALateFinish() {
    let lifecycle = BathroomScanLifecycle()
    XCTAssertTrue(lifecycle.start())
    XCTAssertEqual(lifecycle.claimProcessing(succeeded: true), .unexpectedStop)
    XCTAssertFalse(lifecycle.requestProcessing())
    XCTAssertEqual(lifecycle.claimProcessing(succeeded: true), .ignore)
    XCTAssertFalse(lifecycle.mayAcceptResult)
    XCTAssertTrue(lifecycle.finish())
  }

  func testCancelledCaptureNeverAuthorizesLateRoomProcessingOrResults() {
    for stopAfterFinish in [false, true] {
      let lifecycle = BathroomScanLifecycle()
      XCTAssertTrue(lifecycle.start())
      if stopAfterFinish { XCTAssertTrue(lifecycle.requestProcessing()) }
      XCTAssertTrue(lifecycle.finish())
      XCTAssertFalse(lifecycle.finish())
      XCTAssertEqual(lifecycle.claimProcessing(succeeded: true), .ignore)
      XCTAssertEqual(lifecycle.claimProcessing(succeeded: false), .ignore)
      XCTAssertFalse(lifecycle.mayAcceptResult)
      XCTAssertFalse(lifecycle.start())
      XCTAssertFalse(lifecycle.requestProcessing())
    }
  }

  func testCancellationAfterRoomProcessingBeginsRejectsItsResult() {
    let lifecycle = BathroomScanLifecycle()
    XCTAssertTrue(lifecycle.start())
    XCTAssertTrue(lifecycle.requestProcessing())
    XCTAssertEqual(lifecycle.claimProcessing(succeeded: true), .allow)
    XCTAssertTrue(lifecycle.finish())
    XCTAssertFalse(lifecycle.mayAcceptResult)
  }

  func testFrameworkErrorNeverAuthorizesRoomProcessing() {
    let lifecycle = BathroomScanLifecycle()
    XCTAssertTrue(lifecycle.start())
    XCTAssertTrue(lifecycle.requestProcessing())
    XCTAssertEqual(lifecycle.claimProcessing(succeeded: false), .failed)
    XCTAssertEqual(lifecycle.claimProcessing(succeeded: true), .ignore)
    XCTAssertFalse(lifecycle.mayAcceptResult)
    XCTAssertTrue(lifecycle.finish())
  }

  func testConcurrentFrameworkCallbacksAuthorizeOnlyOneProcessingPass() {
    let lifecycle = BathroomScanLifecycle()
    XCTAssertTrue(lifecycle.start())
    XCTAssertTrue(lifecycle.requestProcessing())
    let countLock = NSLock()
    var allowed = 0
    DispatchQueue.concurrentPerform(iterations: 64) { _ in
      if lifecycle.claimProcessing(succeeded: true) == .allow {
        countLock.lock()
        allowed += 1
        countLock.unlock()
      }
    }
    XCTAssertEqual(allowed, 1)
    XCTAssertTrue(lifecycle.mayAcceptResult)
  }

  func testCaptureReadinessRechecksPermissionActivityAndExistingHeat() {
    for state in [ProcessInfo.ThermalState.nominal, .fair] {
      XCTAssertNil(BathroomScanReadiness.failure(applicationState: .active,
        authorization: .authorized, thermalState: state))
    }
    for state in [ProcessInfo.ThermalState.serious, .critical] {
      let error = BathroomScanReadiness.failure(applicationState: .active,
        authorization: .authorized, thermalState: state)
      XCTAssertEqual(error?.code, "scan_interrupted")
      XCTAssertTrue(error?.message?.contains("cool") == true)
    }
    for state in [UIApplication.State.inactive, .background] {
      XCTAssertEqual(BathroomScanReadiness.failure(applicationState: state,
        authorization: .authorized, thermalState: .nominal)?.code, "scan_interrupted")
    }
    for authorization in [AVAuthorizationStatus.denied, .restricted, .notDetermined] {
      XCTAssertEqual(BathroomScanReadiness.failure(applicationState: .active,
        authorization: authorization, thermalState: .nominal)?.code, "scan_permission_denied")
    }
  }

  func testIdleTimerIsHeldUntilExitAndRestoresEitherPreviousPolicy() {
    for originalValue in [false, true] {
      var idleTimerDisabled = originalValue
      var writes: [Bool] = []
      let lease = BathroomScanIdleTimerLease(read: { idleTimerDisabled }, write: {
        idleTimerDisabled = $0; writes.append($0)
      })
      lease.release()
      XCTAssertTrue(writes.isEmpty)
      lease.acquire()
      lease.acquire()
      XCTAssertTrue(idleTimerDisabled)
      XCTAssertEqual(writes, [true])
      lease.release()
      lease.release()
      XCTAssertEqual(idleTimerDisabled, originalValue)
      XCTAssertEqual(writes, [true, originalValue])
    }
  }

  func testEndedIdleTimerLeaseDoesNotOverwriteAChangedAppPolicy() {
    var idleTimerDisabled = false
    let lease = BathroomScanIdleTimerLease(read: { idleTimerDisabled }, write: { idleTimerDisabled = $0 })
    lease.acquire()
    lease.release()
    idleTimerDisabled = true
    lease.release()
    XCTAssertTrue(idleTimerDisabled)
    lease.acquire()
    lease.release()
    XCTAssertTrue(idleTimerDisabled)
  }

  func testCaptureControlsRemainReachableOnNarrowAndShortScreens() throws {
    try assertCaptureLayout(category: .large)
  }

  func testCaptureInstructionsScrollAndControlsRemainReachableAtLargestText() throws {
    try assertCaptureLayout(category: .accessibilityExtraExtraExtraLarge)
  }

  private func assertCaptureLayout(category: UIContentSizeCategory) throws {
    guard #available(iOS 17.0, *) else { throw XCTSkip("The layout harness uses iOS 17 trait overrides.") }
    for size in [CGSize(width: 288, height: 544), CGSize(width: 780, height: 250), CGSize(width: 288, height: 224)] {
      let camera = UIView()
      let status = UILabel()
      let cancel = UIButton(type: .system)
      let finish = UIButton(type: .system)
      let layout = BathroomScanCaptureLayout(camera: camera, status: status, cancelButton: cancel, finishButton: finish)
      layout.backgroundColor = .white
      camera.backgroundColor = .darkGray
      layout.overrideUserInterfaceStyle = .light
      let window = UIWindow(frame: CGRect(origin: .zero, size: size))
      let host = UIViewController()
      window.rootViewController = host
      window.traitOverrides.preferredContentSizeCategory = category
      host.view.addSubview(layout)
      window.isHidden = false
      defer { window.isHidden = true; window.rootViewController = nil }
      layout.frame = CGRect(origin: .zero, size: size)
      window.layoutIfNeeded()
      layout.layoutIfNeeded()
      XCTAssertEqual(layout.traitCollection.preferredContentSizeCategory, category)
      XCTAssertEqual(status.traitCollection.preferredContentSizeCategory, category)
      let traits = UITraitCollection(preferredContentSizeCategory: category)
      for (label, style) in [(layout.heading, UIFont.TextStyle.title2), (status, .body),
        (cancel.titleLabel!, .headline), (finish.titleLabel!, .headline)] {
        XCTAssertTrue(label.adjustsFontForContentSizeCategory)
        label.font = .preferredFont(forTextStyle: style, compatibleWith: traits)
      }
      layout.layoutIfNeeded()
      let expectedFont = UIFont.preferredFont(forTextStyle: .body,
        compatibleWith: traits)
      XCTAssertEqual(status.font.pointSize, expectedFont.pointSize, accuracy: 0.01)
      XCTAssertFalse(layout.hasAmbiguousLayout)
      let cancelFrame = cancel.convert(cancel.bounds, to: layout)
      let finishFrame = finish.convert(finish.bounds, to: layout)
      for (button, frame) in [(cancel, cancelFrame), (finish, finishFrame)] {
        XCTAssertGreaterThanOrEqual(frame.minX, 0)
        XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.1)
        XCTAssertGreaterThanOrEqual(frame.minY, 0)
        XCTAssertLessThanOrEqual(frame.maxY, size.height + 0.1)
        XCTAssertGreaterThanOrEqual(frame.height, 52)
        let hit = layout.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil)
        XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true)
      }
      XCTAssertLessThanOrEqual(cancelFrame.maxY, finishFrame.minY)
      XCTAssertLessThanOrEqual(layout.captureScroll.frame.maxY, cancelFrame.minY)
      XCTAssertGreaterThan(layout.captureScroll.bounds.height, 0)
      XCTAssertGreaterThanOrEqual(camera.bounds.height, 80)
      let requiredStatusHeight = status.sizeThatFits(CGSize(width: status.bounds.width, height: .greatestFiniteMagnitude)).height
      XCTAssertGreaterThanOrEqual(status.bounds.height + 0.1, requiredStatusHeight)
      let scroll = layout.captureScroll
      scroll.scrollRectToVisible(camera.convert(camera.bounds, to: scroll), animated: false)
      XCTAssertTrue(scroll.bounds.intersects(camera.convert(camera.bounds, to: scroll)))
      XCTAssertGreaterThanOrEqual(scroll.contentSize.height, scroll.bounds.height)
      let preview = UIGraphicsImageRenderer(size: size).image { context in
        layout.layer.render(in: context.cgContext)
      }
      let attachment = XCTAttachment(image: preview)
      attachment.name = "Native capture layout \(Int(size.width))x\(Int(size.height)) \(category.rawValue) - synthetic camera"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }
}
