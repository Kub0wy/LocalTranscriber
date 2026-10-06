import Foundation

enum ManagedComponentState: String, Codable, Equatable, Sendable {
    case unknown
    case missing
    case invalid
    case ready
}

struct ManagedRuntimeStatus: Equatable, Sendable {
    var runtime: ManagedComponentState = .unknown
    var model: ManagedComponentState = .unknown

    var isReady: Bool { runtime == .ready && model == .ready }
}

enum SetupPhase: String, Equatable, Sendable {
    case idle
    case checking
    case needsInstallation
    case downloadingRuntime
    case verifyingRuntime
    case installingRuntime
    case downloadingModel
    case installingModel
    case validating
    case complete
    case cancelled
    case failed

    var isRunning: Bool {
        switch self {
        case .checking, .downloadingRuntime, .verifyingRuntime, .installingRuntime,
             .downloadingModel, .installingModel, .validating:
            return true
        default:
            return false
        }
    }
}

struct InstallerEvent: Codable, Equatable, Sendable {
    let event: String
    let id: String?
    let title: String?
    let component: String?
    let state: String?
    let bytesDownloaded: Int64?
    let bytesTotal: Int64?
    let code: String?
    let message: String?
    let runtime: Bool?
    let model: Bool?
}

enum InstallerEventParser {
    static func parse(_ line: String) throws -> InstallerEvent {
        guard let data = line.data(using: .utf8) else {
            throw ManagedInstallerServiceError.malformedOutput(line)
        }
        do {
            return try JSONDecoder().decode(InstallerEvent.self, from: data)
        } catch {
            throw ManagedInstallerServiceError.malformedOutput(line)
        }
    }
}

struct ManagedSetupError: Equatable, Sendable {
    let code: String
    let installerMessage: String
    let technicalDetails: String

    func title(isPolish: Bool) -> String {
        switch code {
        case "runtimeDownloadFailed", "modelDownloadFailed":
            return isPolish ? "Błąd sieci" : "Network error"
        case "checksumMismatch":
            return isPolish ? "Błąd integralności" : "Integrity error"
        case "insufficientDiskSpace":
            return isPolish ? "Za mało miejsca" : "Not enough disk space"
        case "runtimeValidationFailed":
            return isPolish ? "Błąd środowiska Runtime" : "Runtime validation failed"
        case "modelValidationFailed", "modelDownloadIncomplete":
            return isPolish ? "Błąd modelu" : "Model validation failed"
        case "cancelled":
            return isPolish ? "Instalacja anulowana" : "Setup cancelled"
        default:
            return isPolish ? "Instalacja nie powiodła się" : "Setup failed"
        }
    }

    func userMessage(isPolish: Bool) -> String {
        switch code {
        case "runtimeDownloadFailed":
            return isPolish ? "Nie udało się pobrać Runtime z GitHub." : "Unable to download Runtime from GitHub."
        case "modelDownloadFailed":
            return isPolish ? "Nie udało się pobrać modelu z Hugging Face." : "Unable to download the model from Hugging Face."
        case "checksumMismatch":
            return isPolish ? "Pobrany Runtime nie przeszedł weryfikacji i nie został zainstalowany." : "The downloaded Runtime failed verification and was not installed."
        case "insufficientDiskSpace":
            return isPolish ? "W wybranej lokalizacji nie ma wystarczającej ilości wolnego miejsca." : "The selected location does not have enough free disk space."
        case "runtimeValidationFailed":
            return isPolish ? "Runtime jest niekompletny lub nie przeszedł walidacji." : "Runtime is incomplete or did not pass validation."
        case "modelValidationFailed", "modelDownloadIncomplete":
            return isPolish ? "Model Whisper jest niekompletny lub nie można go załadować." : "The Whisper model is incomplete or could not be loaded."
        case "cancelled":
            return isPolish ? "Nie zainstalowano żadnego niekompletnego komponentu." : "No incomplete component was installed."
        default:
            return installerMessage
        }
    }
}

struct ManagedSetupState: Equatable, Sendable {
    var phase: SetupPhase = .idle
    var status = ManagedRuntimeStatus()
    var currentComponent: String?
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var currentMessage = ""
    var error: ManagedSetupError?

    var progressFraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
    }

    mutating func resetForCheck() {
        phase = .checking
        currentComponent = nil
        downloadedBytes = 0
        totalBytes = 0
        currentMessage = "Checking managed components"
        error = nil
    }

    mutating func resetForInstallation() {
        phase = .checking
        downloadedBytes = 0
        totalBytes = 0
        currentMessage = "Preparing LocalTranscriber"
        error = nil
    }

    mutating func apply(_ event: InstallerEvent) {
        switch event.event {
        case "phase":
            currentMessage = event.title ?? event.id ?? currentMessage
            if event.id == "preflight" { phase = .checking }
        case "status":
            guard let component = event.component,
                  let raw = event.state,
                  let componentState = ManagedComponentState(rawValue: raw) else { return }
            if component == "runtime" { status.runtime = componentState }
            if component == "model" { status.model = componentState }
        case "downloadStart":
            currentComponent = event.component
            downloadedBytes = 0
            totalBytes = event.bytesTotal ?? 0
            if event.component == "runtime" {
                phase = .downloadingRuntime
                currentMessage = "Downloading runtime from GitHub"
            } else {
                phase = .downloadingModel
                currentMessage = "Downloading model from Hugging Face"
            }
        case "downloadProgress":
            currentComponent = event.component
            downloadedBytes = event.bytesDownloaded ?? downloadedBytes
            totalBytes = event.bytesTotal ?? totalBytes
        case "verifyStart":
            phase = .verifyingRuntime
            currentMessage = "Verifying Runtime checksum"
        case "installStart":
            currentComponent = event.component
            if event.component == "runtime" {
                phase = .installingRuntime
                currentMessage = "Installing Runtime"
            } else {
                phase = .installingModel
                currentMessage = "Installing Whisper model"
            }
        case "installComplete":
            if event.component == "runtime" { status.runtime = .ready }
            if event.component == "model" { status.model = .ready }
        case "validationStart":
            phase = .validating
            currentMessage = "Validating managed environment"
        case "complete":
            status.runtime = event.runtime == true ? .ready : status.runtime
            status.model = event.model == true ? .ready : status.model
            phase = .complete
            currentMessage = status.isReady ? "LocalTranscriber is ready" : "Runtime installation is complete"
        case "error":
            let code = event.code ?? "installationFailed"
            error = ManagedSetupError(code: code, installerMessage: event.message ?? "Setup failed.", technicalDetails: "")
            phase = code == "cancelled" ? .cancelled : .failed
        default:
            break
        }
    }
}

enum ManagedSetupPolicy {
    static func shouldInspect(mode: RuntimeMode) -> Bool { mode == .managed }
}

struct ManagedRuntimeManifest: Decodable, Sendable {
    struct RuntimeInfo: Decodable, Sendable {
        let downloadSizeBytes: Int64
    }
    struct PythonInfo: Decodable, Sendable {
        let version: String
    }
    struct FFmpegInfo: Decodable, Sendable {
        let version: String
    }
    struct ModelInfo: Decodable, Sendable {
        let repo: String
        let revision: String
        let downloadSizeBytesApproximate: Int64
    }

    let runtimeVersion: String
    let runtime: RuntimeInfo
    let python: PythonInfo
    let ffmpeg: FFmpegInfo
    let pythonPackages: [String: String]
    let model: ModelInfo
}

struct ManagedInstallerResources: Sendable {
    let rootURL: URL
    let installerURL: URL
    let manifestURL: URL

    static func bundled(in bundle: Bundle = .main) throws -> ManagedInstallerResources {
        guard let resources = bundle.resourceURL else {
            throw ManagedInstallerServiceError.resourcesMissing
        }
        let root = resources.appendingPathComponent("ManagedInstaller", isDirectory: true)
        let installer = root.appendingPathComponent("installer/install.sh")
        let manifest = root.appendingPathComponent("runtime-manifest.json")
        guard FileManager.default.fileExists(atPath: installer.path),
              FileManager.default.fileExists(atPath: manifest.path) else {
            throw ManagedInstallerServiceError.resourcesMissing
        }
        return ManagedInstallerResources(rootURL: root, installerURL: installer, manifestURL: manifest)
    }

    func loadManifest() throws -> ManagedRuntimeManifest {
        try JSONDecoder().decode(ManagedRuntimeManifest.self, from: Data(contentsOf: manifestURL))
    }
}

enum ManagedInstallerMode: Sendable {
    case full
    case runtimeOnly
    case modelOnly
    case repair
    case validate
    case quickValidate
    case reinstallRuntime

    var arguments: [String] {
        switch self {
        case .full: return ["--yes"]
        case .runtimeOnly: return ["--runtime-only", "--yes"]
        case .modelOnly: return ["--model-only", "--yes"]
        case .repair: return ["--repair", "--yes"]
        case .validate: return ["--validate"]
        case .quickValidate: return ["--quick-validate"]
        case .reinstallRuntime: return ["--reinstall-runtime", "--yes"]
        }
    }
}

enum ManagedInstallerServiceError: Error, Equatable {
    case resourcesMissing
    case malformedOutput(String)
    case launchFailed(String)
    case invocationFailed(code: String, message: String, details: String, status: Int32)
}

final class ManagedRuntimeService: @unchecked Sendable {
    private let resourcesProvider: @Sendable () throws -> ManagedInstallerResources
    private let processLock = NSLock()
    private var runningProcess: Process?

    init(resourcesProvider: @escaping @Sendable () throws -> ManagedInstallerResources = { try .bundled() }) {
        self.resourcesProvider = resourcesProvider
    }

    func loadManifest() throws -> ManagedRuntimeManifest {
        try resourcesProvider().loadManifest()
    }

    func run(
        mode: ManagedInstallerMode,
        installDirectory: URL,
        onEvent: @escaping @MainActor (InstallerEvent) -> Void
    ) async throws {
        try await withTaskCancellationHandler {
            let resources = try resourcesProvider()
            let process = Process()
            let output = Pipe()
            let diagnosticURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("LocalTranscriber-installer-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: diagnosticURL.path, contents: nil)
            let diagnosticHandle = try FileHandle(forWritingTo: diagnosticURL)
            defer {
                try? diagnosticHandle.close()
                try? FileManager.default.removeItem(at: diagnosticURL)
            }

            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [resources.installerURL.path, "--machine-readable", "--install-dir", installDirectory.path] + mode.arguments
            process.currentDirectoryURL = resources.rootURL
            process.standardOutput = output
            process.standardError = diagnosticHandle

            do {
                try process.run()
            } catch {
                throw ManagedInstallerServiceError.launchFailed(error.localizedDescription)
            }
            setRunningProcess(process)
            defer { setRunningProcess(nil) }

            var installerError: InstallerEvent?
            do {
                for try await line in output.fileHandleForReading.bytes.lines {
                    guard !line.isEmpty else { continue }
                    let event = try InstallerEventParser.parse(line)
                    if event.event == "error" { installerError = event }
                    await onEvent(event)
                }
            } catch {
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
                throw error
            }

            process.waitUntilExit()
            try? diagnosticHandle.synchronize()
            let details = (try? String(contentsOf: diagnosticURL, encoding: .utf8)) ?? ""
            if Task.isCancelled || process.terminationStatus == 130 {
                throw CancellationError()
            }
            guard process.terminationStatus == 0 else {
                throw ManagedInstallerServiceError.invocationFailed(
                    code: installerError?.code ?? "installationFailed",
                    message: installerError?.message ?? "Installer exited with status \(process.terminationStatus).",
                    details: details,
                    status: process.terminationStatus
                )
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        processLock.lock()
        let process = runningProcess
        processLock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    private func setRunningProcess(_ process: Process?) {
        processLock.lock()
        runningProcess = process
        processLock.unlock()
    }
}

@MainActor
final class ManagedRuntimeSetupModel: ObservableObject {
    @Published private(set) var state = ManagedSetupState()
    @Published private(set) var manifest: ManagedRuntimeManifest?
    @Published private(set) var requiresUserStart = false

    private let service: ManagedRuntimeService
    private var operation: Task<Void, Never>?

    init(service: ManagedRuntimeService = ManagedRuntimeService()) {
        self.service = service
        manifest = try? service.loadManifest()
    }

    func inspect(installDirectory: URL, mode: RuntimeMode) {
        guard ManagedSetupPolicy.shouldInspect(mode: mode) else {
            operation?.cancel()
            state = ManagedSetupState(phase: .idle)
            requiresUserStart = false
            return
        }
        operation?.cancel()
        state.resetForCheck()
        requiresUserStart = false
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await service.run(mode: .quickValidate, installDirectory: installDirectory) { [weak self] event in
                    self?.receive(event)
                }
                state.phase = .complete
            } catch is CancellationError {
                if !Task.isCancelled { state.phase = .cancelled }
            } catch let ManagedInstallerServiceError.invocationFailed(code, message, details, _) {
                if code == "runtimeValidationFailed" || code == "modelValidationFailed" {
                    state.error = nil
                    state.phase = .needsInstallation
                    state.currentMessage = state.status.runtime == .invalid ? "Managed Runtime needs repair" : "Additional components are required"
                } else {
                    state.error = ManagedSetupError(code: code, installerMessage: message, technicalDetails: details)
                    state.phase = .failed
                }
            } catch {
                state.error = ManagedSetupError(code: "installerUnavailable", installerMessage: error.localizedDescription, technicalDetails: String(describing: error))
                state.phase = .failed
            }
        }
    }

    func start(_ mode: ManagedInstallerMode, installDirectory: URL) {
        operation?.cancel()
        state.resetForInstallation()
        requiresUserStart = false
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await service.run(mode: mode, installDirectory: installDirectory) { [weak self] event in
                    self?.receive(event, requireAcknowledgementOnCompletion: true)
                }
            } catch is CancellationError {
                state.error = ManagedSetupError(code: "cancelled", installerMessage: "Setup was cancelled.", technicalDetails: "")
                state.phase = .cancelled
            } catch let ManagedInstallerServiceError.invocationFailed(code, message, details, _) {
                state.error = ManagedSetupError(code: code, installerMessage: message, technicalDetails: details)
                state.phase = code == "cancelled" ? .cancelled : .failed
            } catch {
                state.error = ManagedSetupError(code: "installerUnavailable", installerMessage: error.localizedDescription, technicalDetails: String(describing: error))
                state.phase = .failed
            }
        }
    }

    func cancel() {
        service.cancel()
        operation?.cancel()
        state.error = ManagedSetupError(
            code: "cancelled",
            installerMessage: "Setup was cancelled.",
            technicalDetails: ""
        )
        state.phase = .cancelled
    }

    func acknowledgeCompletion() {
        requiresUserStart = false
    }

    func receive(_ event: InstallerEvent, requireAcknowledgementOnCompletion: Bool = false) {
        if requireAcknowledgementOnCompletion && event.event == "complete" {
            requiresUserStart = true
        }
        state.apply(event)
    }
}
