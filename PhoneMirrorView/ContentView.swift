import SwiftUI

struct ContentView: View {
    @StateObject private var session = MirrorSessionMac()

    private var displayAspect: CGFloat? {
        guard let size = session.videoSize, size.width > 0, size.height > 0 else { return nil }
        return session.rotation % 180 == 0 ? size.width / size.height : size.height / size.width
    }

    var body: some View {
        GeometryReader { geo in
            let sideways = session.rotation % 180 != 0
            let videoWidth = sideways ? geo.size.height : geo.size.width
            let videoHeight = sideways ? geo.size.width : geo.size.height
            VideoLayerView(displayLayer: session.displayLayer, aspect: displayAspect)
                .frame(width: videoWidth, height: videoHeight)
                .rotationEffect(.degrees(Double(session.rotation)))
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black)
        .frame(minWidth: 240, minHeight: 240)
        .toolbar {
            ToolbarItemGroup {
                HStack(spacing: 8) {
                    Circle()
                        .fill(session.state.isStreaming ? Color.green : Color.orange)
                        .frame(width: 9, height: 9)
                    Text(session.state.text)
                    if session.state.isStreaming {
                        Text("· \(session.fps) fps").foregroundStyle(.secondary)
                    }
                }
                .font(.footnote.weight(.medium))
            }
            ToolbarItemGroup {
                Button {
                    session.rotateLeft()
                } label: {
                    Image(systemName: "rotate.left")
                }
                .help("Girar a la izquierda")
                Button {
                    session.rotateRight()
                } label: {
                    Image(systemName: "rotate.right")
                }
                .help("Girar a la derecha")
            }
        }
        .onAppear { session.start() }
        .onDisappear { session.stop() }
    }
}

#Preview {
    ContentView()
}
