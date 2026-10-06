import SwiftUI
import AppKit

struct SettingsView: View {
    @StateObject private var s = SettingsStore.shared
    @ObservedObject var managedRuntime: ManagedRuntimeSetupModel
    @State private var configStatus = ""
    @State private var showReinstallConfirmation = false

    private var managedInstallDirectory: URL {
        s.resolvedRuntimePaths.runtimeDirectoryURL.deletingLastPathComponent()
    }

    var body: some View {
        Form {
            Section {
                Picker(s.tr("Język", "Language"), selection: $s.interfaceLanguage) {
                    Text("Polski").tag("pl")
                    Text("English").tag("en")
                }
                .pickerStyle(.segmented)
                Text(s.tr("Angielski jest językiem domyślnym dla nowych instalacji. Zmiana działa od razu w całej aplikacji.", "English is the default for new installations. Changes apply immediately throughout the app."))
                    .font(AppTheme.secondaryFont).foregroundStyle(.secondary)
            } header: {
                StudioFlowSectionTitle(title: s.tr("OGÓLNE", "GENERAL"))
            }

            Section {
                Picker(s.tr("Tryb środowiska", "Runtime Mode"), selection: $s.runtimeMode) {
                    Text(s.tr("Automatyczny", "Automatic")).tag(RuntimeMode.managed)
                    Text(s.tr("Własny", "Custom")).tag(RuntimeMode.custom)
                }
                .pickerStyle(.segmented)

                if s.runtimeMode == .managed {
                    managedStatusRow("Runtime \(managedRuntime.manifest?.runtimeVersion ?? "1.0.0")", state: managedRuntime.state.status.runtime)
                    managedStatusRow(s.tr("Python", "Python"), state: managedRuntime.state.status.runtime)
                    managedStatusRow("FFmpeg", state: managedRuntime.state.status.runtime)
                    managedStatusRow(s.tr("Model Whisper", "Whisper model"), state: managedRuntime.state.status.model)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(s.tr("Lokalizacja instalacji", "Installation location"))
                            Spacer()
                            Button(s.tr("Zmień…", "Change…"), action: chooseManagedInstallDirectory)
                        }
                        Text(managedInstallDirectory.path)
                            .font(AppTheme.secondaryFont).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Text(s.tr(
                            "Zmiana lokalizacji nie przenosi ani nie usuwa istniejących danych. Składniki trzeba zainstalować w nowym miejscu.",
                            "Changing the location does not move or delete existing data. Components must be installed in the new location."
                        ))
                        .font(AppTheme.secondaryFont).foregroundStyle(.secondary)
                    }

                    HStack {
                        Button(s.tr("Sprawdź", "Validate")) {
                            managedRuntime.inspect(installDirectory: managedInstallDirectory, mode: .managed)
                        }
                        Button(s.tr("Napraw", "Repair")) {
                            managedRuntime.start(.repair, installDirectory: managedInstallDirectory)
                        }
                        .disabled(managedRuntime.state.phase.isRunning)
                        Button(s.tr("Zainstaluj model", "Install Model")) {
                            managedRuntime.start(.modelOnly, installDirectory: managedInstallDirectory)
                        }
                        .disabled(managedRuntime.state.status.runtime != .ready || managedRuntime.state.phase.isRunning)
                        Button(s.tr("Przeinstaluj Runtime", "Reinstall Runtime")) {
                            showReinstallConfirmation = true
                        }
                        .disabled(managedRuntime.state.phase.isRunning)
                    }
                    if managedRuntime.state.phase.isRunning {
                        HStack {
                            ProgressView(value: managedRuntime.state.progressFraction)
                            Text(managedRuntime.state.currentMessage).foregroundStyle(.secondary)
                            Button(s.tr("Anuluj", "Cancel")) { managedRuntime.cancel() }
                        }
                    }
                } else {
                    pathRow(s.tr("Python", "Python"), text: $s.pythonPath, automaticURL: RuntimePathResolver().resolve(RuntimeConfiguration(mode: .managed, customPythonPath: "", customFFmpegPath: "", customModelPath: "")).pythonExecutableURL, chooseDirectory: false)
                    pathRow("FFmpeg", text: $s.ffmpegPath, automaticURL: RuntimePathResolver().resolve(RuntimeConfiguration(mode: .managed, customPythonPath: "", customFFmpegPath: "", customModelPath: "")).ffmpegExecutableURL, chooseDirectory: false)
                    pathRow(s.tr("Model Whisper", "Whisper model"), text: $s.modelPath, automaticURL: RuntimePathResolver().resolve(RuntimeConfiguration(mode: .managed, customPythonPath: "", customFFmpegPath: "", customModelPath: "")).modelDirectoryURL, chooseDirectory: true)
                }
                Text(s.tr("Katalog modelu może wskazywać pamięć podręczną Whispera albo bezpośrednio snapshot. Aplikacja sama odnajduje aktualny snapshot.", "The model directory may point to the Whisper cache or directly to a snapshot. The app automatically finds the current snapshot."))
                    .font(AppTheme.secondaryFont).foregroundStyle(.secondary)
            } header: {
                StudioFlowSectionTitle(title: s.tr("ŚRODOWISKO / ZAAWANSOWANE", "RUNTIME / ADVANCED"))
            }

            Section {
                TextEditor(text: $s.transcriptionConfig)
                    .font(AppTheme.monospacedFont)
                    .frame(minHeight: 180)
                    .scrollContentBackground(.hidden)
                    .background(AppTheme.recessed)
                    .overlay(RoundedRectangle(cornerRadius: AppTheme.cornerRadius).stroke(AppTheme.separator, lineWidth: 0.5))
                HStack {
                    Button(s.tr("Sprawdź", "Validate")) {
                        configStatus = s.configValidationError().map { s.tr("Błąd: ", "Error: ") + $0 } ?? s.tr("Konfiguracja OK", "Config OK")
                    }
                    Button(s.tr("Przywróć domyślne", "Reset to defaults")) {
                        s.resetConfig(); configStatus = s.tr("Przywrócono domyślne parametry", "Default parameters restored")
                    }
                    Spacer(); Text(configStatus).font(AppTheme.secondaryFont).foregroundStyle(configStatus.hasPrefix("Błąd") || configStatus.hasPrefix("Error") ? .red : .secondary)
                }
                Text(s.tr("Parametry z tego pola są zapisywane w ustawieniach aplikacji i przekazywane bezpośrednio do mlx_whisper.transcribe(). Nie edytuje to pliku config.json samego modelu. Nie wpisuj tu: path_or_hf_repo, language ani task — nimi steruje główne okno aplikacji.", "Parameters from this field are saved in app settings and passed directly to mlx_whisper.transcribe(). This does not edit the model's config.json file. Do not enter path_or_hf_repo, language, or task here — these are controlled by the main window."))
                    .font(AppTheme.secondaryFont).foregroundStyle(.secondary)
            } header: {
                StudioFlowSectionTitle(title: s.tr("ZAAWANSOWANA KONFIGURACJA TRANSKRYPCJI (JSON)", "ADVANCED TRANSCRIPTION CONFIG (JSON)"))
            }

            Section {
                Text(s.tr(
                    "LocalTranscriber jest darmowy. Jeśli aplikacja jest dla Ciebie przydatna, możesz wesprzeć jej rozwój.",
                    "LocalTranscriber is free to use. If you find it useful, you can support its development."
                ))
                .foregroundStyle(.secondary)
                BuyMeACoffeeButton(settings: s)
            } header: {
                StudioFlowSectionTitle(title: s.tr("WESPRZYJ LOCALTRANSCRIBER", "SUPPORT LOCALTRANSCRIBER"))
            }
        }
        .font(AppTheme.bodyFont)
        .controlSize(.small)
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(AppTheme.surface)
        .preferredColorScheme(.dark)
        .tint(AppTheme.accent)
        .padding(8)
        .frame(minWidth: 740, minHeight: 650)
        .navigationTitle("LocalTranscriber")
        .confirmationDialog(
            s.tr("Przeinstalować Runtime?", "Reinstall Runtime?"),
            isPresented: $showReinstallConfirmation
        ) {
            Button(s.tr("Przeinstaluj Runtime", "Reinstall Runtime")) {
                managedRuntime.start(.reinstallRuntime, installDirectory: managedInstallDirectory)
            }
            Button(s.tr("Anuluj", "Cancel"), role: .cancel) {}
        } message: {
            Text(s.tr(
                "Runtime zostanie ponownie pobrany z GitHub i atomowo zastąpiony. Model oraz ustawienia Custom pozostaną bez zmian.",
                "Runtime will be downloaded again from GitHub and replaced atomically. The model and Custom settings remain unchanged."
            ))
        }
        .onChange(of: s.runtimeMode) { _, mode in
            if mode == .managed {
                managedRuntime.inspect(installDirectory: managedInstallDirectory, mode: mode)
            }
        }
    }

    @ViewBuilder private func managedStatusRow(_ title: String, state: ManagedComponentState) -> some View {
        LabeledContent(title) {
            Label(statusText(state), systemImage: statusSymbol(state))
                .foregroundStyle(state == .ready ? .green : state == .invalid ? .orange : .secondary)
        }
    }

    private func statusText(_ state: ManagedComponentState) -> String {
        switch state {
        case .ready: return s.tr("Gotowe", "Ready")
        case .missing: return s.tr("Brak", "Missing")
        case .invalid: return s.tr("Niepoprawne", "Invalid")
        case .unknown: return s.tr("Nie sprawdzono", "Not checked")
        }
    }

    private func statusSymbol(_ state: ManagedComponentState) -> String {
        switch state {
        case .ready: return "checkmark.circle.fill"
        case .invalid: return "exclamationmark.triangle.fill"
        case .missing: return "minus.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    private func chooseManagedInstallDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = s.tr(
            "Wybierz nowy katalog danych. Istniejąca instalacja nie zostanie przeniesiona ani usunięta.",
            "Choose a new data directory. The existing installation will not be moved or deleted."
        )
        panel.directoryURL = managedInstallDirectory.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            s.managedInstallPath = url.path
            managedRuntime.inspect(installDirectory: url, mode: .managed)
        }
    }

    @ViewBuilder private func pathRow(_ title: String, text: Binding<String>, automaticURL: URL, chooseDirectory: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField(title, text: text, prompt: Text(s.tr("Automatycznie", "Automatic") + " — " + automaticURL.path))
                Button(s.tr("Wybierz…", "Choose…")) {
                    let p = NSOpenPanel(); p.canChooseDirectories = chooseDirectory; p.canChooseFiles = !chooseDirectory
                    if p.runModal() == .OK, let u = p.url { text.wrappedValue = u.path }
                }
                Button(s.tr("Przywróć automatyczne", "Reset to Automatic")) {
                    text.wrappedValue = ""
                }
                .disabled(text.wrappedValue.isEmpty)
            }
            Text(text.wrappedValue.isEmpty ? s.tr("Automatycznie", "Automatic") : text.wrappedValue)
                .font(AppTheme.secondaryFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
