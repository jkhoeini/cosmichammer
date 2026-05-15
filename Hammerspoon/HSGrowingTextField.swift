import Cocoa

@objc(HSGrowingTextField) public class HSGrowingTextField: NSTextField {

    private var hasLastIntrinsicSize = false
    private var isTextEditing = false
    private var lastIntrinsicSize: NSSize = .zero

    override public func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        isTextEditing = true
    }

    override public func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        isTextEditing = false
    }

    override public func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        invalidateIntrinsicContentSize()
    }

    @objc public func resetGrowth() {
        hasLastIntrinsicSize = false
        invalidateIntrinsicContentSize()
    }

    override public var intrinsicContentSize: NSSize {
        var intrinsicSize = lastIntrinsicSize

        if isTextEditing || !hasLastIntrinsicSize {
            intrinsicSize = super.intrinsicContentSize

            if let fieldEditor = window?.fieldEditor(false, for: self) as? NSTextView,
               let layoutManager = fieldEditor.textContainer?.layoutManager {
                layoutManager.ensureLayout(for: fieldEditor.textContainer!)
                var usedRect = layoutManager.usedRect(for: fieldEditor.textContainer!)

                usedRect.size.height += 5.0

                intrinsicSize.height = usedRect.size.height
            }

            if intrinsicSize.height > 100 {
                intrinsicSize.height = 100
            } else {
                lastIntrinsicSize = intrinsicSize
                hasLastIntrinsicSize = true
            }
        }

        return intrinsicSize
    }
}
