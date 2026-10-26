import SwiftUI
import AppKit
import DoctorCore

final class DoctorAppDelegate: NSObject, NSApplicationDelegate {
    weak var state: DoctorState?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if state?.cleaning == true {
            state?.notice = "正在完成已确认的移动操作，请等处理结束后退出。"
            return .terminateCancel
        }
        return .terminateNow
    }
}

@main
struct DOJAMacDoctorApp: App {
    @NSApplicationDelegateAdaptor(DoctorAppDelegate.self) private var delegate
    @StateObject private var state = DoctorState()
    var body: some Scene {
        WindowGroup("DOJA Mac Doctor", id: "doctor") {
            DoctorMainView().environmentObject(state).preferredColorScheme(.dark)
                .task { delegate.state = state; state.startAutomaticallyIfNeeded() }
        }
        .defaultSize(width: 1220, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("增加检查目录…") { state.chooseDirectory() }.keyboardShortcut("o").disabled(state.scanning || state.cleaning || state.cleanupPreparation)
                Button("重新自动扫描") { state.rescanAutomatic() }.keyboardShortcut("r").disabled(state.scanning || state.cleaning || state.cleanupPreparation)
                Button("导出诊断报告…") { state.exportReport() }.keyboardShortcut("e").disabled(state.result == nil || state.scanning || state.cleaning || state.cleanupPreparation)
            }
        }
        MenuBarExtra {
            DoctorMenuView().environmentObject(state)
        } label: {
            Label(DoctorFormat.bytes(state.sample.availableBytes), systemImage: "internaldrive")
        }
        .menuBarExtraStyle(.window)
    }
}

struct DoctorMenuView: View {
    @EnvironmentObject var state: DoctorState
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DOJA Mac Doctor").font(.headline)
            Text("内部盘剩余").foregroundStyle(.secondary)
            Text(DoctorFormat.bytes(state.sample.availableBytes)).font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle((state.sample.availableBytes ?? Int64.max) < 3_000_000_000 ? Color.doctorRed : Color.doctorMint)
            Text("内存压力：\(state.sample.memoryPressure) · Swap：\(DoctorFormat.bytes(state.sample.swapUsedBytes))").font(.caption)
            Text(state.scanning ? "正在自动检查；只读取文件属性。" : "每分钟刷新容量；仅处理你勾选并确认的缓存。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("打开诊断窗口") { openWindow(id: "doctor"); NSApp.activate(ignoringOtherApps: true) }
            Button("刷新容量") { state.refreshSample() }
            Button("退出 DOJA Mac Doctor") { NSApp.terminate(nil) }
        }
        .padding(20).frame(width: 330).preferredColorScheme(.dark)
    }
}
