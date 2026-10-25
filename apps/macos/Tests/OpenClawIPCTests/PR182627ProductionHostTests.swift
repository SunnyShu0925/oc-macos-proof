import Foundation
import OpenClawKit
import Testing
import WebKit
@testable import OpenClaw

@Suite(.serialized, .testWaitLimit)
@MainActor
struct PR182627ProductionHostTests {
    @Test func `queued bridge request crosses real host acknowledgements after wall clock step`() async throws {
        let server = try await DashboardHTTPFixture.start(
            html: Self.html, contentSecurityPolicy: "default-src 'self' 'unsafe-inline'")
        defer { server.stop() }
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
        let bridge = NativeConversationBridge(document: document)
        handler.owner = bridge
        defer { bridge.close() }
        bridge.load(server.url("/control/chat/main"))
        try await TestWait.observed("production bridge ready") { bridge.currentDocumentId != nil }

        Self.trace("VERDICT:START")
        let first = Task { await bridge.request(.navigate(Self.firstContext)) }
        let firstRequest = try await Self.waitForCommand(in: document.webView, count: 1)
        let firstHost = try await Self.waitForResult(
            in: document.webView, requestId: firstRequest, commandResult: false)
        Self.trace("first request=\(firstRequest) host=\(Self.ack(firstHost))")
        let identity = try await Self.evaluate("window.fixtureReport()", in: document.webView)
        Self.trace("page=\(identity ?? "invalid")")

        let second = Task { await bridge.request(.navigate(Self.secondContext)) }
        let secondRequest = try await Self.waitForCommand(in: document.webView, count: 2)
        try await Self.waitForState(in: document.webView, "secondQueued")
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
            Self.trace("VERDICT:FAILED:clock-unavailable")
            return
        }
        let wallDelta = steppedNow.doubleValue - queuedNow.doubleValue
        let monotonicDelta = max(0, steppedPerformance.doubleValue - queuedPerformance.doubleValue)
        Self.trace("clock Date.now delta=\(Int(wallDelta.rounded()))ms")
        Self.trace("clock performance.now delta=\(Int(monotonicDelta.rounded()))ms")

        // A second command waiting behind the first extends the queue without
        // replacing its result. Its own real Host ACK proves the queue continued.
        let following = Task { await bridge.request(.focusComposer) }
        let followingRequest = try await Self.waitForCommand(in: document.webView, count: 3)
        try await Self.run(
            "const firstFinishedId=window.lastCommand.requestId;window.fixturePost({type:'command-result',requestId:firstFinishedId,ok:true});window.fixturePhase='firstFinished'",
            in: document.webView)
        let firstResult = await first.value
        Self.trace("first native ok=\(firstResult.ok) error=\(firstResult.error ?? "none")")
        let firstBridgeHost = try await Self.waitForResult(
            in: document.webView, requestId: firstRequest, commandResult: true)
        Self.trace("first bridge-result host=\(Self.ack(firstBridgeHost))")
        let followingResult = await following.value
        let followingHost = try await Self.waitForResult(
            in: document.webView, requestId: followingRequest, commandResult: true)
        Self.trace("following host=\(Self.ack(followingHost)) native ok=\(followingResult.ok)")

        let secondLiteral = try Self.literal(secondRequest)
        let secondStartReply = try await Self.evaluate(
            "window.fixtureReplies[\(secondLiteral)]?.host ?? null",
            in: document.webView)
        guard let secondStartReply = secondStartReply as? [String: Any],
              secondStartReply["ok"] as? Bool == true
        else {
            Self.trace("VERDICT:FAILED:second-start-ack")
            return
        }
        try await Self.waitForState(in: document.webView, "secondStarted")
        Self.trace("second navigate started after first host ack")
        try await Self.run(
            "const secondFinishedId=window.lastCommand.requestId;window.fixturePhase='secondStarted';setTimeout(()=>{window.fixturePost({type:'command-result',requestId:secondFinishedId,ok:true});window.fixturePhase='secondFinished'},250)",
            in: document.webView)
        let result = await second.value
        let secondHost = try await Self.waitForResult(
            in: document.webView, requestId: secondRequest, commandResult: true)
        Self.trace("second host=\(Self.ack(secondHost))")
        Self.trace("second native ok=\(result.ok) error=\(result.error ?? "none")")
        _ = try await Self.evaluate("window.restoreClock()", in: document.webView)
        let page = try await Self.evaluate("window.fixtureReport()", in: document.webView)
        Self.trace("page=\(page)")
        Self.trace("VERDICT:\(result.ok ? "SUCCEEDED" : "FAILED:\(result.error ?? "none")")")
        #expect(wallDelta >= 59_900, "wall clock did not step by 60 seconds")
        #expect(result.ok)
    }

    private static let firstContext = NativeConversationContext(
        agentId: "main", sessionKey: "agent:main:first")
    private static let secondContext = NativeConversationContext(
        agentId: "main", sessionKey: "agent:main:next")

    private static func trace(_ line: String) {
        print("[PR182627Host] \(line)")
    }

    private static func ack(_ value: Any?) -> String {
        guard let value = value as? [String: Any] else { return "invalid" }
        return "ok=\(value["ok"] as? Bool == true) error=\(value["error"] as? String ?? "none")"
    }

    private static func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await webView.evaluateJavaScript(script)
    }

    private static func run(_ script: String, in webView: WKWebView) async throws {
        try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }

    private static func waitForCommand(in webView: WKWebView, count: Int) async throws -> String {
        let key = "window.lastCommand?.requestId"
        try await TestWait.state("command \(count)") {
            guard let received = try? await self.evaluate("window.commandCount", in: webView) as? Int
            else { return false }
            return received >= count
        }
        return try #require(try await self.evaluate(key, in: webView) as? String)
    }

    private static func waitForState(in webView: WKWebView, _ state: String) async throws {
        try await TestWait.state("page \(state)") {
            try await self.evaluate("window.fixturePhase", in: webView) as? String == state
        }
    }

    private static func waitForResult(
        in webView: WKWebView,
        requestId: String,
        commandResult: Bool) async throws -> Any?
    {
        let literal = try Self.literal(requestId)
        try await TestWait.state(commandResult ? "bridge result \(requestId)" : "result ACK \(requestId)") {
            guard let replies = try? await self.evaluate(
                "window.fixtureReplies[\(literal)]", in: webView) as? [String: Any],
                let value = replies[commandResult ? "bridge" : "host"] as? [String: Any]
            else { return false }
            return value["ok"] as? Bool == true || value["error"] as? String != nil
        }
        let replies = try #require(
            try await self.evaluate("window.fixtureReplies[\(literal)]", in: webView) as? [String: Any])
        return replies[commandResult ? "bridge" : "host"]
    }

    private static func literal(_ value: String) throws -> String {
        try String(decoding: JSONEncoder().encode(value), as: UTF8.self)
    }

    private static let html = """
    <!doctype html><html><head><title>Native bridge production host</title></head><body><script>
    Object.defineProperty(window, '__OPENCLAW_NATIVE_CONVERSATION_DOCUMENT__', {
      value: {contract:1, documentId:crypto.randomUUID()}
    });
    const documentId = __OPENCLAW_NATIVE_CONVERSATION_DOCUMENT__.documentId;
    const conversation = window.webkit.messageHandlers.openclawConversation;
    window.fixtureReplies = {};
    window.fixturePhase = 'ready';
    window.commandCount = 0;
    window.lastCommand = null;
    window.fixturePost = body => conversation.postMessage({contract:1, documentId, ...body});
    const remember = (kind, requestId, reply) => {
      window.fixtureReplies[requestId] ??= {};
      window.fixtureReplies[requestId][kind] = reply;
    };
    window.addEventListener('openclaw:native-conversation-command', event => {
      const command = event.detail;
      window.commandCount++;
      window.lastCommand = command;
      if (window.commandCount === 1) {
        remember('host', command.requestId, {ok:true});
      }
      if (window.commandCount === 2) window.fixturePhase = 'secondQueued';
    });
    const realNow = Date.now;
    window.stepWallClock = () => {
      Date.now = () => realNow() + 60000;
      window.fixturePhase = 'clockStepped';
    };
    window.restoreClock = () => { Date.now = realNow; };
    window.fixtureReport = () => JSON.stringify({
      phase:window.fixturePhase, commands:window.commandCount,
      firstHost:window.fixtureReplies[firstRequest]?.host?.ok === true,
      firstBridge:window.fixtureReplies[firstRequest]?.bridge?.ok === true
    });
    var firstRequest;
    fixturePost({type:'ready',surface:'conversation',capabilities:[]});
    window.addEventListener('openclaw:native-conversation-command', event => {
      if (window.commandCount === 1) firstRequest = event.detail.requestId;
    });
    </script></body></html>
    """
}
