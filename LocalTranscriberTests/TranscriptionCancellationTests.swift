import XCTest
@testable import LocalTranscriber

final class TranscriptionCancellationTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let temp: URL
        let input: URL
        let model: URL
        let config: String
        let worker: URL

        var engine: TranscriptionEngine {
            TranscriptionEngine(workerURL: worker, temporaryDirectory: temp)
        }
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ value: String) {
            lock.lock(); values.append(value); lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
    }

    private func fixture(workerBody: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let temp = root.appendingPathComponent("engine-temp", isDirectory: true)
        let model = root.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: model.appendingPathComponent("config.json"))
        let input = root.appendingPathComponent("input.wav")
        try Data().write(to: input)
        let worker = root.appendingPathComponent("fake_worker.py")
        try Data(workerBody.utf8).write(to: worker)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Fixture(root: root, temp: temp, input: input, model: model, config: "{}", worker: worker)
    }

    private func transcribe(_ fixture: Fixture, onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws -> WorkerResult {
        try await fixture.engine.transcribe(
            input: fixture.input,
            pythonPath: "/usr/bin/python3",
            ffmpegPath: "/usr/bin/true",
            modelPath: fixture.model.path,
            language: "auto",
            translateToEnglish: false,
            transcriptionConfig: fixture.config,
            onLine: onLine
        )
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: url.path) {
            if Date() > deadline {
                throw NSError(domain: "LocalTranscriberTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for fake backend: \(url.lastPathComponent)"])
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func assertCancelled(_ task: Task<WorkerResult, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail("Cancelled transcription returned a completed result", file: file, line: line)
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)", file: file, line: line)
        }
    }

    func testCancelDuringTranscriptionStopsBackendAndCleansResources() async throws {
        let started = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let terminated = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: started); try? FileManager.default.removeItem(at: terminated) }
        let fixture = try fixture(workerBody: blockingWorker(started: started, terminated: terminated))
        let task = Task { try await transcribe(fixture) }

        try await waitForFile(started)
        task.cancel()
        await assertCancelled(task)
        try await waitForFile(terminated)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.temp.path), [])
    }

    func testRepeatedCancelIsIdempotent() async throws {
        let started = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let terminated = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: started); try? FileManager.default.removeItem(at: terminated) }
        let fixture = try fixture(workerBody: blockingWorker(started: started, terminated: terminated))
        let task = Task { try await transcribe(fixture) }

        try await waitForFile(started)
        task.cancel(); task.cancel(); task.cancel()
        await assertCancelled(task)
        try await waitForFile(terminated)
    }

    func testCancelBetweenSegmentsStopsFurtherProgress() async throws {
        let started = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let terminated = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: started); try? FileManager.default.removeItem(at: terminated) }
        let body = pythonPrelude(terminated: terminated) + "\n" + """
print('[00:00.000 --> 00:01.000] first', flush=True)
open(r'\(started.path)', 'w').close()
while True:
    time.sleep(0.05)
print('[00:01.000 --> 00:02.000] second', flush=True)
"""
        let fixture = try fixture(workerBody: body)
        let lines = Lines()
        let task = Task { try await transcribe(fixture) { value in lines.append(value) } }

        try await waitForFile(started)
        task.cancel()
        await assertCancelled(task)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(lines.snapshot().contains(where: { $0.contains("second") }))
    }

    func testCancelAfterBackendProducedPartialOutputDoesNotReturnCompletedResult() async throws {
        let ready = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let terminated = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: ready); try? FileManager.default.removeItem(at: terminated) }
        let body = pythonPrelude(terminated: terminated) + "\n" + """
with open(args.output, 'w') as output:
    json.dump({'text': 'partial', 'segments': []}, output)
open(r'\(ready.path)', 'w').close()
while True:
    time.sleep(0.05)
"""
        let fixture = try fixture(workerBody: body)
        let task = Task { try await transcribe(fixture) }

        try await waitForFile(ready)
        task.cancel()
        await assertCancelled(task)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.temp.path), [])
    }

    func testCancelJustBeforePublicationLeavesNoCompletedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("completed.txt")
        let writerStarted = expectation(description: "staged output written")
        let releaseWriter = DispatchSemaphore(value: 0)
        let task = Task {
            try TranscriptOutputPublisher.publish(to: destination) { staged in
                try "partial".write(to: staged, atomically: true, encoding: .utf8)
                writerStarted.fulfill()
                releaseWriter.wait()
            }
        }

        await fulfillment(of: [writerStarted], timeout: 2)
        task.cancel()
        releaseWriter.signal()
        do { try await task.value; XCTFail("Publication should have been cancelled") }
        catch is CancellationError { }
        catch { XCTFail("Expected CancellationError, got \(error)") }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testCanStartNewTranscriptionAfterCancel() async throws {
        let firstStarted = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let terminated = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: firstStarted); try? FileManager.default.removeItem(at: terminated) }
        let body = pythonPrelude(terminated: terminated) + "\n" + """
sentinel = r'\(firstStarted.path)'
if not os.path.exists(sentinel):
    open(sentinel, 'w').close()
    while True:
        time.sleep(0.05)
with open(args.output, 'w') as output:
    json.dump({'text': 'complete', 'segments': []}, output)
"""
        let fixture = try fixture(workerBody: body)
        let engine = fixture.engine
        func run() async throws -> WorkerResult {
            try await engine.transcribe(input: fixture.input, pythonPath: "/usr/bin/python3", ffmpegPath: "/usr/bin/true", modelPath: fixture.model.path, language: "auto", translateToEnglish: false, transcriptionConfig: fixture.config) { _ in }
        }
        let first = Task { try await run() }
        try await waitForFile(firstStarted)
        first.cancel()
        await assertCancelled(first)

        let second = try await run()
        XCTAssertEqual(second.text, "complete")
    }

    func testOwnerContextCancellationStopsBackend() async throws {
        let started = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let terminated = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: started); try? FileManager.default.removeItem(at: terminated) }
        let fixture = try fixture(workerBody: blockingWorker(started: started, terminated: terminated))
        let owner = Task { try await transcribe(fixture) }
        try await waitForFile(started)

        owner.cancel() // Mirrors ContentView.onDisappear cancelling its owned task.
        await assertCancelled(owner)
        try await waitForFile(terminated)
    }

    private func pythonPrelude(terminated: URL) -> String {
        """
import argparse, json, os, signal, sys, time
parser = argparse.ArgumentParser()
parser.add_argument('--input')
parser.add_argument('--output')
parser.add_argument('--model')
parser.add_argument('--language')
parser.add_argument('--task')
parser.add_argument('--config')
args = parser.parse_args()
def terminate(signum, frame):
    open(r'\(terminated.path)', 'w').close()
    sys.exit(143)
signal.signal(signal.SIGTERM, terminate)
"""
    }

    private func blockingWorker(started: URL, terminated: URL) -> String {
        pythonPrelude(terminated: terminated) + "\n" + """
open(r'\(started.path)', 'w').close()
while True:
    time.sleep(0.05)
"""
    }
}
