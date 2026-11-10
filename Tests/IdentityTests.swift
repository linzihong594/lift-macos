import AppKit

@main struct IdentityTests {
    static func main() {
        guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]),
              let app = NSRunningApplication(processIdentifier: pid),
              app.bundleIdentifier == "local.suis.lift.background",
              app.localizedName == "轻退", app.icon != nil,
              app.activationPolicy == .prohibited,
              let bundleURL = app.bundleURL, let bundle = Bundle(url: bundleURL),
              let resource = bundle.url(forResource: "AppIcon", withExtension: "icns"),
              NSImage(contentsOf: resource)?.isValid == true else {
            fputs("FAIL expected a running faceless Lift app with its bundled icon; pass its PID.\n", stderr)
            exit(1)
        }
        print("PASS system recognizes the background app name, identity, icon and background-only policy")
    }
}
