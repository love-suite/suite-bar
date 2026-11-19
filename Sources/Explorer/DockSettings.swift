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
        let isShown = DockSettings.shared.options.isShown
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show Explorer's Dock", isOn: dock(\.isShown))
                    Note("At the bottom of the screen: Explorer in Finder's place, your apps, Downloads and the "
                         + "Trash. It starts with the apps of the system Dock; drag them to reorder them. "
                         + "Shown while Explorer manages files (General).")
                }
            }
            Section("Icons") {
                Slider(value: dock(\.iconSize), in: DockGeometry.sizes, step: 8) {
                    Text("Size")
                } minimumValueLabel: {
                    Text("Small")
                } maximumValueLabel: {
                    Text("Large")
                }
            }
            .disabled(!isShown)
            Section("System Dock") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Hide the system Dock", isOn: dock(\.hidesSystemDock))
                    Note("Out of sight with Finder's icon while Explorer's Dock is shown. Its own settings come "
                         + "back when you turn this off, hide Explorer's Dock, switch to Finder or quit Explorer.")
                }
            }
            .disabled(!isShown)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}
