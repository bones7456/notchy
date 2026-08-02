import Testing
import Foundation
@testable import Notchy

/// Integration tests for `CheckpointManager` against a real throwaway git repo.
/// These shell out to `/usr/bin/git` (same as the manager) to exercise the full
/// create → list → restore → delete flow, including the custom-ref naming and the
/// temp-index snapshot of the whole working tree.
@MainActor
@Suite("CheckpointManager")
struct CheckpointManagerTests {

    private let manager = CheckpointManager.shared

    // MARK: - Git test harness

    private enum GitHarnessError: Error {
        case commandFailed(args: [String], status: Int32, message: String)
    }

    @discardableResult
    private func runGit(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = dir
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()

        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A failed setup command (init/config) must surface loudly, not let a
        // test proceed against a half-built repo and pass or fail misleadingly.
        guard p.terminationStatus == 0 else {
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw GitHarnessError.commandFailed(args: args, status: p.terminationStatus,
                                                message: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return stdout
    }

    /// A fresh git repo in a temp directory (with a committer identity so
    /// `commit-tree` works on CI) plus a closure that deletes it.
    private func makeRepo() throws -> (dir: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CheckpointTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init"], in: dir)
        try runGit(["config", "user.email", "test@example.com"], in: dir)
        try runGit(["config", "user.name", "Notchy Test"], in: dir)
        return (dir, { try? FileManager.default.removeItem(at: dir) })
    }

    private func write(_ content: String, to name: String, in dir: URL) throws {
        try content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func read(_ name: String, in dir: URL) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: - create / list

    @Test("Creating a checkpoint stores a ref under refs/Notchy-snapshots/<project>/")
    func createStoresNamespacedRef() throws {
        let (dir, cleanup) = try makeRepo(); defer { cleanup() }
        try write("v1", to: "file.txt", in: dir)

        try manager.createCheckpoint(projectName: "Proj", projectDirectory: dir.path)

        let list = manager.checkpoints(for: "Proj", in: dir.path)
        #expect(list.count == 1)
        #expect(list[0].id.hasPrefix("refs/Notchy-snapshots/Proj/"))
        #expect(!list[0].commitHash.isEmpty)
    }

    @Test("A project with no checkpoints lists none")
    func noCheckpointsIsEmpty() throws {
        let (dir, cleanup) = try makeRepo(); defer { cleanup() }
        #expect(manager.checkpoints(for: "Proj", in: dir.path).isEmpty)
    }

    @Test("Checkpoints are namespaced per project name")
    func checkpointsAreNamespacedPerProject() throws {
        let (dir, cleanup) = try makeRepo(); defer { cleanup() }
        try write("x", to: "file.txt", in: dir)
        try manager.createCheckpoint(projectName: "Alpha", projectDirectory: dir.path)

        #expect(manager.checkpoints(for: "Alpha", in: dir.path).count == 1)
        #expect(manager.checkpoints(for: "Beta", in: dir.path).isEmpty)
    }

    // MARK: - restore

    @Test("Restoring a checkpoint overwrites a modified file with the snapshot")
    func restoreOverwritesModifiedFile() throws {
        let (dir, cleanup) = try makeRepo(); defer { cleanup() }
        try write("original", to: "file.txt", in: dir)
        try manager.createCheckpoint(projectName: "Proj", projectDirectory: dir.path)

        try write("modified", to: "file.txt", in: dir)
        let checkpoint = try #require(manager.checkpoints(for: "Proj", in: dir.path).first)
        try manager.restoreCheckpoint(checkpoint, to: dir.path)

        #expect(read("file.txt", in: dir) == "original")
    }

    @Test("A checkpoint snapshots uncommitted files and restore brings a deleted one back")
    func restoresDeletedUncommittedFile() throws {
        let (dir, cleanup) = try makeRepo(); defer { cleanup() }
        // Never committed — the temp-index `add -A` still captures it.
        try write("keep me", to: "note.txt", in: dir)
        try manager.createCheckpoint(projectName: "Proj", projectDirectory: dir.path)

        try FileManager.default.removeItem(at: dir.appendingPathComponent("note.txt"))
        #expect(read("note.txt", in: dir) == nil)

        let checkpoint = try #require(manager.checkpoints(for: "Proj", in: dir.path).first)
        try manager.restoreCheckpoint(checkpoint, to: dir.path)
        #expect(read("note.txt", in: dir) == "keep me")
    }

    // MARK: - delete / clear

    @Test("Deleting a checkpoint removes just its ref")
    func deleteRemovesCheckpoint() throws {
        let (dir, cleanup) = try makeRepo(); defer { cleanup() }
        try write("v1", to: "file.txt", in: dir)
        try manager.createCheckpoint(projectName: "Proj", projectDirectory: dir.path)
        let checkpoint = try #require(manager.checkpoints(for: "Proj", in: dir.path).first)

        try manager.deleteCheckpoint(checkpoint, in: dir.path)
        #expect(manager.checkpoints(for: "Proj", in: dir.path).isEmpty)
    }

    @Test("Clearing removes all of a project's checkpoints")
    func clearRemovesAll() throws {
        let (dir, cleanup) = try makeRepo(); defer { cleanup() }
        try write("v1", to: "file.txt", in: dir)
        try manager.createCheckpoint(projectName: "Proj", projectDirectory: dir.path)

        manager.clearCheckpoints(for: "Proj", in: dir.path)
        #expect(manager.checkpoints(for: "Proj", in: dir.path).isEmpty)
    }

    // MARK: - error handling

    @Test("Creating a checkpoint outside a git repo throws")
    func createOutsideRepoThrows() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CheckpointTests-nogit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: CheckpointError.self) {
            try manager.createCheckpoint(projectName: "Proj", projectDirectory: dir.path)
        }
    }
}
