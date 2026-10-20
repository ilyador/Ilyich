import IlyichPlatform
import Synchronization
import XCTest
@testable import Ilyich

/// The dormant background transport (rebuild milestone B5), driven through its session and
/// TaskEventHandling seams with a temporary App Group.
final class BackgroundTransportTests: XCTestCase {
    private typealias G = LegacyGoldens
    private static let stageFolder = "Backup/\(LegacyGoldens.digest)/\(LegacyGoldens.currentFolder)"
    private static let shareFolder = "ShareInbox/\(LegacyGoldens.batchID.uuidString)"
    private static let newAttempt = "0F1E2D3C-4B5A-4697-8877-665544332211"
    private static let otherAttempt = "1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D"
    private static let receiptJSON = #"{"id":"e1f2a3b4-c5d6-4e7f-8091-a2b3c4d5e6f7","status":"created"}"#

    private var group: TemporaryAppGroup!

    override func setUpWithError() throws { group = try TemporaryAppGroup() }
    override func tearDown() { group?.remove() }

    // MARK: Submitting

    func testSubmitDescribesANewTaskWithVersion2AndAdoptsItAfterwards() async throws {
        let fake = FakeTransportSession()
        let transport = makeTransport(fake)
        let key = key()
        let request = Self.request
        try group.write("body", to: key.bodyPath)

        let id = try await transport.submit(request, key: key)
        let description = #"{"attempt":"\#(Self.newAttempt)","outcome":"\#(Self.stageFolder)/\#(Self.newAttempt).receipt","scope":"\#(G.digest)","v":2}"#
        XCTAssertEqual(fake.uploads, [.init(id: id, url: request.url, body: group.url(key.bodyPath), description: description)])
        XCTAssertEqual(TaskDescriptor(taskDescription: description), key.descriptor)

        // Submitting the attempt again, as after a relaunch, adopts its task.
        let again = try await transport.submit(request, key: key)
        XCTAssertEqual(again, id)
        XCTAssertEqual(fake.uploads.count, 1, "One attempt never has two tasks.")
        XCTAssertEqual(fake.resumed, [id])
        let inventory = await transport.inventory()
        XCTAssertEqual(inventory.task(for: key.attempt)?.taskID, id)
        XCTAssertEqual(inventory.tasks(scope: G.digest).map(\.taskID), [id])
    }

    func testLegacyDescriptorAdoptedByStageIDDespitePathForm() async throws {
        // An earlier build's tasks, described under their day's container path: /private/var for
        // the backup, /var for the share, both in a container this install no longer has.
        let backupText = try fixtureText("backup/descriptor-backup.json")
        let shareText = try fixtureText("share/descriptor-share-var.json")
        XCTAssertTrue(backupText.contains(#"file:\/\/\/private\/var\/mobile\/Containers\/Shared\/AppGroup\/0E4C1B7A"#))
        XCTAssertTrue(shareText.contains(#"file:\/\/\/var\/mobile\/Containers\/Shared\/AppGroup\/0E4C1B7A"#))
        let share = try FixtureLoader.decode(Legacy.Descriptor.self, from: "share/descriptor-share-var.json")
        let backups = FakeTransportSession(tasks: [SessionTask(id: 7, description: backupText, state: .running, sent: 1_000, expected: 9_000)])
        let shares = FakeTransportSession(tasks: [SessionTask(id: 9, description: shareText, state: .suspended, sent: 0, expected: 4_000)])
        let log = TransportEventLog()
        let backup = makeTransport(backups, log: log)
        let sharing = makeTransport(shares, session: .shareUpload)
        let stageKey = key(G.currentStage)
        let shareKey = key(share.id, folder: Self.shareFolder)
        try group.write("body", to: stageKey.bodyPath)
        try group.write("body", to: shareKey.bodyPath)

        let inventory = await backup.inventory()
        XCTAssertEqual(inventory.task(for: stageKey.attempt)?.taskID, 7, "Matched by the stage ID, not by the recorded path.")
        XCTAssertEqual(inventory.tasks(scope: G.digest).map(\.taskID), [7])
        let shareInventory = await sharing.inventory()
        XCTAssertEqual(shareInventory.task(for: shareKey.attempt)?.taskID, 9)

        // Submitting each attempt adopts its task instead of uploading again, and keeps the legacy
        // description, which an older build reinstalled over this one still reads.
        let adoptedBackup = try await backup.submit(Self.request, key: stageKey)
        let adoptedShare = try await sharing.submit(Self.request, key: shareKey)
        XCTAssertEqual(adoptedBackup, 7)
        XCTAssertEqual(adoptedShare, 9)
        XCTAssertEqual(backups.uploads, [])
        XCTAssertEqual(shares.uploads, [])
        XCTAssertEqual(shares.resumed, [9], "A suspended task is resumed when adopted.")
        XCTAssertEqual(backups.current.map(\.description), [backupText])

        // Its outcome lands in this install's container, where the stage's key looks for it.
        XCTAssertTrue(backups.handler.task(7, didReceive: Data(Self.receiptJSON.utf8)))
        backups.handler.taskDidComplete(CompletedTask(id: 7, description: backupText, httpStatus: 201, failure: nil))
        let outcome = try XCTUnwrap(try backup.outcome(for: stageKey))
        XCTAssertEqual(outcome.receipt, OutcomeRecord.Receipt(id: G.originalAsset, status: "created"))
        guard case .finished(.backup, let completion)? = log.all.last else { return XCTFail("\(log.all)") }
        XCTAssertEqual(completion, TransportCompletion(taskID: 7, attempt: stageKey.attempt, outcomePath: stageKey.outcomePath, journal: .recorded(outcome)))
    }

    func testAnOutcomeIsNeitherReplayedNorLostBySendingAgain() async throws {
        let fake = FakeTransportSession()
        let transport = makeTransport(fake)
        let key = key()
        try group.write("body", to: key.bodyPath)
        // An earlier attempt's failure, as a share retry finds it today.
        try group.write(#"{"error":"cancelled"}"#, to: key.outcomePath)
        await assertSubmit(transport, key, throws: .unacknowledgedOutcome)
        XCTAssertEqual(fake.uploads, [])
        let legacy = try XCTUnwrap(try transport.outcome(for: key))
        XCTAssertNil(legacy.v)
        XCTAssertNil(legacy.receipt)
        XCTAssertNil(legacy.httpStatus)

        try transport.acknowledge(key)
        XCTAssertFalse(group.exists(key.outcomePath))
        XCTAssertFalse(group.exists(key.bodyPath))
        try transport.acknowledge(key)
        XCTAssertNil(try transport.outcome(for: key))

        try group.write("body", to: key.bodyPath)
        let id = try await transport.submit(Self.request, key: key)
        XCTAssertEqual(fake.uploads.map(\.id), [id])
    }

    func testSubmitRefusesKeysOutsideTheAppGroupAndMissingBodies() async throws {
        let fake = FakeTransportSession()
        let transport = makeTransport(fake)
        let outside = [
            AttemptKey(attempt: AttemptID(legacy: "a"), scope: G.digest, folder: "/private/var/mobile/Backup"),
            AttemptKey(attempt: AttemptID(legacy: "a"), scope: G.digest, folder: "Backup/../.."),
            AttemptKey(attempt: AttemptID(legacy: "a"), scope: G.digest, folder: ""),
            AttemptKey(attempt: AttemptID(legacy: "a"), scope: G.digest, folder: "file:///Backup"),
            AttemptKey(attempt: AttemptID(legacy: "a/b"), scope: G.digest, folder: Self.stageFolder),
            AttemptKey(attempt: AttemptID(legacy: ".."), scope: G.digest, folder: Self.stageFolder),
            AttemptKey(attempt: AttemptID(legacy: "a"), scope: "", folder: Self.stageFolder),
        ]
        for key in outside { await assertSubmit(transport, key, throws: .invalidKey) }
        await assertSubmit(transport, key(), throws: .missingBody)
        let nowhere = BackgroundTransport(session: .backup, journal: FileOutcomeJournal(layout: nil), emit: { _ in }) { _ in fake }
        await assertSubmit(nowhere, key(), throws: .unavailable)
        XCTAssertEqual(fake.uploads, [])
    }

    func testTwoSubmitsOfOneAttemptNeverSendTwice() async throws {
        let gate = StubServer.Gate()
        let fake = FakeTransportSession(listGate: gate)
        let transport = makeTransport(fake)
        let key = key()
        let request = Self.request
        try group.write("body", to: key.bodyPath)
        let first = Task { try await transport.submit(request, key: key) }
        try await poll("The first submit did not reach the task list.") { gate.waiting == 1 }
        let second = Task { () -> TransportSubmitError? in
            do { _ = try await transport.submit(request, key: key); return nil } catch { return error as? TransportSubmitError }
        }
        let refused = await second.value
        XCTAssertEqual(refused, .alreadySubmitting)
        gate.open()
        let id = try await first.value
        XCTAssertEqual(fake.uploads.map(\.id), [id])
    }

    func testCancellingAnAccountCancelsOnlyItsLiveTasks() async throws {
        let other = String(repeating: "b", count: 64)
        let theirs = AttemptKey(attempt: AttemptID(legacy: Self.otherAttempt), scope: other, folder: "Backup/\(other)/F")
        let fake = FakeTransportSession(tasks: [
            SessionTask(id: 1, description: key().descriptor.taskDescription, state: .running, sent: 0, expected: 10),
            SessionTask(id: 2, description: theirs.descriptor.taskDescription, state: .running, sent: 0, expected: 10),
            SessionTask(id: 3, description: try fixtureText("backup/descriptor-backup.json"), state: .suspended, sent: 0, expected: 10),
            SessionTask(id: 4, description: try fixtureText("share/descriptor-share-var.json"), state: .running, sent: 0, expected: 10),
            SessionTask(id: 5, description: key(Self.otherAttempt).descriptor.taskDescription, state: .canceling, sent: 0, expected: 10),
            SessionTask(id: 6, description: "upload", state: .running, sent: 0, expected: 10),
        ])
        let transport = makeTransport(fake)
        let cancelled = await transport.cancel(scope: G.digest)
        XCTAssertEqual(cancelled, 2)
        XCTAssertEqual(fake.cancelled, [1, 3], "The account's version 2 and legacy backup tasks; a legacy share names no account.")
        let inventory = await transport.inventory()
        XCTAssertEqual(inventory.foreign.map(\.taskID), [6])
    }

    // MARK: The delegate's work

    func testOutcomeIsWrittenBeforeTheTaskIsReportedFinished() throws {
        let group = try XCTUnwrap(self.group)
        let key = key()
        try group.makeFolder(key.folder)
        let existed = Locked<[Bool]>([])
        let fake = FakeTransportSession()
        _ = BackgroundTransport(session: .backup, journal: group.journal, emit: { event in
            guard case .finished(_, let completion) = event else { return }
            existed.mutate { $0.append(group.exists(completion.outcomePath ?? "")) }
        }) { fake.attach($0) }
        let description = try XCTUnwrap(key.descriptor.taskDescription)

        XCTAssertTrue(fake.handler.task(3, didReceive: Data(Self.receiptJSON.prefix(20).utf8)))
        XCTAssertTrue(fake.handler.task(3, didReceive: Data(Self.receiptJSON.dropFirst(20).utf8)))
        fake.handler.taskDidComplete(CompletedTask(id: 3, description: description, httpStatus: 201, failure: nil))

        XCTAssertEqual(existed.value, [true], "The outcome file existed when the task was reported finished.")
        let text = try group.text(key.outcomePath)
        XCTAssertEqual(text, #"{"httpStatus":201,"receipt":{"id":"\#(G.originalAsset)","status":"created"},"v":2}"#)
        // Older builds read version 2, so an install rolled back over this one still finds the upload.
        let data = Data(text.utf8)
        XCTAssertEqual(try JSONDecoder().decode(BackgroundUploads.Outcome.self, from: data).receipt?.id, G.originalAsset)
        XCTAssertEqual(try Legacy.decoder().decode(Legacy.Outcome.self, from: data).receipt, Legacy.UploadReceipt(id: G.originalAsset, status: "created"))
    }

    func testOutcomesRecordWhatHappenedWithoutClassifying() throws {
        func outcome(_ status: Int?, _ body: String = "", failure: CompletedTask.Failure? = nil, oversized: Bool = false) -> OutcomeRecord {
            TransportEventProcessor.outcome(of: CompletedTask(id: 1, description: nil, httpStatus: status, failure: failure),
                                            response: Data(body.utf8), oversized: oversized)
        }
        XCTAssertEqual(outcome(201, Self.receiptJSON), OutcomeRecord(receipt: .init(id: G.originalAsset, status: "created"), httpStatus: 201, v: 2))
        XCTAssertEqual(outcome(200, #"{"id":"\#(G.originalAsset)","status":"duplicate"}"#).receipt?.status, "duplicate")
        for body in ["", "<html></html>", #"{"id":"not-a-uuid","status":"created"}"#, #"{"id":"\#(G.originalAsset)","status":"replaced"}"#] {
            let unconfirmed = outcome(201, body)
            XCTAssertNil(unconfirmed.receipt, body)
            XCTAssertEqual(unconfirmed.httpStatus, 201, body)
            XCTAssertEqual(unconfirmed.errorDomain, TransportOutcomeCode.domain, body)
            XCTAssertEqual(unconfirmed.errorCode, TransportOutcomeCode.invalidReceipt.rawValue, body)
        }
        // A refusal keeps its status, and an Immich answer its message; a proxy's page only its status.
        let immich = #"{"message":"Invalid user token","error":"Unauthorized","statusCode":401,"correlationId":"c0ffee"}"#
        XCTAssertEqual(outcome(401, immich), OutcomeRecord(error: "Invalid user token", httpStatus: 401, v: 2))
        XCTAssertEqual(outcome(400, #"{"message":["assetData must be a file"],"error":"Bad Request","statusCode":400}"#).error, "assetData must be a file")
        let proxy = outcome(413, "<html>Request Entity Too Large</html>")
        XCTAssertEqual(proxy.httpStatus, 413)
        XCTAssertNil(proxy.receipt)
        XCTAssertNil(proxy.errorDomain)
        XCTAssertNotNil(proxy.error)
        // A transport failure keeps its domain, its code and iOS's cancel reason.
        let lost = outcome(nil, failure: CompletedTask.Failure(URLError(.networkConnectionLost)))
        XCTAssertEqual(lost.errorDomain, NSURLErrorDomain)
        XCTAssertEqual(lost.errorCode, URLError.networkConnectionLost.rawValue)
        XCTAssertNil(lost.httpStatus)
        XCTAssertNil(lost.cancelReason)
        let forceQuit = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                                userInfo: [NSURLErrorBackgroundTaskCancelledReasonKey: 0, NSLocalizedDescriptionKey: "cancelled"])
        XCTAssertEqual(String(decoding: try OutcomeRecord.encoded(outcome(nil, failure: CompletedTask.Failure(forceQuit))), as: UTF8.self),
                       #"{"cancelReason":0,"error":"cancelled","errorCode":-999,"errorDomain":"NSURLErrorDomain","v":2}"#)
        XCTAssertEqual(outcome(nil).errorCode, TransportOutcomeCode.noResponse.rawValue)
        // An answer cut off at 64 KiB is never a receipt, whatever its status.
        let oversized = outcome(201, Self.receiptJSON, oversized: true)
        XCTAssertNil(oversized.receipt)
        XCTAssertEqual(oversized.errorCode, TransportOutcomeCode.responseTooLarge.rawValue)
    }

    func testAnswersOver64KiBAreCancelledUnread() throws {
        let fake = FakeTransportSession()
        let transport = makeTransport(fake)
        let key = key()
        try group.makeFolder(key.folder)
        let limit = TransportEventProcessor.responseLimit
        XCTAssertEqual(limit, 65_536)
        XCTAssertTrue(fake.handler.task(4, didReceive: Data(count: limit)), "Exactly 64 KiB is read.")
        XCTAssertTrue(fake.handler.task(5, didReceive: Data(count: limit - 1)))
        XCTAssertFalse(fake.handler.task(5, didReceive: Data(count: 2)), "One byte more cancels the task.")
        XCTAssertFalse(fake.handler.task(5, didReceive: Data(count: 1)), "Nothing more is buffered once cancelled.")
        fake.handler.taskDidComplete(CompletedTask(id: 5, description: key.descriptor.taskDescription, httpStatus: 201,
                                                   failure: CompletedTask.Failure(URLError(.cancelled))))
        let outcome = try XCTUnwrap(try transport.outcome(for: key))
        XCTAssertNil(outcome.receipt)
        XCTAssertEqual(outcome.errorDomain, TransportOutcomeCode.domain)
        XCTAssertEqual(outcome.errorCode, TransportOutcomeCode.responseTooLarge.rawValue)
    }

    func testProgressIsReportedAtMostFourTimesASecondPerTask() throws {
        let now = Locked<Duration>(.zero)
        let fake = FakeTransportSession()
        let log = TransportEventLog()
        _ = makeTransport(fake, log: log, uptime: { now.value })
        let first = try XCTUnwrap(key().descriptor.taskDescription)
        let second = try XCTUnwrap(key(Self.otherAttempt).descriptor.taskDescription)
        func send(_ id: Int, _ description: String?, _ sent: Int64, at milliseconds: Int) {
            now.mutate { $0 = .milliseconds(milliseconds) }
            fake.handler.task(id, description: description, didSend: sent, of: 1_000)
        }
        send(1, first, 100, at: 0)
        send(1, first, 200, at: 100)
        send(2, second, 50, at: 120)
        send(1, first, 300, at: 249)
        send(1, first, 400, at: 250)
        send(1, first, 1_000, at: 260)
        send(3, "upload", 10, at: 600)
        let attempt = AttemptID(legacy: Self.newAttempt), other = AttemptID(legacy: Self.otherAttempt)
        XCTAssertEqual(log.all, [
            .progress(.backup, TransportProgress(taskID: 1, attempt: attempt, sent: 100, expected: 1_000)),
            .progress(.backup, TransportProgress(taskID: 2, attempt: other, sent: 50, expected: 1_000)),
            .progress(.backup, TransportProgress(taskID: 1, attempt: attempt, sent: 400, expected: 1_000)),
            .progress(.backup, TransportProgress(taskID: 1, attempt: attempt, sent: 1_000, expected: 1_000)),
        ], "Each task at most every 250 ms, the last bytes always, and nothing for a task this app did not describe.")
    }

    func testSessionDrainIsReportedAfterItsFinishedTasks() throws {
        let fake = FakeTransportSession()
        let log = TransportEventLog()
        _ = makeTransport(fake, session: .shareUpload, log: log)
        let keys = [key(folder: Self.shareFolder), key(Self.otherAttempt, folder: Self.shareFolder)]
        try group.makeFolder(Self.shareFolder)
        for (index, key) in keys.enumerated() {
            fake.handler.taskDidComplete(CompletedTask(id: index + 1, description: key.descriptor.taskDescription, httpStatus: nil,
                                                       failure: CompletedTask.Failure(URLError(.networkConnectionLost))))
        }
        fake.handler.taskDidComplete(CompletedTask(id: 3, description: "upload", httpStatus: 201, failure: nil))
        fake.handler.sessionDidFinishEvents()
        XCTAssertEqual(log.all.map(Self.summary), ["finished 1 recorded", "finished 2 recorded", "drained share-upload"],
                       "A task this app did not describe leaves no outcome and no event.")
        XCTAssertTrue(keys.allSatisfy { group.exists($0.outcomePath) })
    }

    // MARK: The URLSession delegate

    func testDelegateRefusesRedirectsAndForwardsEveryCallback() throws {
        let handler = RecordingHandler(accepts: false)
        let delegate = BackgroundSessionDelegate(handler: handler, challenges: UploadChallengeResponder(credential: { nil }))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://photos.example.org/api/assets"))
        let task = session.dataTask(with: url)
        task.taskDescription = "described"

        let redirects = Locked<[URLRequest?]>([])
        let elsewhere = try XCTUnwrap(URL(string: "https://elsewhere.example/api/assets"))
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil)),
                            newRequest: URLRequest(url: elsewhere)) { request in redirects.mutate { $0.append(request) } }
        XCTAssertEqual(redirects.value, [nil], "A multipart POST is never redirected.")

        delegate.urlSession(session, dataTask: task, didReceive: Data(count: 3))
        XCTAssertNotEqual(task.state, .suspended, "A refused answer cancels its task.")
        delegate.urlSession(session, task: task, didSendBodyData: 10, totalBytesSent: 100, totalBytesExpectedToSend: 1_000)
        delegate.urlSession(session, task: task, didCompleteWithError: URLError(.timedOut))
        delegate.urlSessionDidFinishEvents(forBackgroundURLSession: session)
        let id = task.taskIdentifier
        XCTAssertEqual(handler.calls, ["data \(id) 3", "sent \(id) described 100/1000", "done \(id) described - NSURLErrorDomain -1001", "drained"])

        let challenge = Self.certificateChallenge()
        let dispositions = Locked<[URLSession.AuthChallengeDisposition]>([])
        delegate.urlSession(session, task: task, didReceive: challenge) { disposition, _ in dispositions.mutate { $0.append(disposition) } }
        XCTAssertEqual(dispositions.value, [.performDefaultHandling], "Signed out, no certificate is offered.")
    }

    func testCertificateChallengesAreAnsweredOnlyForTheSignedInServer() throws {
        let saved = G.credential
        let answered = Locked<[String]>([])
        let responder = UploadChallengeResponder(credential: { saved }, configuration: { _ in G.networkConfiguration }) { _, server, url, completion in
            answered.mutate { $0.append(server.absoluteString + " " + url.absoluteString) }
            completion(.useCredential, nil)
        }
        let challenge = Self.certificateChallenge()
        func disposition(_ address: String, token: String?, header: String = "Authorization") -> URLSession.AuthChallengeDisposition? {
            var request = URLRequest(url: URL(string: address)!)
            if let token { request.setValue(header == "Authorization" ? "Bearer " + token : token, forHTTPHeaderField: header) }
            let result = Locked<URLSession.AuthChallengeDisposition?>(nil)
            responder.respond(to: challenge, request: request) { value, _ in result.mutate { $0 = value } }
            return result.value
        }
        XCTAssertEqual(disposition("https://photos.example.org/api/assets", token: saved.token), .useCredential)
        XCTAssertEqual(disposition("https://photos.tailnet-1234.ts.net/api/assets", token: saved.token), .useCredential)
        XCTAssertEqual(disposition("http://192.168.1.20:2283/api/assets", token: saved.token), .useCredential, "The local address is the server's too.")
        XCTAssertEqual(disposition("https://photos.example.org/api/assets", token: saved.token, header: "x-immich-user-token"), .useCredential)
        XCTAssertEqual(disposition("https://elsewhere.example/api/assets", token: saved.token), .performDefaultHandling)
        XCTAssertEqual(disposition("https://photos.example.org/api/assets", token: "someone-else"), .performDefaultHandling)
        XCTAssertEqual(disposition("https://photos.example.org/api/assets", token: nil), .performDefaultHandling)
        XCTAssertEqual(answered.value.count, 4)
        XCTAssertTrue(answered.value.allSatisfy { $0.hasPrefix(saved.server.absoluteString + " ") }, "The certificate is the signed-in server's.")
    }

    // MARK: Support

    private static var request: URLRequest {
        var request = URLRequest(url: URL(string: "https://photos.example.org/api/assets")!)
        request.httpMethod = "POST"
        return request
    }

    private func key(_ attempt: String = newAttempt, folder: String = stageFolder) -> AttemptKey {
        AttemptKey(attempt: AttemptID(legacy: attempt), scope: G.digest, folder: folder)
    }

    private func makeTransport(_ fake: FakeTransportSession, session: TransferSessionID = .backup, log: TransportEventLog = TransportEventLog(),
                               uptime: @escaping @Sendable () -> Duration = { .zero }) -> BackgroundTransport {
        BackgroundTransport(session: session, journal: group.journal, emit: log.emit, uptime: uptime) { fake.attach($0) }
    }

    private func fixtureText(_ path: String) throws -> String { String(decoding: try FixtureLoader.data(path), as: UTF8.self) }

    private func assertSubmit(_ transport: BackgroundTransport, _ key: AttemptKey, throws expected: TransportSubmitError,
                              line: UInt = #line) async {
        do {
            _ = try await transport.submit(Self.request, key: key)
            XCTFail("Submitted \(key)", line: line)
        } catch { XCTAssertEqual(error, expected, "\(key)", line: line) }
    }

    private func poll(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail(message); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func summary(_ event: TransportEvent) -> String {
        switch event {
        case .progress(_, let progress): "progress \(progress.taskID)"
        case .finished(_, let completion): "finished \(completion.taskID) \(completion.journal.isRecorded ? "recorded" : "unrecorded")"
        case .drained(let session): "drained \(session.rawValue)"
        }
    }

    static func certificateChallenge() -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(host: "photos.example.org", port: 443, protocol: NSURLProtectionSpaceHTTPS, realm: nil,
                                       authenticationMethod: NSURLAuthenticationMethodClientCertificate)
        return URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil,
                                          error: nil, sender: ChallengeSender())
    }
}

/// Records what a session's delegate forwarded through the TaskEventHandling seam.
private final class RecordingHandler: TaskEventHandling {
    private let recorded = Locked<[String]>([])
    private let accepts: Bool

    init(accepts: Bool) { self.accepts = accepts }

    var calls: [String] { recorded.value }

    func task(_ id: Int, didReceive data: Data) -> Bool {
        recorded.mutate { $0.append("data \(id) \(data.count)") }
        return accepts
    }

    func task(_ id: Int, description: String?, didSend sent: Int64, of expected: Int64) {
        recorded.mutate { $0.append("sent \(id) \(description ?? "-") \(sent)/\(expected)") }
    }

    func taskDidComplete(_ task: CompletedTask) {
        let status = task.httpStatus.map(String.init) ?? "-"
        let failure = task.failure.map { "\($0.domain) \($0.code)" } ?? "-"
        recorded.mutate { $0.append("done \(task.id) \(task.description ?? "-") \(status) \(failure)") }
    }

    func sessionDidFinishEvents() { recorded.mutate { $0.append("drained") } }
}

extension TransportCompletion.Journal {
    var isRecorded: Bool {
        if case .recorded = self { return true }
        return false
    }
}

private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
