import SwiftUI
import AppKit

enum AppLinks {
    static let buyMeACoffeeURL = URL(string: "https://buymeacoffee.com/jakubrolkab")
    static let studioFlowURL = URL(string: "https://studioflow.media/")
}

enum AppColors {
    static let buyMeACoffeeYellow = Color(red: 1.0, green: 0.8667, blue: 0.0)
}

struct BuyMeACoffeeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTheme.buttonFont.weight(.semibold))
            .foregroundStyle(Color.black.opacity(configuration.isPressed ? 0.68 : 0.88))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(AppColors.buyMeACoffeeYellow.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
    }
}

struct StudioFlowWebsiteButton: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Button(action: openStudioFlowWebsite) {
            HStack(spacing: 5) {
                Text(settings.tr("Poznaj pozostałe produkty StudioFlow", "Explore more StudioFlow products"))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .buttonStyle(.borderless)
        .font(AppTheme.buttonFont)
        .foregroundStyle(.secondary)
        .disabled(AppLinks.studioFlowURL == nil)
        .help(settings.tr(
            "Otwórz stronę StudioFlow w domyślnej przeglądarce",
            "Open the StudioFlow website in your default browser"
        ))
    }

    private func openStudioFlowWebsite() {
        guard let url = AppLinks.studioFlowURL else { return }
        NSWorkspace.shared.open(url)
    }
}

struct BuyMeACoffeeButton: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Button(action: openSupportPage) {
            Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
        }
        .buttonStyle(BuyMeACoffeeButtonStyle())
        .disabled(AppLinks.buyMeACoffeeURL == nil)
        .help(settings.tr(
            "Otwórz stronę wsparcia LocalTranscriber w domyślnej przeglądarce",
            "Open the LocalTranscriber support page in your default browser"
        ))
    }

    private func openSupportPage() {
        guard let url = AppLinks.buyMeACoffeeURL else { return }
        NSWorkspace.shared.open(url)
    }
}
