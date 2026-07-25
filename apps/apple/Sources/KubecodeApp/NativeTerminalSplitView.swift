import AppKit
import SwiftUI

enum NativeSplitGeometry {
    static func ratio(
        dividerPosition: CGFloat,
        availableLength: CGFloat
    ) -> Double? {
        guard availableLength > 0 else { return nil }
        return min(0.95, max(0.05, Double(dividerPosition / availableLength)))
    }
}

struct NativeTerminalSplitView: NSViewRepresentable {
    let axis: TerminalSplitAxis
    let ratio: Double
    let first: AnyView
    let second: AnyView
    let onRatioChange: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRatioChange: onRatioChange)
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = NSSplitView(frame: .zero)
        splitView.dividerStyle = .thin
        splitView.isVertical = axis == .horizontal
        splitView.delegate = context.coordinator
        splitView.addArrangedSubview(NSHostingView(rootView: first))
        splitView.addArrangedSubview(NSHostingView(rootView: second))
        context.coordinator.splitView = splitView
        context.coordinator.apply(ratio: ratio, to: splitView)
        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        splitView.isVertical = axis == .horizontal
        if let firstHost = splitView.arrangedSubviews.first as? NSHostingView<AnyView> {
            firstHost.rootView = first
        }
        if let secondHost = splitView.arrangedSubviews.dropFirst().first as? NSHostingView<AnyView> {
            secondHost.rootView = second
        }
        context.coordinator.onRatioChange = onRatioChange
        context.coordinator.apply(ratio: ratio, to: splitView)
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        weak var splitView: NSSplitView?
        var onRatioChange: (Double) -> Void
        private var appliedRatio: Double?
        private var isApplyingRatio = false

        init(onRatioChange: @escaping (Double) -> Void) {
            self.onRatioChange = onRatioChange
        }

        func apply(ratio: Double, to splitView: NSSplitView) {
            let ratio = TerminalLayoutState.clampedRatio(ratio)
            guard appliedRatio.map({ abs($0 - ratio) > 0.002 }) ?? true else { return }
            appliedRatio = ratio
            DispatchQueue.main.async { [weak self, weak splitView] in
                guard let self, let splitView else { return }
                let length = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
                guard length > 0 else {
                    self.appliedRatio = nil
                    return
                }
                self.isApplyingRatio = true
                splitView.setPosition(CGFloat(ratio) * length, ofDividerAt: 0)
                self.isApplyingRatio = false
            }
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard !isApplyingRatio,
                  let splitView,
                  let first = splitView.arrangedSubviews.first
            else { return }
            let position = splitView.isVertical ? first.frame.maxX : first.frame.maxY
            let length = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
            guard let ratio = NativeSplitGeometry.ratio(
                dividerPosition: position,
                availableLength: length
            ), appliedRatio.map({ abs($0 - ratio) > 0.002 }) ?? true else { return }
            appliedRatio = ratio
            onRatioChange(ratio)
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            max(80, proposedMinimumPosition)
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            let length = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
            return min(max(80, length - 80), proposedMaximumPosition)
        }

        func splitView(
            _ splitView: NSSplitView,
            canCollapseSubview subview: NSView
        ) -> Bool {
            false
        }
    }
}
