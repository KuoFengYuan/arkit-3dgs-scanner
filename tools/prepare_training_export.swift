// Repair an existing fable scan using the same preparation path as history sharing.
import Foundation

@main struct PrepareTrainingExport {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            print("Usage: prepare_training_export /path/to/scan_directory"); exit(2)
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let library = ScanLibrary(root: directory.deletingLastPathComponent())
        let entries = try await library.entries()
        guard let entry = entries.first(where: { $0.directory.standardizedFileURL == directory }) else {
            throw ScanLibrary.LibraryError.invalidDirectory
        }
        let archive = try await library.archive(entry)
        print(archive.path)
    }
}
