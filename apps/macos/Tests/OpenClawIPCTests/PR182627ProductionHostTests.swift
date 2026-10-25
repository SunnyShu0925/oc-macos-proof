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
        bridge.load(server.url("/control/chat/main?pr182627-proof"))
        try await TestWait.observed("production bridge ready") { bridge.currentDocumentId != nil }
        try await TestWait.observed("production page bridge") {
            try await Self.evaluate(
                "window.__PR182627_PROOF__ === true || typeof window.__PR182627_PROOF_ERROR__ === 'string'",
                in: document.webView) as? Bool == true
        }
        let pageBridgeError = try await Self.evaluate(
            "String(window.__PR182627_PROOF_ERROR__ ?? 'none')", in: document.webView)
        Self.trace("production page bridge error=\(pageBridgeError as? String ?? "invalid")")
        try #require(pageBridgeError as? String == "none")

        Self.trace("VERDICT:START")
        let first = Task { await bridge.request(.navigate(Self.firstContext)) }
        let firstRequest = try await Self.waitForCommand(in: document.webView, count: 1)
        let firstHost = try await Self.waitForResult(
            in: document.webView, requestId: firstRequest, commandResult: false)
        Self.trace("first request=\(firstRequest) host=\(Self.ack(firstHost))")

        let second = Task { await bridge.request(.navigate(Self.secondContext)) }
        let secondRequest = try await Self.waitForCommand(in: document.webView, count: 2)
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
            Self.trace("VERDICT:FAILED:clock-unavailable")
            return
        }
        let wallDelta = steppedNow.doubleValue - queuedNow.doubleValue
        let monotonicDelta = max(0, steppedPerformance.doubleValue - queuedPerformance.doubleValue)
        Self.trace("clock Date.now delta=\(Int(wallDelta.rounded()))ms")
        Self.trace("clock performance.now delta=\(Int(monotonicDelta.rounded()))ms")

        // Finish the blocker through the real page-world command-result handshake.
        let bridgePage = try await Self.run("""
        return await window.fixtureFinishBridge(\(try Self.literal(firstRequest)));
        """, in: document.webView)
        let bridgePageAck = try #require(bridgePage as? [String: Any])
        Self.trace("first bridge page ack=\(Self.ack(bridgePageAck))")
        let firstResult = await first.value
        Self.trace("first native ok=\(firstResult.ok) error=\(firstResult.error ?? "none")")
        let firstReply = try await Self.waitForResult(
            in: document.webView, requestId: firstRequest, commandResult: true)
        Self.trace("first result host=\(Self.ack(firstReply))")

        let firstPage = try await Self.run("""
        return await window.fixtureStartNavigation();
        """, in: document.webView)
        let firstPageAck = try #require(firstPage as? [String: Any])
        Self.trace("first page ack=\(Self.ack(firstPageAck))")
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
        let result = await second.value
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
        #expect(firstHost is [String: Any], "page did not receive the first native ACK")
        #expect(firstHost as? [String: Any] as? [String: Bool] == ["ok": true],
                "first native ACK was rejected")
        #expect(firstReply is [String: Any], "native command-result was not acknowledged")
        #expect(firstPageAck["ok"] as? Bool == true, "first page acknowledgement was rejected")
        #expect(queuedStatus as? String == "queued", "second navigation was not queued")
        #expect(started, "second navigation did not begin after the first completed")
        #expect((secondPageAck as? [String: Any])?["ok"] as? Bool == true,
                "second page acknowledgement was rejected")
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

    private static func run(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }

    private static func waitForCommand(
        in webView: WKWebView,
        count: Int? = nil,
        requestId: String? = nil) async throws -> String
    {
        let target = requestId
            .map { "Boolean(window.commands.some(command => command.requestId === \(try Self.literal($0))))" }
            ?? "window.commandCount >= \(count ?? 0)"
        try await TestWait.state("command \(requestId ?? String(count ?? 0))") {
            let received = try? await self.evaluate(
                target, in: webView) as? Bool
            return received == true
        }
        if let requestId { return requestId }
        return try #require(try await self.evaluate(
            "window.commands[\(try #require(count) - 1)].requestId",
            in: webView) as? String)
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
        try await TestWait.state(commandResult ? "native result \(requestId)" : "result ACK \(requestId)") {
            guard let replies = try? await self.evaluate(
                "window.fixtureReplies[\(literal)]", in: webView) as? [String: Any],
                let value = replies[commandResult ? "native" : "host"] as? [String: Any]
            else { return false }
            return value["ok"] as? Bool == true || value["error"] as? String != nil
        }
        let replies = try #require(
            try await self.evaluate("window.fixtureReplies[\(literal)]", in: webView) as? [String: Any])
        return replies[commandResult ? "native" : "host"]
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
    window.commandCount = 0;
    window.commands = [];
    window.fixtureReplies = {};
    window.fixturePageReport = {firstHost:false, firstPage:false, secondStatus:'queued'};
    const post = body => conversation.postMessage({contract:1, documentId, ...body});
    window.fixturePost = post;
    const remember = (kind, requestId, reply) => {
      window.fixtureReplies[requestId] ??= {};
      window.fixtureReplies[requestId][kind] = reply;
    };
    window.addEventListener('openclaw:native-conversation-command', event => {
      const command = event.detail;
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
          snapshot: { phase:'connected', hello:null, assistantAgentId:'main' }
        },
        sessions: {
          presentation: { agentId:'main', result:null },
          isRunVisuallyActive: () => false,
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
          })
        },
        navigateAndWait: async (_routeId, options) => {
          if (pendingNavigations.length === 1) window.fixturePageReport.secondStatus = 'started';
          return navigate(options);
        }
      };
      window.fixtureNativeBridge = bridge;
      import('/src/app/native-conversation-bridge.ts?pr182627-proof')
        .then(({createNativeConversationBridge}) => {
          const nativeBridge = createNativeConversationBridge(bridge);
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
