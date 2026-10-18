import SwiftUI
import UIKit

struct OCRPhotoReader: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let asset: Asset
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var text: [RecognizedText] = []
    @State private var selection = Set<String>()
    @State private var failure: String?
    @State private var copied = false
    @State private var retry = 0
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    ZoomablePhoto(image: image, resetZoom: false, onTap: { _ in }, onDismiss: { dismiss() }, onZoom: {},
                                  recognizedText: text, textSelection: selection, onTextSelection: { id in
                        if !selection.insert(id).inserted { selection.remove(id) }; copied = false
                    })
                } else if let failure {
                    ContentUnavailableView { Label("Couldn’t load text", systemImage: "text.viewfinder") }
                        description: { Text(failure) } actions: { Button("Retry") { retry += 1 } }
                } else { ProgressView("Loading recognized text") }
            }
            .navigationTitle("Text in photo").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selection.count == text.count ? "Deselect all" : "Select all") {
                        selection = selection.count == text.count ? [] : Set(text.map(\.id)); copied = false
                    }.disabled(text.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Text(text.isEmpty && image != nil ? "No recognized text in this photo" : "Tap text to select. Pinch to zoom.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = text.filter { selection.contains($0.id) }.map(\.text).joined(separator: "\n")
                        copied = true
                    }.disabled(selection.isEmpty).buttonStyle(.glass)
                }.padding(16).background(.regularMaterial)
            }
            .task(id: retry) {
                failure = nil
                do {
                    async let words = api.assetOCR(id: asset.id)
                    async let photo = pipeline.image(for: asset, size: .preview, pixelSize: 3000)
                    text = try await words
                    image = try await photo.uiImage
                } catch is CancellationError { } catch { failure = error.localizedDescription }
            }
        }.preferredColorScheme(.dark)
    }
}

/// Image-relative quads live inside the zoomed image view, so their coordinates
/// follow aspect fit, pan, rotation layout and resolution changes together.
@MainActor final class OCRSelectionOverlay: UIView {
    private var words: [RecognizedText] = []
    private var selection = Set<String>()
    private var onSelect: ((String) -> Void)?
    private var shapes: [(String, CAShapeLayer)] = []
    private var signature = ""
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func configure(_ words: [RecognizedText], selection: Set<String>, onSelect: ((String) -> Void)?) {
        let next = words.map { "\($0.id):\($0.text):\($0.x1),\($0.y1),\($0.x2),\($0.y2),\($0.x3),\($0.y3),\($0.x4),\($0.y4)" }.joined(separator: "|")
        self.onSelect = onSelect; isHidden = words.isEmpty
        if signature != next {
            signature = next; self.words = words
            shapes.forEach { $0.1.removeFromSuperlayer() }
            shapes = words.map { word in let shape = CAShapeLayer(); layer.addSublayer(shape); return (word.id, shape) }
            setNeedsLayout()
        }
        if self.selection != selection { setNeedsLayout() }
        self.selection = selection
        for (id, shape) in shapes {
            shape.strokeColor = UIColor.systemCyan.cgColor
            shape.fillColor = UIColor.systemCyan.withAlphaComponent(selection.contains(id) ? 0.4 : 0.08).cgColor
            shape.lineWidth = selection.contains(id) ? 2 : 1
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        accessibilityElements = words.enumerated().map { index, word in
            let points = [CGPoint(x: word.x1, y: word.y1), CGPoint(x: word.x2, y: word.y2), CGPoint(x: word.x3, y: word.y3), CGPoint(x: word.x4, y: word.y4)]
            let path = UIBezierPath()
            if points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) {
                for (index, point) in points.enumerated() {
                    let point = CGPoint(x: point.x * bounds.width, y: point.y * bounds.height)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }; path.close()
            }
            shapes[index].1.path = path.cgPath
            let element = OCRTextAccessibility(container: self) { [weak self] in self?.onSelect?(word.id) }
            element.accessibilityLabel = word.text
            element.accessibilityTraits = selection.contains(word.id) ? [.button, .selected] : .button
            element.accessibilityFrameInContainerSpace = path.bounds
            return element
        }
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        !isHidden && shapes.contains { $0.1.path?.contains(point) == true }
    }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        if let shape = shapes.first(where: { $0.1.path?.contains(point) == true }) { onSelect?(shape.0) }
    }
}

@MainActor private final class OCRTextAccessibility: UIAccessibilityElement {
    let activate: () -> Void
    init(container: Any, activate: @escaping () -> Void) { self.activate = activate; super.init(accessibilityContainer: container) }
    override func accessibilityActivate() -> Bool { activate(); return true }
}
