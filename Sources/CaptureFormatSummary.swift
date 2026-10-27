import SwiftUI

struct CaptureFormatSummary: View {
    @ObservedObject var settings: CaptureTuningSettings
    var body: some View {
        Text((settings.codec == .hevc ? "HEVC" : "H.264") + " + AAC  ·  MOV")
            .font(.system(size: 9, design: .monospaced))
    }
}
