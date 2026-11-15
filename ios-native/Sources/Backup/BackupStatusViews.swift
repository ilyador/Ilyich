import SwiftUI

/// Observes transfer ticks here, rather than invalidating the Settings form or photo grid.
struct BackupSettingsLabel: View {
    @State private var backup = BackupStore.shared

    var body: some View {
        let statistics = backup.statistics
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text("Backup")
                Text(summary(statistics))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        } icon: {
            Image(systemName: "icloud.and.arrow.up")
        }
        .accessibilityElement(children: .combine)
    }

    private func summary(_ statistics: BackupStatistics) -> String {
        if statistics.preparingServerLibrary { return "Preparing server library" }
        if let selection = statistics.selectionProgress {
            if selection.unchecked > 0 { return "\(selection.unchecked.formatted()) awaiting duplicate check" }
            return "\(selection.backedUp.formatted()) verified · \(selection.pending.formatted()) to upload"
        }
        if statistics.phase == .discovering { return "Checking selected photos…" }
        return statistics.remaining > 0 ? "\(statistics.remaining.formatted()) items awaiting processing" : "Choose what to back up"
    }
}

/// Account history and unfinished work are separate counts, not a fabricated run percentage.
struct BackupStatisticsSummary: View {
    let statistics: BackupStatistics
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if let selection = statistics.selectionProgress {
            selectedCounts(selection)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(statistics.phase == .discovering ? "Checking selected photos…" : "Selection not checked yet")
                    .font(.subheadline.weight(.medium))
                LabeledContent("Awaiting processing", value: statistics.remaining.formatted())
                LabeledContent("Previously verified", value: statistics.backedUp.formatted())
                    .foregroundStyle(.secondary)
            }.monospacedDigit()
        }
        if statistics.preparingServerLibrary {
            Text("Backup is waiting while your server checks archived files for existing copies.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func selectedCounts(_ selection: SelectionProgress) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                metric("Selected", value: selection.total)
                Spacer(minLength: 0)
                metric("Verified", value: selection.backedUp)
                Spacer(minLength: 0)
                metric("To upload", value: selection.pending)
            }.fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 10) {
                countRow("Selected", value: selection.total)
                countRow("Verified", value: selection.backedUp)
                countRow("To upload", value: selection.pending)
            }.monospacedDigit()
        }
        .accessibilityIdentifier("backup.statistics")
        if selection.unchecked > 0 {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Not checked yet", value: selection.unchecked.formatted())
                    .monospacedDigit()
                Text("These photos may already be on your server.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func countRow(_ title: LocalizedStringKey, value: Int) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value.formatted()).font(.headline).monospacedDigit().lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(value.formatted()).font(.headline).monospacedDigit().lineLimit(1)
            }.accessibilityElement(children: .combine)
        }
    }

    private func metric(_ title: LocalizedStringKey, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted()).font(.title3.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.formatted())
    }
}

/// These bytes belong to active upload parts. They reset as photos (or Live Photo parts) finish.
struct BackupTransferDetail: View {
    let progress: TransferProgress
    @AppStorage(AppearanceAccent.storageKey) private var accentName = AppearanceAccent.design.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Current uploads").font(.caption.weight(.medium))
                    Text(bytes).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Current uploads").font(.caption.weight(.medium))
                    Text(bytes).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .tint((AppearanceAccent(rawValue: accentName) ?? .design).selectionTint)
                    .accessibilityLabel("Current uploads")
                    .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress.sentBytes > 0 ? "Uploading…" : "Preparing files…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("backup.currentUploads")
    }

    private var bytes: String {
        let sent = ByteCountFormatter.string(fromByteCount: progress.sentBytes, countStyle: .file)
        guard let expected = progress.expectedBytes else { return sent }
        return "\(sent) of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))"
    }
}

/// A small live status above the library's bottom controls. Only this subtree reads backup ticks.
struct BackupActivityIndicator: View {
    @State private var backup = BackupStore.shared
    let openBackup: () -> Void

    var body: some View {
        let statistics = backup.statistics
        if statistics.remaining > 0 || statistics.phase == .running || statistics.phase == .discovering {
            BackupActivityBar(statistics: statistics, openBackup: openBackup)
                .padding(.bottom, 8)
        }
    }
}

struct BackupActivityBar: View {
    let statistics: BackupStatistics
    let openBackup: () -> Void
    @AppStorage(AppearanceAccent.storageKey) private var accentName = AppearanceAccent.design.rawValue
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: openBackup) {
            VStack(alignment: .leading, spacing: 7) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(compactTitle).font(.subheadline.weight(.semibold))
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(true)
                        }
                        if statistics.phase == .discovering {
                            Text("Finding photos and videos…").font(.caption)
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(visibleCountLabel).font(.caption)
                                Text(visibleRemaining.formatted())
                                    .font(.headline).monospacedDigit().lineLimit(1)
                            }
                        }
                    }
                } else {
                  HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.body)
                        .foregroundStyle((AppearanceAccent(rawValue: accentName) ?? .design).selectionTint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.subheadline.weight(.semibold))
                        Text(detail).font(.caption).foregroundStyle(.primary.opacity(0.85)).monospacedDigit()
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                  }
                }
                if let selection = statistics.selectionProgress, let fraction = selection.fraction,
                   selection.remaining > 0 || statistics.remaining == 0 {
                    ProgressView(value: fraction)
                        .tint((AppearanceAccent(rawValue: accentName) ?? .design).selectionTint)
                        .accessibilityLabel("Selected photos backed up")
                        .accessibilityValue("\(selection.backedUp.formatted()) of \(selection.total.formatted())")
                } else if let progress = statistics.currentTransfer, progress.expectedBytes != nil || progress.sentBytes > 0 {
                    BackupTransferDetail(progress: progress)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        .accessibilityIdentifier("backup.activity")
        .accessibilityHint("Opens backup settings")
    }

    private var compactTitle: String {
        if statistics.phase == .discovering { return "Checking Photos…" }
        if statistics.intent == .paused { return "Paused" }
        if statistics.preparingServerLibrary { return "Preparing library" }
        if isChecking { return "Checking backups" }
        if statistics.phase == .running { return "Backing up" }
        return statistics.failed > 0 && statistics.queued == 0 ? "Needs retry" : "Backup waiting"
    }

    private var visibleRemaining: Int {
        guard let selection = statistics.selectionProgress else { return statistics.remaining }
        if selection.remaining == 0 && statistics.remaining > 0 { return statistics.remaining }
        return selection.unchecked > 0 ? selection.unchecked : selection.pending
    }

    private var visibleCountLabel: String {
        guard let selection = statistics.selectionProgress else { return "To process" }
        if selection.remaining == 0 && statistics.remaining > 0 { return "To process" }
        return selection.unchecked > 0 ? "Not checked" : "To upload"
    }

    private var isChecking: Bool {
        statistics.phase == .running && (statistics.currentTransfer?.sentBytes ?? 0) == 0 && (statistics.checkingExistingBackups ||
            ((statistics.selectionProgress?.unchecked ?? 0) > 0 && statistics.currentTransfer?.expectedBytes == nil))
    }

    private var title: String {
        if statistics.phase == .discovering { return "Checking Photos…" }
        if statistics.intent == .paused { return "Backup paused" }
        if statistics.preparingServerLibrary { return "Preparing server library" }
        if isChecking { return "Checking existing backups" }
        if statistics.phase == .running { return "Backing up" }
        if statistics.failed > 0 && statistics.queued == 0 { return "Backup needs attention" }
        return statistics.activity
    }

    private var detail: String {
        if statistics.phase == .discovering {
            return "\(statistics.backedUp.formatted()) previously verified"
        }
        if let selection = statistics.selectionProgress {
            if selection.remaining == 0, statistics.remaining > 0 {
                return "Selected photos backed up · \(statistics.remaining.formatted()) other items to process"
            }
            if selection.unchecked > 0 {
                return "\(selection.backedUp.formatted()) verified · \(selection.unchecked.formatted()) not checked"
            }
            return "\(selection.backedUp.formatted()) verified · \(selection.pending.formatted()) to upload"
        }
        if statistics.failed > 0 {
            return "\(statistics.remaining.formatted()) to process · \(statistics.failed.formatted()) need retry"
        }
        return "\(statistics.remaining.formatted()) to process · \(statistics.backedUp.formatted()) previously verified"
    }

    private var symbol: String {
        if statistics.phase == .discovering { return "photo.stack" }
        if statistics.intent == .paused { return "pause.circle" }
        if statistics.preparingServerLibrary { return "clock.arrow.circlepath" }
        if isChecking { return "checkmark.icloud" }
        if statistics.failed > 0 && statistics.queued == 0 { return "exclamationmark.icloud" }
        return "icloud.and.arrow.up"
    }
}
