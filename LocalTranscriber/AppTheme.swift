import SwiftUI

/// Visual tokens adapted directly from AutoSync's `WorkspaceStyle` and
/// compact workspace components. LocalTranscriber remains a standalone app.
enum AppTheme {
    static let surface = Color(white: 0.115)
    static let header = Color(white: 0.145)
    static let recessed = Color(white: 0.095)

    static let accent = Color.blue
    static let separator = Color(nsColor: .separatorColor)

    static let spacing: CGFloat = 12
    static let compactSpacing: CGFloat = 8
    static let paneHeaderHeight: CGFloat = 30
    static let progressRowHeight: CGFloat = 52
    static let footerHeight: CGFloat = 38
    static let cornerRadius: CGFloat = 4
    static let settingsSymbolSize: CGFloat = 17
    static let settingsHitTarget: CGFloat = 32

    static let titleFont = Font.system(size: 14, weight: .semibold)
    static let sectionTitleFont = Font.system(size: 10, weight: .semibold)
    static let bodyFont = Font.system(size: 11)
    static let secondaryFont = Font.system(size: 10)
    static let buttonFont = Font.system(size: 11, weight: .medium)
    static let monospacedFont = Font.system(size: 10, design: .monospaced)
}

struct StudioFlowSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(AppTheme.sectionTitleFont)
            .tracking(1)
            .foregroundStyle(.secondary)
    }
}

struct StudioFlowPanel<Content: View>: View {
    let title: String
    let fillsAvailableHeight: Bool
    @ViewBuilder let content: Content

    init(
        title: String,
        fillsAvailableHeight: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.fillsAvailableHeight = fillsAvailableHeight
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            StudioFlowSectionTitle(title: title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppTheme.spacing)
                .frame(height: AppTheme.paneHeaderHeight)
                .background(AppTheme.header)
            Divider()
            content
                .padding(AppTheme.spacing)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: fillsAvailableHeight ? .infinity : nil,
                    alignment: .topLeading
                )
                .background(AppTheme.recessed)
        }
        .frame(maxHeight: fillsAvailableHeight ? .infinity : nil)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .stroke(AppTheme.separator, lineWidth: 0.5)
        }
    }
}

private struct StudioFlowRecessedSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(AppTheme.recessed)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .stroke(AppTheme.separator, lineWidth: 0.5)
            }
    }
}

extension View {
    func studioFlowRecessedSurface() -> some View {
        modifier(StudioFlowRecessedSurface())
    }
}
