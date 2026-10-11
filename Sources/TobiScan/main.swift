import Foundation

if CommandLine.arguments.contains("--selfcheck") {
    SelfCheck.run()
} else if CommandLine.arguments.contains("--wifi-probe") {
    WifiProbe.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--wifi-scan") {
    WifiProbe.scan(arguments: Array(CommandLine.arguments.dropFirst(index + 1)))
} else {
    TobiScanApp.main()
}
