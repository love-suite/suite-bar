import ExplorerCore
import Foundation
import SwiftUI

/// The Dock's options, shared by the Dock and its settings tab. Saved on every change.
final class DockSettings {
    static let shared = DockSettings()
    static let didChange = Notification.Name("DockSettingsDidChange")
    private static let key = "DockOptions"

    var options: DockOptions {
        didSet {
            guard options != oldValue else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(options), forKey: Self.key)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    private init() {
        options = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(DockOptions.self, from: $0) } ?? DockOptions()
    }
}

/// Settings › Dock.
struct DockSettingsView: View {
    @ObservedObject var model: SettingsModel

    private func dock<Value>(_ keyPath: WritableKeyPath<DockOptions, Value>) -> Binding<Value> {
        model.binding({ DockSettings.shared.options[keyPath: keyPath] },
                      { DockSettings.shared.options[keyPath: keyPath] = $0 })
    }

    // Every row is always there (greyed out with the System Dock) and every note keeps its text: the
    // tab's height must not change, or the settings window lays it out wrong.
    var body: some View {
        let options = DockSettings.shared.options
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Enable", selection: dock(\.isShown)) {
                        Text("System Dock").tag(false)
                        Text("New Dock").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Note("The New Dock replaces the system Dock, hidden with Finder's icon, whose settings come "
                         + "back with the System Dock. Shown while Explorer manages files (General).")
                }
            }
            Section("New Dock") {
                Slider(value: dock(\.iconSize), in: DockGeometry.sizes, step: 8) {
                    Text("Size")
                } minimumValueLabel: {
                    Text("Small")
                } maximumValueLabel: {
                    Text("Large")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Automatically hide and show the Dock", isOn: dock(\.autohides))
                    Note("It slides in when the pointer reaches the bottom of the screen. Otherwise it stays, "
                         + "and maximized windows end above it.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Keep other apps' windows above the Dock")
                        Spacer()
                        if WindowFitter.isPermitted {
                            Label("Allowed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Allow…") { WindowFitter.askForPermission() }
                        }
                    }
                    Note("Needs the Accessibility permission (Privacy & Security › Accessibility). "
                         + "Explorer's own windows don't.")
                }
                .disabled(options.autohides)
            }
            .disabled(!options.isShown)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onReceive(NotificationCenter.default.publisher(for: WindowFitter.permissionDidChange)) { _ in
            model.objectWillChange.send()
        }
    }
}
