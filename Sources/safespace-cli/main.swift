import Foundation
import SafeSpaceCore

// safespace-cli (contract §7). Exit codes: 0 every image produced a valid record, 1 usage
// error, 2 an image failed to load or validate, 3 output directory not writable.

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "analyze":
        exit(try await AnalyzeCommand.run(Array(args.dropFirst())))
    case "validate":
        let files = args.dropFirst()
        guard !files.isEmpty else { throw CLIError.usage(AnalyzeCommand.usage) }
        var failed = false
        for path in files {
            do {
                _ = try AssessmentJSON.decode(Data(contentsOf: URL(fileURLWithPath: path)))
                print("\(path): valid")
            } catch {
                print("\(path): invalid\n\(error.localizedDescription)")
                failed = true
            }
        }
        exit(failed ? 2 : 0)
    case "version":
        print(SafeSpaceCore.version)
    case "contrast":
        throw CLIError.usage("contrast is not available until region contrast (Task 16) lands")
    case "--compare":
        // Task 8 development tool, outside the contract commands (docs/Palette/MEDIAN_CUT_TASK.md).
        do {
            _ = try PaletteComparisonCommand.run(args)
            exit(0)
        } catch let error as PaletteComparisonCommand.Failure {
            AnalyzeCommand.warn(error.localizedDescription)
            exit(error.exitCode)
        } catch {
            AnalyzeCommand.warn("Comparison failed: \(error.localizedDescription)")
            exit(2)
        }
    case "--help", "-h":
        print(AnalyzeCommand.usage)
        print(PaletteComparisonCommand.usage)
        print("--compare is a development utility, outside the contract analyze/contrast/validate commands.")
    default:
        throw CLIError.usage(AnalyzeCommand.usage)
    }
} catch let error as CLIError {
    AnalyzeCommand.warn(error.localizedDescription)
    if case .notWritable = error { exit(3) }
    exit(1)
} catch {
    AnalyzeCommand.warn(error.localizedDescription)
    exit(1)
}
