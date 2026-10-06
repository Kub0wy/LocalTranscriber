import XCTest
import AppKit
@testable import LocalTranscriber

@MainActor
final class RuntimeConfigurationTests: XCTestCase {
    private let support = URL(fileURLWithPath: "/tmp/Application Support", isDirectory: true)

    func testFreshInstallDefaultsToEnglish() {
        XCTAssertEqual(SettingsStore.defaultInterfaceLanguage, "en")
    }

    func testManagedRuntimeUsesApplicationSupportHierarchy() {
        let paths = RuntimePathResolver(applicationSupportDirectory: support).resolve(
            RuntimeConfiguration(mode: .managed, customPythonPath: "", customFFmpegPath: "", customModelPath: "")
        )

        XCTAssertEqual(paths.runtimeDirectoryURL.path, "/tmp/Application Support/LocalTranscriber/Runtime")
        XCTAssertEqual(paths.pythonExecutableURL.path, "/tmp/Application Support/LocalTranscriber/Runtime/Environment/bin/python3")
        XCTAssertEqual(paths.ffmpegExecutableURL.path, "/tmp/Application Support/LocalTranscriber/Runtime/FFmpeg/ffmpeg")
        XCTAssertEqual(paths.ffprobeExecutableURL.path, "/tmp/Application Support/LocalTranscriber/Runtime/FFmpeg/ffprobe")
        XCTAssertEqual(paths.modelDirectoryURL.path, "/tmp/Application Support/LocalTranscriber/Models")
    }

    func testManagedRuntimeUsesRememberedCustomInstallLocation() {
        let paths = RuntimePathResolver(applicationSupportDirectory: support).resolve(
            RuntimeConfiguration(
                mode: .managed,
                customPythonPath: "/custom/python",
                customFFmpegPath: "/custom/ffmpeg",
                customModelPath: "/custom/models",
                managedInstallPath: "/Volumes/External SSD/LocalTranscriber"
            )
        )

        XCTAssertEqual(paths.runtimeDirectoryURL.path, "/Volumes/External SSD/LocalTranscriber/Runtime")
        XCTAssertEqual(paths.modelDirectoryURL.path, "/Volumes/External SSD/LocalTranscriber/Models")
    }

    func testCustomRuntimeAllowsIndependentOverrides() {
        let paths = RuntimePathResolver(applicationSupportDirectory: support).resolve(
            RuntimeConfiguration(
                mode: .custom,
                customPythonPath: "/custom/python",
                customFFmpegPath: "",
                customModelPath: "/custom/models"
            )
        )

        XCTAssertEqual(paths.pythonExecutableURL.path, "/custom/python")
        XCTAssertEqual(paths.ffmpegExecutableURL.path, "/tmp/Application Support/LocalTranscriber/Runtime/FFmpeg/ffmpeg")
        XCTAssertEqual(paths.modelDirectoryURL.path, "/custom/models")
    }

    func testManagedModeIgnoresStoredCustomPaths() {
        let paths = RuntimePathResolver(applicationSupportDirectory: support).resolve(
            RuntimeConfiguration(
                mode: .managed,
                customPythonPath: "/custom/python",
                customFFmpegPath: "/custom/ffmpeg",
                customModelPath: "/custom/models"
            )
        )

        XCTAssertEqual(paths.pythonExecutableURL.path, "/tmp/Application Support/LocalTranscriber/Runtime/Environment/bin/python3")
        XCTAssertEqual(paths.ffmpegExecutableURL.path, "/tmp/Application Support/LocalTranscriber/Runtime/FFmpeg/ffmpeg")
        XCTAssertEqual(paths.modelDirectoryURL.path, "/tmp/Application Support/LocalTranscriber/Models")
    }

    func testMissingRuntimeErrorDoesNotExposeConfiguredPath() {
        let paths = RuntimePathResolver(applicationSupportDirectory: support).resolve(
            RuntimeConfiguration(mode: .managed, customPythonPath: "", customFFmpegPath: "", customModelPath: "")
        )

        XCTAssertThrowsError(try RuntimeValidator().validateExecutables(paths)) { error in
            let description = error.localizedDescription
            XCTAssertTrue(description.contains("Settings") || description.contains("Ustawienia"))
            XCTAssertFalse(description.contains(paths.pythonExecutableURL.path))
        }
    }

    func testDefaultAdvancedConfigKeepsPreviousTextDisabled() {
        XCTAssertTrue(SettingsStore.defaultTranscriptionConfig.contains("\"condition_on_previous_text\": false"))
    }

    func testTXTAndSRTExportsFilterNoiseOnlySegments() {
        let result = WorkerResult(
            text: "Useful speech",
            segments: [
                Segment(start: 0, end: 1, text: "..."),
                Segment(start: 1, end: 2, text: "Useful speech")
            ]
        )

        let txt = txtContent(result, timestamps: true, title: "Sample")
        let srt = srtContent(result)
        XCTAssertFalse(txt.contains("] ..."))
        XCTAssertFalse(srt.contains("\n...\n"))
        XCTAssertTrue(txt.contains("Useful speech"))
        XCTAssertTrue(srt.contains("Useful speech"))
    }

    func testPDFExportCreatesDocumentWithProductMetadata() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: destination) }

        try writePDF(title: "Sample", text: "Transcript", to: destination, polishInterface: false)
        let data = try Data(contentsOf: destination)
        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
        XCTAssertTrue(data.count > 500)
    }

    func testBuyMeACoffeeLinkIsCentralizedAndSecure() {
        let url = AppLinks.buyMeACoffeeURL
        XCTAssertEqual(url?.absoluteString, "https://buymeacoffee.com/jakubrolkab")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "buymeacoffee.com")
    }

    func testStudioFlowLinkIsCentralizedAndSecure() {
        let url = AppLinks.studioFlowURL
        XCTAssertEqual(url?.absoluteString, "https://studioflow.media/")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "studioflow.media")
    }

    func testBuyMeACoffeeBrandColorIsAppearanceIndependent() throws {
        let color = try XCTUnwrap(NSColor(AppColors.buyMeACoffeeYellow).usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 0.8667, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 0.0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 1.0, accuracy: 0.001)
    }
}
