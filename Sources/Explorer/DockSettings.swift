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
                    Note(options.isShown
                         ? "Explorer's Dock replaces the system Dock, hidden with Finder's icon. It starts with the "
                           + "system Dock's apps; drag them to reorder them, or up and away to remove them. "
                           + "Shown while Explorer manages files (General)."
                         : "The system Dock, with Finder's icon. Its settings are the ones you had before.")
                }
            }
            if options.isShown {
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
                        Note(options.autohides
                             ? "It shows when the pointer reaches the bottom of the screen; windows go all the way down."
                             : "It stays on screen, and maximized windows end above it.")
                    }
                    if !options.autohides && !WindowFitter.isPermitted {
                        HStack(alignment: .firstTextBaseline) {
                            Note("To keep other apps' windows above the Dock, Explorer needs the Accessibility "
                                 + "permission (Privacy & Security › Accessibility).")
                            Spacer()
                            Button("Allow…") { WindowFitter.askForPermission() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onReceive(NotificationCenter.default.publisher(for: WindowFitter.permissionDidChange)) { _ in
            model.objectWillChange.send()
        }
    }
}
