import ExpoModulesCore
import WidgetKit

/// Bridge between the React Native app and the App Group container shared
/// with the PearWidget WidgetKit extension.
///
/// The app writes the widget token + API base URL here after sign-in; the
/// widget reads them when its timeline is regenerated. `reloadTimelines()`
/// nudges WidgetKit after fresh data lands (subject to the system's
/// reload budget).
public class PearSharedModule: Module {
  private let suiteName = "group.com.peard.app"

  public func definition() -> ModuleDefinition {
    Name("PearShared")

    Function("setSharedItem") { (key: String, value: String) in
      UserDefaults(suiteName: self.suiteName)?.set(value, forKey: key)
    }

    Function("getSharedItem") { (key: String) -> String? in
      UserDefaults(suiteName: self.suiteName)?.string(forKey: key)
    }

    Function("removeSharedItem") { (key: String) in
      UserDefaults(suiteName: self.suiteName)?.removeObject(forKey: key)
    }

    Function("reloadTimelines") {
      WidgetCenter.shared.reloadAllTimelines()
    }
  }
}
