import Cocoa

class StatusIconService {
    static let shared = StatusIconService()

    // Cached status images - precomputed for each BuildStatus
    private var cachedStatusImages: [BuildStatus: NSImage] = [:]
    private var loadingImage: NSImage?

    // Cached animation frames
    private var cachedRunningFrames: [NSImage] = []
    private var cachedLoadingFrames: [NSImage] = []
    private let totalFrames = 36

    private init() {
        // Regenerate cached frames when appearance changes (light/dark mode)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(appearanceDidChange),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
        refreshCache()
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func appearanceDidChange() {
        refreshCache()
    }

    private func refreshCache() {
        cacheStatusImages()
        cacheAnimationFrames()
    }

    func getStatusImage(for status: BuildStatus) -> NSImage? {
        return cachedStatusImages[status]
    }

    func getLoadingImage() -> NSImage? {
        return loadingImage
    }

    func getRunningFrame(index: Int) -> NSImage? {
        guard !cachedRunningFrames.isEmpty else { return nil }
        return cachedRunningFrames[index % cachedRunningFrames.count]
    }

    func getLoadingFrame(index: Int) -> NSImage? {
        guard !cachedLoadingFrames.isEmpty else { return nil }
        return cachedLoadingFrames[index % cachedLoadingFrames.count]
    }

    private func cacheStatusImages() {
        cachedStatusImages.removeAll()
        for status in [
            BuildStatus.success, .running, .failed, .error, .failing,
            .onHold, .canceled, .notRun, .unknown,
        ] {
            if let image = createStatusImage(symbolName: status.symbolName, color: status.color) {
                cachedStatusImages[status] = image
            }
        }
        loadingImage = createStatusImage(symbolName: "circle.dotted", color: nil)
    }

    private func cacheAnimationFrames() {
        cachedRunningFrames = (0..<totalFrames).map { frame in
            let angle = CGFloat(frame) * (.pi * 2 / CGFloat(totalFrames))
            return createRotatedCImage(angle: angle, color: .systemOrange)
        }
        cachedLoadingFrames = (0..<totalFrames).map { frame in
            let phase = CGFloat(frame) / CGFloat(totalFrames)
            return createDottedCircleWithPulsingDot(phase: phase)
        }
    }

    private func createStatusImage(symbolName: String, color: NSColor?) -> NSImage? {
        guard let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "CircleCI Status") else {
            return nil
        }

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        guard let configuredImage = baseImage.withSymbolConfiguration(config) else {
            return nil
        }

        if let color = color {
            guard let img = configuredImage.copy() as? NSImage else { return nil }
            img.lockFocus()
            color.set()
            let imageRect = NSRect(origin: .zero, size: img.size)
            imageRect.fill(using: .sourceAtop)
            img.unlockFocus()
            img.isTemplate = false
            return img
        } else {
            guard let img = configuredImage.copy() as? NSImage else { return nil }
            img.isTemplate = true
            return img
        }
    }

    private func createDottedCircleWithPulsingDot(phase: CGFloat) -> NSImage {
        guard let baseImage = NSImage(systemSymbolName: "circle.dotted", accessibilityDescription: nil) else {
            return NSImage()
        }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        guard let symbolImage = baseImage.withSymbolConfiguration(config) else {
            return NSImage()
        }

        guard let image = symbolImage.copy() as? NSImage else {
            return NSImage()
        }

        image.lockFocus()

        NSColor.labelColor.set()
        let imageRect = NSRect(origin: .zero, size: image.size)
        imageRect.fill(using: .sourceAtop)

        let pulseAlpha = 0.3 + 0.7 * (0.5 + 0.5 * sin(phase * .pi * 2))
        let greenDotRadius: CGFloat = 2.0
        let centerX = floor(image.size.width / 2)
        let centerY = floor(image.size.height / 2)
        NSColor.systemGreen.withAlphaComponent(pulseAlpha).setFill()
        let greenDotRect = CGRect(
            x: centerX - greenDotRadius,
            y: centerY - greenDotRadius,
            width: greenDotRadius * 2,
            height: greenDotRadius * 2
        )
        NSBezierPath(ovalIn: greenDotRect).fill()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func createRotatedCImage(angle: CGFloat, color: NSColor?) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.rotate(by: angle)
        context.translateBy(x: -size.width / 2, y: -size.height / 2)

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius: CGFloat = 6
        let lineWidth: CGFloat = 2.5

        let drawColor = color ?? NSColor.black
        context.setStrokeColor(drawColor.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)

        context.addArc(
            center: center, radius: radius, startAngle: .pi * 0.25, endAngle: .pi * 1.75, clockwise: true)
        context.strokePath()

        image.unlockFocus()
        image.isTemplate = (color == nil)
        return image
    }
}
