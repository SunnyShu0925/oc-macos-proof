import AppKit
import Foundation
import OpenClawKit
import Testing
import WebKit
@testable import OpenClaw

@Suite(.serialized, .testWaitLimit)
@MainActor
struct PR182627ProductionHostTests {
    private struct StageTimeout: Error {
        let stage: String
    }

    private static let waitLimit: Duration = .seconds(60)

    @Test(.timeLimit(.minutes(2)))
    func `fixture serves its exact page without a Host`() async throws {
        let bridgeBundleURL = try #require(
            ProcessInfo.processInfo.environment["PR182627_BRIDGE_BUNDLE"].map {
                URL(fileURLWithPath: $0)
            })
        let pages = try BridgePages(bundle: bridgeBundleURL, html: Self.html)
        let requests = LockedBox<[String]>([])
        let server = try await DashboardHTTPFixture.start(
            html: Self.html,
            contentSecurityPolicy: "default-src 'self' 'unsafe-inline'",
            rawResponseHandler: { request in
                requests.withLock { $0.append(request) }
                return pages.reply(request: request, bridge: Data())
            })
        defer { server.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(
            from: server.url("/control/chat/main?pr182627-proof"))
        let httpResponse = try #require(response as? HTTPURLResponse)
        Self.trace(
            "fixture response status=\(httpResponse.statusCode) mime=\(httpResponse.mimeType ?? "none") "
                + "bytes=\(data.count)")
        Self.trace("fixture response prefix=\(String(decoding: data.prefix(160), as: UTF8.self))")
        Self.trace("fixture requests=\(requests.withLock { $0.map(Self.requestLine) })")
        #expect(httpResponse.mimeType == "text/html", "fixture page was not served as HTML")
        #expect(String(decoding: data, as: UTF8.self) == Self.html,
                "fixture route did not return its exact HTML")
    }

    @Test(.timeLimit(.minutes(3)))
    func `queued bridge request crosses real host acknowledgements after wall clock step`() async throws {
        Self.trace("runner=swift-testing")
        _ = AppKitTestSupport.application
        let bridgeBundleURL = try #require(
            ProcessInfo.processInfo.environment["PR182627_BRIDGE_BUNDLE"].map {
                URL(fileURLWithPath: $0)
            })
        let bridgeBundle = try Data(contentsOf: bridgeBundleURL)
        try #require(!bridgeBundle.isEmpty)
        let pages = try BridgePages(bundle: bridgeBundleURL, html: Self.html)
        let server = try await Self.stage("fixture server") {
            try await DashboardHTTPFixture.start(
                html: Self.html,
                contentSecurityPolicy: "default-src 'self' 'unsafe-inline'",
                rawResponseHandler: { [pages] request in
                    Self.trace("request=\(Self.requestLine(request))")
                    guard let reply = pages.reply(request: request, bridge: bridgeBundle) else {
                        Self.trace("unexpected request=\(request.components(separatedBy: "\r\n").first ?? "?")")
                        return nil
                    }
                    return reply
                })
        }
        defer { server.stop() }
        Self.trace("bridge bundle=\(bridgeBundleURL.path) bytes=\(bridgeBundle.count)")
        let handler = NativeConversationMessageHandler()
        let url = server.url("/control/")
        let document = ControlUIDocumentHost(
            url: url, auth: .unauthenticated,
            websiteDataStore: .nonPersistent())
        { controller in
            controller.addScriptMessageHandler(
                handler,
                contentWorld: .page,
                name: NativeConversationContract.handlerName)
            controller.addUserScript(WKUserScript(
                source: ControlUIDocumentHost.scopedDashboardScript(
                    NativeConversationContract.hostScript,
                    url: url),
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        var bridge: NativeConversationBridge?
        handler.owner = bridge
        do {
            bridge = NativeConversationBridge(document: document)
            let currentBridge = try #require(bridge)
            handler.owner = currentBridge
            currentBridge.load(server.url("/control/chat/main?pr182627-proof"))
            Self.trace("production bridge start")
            try await Self.state("production bridge load") { document.webView.url != nil }
            for attempt in 1...3 {
                let page = try await Self.evaluate("""
                JSON.stringify({
                  lifecycle:document.readyState, href:location.href,
                  documentType:String(document.contentType),
                  html:document.documentElement?.outerHTML?.slice(0, 160) || '',
                  loading:false,
                })
                """, in: document.webView)
                Self.trace("page document=\(attempt) \(page as? String ?? "invalid")")
                let state = try await Self.evaluate("""
                JSON.stringify({
                  readyState:document.readyState, href:location.href,
                  script:window.__PR182627_SCRIPT__ === true,
                  module:window.__PR182627_MODULE__ === true,
                  proof:window.__PR182627_PROOF__ === true,
                  error:String(window.__PR182627_PROOF_ERROR__ || ''),
                })
                """, in: document.webView)
                let mounted = try await Self.evaluate("""
                JSON.stringify({
                  document:document.querySelectorAll('script').length,
                  module:window.__PR182627_MODULE__ === true,
                  proof:window.__PR182627_PROOF__ === true,
                })
                """, in: document.webView)
                Self.trace("page probe=\(attempt) \(state as? String ?? "invalid")")
                Self.trace("page lifecycle=\(attempt) \(mounted as? String ?? "invalid")")
                Self.trace(
                    "host session=\(attempt) lease=\(document.browserSessionLease != nil) "
                        + "current=\(document.hasCurrentBrowserSession) "
                        + "document=\(currentBridge.currentDocumentId != nil) "
                        + "availability=\(currentBridge.availability)")
                if attempt < 3 {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            let pageBridgeError = try await Self.evaluate(
                "String(window.__PR182627_PROOF_ERROR__ ?? 'none')", in: document.webView)
            Self.trace("production page bridge error=\(pageBridgeError as? String ?? "invalid")")
            try #require(pageBridgeError as? String == "none")
            try await Self.state("production bridge ready") {
                currentBridge.currentDocumentId != nil
            }
            let availability = "\(currentBridge.availability)"
            Self.trace("production bridge availability=\(availability)")
            try #require(availability == "ready")
            #expect(currentBridge.currentDocumentId != nil)

            Self.trace("VERDICT:START")
            let first = Self.request(
                currentBridge, .navigate(Self.firstContext), stage: "first")
            let firstRequest = try await Self.waitForFirstRequest(in: document.webView, first: first)
            let firstHost = try await Self.waitForResult(
                in: document.webView, requestId: firstRequest, commandResult: false)
            Self.trace("first request=\(firstRequest) host=\(Self.ack(firstHost))")

            let second = Self.request(
                currentBridge, .navigate(Self.secondContext), stage: "second")
            let secondRequest = try await Self.waitForSecondRequest(
                in: document.webView, first: firstRequest, second: second)
            let queuedStatus = try await Self.evaluate(
                "window.fixturePageReport.secondStatus", in: document.webView)
            Self.trace("second status=\(queuedStatus as? String ?? "invalid")")
            Self.trace("second request=\(secondRequest) queued=true")
            let queuedNow = try await Self.evaluate("Date.now()", in: document.webView)
            let queuedPerformance = try await Self.evaluate("performance.now()", in: document.webView)
            _ = try await Self.evaluate("window.stepWallClock()", in: document.webView)
            try await Self.waitForState(in: document.webView, "clockStepped")
            let steppedNow = try await Self.evaluate("Date.now()", in: document.webView)
            let steppedPerformance = try await Self.evaluate("performance.now()", in: document.webView)
            guard let queuedNow = queuedNow as? NSNumber,
                  let steppedNow = steppedNow as? NSNumber,
                  let queuedPerformance = queuedPerformance as? NSNumber,
                  let steppedPerformance = steppedPerformance as? NSNumber
            else {
                throw StageTimeout(stage: "clock unavailable")
            }
            let wallDelta = steppedNow.doubleValue - queuedNow.doubleValue
            let monotonicDelta = max(0, steppedPerformance.doubleValue - queuedPerformance.doubleValue)
            Self.trace("clock Date.now delta=\(Int(wallDelta.rounded()))ms")
            Self.trace("clock performance.now delta=\(Int(monotonicDelta.rounded()))ms")

            // The second command is queued before the step. Resolve the first after the
            // step so both deadlines are consumed under the same skewed wall clock.
            let firstPage = try await Self.run("""
            return await window.fixtureStartNavigation();
            """, in: document.webView)
            let firstPageAck = try #require(firstPage as? [String: Any])
            Self.trace("first page ack=\(Self.ack(firstPageAck))")
            let bridgePage = try await Self.run("""
            return await window.fixtureFinishBridge(\(try Self.literal(firstRequest)));
            """, in: document.webView)
            let bridgePageAck = try #require(bridgePage as? [String: Any])
            Self.trace("first bridge page ack=\(Self.ack(bridgePageAck))")
            let firstResult = try await Self.value(of: first, "first request")
            Self.trace("first native ok=\(firstResult.ok) error=\(firstResult.error ?? "none")")
            let firstReply = try await Self.waitForResult(
                in: document.webView, requestId: firstRequest, commandResult: true)
            Self.trace("first result host=\(Self.ack(firstReply))")

            let secondStatus = try await Self.evaluate(
                "window.fixturePageReport.secondStatus", in: document.webView)
            let started = secondStatus as? String == "started"
            Self.trace("second started=\(started)")
            var secondHost: Any?
            var secondPageAck: Any?
            if started {
                secondHost = try await Self.waitForResult(
                    in: document.webView, requestId: secondRequest, commandResult: false)
                Self.trace("second host=\(Self.ack(secondHost))")
                try await Self.waitForState(in: document.webView, "secondPending")
                let pageReply = try await Self.run("""
                return await window.fixtureFinishSecond(\(try Self.literal(secondRequest)));
                """, in: document.webView)
                secondPageAck = pageReply
                Self.trace("second page ack=\(Self.ack(secondPageAck))")
            }
            let result = try await Self.value(of: second, "second request")
            Self.trace("second native ok=\(result.ok) error=\(result.error ?? "none")")
            let page = try await Self.evaluate(secondPageAck == nil
                ? "JSON.stringify(window.fixturePageReport)"
                : "JSON.stringify({...window.fixturePageReport, firstHost:window.fixtureReplies["
                    + "\(try Self.literal(firstRequest))].host.ok === true})", in: document.webView)
            Self.trace("page=\(page as? String ?? "invalid")")
            Self.trace("VERDICT:\(result.ok ? "SUCCEEDED" : "FAILED:\(result.error ?? "none")")")
            #expect(wallDelta >= 59_900, "wall clock did not step by 60 seconds")
            #expect(monotonicDelta < 5_000, "performance.now moved with the wall clock")
            #expect(bridgePageAck["ok"] as? Bool == true,
                    "fixture command-result did not reach the native host")
            #expect((firstHost as? [String: Any])?["ok"] as? Bool == true,
                    "first native ACK was rejected")
            #expect(firstReply is [String: Any], "native command-result was not acknowledged")
            #expect(firstPageAck["ok"] as? Bool == true, "first page acknowledgement was rejected")
            #expect(queuedStatus as? String == "queued", "second navigation was not queued")
            #expect(started, "second navigation did not begin after the first completed")
            #expect(
                secondPageAck == nil || (secondPageAck as? [String: Any])?["ok"] as? Bool == true,
                "second page acknowledgement was rejected")
            #expect(pages.unexpectedRequests.withLock { $0.isEmpty },
                    "fixture served an unexpected path")
            await Self.cleanup(currentBridge, document.webView, server)
            #expect(result.ok)
            Self.trace("TEST:PASS")
        } catch {
            Self.trace("TEST:ERROR \(String(describing: error))")
            await Self.cleanup(bridge, document.webView, server)
            throw error
        }
        if !pages.unexpectedRequests.withLock({ $0.isEmpty }) {
            throw StageTimeout(stage: "unexpected fixture request")
        }
        Self.exitRunner()
    }

    private static let firstContext = NativeConversationContext(
        agentId: "main", sessionKey: "agent:main:first")
    private static let secondContext = NativeConversationContext(
        agentId: "main", sessionKey: "agent:main:next")
    private static func trace(_ line: String) {
        print("[PR182627Host] \(line)")
    }

    private static func requestLine(_ request: String) -> String {
        String(request.components(separatedBy: "\r\n").first ?? "?")
    }

    private static func ack(_ value: Any?) -> String {
        guard let value = value as? [String: Any] else { return "invalid" }
        return "ok=\(value["ok"] as? Bool == true) error=\(value["error"] as? String ?? "none")"
    }

    private static func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
        let task = Task { @MainActor in
            try await Self.encodeJavaScript(try await webView.evaluateJavaScript(script))
        }
        do {
            return try await Self.decodeJavaScript(try await Self.value(of: task, "JavaScript evaluate"))
        } catch {
            task.cancel()
            throw error
        }
    }

    private static func run(_ script: String, in webView: WKWebView) async throws -> Any? {
        let task = Task { @MainActor in
            try await Self.encodeJavaScript(
                try await webView.callAsyncJavaScript(
                    script, arguments: [:], in: nil, contentWorld: .page))
        }
        do {
            return try await Self.decodeJavaScript(
                try await Self.value(of: task, "JavaScript async call"))
        } catch {
            task.cancel()
            throw error
        }
    }

    private static func encodeJavaScript(_ value: Any?) throws -> Data {
        if value == nil {
            return Data("null".utf8)
        }
        return try JSONSerialization.data(
            withJSONObject: value as Any,
            options: .fragmentsAllowed)
    }

    private static func decodeJavaScript(_ value: Data) throws -> Any? {
        let decoded = try JSONSerialization.jsonObject(
            with: value,
            options: .fragmentsAllowed)
        if decoded is NSNull {
            return nil
        }
        return decoded
    }

    private static func waitForFirstRequest(
        in webView: WKWebView,
        first: Task<NativeConversationResult, Never>) async throws -> String
    {
        try await Self.state("first command") {
            try await Self.evaluate(
                "window.commandCount === 1 || window.commandCount === 2",
                in: webView) as? Bool == true
        }
        let request = try #require(
            try await Self.evaluate("window.commands[0].requestId", in: webView) as? String)
        if try await Self.evaluate("window.commandCount", in: webView) as? Int == 2 {
            let second = try await Self.evaluate("window.commands[1].requestId", in: webView) as? String
            let result = try? await Self.value(of: first, "first request")
            Self.trace("first early second=\(second ?? "invalid") native=\(result?.error ?? "pending")")
            if result?.ok == true {
                throw StageTimeout(stage: "second command arrived before first ACK")
            }
        }
        return request
    }

    private static func request(
        _ bridge: NativeConversationBridge,
        _ action: NativeConversationCommand.Action,
        stage: String
    ) -> Task<NativeConversationResult, Never> {
        Task { @MainActor in
            Self.trace("\(stage) task started")
            return await bridge.request(action)
        }
    }

    private static func waitForSecondRequest(
        in webView: WKWebView,
        first: String,
        second: Task<NativeConversationResult, Never>) async throws -> String
    {
        let firstLiteral = try Self.literal(first)
        try await Self.state("second command") {
            try await Self.evaluate(
                "window.commandCount === 1 || window.commands.some("
                    + "command => command.requestId !== \(firstLiteral))",
                in: webView) as? Bool == true
        }
        if let request = try await Self.evaluate(
            "window.commands.find(command => command.requestId !== \(firstLiteral))?.requestId",
            in: webView) as? String
        {
            return request
        }
        let result = try await Self.value(of: second, "second request")
        Self.trace("second early native error=\(result.error ?? "none")")
        throw StageTimeout(stage: "second native error=\(result.error ?? "none")")
    }

    private static func waitForState(in webView: WKWebView, _ state: String) async throws {
        try await Self.state("page \(state)") {
            try await Self.evaluate("window.fixturePhase", in: webView) as? String == state
        }
    }

    private static func waitForResult(
        in webView: WKWebView,
        requestId: String,
        commandResult: Bool) async throws -> Any?
    {
        let literal = try Self.literal(requestId)
        try await Self.state(commandResult ? "native result \(requestId)" : "result ACK \(requestId)") {
            guard let replies = try? await Self.evaluate(
                "window.fixtureReplies[\(literal)]", in: webView) as? [String: Any],
                let value = replies[commandResult ? "native" : "host"] as? [String: Any]
            else { return false }
            return value["ok"] as? Bool == true || value["error"] as? String != nil
        }
        let replies = try #require(
            try await Self.evaluate("window.fixtureReplies[\(literal)]", in: webView) as? [String: Any])
        return replies[commandResult ? "native" : "host"]
    }

    private static func state(
        _ stage: String,
        _ condition: @escaping () async throws -> Bool) async throws
    {
        let started = ContinuousClock.now
        while true {
            let deadline = ContinuousClock.now + Self.waitLimit
            let attempt = Task { @MainActor in try await condition() }
            let conditionMet = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask { try await attempt.value }
                group.addTask {
                    try await Task.sleep(until: deadline)
                    return false
                }
                return try await group.next()!
            }
            if conditionMet {
                Self.trace("stage=\(stage) elapsed_ms=\(Self.milliseconds(ContinuousClock.now - started))")
                return
            }
            Self.trace("stage=\(stage) unsafe_window_ms=\(Self.milliseconds(ContinuousClock.now - deadline))")
            attempt.cancel()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func stage<Value>(
        _ name: String,
        _ operation: () async throws -> Value) async throws -> Value
    {
        let started = ContinuousClock.now
        let value = try await operation()
        Self.trace("stage=\(name) elapsed_ms=\(Self.milliseconds(ContinuousClock.now - started))")
        return value
    }

    private static func cleanup(
        _ bridge: NativeConversationBridge?,
        _ webView: WKWebView,
        _ server: DashboardHTTPFixture) async
    {
        let started = ContinuousClock.now
        if bridge == nil {
            Self.trace("stage=production Host cleanup skipped=no-bridge")
            Self.cleanupServer(server, pageState: webView.isLoading ? "still-loading" : "stopped")
            return
        }
        let done = LockedBox(false)
        let result = Task { @MainActor in
            await withCheckedContinuation { completion in
                guard let bridge else {
                    completion.resume()
                    return
                }
                bridge.close(afterShutdown: {
                    let first = done.withLock { value in
                        let first = !value
                        value = true
                        return first
                    }
                    guard first else { return }
                    Self.trace("stage=production Host close callback")
                    completion.resume()
                })
            }
        }
        Self.trace("stage=production Host cleanup requested")
        do {
            try await Self.bounded(of: result, stage: "production Host cleanup")
        } catch {
            result.cancel()
            Self.trace("stage=production Host cleanup timeout_or_cancel")
        }
        Self.trace("stage=production Host cleanup elapsed_ms=\(Self.milliseconds(ContinuousClock.now - started))")
        Self.cleanupServer(server, pageState: webView.isLoading ? "still-loading" : "stopped")
    }

    private static func cleanupServer(_ server: DashboardHTTPFixture, pageState: String) {
        Self.trace("stage=fixture server stopping page=\(pageState)")
        server.stop()
        Self.trace("stage=fixture server stopped page=\(pageState)")
    }

    private static func value<Value: Sendable, Failure: Error>(
        of task: Task<Value, Failure>,
        _ stage: String) async throws -> Value
    {
        do {
            return try await Self.bounded(of: task, stage: stage)
        } catch {
            task.cancel()
            throw error
        }
    }

    @MainActor
    private static func bounded<Value: Sendable, Failure: Error>(
        of task: Task<Value, Failure>,
        stage: String,
        limit: Duration = waitLimit) async throws -> Value
    {
        // Keep the wait outside MainActor so its timeout can run while WKWebView holds
        // the actor. Cancelling captures releases the web process on every failure.
        let deadline = ContinuousClock.now + limit
        do {
            return try await withThrowingTaskGroup(of: Value.self) { group in
                group.addTask { try await task.value }
                group.addTask { () -> Value in
                    do {
                        try await Task.sleep(until: deadline)
                    } catch {
                        throw CancellationError()
                    }
                    throw StageTimeout(stage: stage)
                }
                return try await group.next()!
            }
        } catch {
            task.cancel()
            throw error
        }
    }

    private static func exitRunner() -> Never {
        fflush(stdout)
        fflush(stderr)
        exit(0)
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds * 1_000 + attoseconds / 1_000_000_000_000_000)
    }

    private static func literal(_ value: String) throws -> String {
        try String(decoding: JSONEncoder().encode(value), as: UTF8.self)
    }

    private struct BridgePages {
        let bridgeName = "pr182627-bridge.js"
        let localeName: String
        let locale: Data
        let listenerName: String
        let listener: Data
        let sessionActionsName: String
        let sessionActions: Data
        let html: Data
        let responses: [String: Data]
        let unexpectedRequests = LockedBox<[String]>([])

        init(bundle: URL, html: String) throws {
            let directory = bundle.deletingLastPathComponent()
            let bridge = try String(contentsOf: bundle, encoding: .utf8)
            self.localeName = try Self.staticImport(
                prefix: "locale-catalog-", suffix: ".js", in: bridge)
            self.listenerName = try Self.staticImport(
                prefix: "listener-", suffix: ".js", in: bridge)
            self.sessionActionsName = try Self.importName(
                prefix: "native-session-menu.runtime-", suffix: ".js", in: bridge)
            self.locale = try Data(contentsOf: directory.appendingPathComponent(self.localeName))
            self.listener = try Data(contentsOf: directory.appendingPathComponent(self.listenerName))
            self.sessionActions = try Data(contentsOf: directory.appendingPathComponent(
                self.sessionActionsName))
            self.html = Data(html.utf8)
            try #require(!self.locale.isEmpty)
            try #require(!self.listener.isEmpty)
            try #require(!self.sessionActions.isEmpty)
            self.responses = [
                "/control/": self.html,
                "/control/chat/main?pr182627-proof": self.html,
                "/control/\(self.bridgeName)": Data(bridge.utf8),
                "/control/\(self.localeName)": self.locale,
                "/control/chat/main/\(self.localeName)": self.locale,
                "/control/\(self.listenerName)": self.listener,
                "/control/chat/main/\(self.listenerName)": self.listener,
                "/control/\(self.sessionActionsName)": self.sessionActions,
                "/control/chat/main/\(self.sessionActionsName)": self.sessionActions,
            ]
            print("[PR182627Host] locale chunk=\(self.localeName) bytes=\(self.locale.count)")
            print("[PR182627Host] listener chunk=\(self.listenerName) bytes=\(self.listener.count)")
            print(
                "[PR182627Host] session-actions chunk=\(self.sessionActionsName) "
                    + "bytes=\(self.sessionActions.count)")
        }

        func reply(request: String, bridge: Data) -> DashboardHTTPFixture.RawResponse? {
            let requestLine = request.components(separatedBy: "\r\n").first ?? "?"
            let path = requestLine.split(separator: " ").dropFirst().first.map(String.init)
            guard let path,
                  let body = path == "/control/\(self.bridgeName)" ? bridge : self.responses[path]
            else {
                self.unexpectedRequests.withLock { $0.append(request) }
                return nil
            }
            let isPage = path.hasPrefix("/control/chat/main") || path == "/control/"
            let contentType = isPage ? "text/html" : "application/javascript"
            let headers = (
                "HTTP/1.1 200 OK\r\n"
                    + "Content-Type: \(contentType)"
                    + "; charset=utf-8\r\n"
                    + "Cache-Control: no-store\r\n"
                    + "X-Content-Type-Options: nosniff\r\n"
                    + "Content-Length: \(body.count)\r\n"
                    + "Connection: close\r\n\r\n")
            var response = Data(headers.utf8)
            response.append(body)
            return DashboardHTTPFixture.RawResponse(data: response)
        }

        private static func staticImport(prefix: String, suffix: String, in script: String) throws -> String {
            let pattern = #""\./\#(prefix)[A-Za-z0-9_-]+\#(suffix)""#
            let regex = try NSRegularExpression(pattern: pattern)
            let matches = regex.matches(
                in: script, range: NSRange(script.startIndex..., in: script))
            try #require(matches.count == 1)
            return try #require(Range(matches[0].range, in: script).map {
                String(script[$0].dropFirst(3).dropLast())
            })
        }

        private static func importName(prefix: String, suffix: String, in script: String) throws -> String {
            let pattern = #"import\("\./\#(prefix)[A-Za-z0-9_-]+\#(suffix)"\)"#
            let regex = try NSRegularExpression(pattern: pattern)
            let matches = regex.matches(
                in: script, range: NSRange(script.startIndex..., in: script))
            try #require(matches.count == 1)
            let matched = try #require(Range(matches[0].range, in: script).map { String(script[$0]) })
            let nameStart = try #require(matched.range(of: prefix)?.lowerBound)
            let name = matched[nameStart...].prefix { $0 != "\"" }
            try #require(!name.isEmpty)
            return String(name)
        }
    }

    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) {
            self.value = value
        }

        func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
            self.lock.lock()
            defer { self.lock.unlock() }
            return try body(&self.value)
        }
    }

    private static let html = """
    <!doctype html><html><head><title>Native bridge production host</title></head><body><script>
    window.__PR182627_SCRIPT__ = true;
    Object.defineProperty(window, '__OPENCLAW_NATIVE_EMBED__', {
      value: {platform:'macos', formFactor:'desktop', surface:'conversation'}
    });
    Object.defineProperty(window, '__OPENCLAW_NATIVE_CONVERSATION__', {
      value: {contract:1, features:[]}
    });
    Object.defineProperty(window, '__OPENCLAW_NATIVE_CONVERSATION_DOCUMENT__', {
      value: {contract:1, documentId:crypto.randomUUID()}, writable:true
    });
    const documentId = __OPENCLAW_NATIVE_CONVERSATION_DOCUMENT__.documentId;
    const conversation = window.webkit.messageHandlers.openclawConversation;
    window.commandCount = 0;
    window.commands = [];
    window.fixtureReplies = {};
    window.fixturePageReport = {firstHost:false, firstPage:false, secondStatus:'queued'};
    window.fixtureEvents = [];
    const post = body => conversation.postMessage({contract:1, documentId, ...body});
    window.fixturePost = post;
    const remember = (kind, requestId, reply) => {
      window.fixtureReplies[requestId] ??= {};
      window.fixtureReplies[requestId][kind] = reply;
    };
    window.addEventListener('openclaw:native-conversation-command', event => {
      const command = event.detail;
      window.fixtureEvents.push(`command:${commandCount}`);
      window.commandCount++;
      window.commands.push(command);
      if (window.commandCount === 2) {
        window.fixturePageReport.secondStatus = 'queued';
        window.fixturePhase = 'secondQueued';
      }
    });
    const realNow = Date.now;
    window.stepWallClock = () => {
      Date.now = () => realNow() + 60000;
      window.fixturePhase = 'clockStepped';
    };
    const pendingNavigations = [];
    const navigate = options => new Promise(resolve => {
      pendingNavigations.push({options, resolve});
    });
    window.fixtureStartNavigation = async () => {
      const navigation = pendingNavigations[0];
      const reply = await post({type:'command-result', requestId:window.commands[0].requestId, ok:true});
      window.fixturePageReport.firstPage = reply.ok === true;
      navigation.resolve();
      window.fixtureConversation = {
        agentId:navigation.options.agentId, sessionKey:navigation.options.sessionKey
      };
      return reply;
    };
    window.fixtureFinishBridge = async requestId => {
      const reply = await post({type:'command-result', requestId, ok:true});
      remember('native', requestId, reply);
      return reply;
    };
    window.fixtureFinishSecond = async () => {
      const navigation = pendingNavigations[0];
      const reply = await post({type:'command-result', requestId:window.commands[1].requestId, ok:true});
      window.fixturePhase = 'secondPending';
      navigation.resolve();
      window.fixtureConversation = {
        agentId:navigation.options.agentId, sessionKey:navigation.options.sessionKey
      };
      return reply;
    };
    post({type:'ready',surface:'conversation',capabilities:[]});
    if (location.search.includes('pr182627-proof')) {
      const bridge = {
        agents: {
          state: { agentsList: [{ id:'main', name:'Main' }] }
        },
        gateway: {
          snapshot: { phase:'connected', hello:null, assistantAgentId:'main' },
          subscribe: () => () => {}
        },
        sessions: {
          presentation: { agentId:'main', result:null },
          isRunVisuallyActive: () => false,
          subscribe: () => () => {}
        },
        conversation: {
          subscribe: () => () => {}
        },
        router: {
          getState: () => ({
            get matches() {
              const sessionKey = window.fixtureConversation?.sessionKey;
              return [{
                routeId:'chat',
                status:sessionKey ? 'success' : 'pending',
                data:sessionKey ? {kind:'session',agentId:'main',sessionKey} : null
              }];
            },
            pendingMatches:[]
          }),
          subscribe: () => () => {}
        },
        navigateAndWait: async (_routeId, options) => {
          if (pendingNavigations.length === 1) window.fixturePageReport.secondStatus = 'started';
          return navigate(options);
        }
      };
      window.fixtureNativeBridge = bridge;
    }
    </script>
    <script type="module">
    window.__PR182627_MODULE__ = true;
    if (location.search.includes('pr182627-proof')) {
      import('/control/pr182627-bridge.js')
        .then(({createNativeConversationBridge}) => {
          const nativeBridge = createNativeConversationBridge(window.fixtureNativeBridge);
          if (!nativeBridge) throw new Error('production native bridge was not created');
          window.__PR182627_PROOF__ = true;
        })
        .catch(error => {
          window.__PR182627_PROOF_ERROR__ = String(error);
        });
    }
    </script></body></html>
    """
}
