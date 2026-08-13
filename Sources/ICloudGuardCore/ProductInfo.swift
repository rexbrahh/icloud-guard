import Foundation

public enum ICloudGuardProduct {
    public static let version = "0.4.4"
    public static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "source"
    }
}
