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
                    DockNote("The New Dock replaces the system Dock, hidden with Finder's icon, whose settings come "
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
                    DockNote("It slides in when the pointer reaches the bottom of the screen. Otherwise it stays, "
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
                    DockNote("Needs the Accessibility permission (Privacy & Security › Accessibility). "
                         + "Explorer's own windows don't.")
                }
                .disabled(options.autohides)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Stop the system Dock (experimental)", isOn: dock(\.stopsSystemDock))
                    DockNote("Rather than hiding it, so the whole bottom edge is free. Explorer then does ⌘Tab "
                             + "(with the Accessibility permission above); Mission Control, Spaces and full screen "
                             + "stop for now. The system Dock starts again when you turn this off, go back to the "
                             + "System Dock, switch to Finder, quit Explorer or log out.")
                }
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

/// Grey explanation under a setting, as in the other tabs.
private struct DockNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
