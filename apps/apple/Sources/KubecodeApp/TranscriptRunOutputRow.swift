import SwiftUI
import KubecodeUI

struct TranscriptRunOutputContentIdentity: Hashable {
    let outputID: String
    let source: String

    init(output: TranscriptRunOutput) {
        outputID = output.id
        source = output.text
    }

    var contentRevision: Int {
        var hasher = Hasher()
        hash(into: &hasher)
        return hasher.finalize()
    }
}

struct TranscriptRunOutputRow: View {
    let output: TranscriptRunOutput

    var body: some View {
        AgentMarkdownView(
            source: output.text,
            copyResponseSource: output.text
        )
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
