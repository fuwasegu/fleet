import SwiftUI
import Foundation

/// スリープ防止 (`caffeinate -dimsu -t <秒>`) の制御。
/// プロセスが終了(タイムアウト失効/kill)したら isOn を自動的に false に戻す
/// (kanban_ui.fsl の CaffeinateToggleSynced: トグルON ⇒ 実プロセス生存)。
@MainActor
@Observable
final class CaffeineController {
    private(set) var isOn = false
    var timeoutSeconds = 86400          // 既定 24 時間
    private var process: Process?

    func toggle() {
        if isOn { stop() } else { start() }
    }

    func start() {
        stop()                          // 二重起動を避け、常に現在の秒数で起動
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-dimsu", "-t", String(max(1, timeoutSeconds))]
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.isOn = false      // 失効/終了で自動 OFF
                self?.process = nil
            }
        }
        do {
            try p.run()
            process = p
            isOn = true
        } catch {
            process = nil
            isOn = false
        }
    }

    func stop() {
        if let p = process {
            p.terminationHandler = nil
            p.terminate()
        }
        process = nil
        isOn = false
    }
}

struct CaffeinePopover: View {
    @Bindable var caffeine: CaffeineController

    private let presets: [(String, Int)] = [("1時間", 3600), ("8時間", 28800), ("24時間", 86400)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("スリープ防止 (caffeinate)").font(.headline)

            HStack {
                Text("タイムアウト(秒)")
                Spacer()
                TextField("秒", value: $caffeine.timeoutSeconds, format: .number)
                    .frame(width: 100)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                ForEach(presets, id: \.1) { label, secs in
                    Button(label) { caffeine.timeoutSeconds = secs }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Divider()

            HStack(spacing: 6) {
                Circle().fill(caffeine.isOn ? .green : .secondary).frame(width: 8, height: 8)
                Text(caffeine.isOn ? "ON" : "OFF").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(caffeine.isOn ? "OFF にする" : "ON にする") { caffeine.toggle() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}
