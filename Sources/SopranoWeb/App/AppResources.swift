import AppKit

/// The SPM resource bundle (`AppIcon.icns`), used when the app runs from
/// `.build` without its packaged bundle.
enum AppResources {
    static let bundleName = "SopranoWeb_SopranoWeb.bundle"

    static let bundle: Bundle = {
        if let url = packagedBundleURL(resourcesURL: Bundle.main.resourceURL),
           let bundle = Bundle(url: url)
        {
            return bundle
        }
        return Bundle.module
    }()

    static func packagedBundleURL(
        resourcesURL: URL?,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL? {
        guard let resourcesURL else { return nil }
        let url = resourcesURL.appendingPathComponent(bundleName, isDirectory: true)
        return fileExists(url) ? url : nil
    }
}
