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
} else if let dumpIndex = CommandLine.arguments.firstIndex(of: "--particle-dump"),
          CommandLine.arguments.indices.contains(dumpIndex + 1) {
    let projectPath = CommandLine.arguments[dumpIndex + 1]
    let outputPath: String
    if CommandLine.arguments.indices.contains(dumpIndex + 2) {
        outputPath = CommandLine.arguments[dumpIndex + 2]
    } else {
        outputPath = "/tmp/wallflow-particle-dump.png"
    }
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    do {
        try WallflowParticleDumpTest.run(projectPath: projectPath, outputPath: outputPath)
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Wallflow particle dump failed: \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
} else if CommandLine.arguments.contains("--library-self-test") {
    let application = NSApplication.shared
    let runner = WallflowLibrarySelfTest()
    application.setActivationPolicy(.accessory)
    runner.run { result in
        switch result {
        case .success(let outputURL):
            print("Wallflow library self-test passed: \(outputURL.path)")
            exit(EXIT_SUCCESS)
        case .failure(let error):
            fputs("Wallflow library self-test failed: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
    application.run()
    withExtendedLifetime(runner) {}
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
} else if let testIndex = CommandLine.arguments.firstIndex(of: "--canvas-metal-self-test"),
          CommandLine.arguments.indices.contains(testIndex + 1) {
    let application = NSApplication.shared
    let runner = WallflowCanvasMetalSelfTest()
    let projectURL = URL(fileURLWithPath: CommandLine.arguments[testIndex + 1])
    application.setActivationPolicy(.prohibited)
    runner.run(projectURL: projectURL) { result in
        switch result {
        case .success:
            print("Wallflow Canvas Metal self-test passed")
            exit(EXIT_SUCCESS)
        case .failure(let error):
            fputs("Wallflow Canvas Metal self-test failed: \(error)\n", stderr)
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
