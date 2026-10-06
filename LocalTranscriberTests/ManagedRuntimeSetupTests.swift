import XCTest
@testable import LocalTranscriber

final class ManagedRuntimeSetupTests: XCTestCase {
    func testInstallerJSONParsing() throws {
        let event = try InstallerEventParser.parse(#"{"event":"downloadProgress","component":"runtime","bytesDownloaded":123,"bytesTotal":456}"#)
        XCTAssertEqual(event.event, "downloadProgress")
        XCTAssertEqual(event.component, "runtime")
        XCTAssertEqual(event.bytesDownloaded, 123)
        XCTAssertEqual(event.bytesTotal, 456)
    }

    func testMalformedInstallerJSONIsRejected() {
        XCTAssertThrowsError(try InstallerEventParser.parse("not-json")) { error in
            XCTAssertEqual(error as? ManagedInstallerServiceError, .malformedOutput("not-json"))
        }
    }

    func testRuntimeDownloadPhaseAndRealProgress() throws {
        var state = ManagedSetupState()
        state.apply(try event(#"{"event":"downloadStart","component":"runtime","bytesTotal":400}"#))
        state.apply(try event(#"{"event":"downloadProgress","component":"runtime","bytesDownloaded":100,"bytesTotal":400}"#))
        XCTAssertEqual(state.phase, .downloadingRuntime)
        XCTAssertEqual(state.currentComponent, "runtime")
        XCTAssertEqual(state.progressFraction, 0.25)
    }

    func testMissingRuntimeAndModelStates() throws {
        var state = ManagedSetupState()
        state.apply(try event(#"{"event":"status","component":"runtime","state":"missing"}"#))
        state.apply(try event(#"{"event":"status","component":"model","state":"missing"}"#))
        XCTAssertEqual(state.status.runtime, .missing)
        XCTAssertEqual(state.status.model, .missing)
        XCTAssertFalse(state.status.isReady)
    }

    func testCompletedRuntimeWithMissingModel() throws {
        var state = ManagedSetupState()
        state.apply(try event(#"{"event":"complete","runtime":true,"model":false}"#))
        XCTAssertEqual(state.phase, .complete)
        XCTAssertEqual(state.status.runtime, .ready)
        XCTAssertNotEqual(state.status.model, .ready)
    }

    func testCompleteEnvironmentTransition() throws {
        var state = ManagedSetupState()
        state.apply(try event(#"{"event":"installComplete","component":"runtime"}"#))
        state.apply(try event(#"{"event":"installComplete","component":"model"}"#))
        state.apply(try event(#"{"event":"validationStart"}"#))
        XCTAssertEqual(state.phase, .validating)
        state.apply(try event(#"{"event":"complete","runtime":true,"model":true}"#))
        XCTAssertEqual(state.phase, .complete)
        XCTAssertTrue(state.status.isReady)
    }

    func testInstallerErrorMapping() throws {
        var state = ManagedSetupState()
        state.apply(try event(#"{"event":"error","code":"checksumMismatch","message":"bad checksum"}"#))
        XCTAssertEqual(state.phase, .failed)
        XCTAssertEqual(state.error?.title(isPolish: false), "Integrity error")
        XCTAssertTrue(state.error?.userMessage(isPolish: false).contains("verification") == true)
    }

    func testCustomModeBypassesManagedInspection() {
        XCTAssertFalse(ManagedSetupPolicy.shouldInspect(mode: .custom))
        XCTAssertTrue(ManagedSetupPolicy.shouldInspect(mode: .managed))
    }

    func testLaunchInspectionUsesFastNonInteractiveValidation() {
        XCTAssertEqual(ManagedInstallerMode.quickValidate.arguments, ["--quick-validate"])
        XCTAssertFalse(ManagedInstallerMode.quickValidate.arguments.contains("--yes"))
    }

    @MainActor
    func testSuccessfulInstallRequiresExplicitStartAcknowledgement() throws {
        let model = ManagedRuntimeSetupModel()
        model.receive(
            try event(#"{"event":"complete","runtime":true,"model":true}"#),
            requireAcknowledgementOnCompletion: true
        )

        XCTAssertEqual(model.state.phase, .complete)
        XCTAssertTrue(model.requiresUserStart)
        model.acknowledgeCompletion()
        XCTAssertFalse(model.requiresUserStart)
    }

    @MainActor
    func testCancellationImmediatelyPublishesSafeCancelledState() {
        let model = ManagedRuntimeSetupModel()
        model.cancel()

        XCTAssertEqual(model.state.phase, .cancelled)
        XCTAssertEqual(model.state.error?.code, "cancelled")
        XCTAssertTrue(model.state.error?.userMessage(isPolish: false).contains("No incomplete component") == true)
    }

    private func event(_ json: String) throws -> InstallerEvent {
        try InstallerEventParser.parse(json)
    }
}
