import Foundation

enum AppEnvironment {
    static let cloudBaseURL = URL(string: "https://sh-lamp-cloud-render.onrender.com")!
    static let appName = "SH Lamp"
    static let bundleIdentifier = "com.smarthandicrafts.shlamp"
    static let controllerLabel = "iPhone"

    enum BLE {
        static let service = "FFE0"
        static let control = "FFE1"
        static let wifi = "FFE2"
        static let identity = "FFE3"
        static let batteryService = "180F"
        static let batteryLevel = "2A19"
    }
}
