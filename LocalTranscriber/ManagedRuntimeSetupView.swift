import SwiftUI
import AppKit

struct RootView: View {
    @StateObject private var settings = SettingsStore.shared
    @ObservedObject var setup: ManagedRuntimeSetupModel
    @State private var allowIncompleteManagedRuntime = false

    private var installDirectory: URL {
        settings.resolvedRuntimePaths.runtimeDirectoryURL.deletingLastPathComponent()
    }

    private var showsSetup: Bool {
        guard settings.runtimeMode == .managed else { return false }
        if setup.requiresUserStart { return true }
        if setup.state.status.isReady { return false }
        return !allowIncompleteManagedRuntime
    }

    var body: some View {
        Group {
            if showsSetup {
                ManagedRuntimeSetupView(
                    settings: settings,
                    setup: setup,
                    onStart: {
                        setup.acknowledgeCompletion()
                        allowIncompleteManagedRuntime = false
                    },
                    onContinueWithoutModel: {
                        setup.acknowledgeCompletion()
                        allowIncompleteManagedRuntime = true
                    }
                )
                .frame(minWidth: 900, minHeight: 650)
            } else {
                ContentView(
                    managedRuntime: setup,
                    showManagedSetup: {
                        allowIncompleteManagedRuntime = false
                        setup.inspect(installDirectory: installDirectory, mode: settings.runtimeMode)
                    }
                )
                .frame(minWidth: 900, minHeight: 650)
            }
        }
        .task(id: settings.runtimeMode.rawValue + "|" + settings.managedInstallPath) {
            allowIncompleteManagedRuntime = false
            setup.inspect(installDirectory: installDirectory, mode: settings.runtimeMode)
        }
    }
}

struct ManagedRuntimeSetupView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var setup: ManagedRuntimeSetupModel
    let onStart: () -> Void
    let onContinueWithoutModel: () -> Void

    @State private var showAdvanced = false
    @State private var showDetails = false
    @Environment(\.openSettings) private var openSettings

    private var installDirectory: URL {
        settings.resolvedRuntimePaths.runtimeDirectoryURL.deletingLastPathComponent()
    }

    private var runtimeBytes: Int64 { setup.manifest?.runtime.downloadSizeBytes ?? 398_146_982 }
    private var modelBytes: Int64 { setup.manifest?.model.downloadSizeBytesApproximate ?? 1_610_612_736 }
    private var requiredDownloadBytes: Int64 {
        (setup.state.status.runtime == .ready ? 0 : runtimeBytes) +
        (setup.state.status.model == .ready ? 0 : modelBytes)
    }
    private var requiredDiskBytes: Int64 {
        (setup.state.status.runtime == .ready ? 0 : runtimeBytes * 4) +
        (setup.state.status.model == .ready ? 0 : modelBytes + 536_870_912)
    }

    var body: some View {
        VStack(spacing: 0) {
            setupHeader
            Divider()
            Group {
                switch setup.state.phase {
                case .checking, .idle:
                    checkingView
                case .needsInstallation:
                    planView
                case .downloadingRuntime, .verifyingRuntime, .installingRuntime,
                     .downloadingModel, .installingModel, .validating:
                    progressView
                case .complete:
                    completionView
                case .cancelled:
                    cancelledView
                case .failed:
                    failureView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            privacyFooter
        }
        .font(AppTheme.bodyFont)
        .controlSize(.small)
        .background(AppTheme.surface)
        .preferredColorScheme(.dark)
        .tint(AppTheme.accent)
    }

    private var setupHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("LocalTranscriber").font(AppTheme.titleFont)
                Text(settings.tr("Konfiguracja środowiska zarządzanego", "Managed runtime setup"))
                    .font(AppTheme.secondaryFont)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
                    .frame(width: AppTheme.settingsHitTarget, height: AppTheme.settingsHitTarget)
            }
            .buttonStyle(.borderless)
            .help(settings.tr("Ustawienia", "Settings"))
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
        .background(AppTheme.header)
    }

    private var checkingView: some View {
        VStack(spacing: AppTheme.spacing) {
            ProgressView().controlSize(.regular)
            Text(settings.tr("Sprawdzanie środowiska lokalnego…", "Checking the local environment…"))
                .font(AppTheme.titleFont)
            Text(settings.tr("Nie jest wykonywane żadne pobieranie.", "No network download is taking place."))
                .foregroundStyle(.secondary)
        }
    }

    private var planView: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(settings.tr("Wymagane są dodatkowe składniki", "Additional components are required"))
                    .font(.system(size: 22, weight: .semibold))
                Text(settings.tr(
                    "LocalTranscriber działa całkowicie na tym Macu. Do transkrypcji potrzebuje lokalnego Runtime i modelu Whisper.",
                    "LocalTranscriber runs entirely on your Mac. Transcription requires a local Runtime and Whisper model."
                ))
                .foregroundStyle(.secondary)
            }

            componentPlanCard(
                title: "Runtime \(setup.manifest?.runtimeVersion ?? "1.0.0")",
                subtitle: settings.tr("Python, FFmpeg, MLX i wymagane biblioteki", "Python, FFmpeg, MLX and required libraries"),
                source: "GitHub Release",
                bytes: runtimeBytes,
                state: setup.state.status.runtime
            )
            componentPlanCard(
                title: "Whisper Large v3 Turbo",
                subtitle: settings.tr("Lokalny model rozpoznawania mowy", "Local speech recognition model"),
                source: "Hugging Face",
                bytes: modelBytes,
                state: setup.state.status.model
            )

            installationLocationRow

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(settings.tr("Wymagane pobieranie", "Required download"))
                    Text(ByteCountFormatter.string(fromByteCount: requiredDownloadBytes, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(settings.tr("Szacowane wymagane miejsce", "Estimated required disk space"))
                    Text(ByteCountFormatter.string(fromByteCount: requiredDiskBytes, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
            }

            DisclosureGroup(settings.tr("Opcje zaawansowane", "Advanced options"), isExpanded: $showAdvanced) {
                HStack {
                    Text(settings.tr("Możesz zainstalować sam Runtime. Transkrypcja pozostanie niedostępna do czasu instalacji modelu.", "You can install Runtime only. Transcription remains unavailable until a model is installed."))
                        .font(AppTheme.secondaryFont)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(settings.tr("Zainstaluj tylko Runtime", "Install Runtime only")) {
                        setup.start(.runtimeOnly, installDirectory: installDirectory)
                    }
                    .disabled(setup.state.status.runtime == .ready)
                }
                .padding(.top, 8)
            }

            HStack {
                Button(settings.tr("Anuluj", "Cancel")) { setup.cancel() }
                Spacer()
                Button(primaryInstallTitle) {
                    setup.start(recommendedMode, installDirectory: installDirectory)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(maxWidth: 720)
    }

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(settings.tr("Przygotowywanie LocalTranscriber", "Preparing LocalTranscriber"))
                .font(.system(size: 22, weight: .semibold))
            componentProgressCard(title: "Runtime \(setup.manifest?.runtimeVersion ?? "1.0.0")", component: "runtime")
            componentProgressCard(title: "Whisper Large v3 Turbo", component: "model")

            StudioFlowPanel(title: settings.tr("BIEŻĄCY KROK", "CURRENT STEP")) {
                HStack {
                    if setup.state.phase.isRunning { ProgressView().controlSize(.small) }
                    Text(localizedCurrentMessage)
                    Spacer()
                }
            }

            HStack {
                Spacer()
                Button(settings.tr("Anuluj", "Cancel")) { setup.cancel() }
            }
        }
        .padding(28)
        .frame(maxWidth: 720)
    }

    private var completionView: some View {
        VStack(spacing: 18) {
            Image(systemName: setup.state.status.isReady ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: 44))
                .foregroundStyle(setup.state.status.isReady ? .green : AppTheme.accent)
            Text(setup.state.status.isReady
                 ? settings.tr("LocalTranscriber jest gotowy", "LocalTranscriber is ready")
                 : settings.tr("Runtime jest gotowy", "Runtime is ready"))
                .font(.system(size: 22, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                completionLine("Runtime \(setup.manifest?.runtimeVersion ?? "1.0.0")", ready: setup.state.status.runtime == .ready)
                completionLine("Python \(setup.manifest?.python.version ?? "3.12.14")", ready: setup.state.status.runtime == .ready)
                completionLine("FFmpeg \((setup.manifest?.ffmpeg.version ?? "9.0.1").split(separator: "-").first ?? "9.0.1")", ready: setup.state.status.runtime == .ready)
                completionLine("MLX \(setup.manifest?.pythonPackages["mlx"] ?? "0.32.2")", ready: setup.state.status.runtime == .ready)
                completionLine("Whisper Large v3 Turbo", ready: setup.state.status.model == .ready)
            }
            if setup.state.status.isReady {
                Button(settings.tr("Uruchom LocalTranscriber", "Start LocalTranscriber"), action: onStart)
                    .buttonStyle(.borderedProminent)
            } else {
                Text(settings.tr("Transkrypcja wymaga modelu Whisper. Możesz zainstalować go teraz lub kontynuować do aplikacji.", "Transcription requires the Whisper model. Install it now or continue to the application."))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack {
                    Button(settings.tr("Kontynuuj bez modelu", "Continue without model"), action: onContinueWithoutModel)
                    Button(settings.tr("Zainstaluj model", "Install model")) {
                        setup.start(.modelOnly, installDirectory: installDirectory)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 620)
    }

    private var cancelledView: some View {
        VStack(spacing: AppTheme.spacing) {
            Image(systemName: "xmark.circle").font(.system(size: 38)).foregroundStyle(.secondary)
            Text(settings.tr("Instalacja anulowana", "Setup cancelled")).font(.system(size: 20, weight: .semibold))
            Text(settings.tr("Nie zainstalowano żadnego niekompletnego Runtime. Poprzednie poprawne dane pozostały bez zmian.", "No incomplete Runtime was installed. Previous valid data was left unchanged."))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(settings.tr("Spróbuj ponownie", "Try Again")) {
                setup.inspect(installDirectory: installDirectory, mode: settings.runtimeMode)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: 560)
    }

    private var failureView: some View {
        let error = setup.state.error
        return VStack(spacing: AppTheme.spacing) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 38)).foregroundStyle(.orange)
            Text(error?.title(isPolish: settings.isPolish) ?? settings.tr("Błąd instalacji", "Setup failed"))
                .font(.system(size: 20, weight: .semibold))
            Text(error?.userMessage(isPolish: settings.isPolish) ?? "")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let details = error?.technicalDetails, !details.isEmpty {
                DisclosureGroup(settings.tr("Szczegóły techniczne", "Technical details"), isExpanded: $showDetails) {
                    ScrollView {
                        Text(details).font(AppTheme.monospacedFont).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                    .padding(8)
                    .studioFlowRecessedSurface()
                }
            }
            HStack {
                Button(settings.tr("Otwórz Ustawienia", "Open Settings")) { openSettings() }
                Button(settings.tr("Spróbuj ponownie", "Try Again")) {
                    setup.inspect(installDirectory: installDirectory, mode: settings.runtimeMode)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(maxWidth: 620)
    }

    private var installationLocationRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            StudioFlowSectionTitle(title: settings.tr("LOKALIZACJA INSTALACJI", "INSTALLATION LOCATION"))
            HStack {
                Text(installDirectory.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Spacer()
                Button(settings.tr("Zmień…", "Change…"), action: chooseInstallDirectory)
            }
            .padding(10)
            .studioFlowRecessedSurface()
        }
    }

    private var privacyFooter: some View {
        Text(settings.tr(
            "Runtime jest pobierany wyłącznie z GitHub, model wyłącznie z Hugging Face. Nagrania i transkrypcje nie są wysyłane. Brak analityki i śledzenia.",
            "Runtime is downloaded only from GitHub and the model only from Hugging Face. Audio and transcripts are never uploaded. No analytics or tracking."
        ))
        .font(AppTheme.secondaryFont)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: 42)
        .frame(maxWidth: .infinity)
        .background(AppTheme.header)
    }

    private func componentPlanCard(title: String, subtitle: String, source: String, bytes: Int64, state: ManagedComponentState) -> some View {
        HStack(spacing: 12) {
            Image(systemName: state == .ready ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(state == .ready ? .green : AppTheme.accent)
                .font(.system(size: 22))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(AppTheme.titleFont)
                Text(subtitle).foregroundStyle(.secondary)
                Text(state == .ready ? settings.tr("Zainstalowano", "Installed") : "\(source) • \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                    .font(AppTheme.secondaryFont).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .studioFlowRecessedSurface()
    }

    private func componentProgressCard(title: String, component: String) -> some View {
        let active = setup.state.currentComponent == component
        let ready = component == "runtime" ? setup.state.status.runtime == .ready : setup.state.status.model == .ready
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: ready ? "checkmark.circle.fill" : active ? "arrow.down.circle.fill" : "clock")
                    .foregroundStyle(ready ? .green : active ? AppTheme.accent : .secondary)
                Text(title).font(AppTheme.titleFont)
                Spacer()
                Text(ready ? settings.tr("Gotowe", "Ready") : active ? phaseLabel : settings.tr("Oczekiwanie", "Waiting"))
                    .foregroundStyle(.secondary)
            }
            if active, let fraction = setup.state.progressFraction,
               setup.state.phase == .downloadingRuntime || setup.state.phase == .downloadingModel {
                ProgressView(value: fraction).tint(AppTheme.accent)
                HStack {
                    Text("\(Int(fraction * 100))%").monospacedDigit()
                    Spacer()
                    Text("\(ByteCountFormatter.string(fromByteCount: setup.state.downloadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: setup.state.totalBytes, countStyle: .file))")
                }
                .font(AppTheme.secondaryFont).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .studioFlowRecessedSurface()
    }

    private func completionLine(_ title: String, ready: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ready ? "checkmark" : "minus").foregroundStyle(ready ? .green : .secondary)
            Text(title)
        }
    }

    private var recommendedMode: ManagedInstallerMode {
        if setup.state.status.runtime == .invalid { return .repair }
        if setup.state.status.runtime == .ready && setup.state.status.model != .ready { return .modelOnly }
        return .full
    }

    private var primaryInstallTitle: String {
        if setup.state.status.runtime == .invalid { return settings.tr("Napraw", "Repair") }
        if setup.state.status.runtime == .ready { return settings.tr("Zainstaluj model", "Install Model") }
        return settings.tr("Zainstaluj", "Install")
    }

    private var phaseLabel: String {
        switch setup.state.phase {
        case .downloadingRuntime, .downloadingModel: return settings.tr("Pobieranie…", "Downloading…")
        case .verifyingRuntime: return settings.tr("Weryfikacja…", "Verifying…")
        case .installingRuntime, .installingModel: return settings.tr("Instalacja…", "Installing…")
        case .validating: return settings.tr("Walidacja…", "Validating…")
        default: return settings.tr("Przygotowanie…", "Preparing…")
        }
    }

    private var localizedCurrentMessage: String {
        switch setup.state.phase {
        case .downloadingRuntime: return settings.tr("Pobieranie Runtime z GitHub", "Downloading Runtime from GitHub")
        case .verifyingRuntime: return settings.tr("Sprawdzanie sumy SHA-256", "Verifying SHA-256 checksum")
        case .installingRuntime: return settings.tr("Instalowanie Runtime", "Installing Runtime")
        case .downloadingModel: return settings.tr("Pobieranie modelu z Hugging Face", "Downloading model from Hugging Face")
        case .installingModel: return settings.tr("Instalowanie modelu Whisper", "Installing Whisper model")
        case .validating: return settings.tr("Sprawdzanie kompletnego środowiska", "Validating the complete environment")
        default: return setup.state.currentMessage
        }
    }

    private func chooseInstallDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = settings.tr("Wybierz", "Choose")
        panel.message = settings.tr(
            "Wybierz docelowy katalog LocalTranscriber. Istniejące dane nie zostaną przeniesione ani usunięte.",
            "Choose the LocalTranscriber data directory. Existing data will not be moved or deleted."
        )
        panel.directoryURL = installDirectory.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            settings.managedInstallPath = url.path
            setup.inspect(installDirectory: url, mode: settings.runtimeMode)
        }
    }
}
