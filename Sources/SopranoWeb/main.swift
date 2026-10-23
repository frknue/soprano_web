import AppKit

let arguments = CommandLine.arguments
if let exitCode = BrowserCommand.run(arguments: arguments) {
    exit(exitCode)
}
if arguments.count > 1, arguments[1] == "snapshot" {
    SnapshotCommand.run(arguments: Array(arguments.dropFirst(2)))
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
