#if !arch(arm64)
#error("Wallflow supports Apple Silicon Macs only.")
#endif

import AppKit
import Darwin

if CommandLine.arguments.contains("--self-test") {
    do {
        try WallflowSelfTest.run()
        print("Wallflow self-test passed")
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Wallflow self-test failed: \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
} else if let testIndex = CommandLine.arguments.firstIndex(of: "--video-self-test"),
          CommandLine.arguments.indices.contains(testIndex + 1) {
    let application = NSApplication.shared
    let runner = WallflowVideoSelfTest()
    let videoURL = URL(fileURLWithPath: CommandLine.arguments[testIndex + 1])
    application.setActivationPolicy(.prohibited)
    runner.run(videoURL: videoURL) { result in
        switch result {
        case .success:
            print("Wallflow video self-test passed")
            exit(EXIT_SUCCESS)
        case .failure(let error):
            fputs("Wallflow video self-test failed: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
    application.run()
    withExtendedLifetime(runner) {}
} else if let testIndex = CommandLine.arguments.firstIndex(of: "--external-web-self-test"),
          CommandLine.arguments.indices.contains(testIndex + 1) {
    let application = NSApplication.shared
    let runner = WallflowExternalWebTest()
    let projectURL = URL(fileURLWithPath: CommandLine.arguments[testIndex + 1])
    application.setActivationPolicy(.accessory)
    runner.run(projectURL: projectURL) { result in
        switch result {
        case .success:
            print("Wallflow external web self-test passed")
            exit(EXIT_SUCCESS)
        case .failure(let error):
            fputs("Wallflow external web self-test failed: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
    application.run()
    withExtendedLifetime(runner) {}
} else if CommandLine.arguments.contains("--web-self-test") {
    let application = NSApplication.shared
    let runner = WallflowWebSelfTest()
    application.setActivationPolicy(.prohibited)
    runner.run { result in
        switch result {
        case .success:
            print("Wallflow web self-test passed")
            exit(EXIT_SUCCESS)
        case .failure(let error):
            fputs("Wallflow web self-test failed: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
    application.run()
    withExtendedLifetime(runner) {}
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate()

    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()

    withExtendedLifetime(delegate) {}
}
