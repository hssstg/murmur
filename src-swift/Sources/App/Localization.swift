import Foundation

/// Look up a localized string from the app's resource bundle.
/// Required because SPM debug builds store resources in Bundle.module, not Bundle.main.
func L(_ key: String) -> String {
    Bundle.module.localizedString(forKey: key, value: key, table: nil)
}
