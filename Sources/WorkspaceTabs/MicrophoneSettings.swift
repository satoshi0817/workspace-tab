import AppKit
import AVFoundation
import SwiftUI

struct MicrophoneSettings:View {
    @State private var status=AVCaptureDevice.authorizationStatus(for:.audio)
    private var label:String {
        switch status {
        case .authorized:return "許可済み"
        case .notDetermined:return "未確認（ページで録音を開始すると確認します）"
        case .denied:return "許可されていません"
        case .restricted:return "このMacの管理設定により制限されています"
        @unknown default:return "確認できません"
        }
    }
    var body:some View {
        Section("マイク・ミーティングノート") {
            LabeledContent("macOSのマイク権限",value:label)
            HStack {
                Button("macOSのマイク設定を開く") {
                    if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {NSWorkspace.shared.open(url)}
                }
                Button("状態を更新") {refresh()}
            }
            Text("Notionで文字起こしを開始したときに、macOSとサイトのマイク確認を許可してください。許可を変更した後はページを再読み込みします。反映されない場合は入力内容を保存してアプリを再起動してください。")
                .font(.callout).foregroundStyle(.secondary)
            Text("Web版の音声入力を使います。ほかのアプリのシステム音声を直接取り込む機能はありません。ヘッドホン使用中は相手の音声がマイクに入らない場合があります。")
                .font(.callout).foregroundStyle(.secondary)
        }.onAppear{refresh()}
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)){_ in refresh()}
    }
    private func refresh(){status=AVCaptureDevice.authorizationStatus(for:.audio)}
}
