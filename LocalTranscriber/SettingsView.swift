import SwiftUI
import AppKit

struct SettingsView: View {
    @StateObject private var s = SettingsStore.shared
    @State private var configStatus = ""

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
                    managedPathRow(s.tr("Python", "Python"), url: s.resolvedRuntimePaths.pythonExecutableURL)
                    managedPathRow("FFmpeg", url: s.resolvedRuntimePaths.ffmpegExecutableURL)
                    managedPathRow(s.tr("Model Whisper", "Whisper model"), url: s.resolvedRuntimePaths.modelDirectoryURL)
                    Text(s.tr(
                        "Automatyczna instalacja nie jest jeszcze dostępna. Do czasu jej dodania wybierz tryb Własny i wskaż istniejące składniki.",
                        "Automatic installation is not available yet. Until it is added, choose Custom and select existing components."
                    ))
                    .font(AppTheme.secondaryFont).foregroundStyle(.secondary)
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
    }

    @ViewBuilder private func managedPathRow(_ title: String, url: URL) -> some View {
        LabeledContent(title) {
            Text(s.tr("Automatycznie", "Automatic") + " — " + url.path)
                .font(AppTheme.bodyFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
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
