import SwiftUI
import UIKit
import XCTest
@testable import Ilyich

@MainActor final class BackupStatusSnapshotTests: XCTestCase {
    func testFixtureSnapshotsBackupStatusComponentsAgainstPhotoBackdrop() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalAccent = UserDefaults.standard.object(forKey: AppearanceAccent.storageKey)
        UserDefaults.standard.set(AppearanceAccent.design.rawValue, forKey: AppearanceAccent.storageKey)
        defer {
            if let originalAccent { UserDefaults.standard.set(originalAccent, forKey: AppearanceAccent.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: AppearanceAccent.storageKey) }
        }

        // Reproduce the misleading whole-library case: no missing remote files have been
        // proven, so thousands of unchecked items must not look like queued new uploads.
        let snapshot = TransferSnapshot(intent: .paused, phase: .idle, remaining: 18_462, confirmed: 49,
                                        failed: 0, fileProgress: nil, bytesSent: 0, bytesExpected: 0,
                                        bytesPerSecond: nil, lastMessage: nil, activity: "Backup paused",
                                        backupPhase: .idle,
                                        selectionProgress: SelectionProgress(total: 18_511, backedUp: 49, pending: 0,
                                                                             checkedAt: Date(timeIntervalSince1970: 1_794_768_000)))
        let statistics = BackupStatistics(snapshot: snapshot)
        XCTAssertEqual(statistics.backedUp, 49)
        XCTAssertEqual(statistics.selectionProgress?.pending, 0)
        XCTAssertEqual(statistics.selectionProgress?.unchecked, 18_462)
        XCTAssertNil(statistics.selectionProgress?.fraction)

        let appearances: [(String, ColorScheme, DynamicTypeSize)] = [
            ("light", .light, .large),
            ("dark", .dark, .large),
            ("accessibility-xxxl", .light, .accessibility5),
        ]
        for (name, scheme, typeSize) in appearances {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            window.rootViewController = UIHostingController(rootView:
                BackupStatusSnapshotFixture(statistics: statistics, appearance: scheme, typeSize: typeSize)
                    .appControlAppearance()
            )
            window.makeKeyAndVisible()
            window.rootViewController?.view.setNeedsLayout()
            window.rootViewController?.view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))

            var hierarchyDrawn = false
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let image = renderer.image { _ in
                hierarchyDrawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(hierarchyDrawn, "The " + name + " fixture must render as a UIKit view hierarchy.")
            let attachment = XCTAttachment(image: image)
            attachment.name = "attachmentsFixture — backup components — " + name
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
            window.rootViewController = nil
        }
    }
}

private struct BackupStatusSnapshotFixture: View {
    let statistics: BackupStatistics
    let appearance: ColorScheme
    let typeSize: DynamicTypeSize

    var body: some View {
        ZStack {
            Image(uiImage: Self.photoBackdrop)
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.08), .black.opacity(0.34)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                Form {
            Section {
                        BackupStatisticsSummary(statistics: statistics)
                        if let progress = statistics.currentTransfer { BackupTransferDetail(progress: progress) }
                    } header: {
                        Text("Backup")
                    } footer: {
                        Text("Fixture counts for layout review only.")
                    }
                }
                .scrollContentBackground(.hidden)
                .background(.clear)

                BackupActivityBar(statistics: statistics, openBackup: {})
                    .padding(.horizontal, 18)
                    .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(appearance)
        .dynamicTypeSize(typeSize)
    }

    /// A deterministic landscape-like backdrop keeps the status components legible over image color.
    private static let photoBackdrop: UIImage = {
        let size = CGSize(width: 393, height: 852)
        return UIGraphicsImageRenderer(size: size).image { context in
            let bounds = CGRect(origin: .zero, size: size)
            UIColor(red: 0.28, green: 0.53, blue: 0.69, alpha: 1).setFill()
            context.fill(bounds)
            UIColor(red: 0.91, green: 0.66, blue: 0.35, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 250, y: 124, width: 78, height: 78)).fill()
            let farHill = UIBezierPath()
            farHill.move(to: CGPoint(x: 0, y: 420))
            farHill.addCurve(to: CGPoint(x: size.width, y: 390), controlPoint1: CGPoint(x: 120, y: 300), controlPoint2: CGPoint(x: 260, y: 500))
            farHill.addLine(to: CGPoint(x: size.width, y: size.height))
            farHill.addLine(to: CGPoint(x: 0, y: size.height))
            farHill.close()
            UIColor(red: 0.20, green: 0.36, blue: 0.30, alpha: 1).setFill()
            farHill.fill()
            let nearHill = UIBezierPath()
            nearHill.move(to: CGPoint(x: 0, y: 560))
            nearHill.addCurve(to: CGPoint(x: size.width, y: 510), controlPoint1: CGPoint(x: 120, y: 430), controlPoint2: CGPoint(x: 250, y: 640))
            nearHill.addLine(to: CGPoint(x: size.width, y: size.height))
            nearHill.addLine(to: CGPoint(x: 0, y: size.height))
            nearHill.close()
            UIColor(red: 0.12, green: 0.25, blue: 0.21, alpha: 1).setFill()
            nearHill.fill()
        }
    }()
}
