import Foundation
import Network
import Combine

final class StreamClient: ObservableObject {
    enum State: Equatable {
        case idle
        case searching
        case connecting
        case streaming
        case failed(String)

        var text: String {
            switch self {
            case .idle: return "Inactivo"
            case .searching: return "Buscando…"
            case .connecting: return "Conectando…"
            case .streaming: return "Conectado"
            case .failed(let message): return "Error: \(message)"
            }
        }

        var isStreaming: Bool {
            if case .streaming = self { return true }
            return false
        }
    }

    @Published var state: State = .idle
    @Published var fps = 0

    var onFormat: ((VideoFormatMessage) -> Void)?
    var onFrame: ((VideoFrameMessage) -> Void)?

    private let queue = DispatchQueue(label: "com.edunavajas.macmirror.client")
    private let decodeQueue = DispatchQueue(label: "com.edunavajas.macmirror.decode")
    private let parser = FrameParser()
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var preferredEndpoint: NWEndpoint?
    private var stopped = false
    private var frameCount = 0
    private var lastFPS = CFAbsoluteTimeGetCurrent()

    func start() {
        guard browser == nil, connection == nil else { return }
        stopped = false
        // Test hook: connect straight to the host over loopback (exempt from the
        // macOS Local Network privacy prompt, which cannot be granted headlessly).
        if ProcessInfo.processInfo.arguments.contains("--loopback") {
            connect(to: .hostPort(host: "127.0.0.1", port: 7777))
            return
        }
        beginBrowsing()
    }

    func stop() {
        stopped = true
        connection?.cancel()
        connection = nil
        browser?.cancel()
        browser = nil
        preferredEndpoint = nil
        setState(.idle)
    }

    private func beginBrowsing() {
        guard browser == nil, connection == nil, !stopped else { return }
        setState(.searching)
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: MirrorService.type, domain: MirrorService.domain), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.connection == nil, !self.stopped else { return }
            guard let endpoint = results.first?.endpoint else { return }
            self.connect(to: endpoint)
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.setState(.failed("\(error)")) }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func connect(to endpoint: NWEndpoint) {
        guard !stopped else { return }
        preferredEndpoint = endpoint
        setState(.connecting)
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.connection === connection else { return }
            switch state {
            case .ready:
                self.setState(.streaming)
                self.receive(on: connection)
            case .failed(let error):
                self.handleDisconnect("\(error)")
            case .waiting:
                // The Mac is not answering (down or still starting): tear this attempt
                // down and retry on the backoff timer rather than waiting forever.
                self.handleDisconnect(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        self.connection = connection
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, self.connection === connection else { return }
            if let data, !data.isEmpty { self.handleOnQueue(data) }
            if error != nil || isComplete {
                self.handleDisconnect(error.map { "\($0)" })
                return
            }
            self.receive(on: connection)
        }
    }

    private func handleDisconnect(_ reason: String?) {
        guard connection != nil else { return }
        connection?.cancel()
        connection = nil
        browser?.cancel()
        browser = nil
        setState(reason.map { .failed($0) } ?? .searching)
        guard !stopped else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.stopped, self.connection == nil, self.browser == nil else { return }
            if let endpoint = self.preferredEndpoint {
                self.connect(to: endpoint)
            } else {
                self.beginBrowsing()
            }
        }
    }

    private func handleOnQueue(_ data: Data) {
        for (header, payload) in parser.append(data) {
            switch header.type {
            case .videoFormat:
                if let format = VideoFormatMessage.decode(payload) {
                    decodeQueue.async { [weak self] in self?.onFormat?(format) }
                }
            case .videoFrame:
                if let frame = VideoFrameMessage.decode(payload) {
                    recordFPS()
                    decodeQueue.async { [weak self] in self?.onFrame?(frame) }
                }
            }
        }
    }

    private func recordFPS() {
        frameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastFPS
        if elapsed >= 1.0 {
            let value = Double(frameCount) / elapsed
            frameCount = 0
            lastFPS = now
            DispatchQueue.main.async { self.fps = Int(value.rounded()) }
        }
    }

    private func setState(_ newState: State) {
        DispatchQueue.main.async { self.state = newState }
    }
}
