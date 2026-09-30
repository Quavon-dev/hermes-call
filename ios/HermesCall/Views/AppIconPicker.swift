import os
import SwiftUI
import UIKit

/// Switches the home-screen icon (iOS confirms every change with its own alert).
@MainActor
enum AppIconSwitcher {
    nonisolated private static let log = Logger(subsystem: "de.quavon.hermescall", category: "icon")

    static func apply(_ choice: AppIconChoice, appearance: Appearance, attempt: Int = 1) {
        let application = UIApplication.shared
        let wanted = choice.iconName(for: appearance)
        guard application.supportsAlternateIcons, application.alternateIconName != wanted else { return }
        application.setAlternateIconName(wanted) { error in
            guard let error else { return }
            // iOS sometimes answers "Resource temporarily unavailable" (e.g. right after launch): try again.
            log.error("icon not changed (attempt \(attempt)): \(error.localizedDescription, privacy: .public)")
            guard attempt < 4 else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Double(attempt)))
                apply(choice, appearance: appearance, attempt: attempt + 1)
            }
        }
    }
}

/// Settings › App icon: the two icons as tiles, plus "Match appearance" (Presence icon with the HUD).
struct AppIconPicker: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var preferences = app.preferences
        VStack(alignment: .leading, spacing: 12) {
            Text("App icon")
            HStack(spacing: 20) {
                tile(.standard, image: "IconPreviewStandard", title: "Standard")
                tile(.presence, image: "IconPreviewPresence", title: "Presence")
                Spacer(minLength: 0)
            }
            Toggle("Match appearance", isOn: Binding(
                get: { preferences.appIcon == .automatic },
                set: { automatic in
                    preferences.appIcon = automatic ? .automatic
                        : (preferences.appearance == .hud ? .presence : .standard)
                }))
        }
        .padding(.vertical, 4)
        .onChange(of: preferences.appIcon) { apply() }
        .onChange(of: preferences.appearance) { apply() }
    }

    /// The icon shown on the Home Screen right now.
    private var shown: AppIconChoice {
        app.preferences.appIcon.iconName(for: app.preferences.appearance) == nil ? .standard : .presence
    }

    private func tile(_ choice: AppIconChoice, image: String, title: String) -> some View {
        let selected = shown == choice
        return Button { app.preferences.appIcon = choice } label: {
            VStack(spacing: 6) {
                Image(image).resizable().scaledToFit().frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: selected ? 3 : 0).padding(-4))
                Text(title).font(.caption).foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) icon")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func apply() {
        AppIconSwitcher.apply(app.preferences.appIcon, appearance: app.preferences.appearance)
    }
}
