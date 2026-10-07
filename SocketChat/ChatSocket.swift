//
//  ChatSocket.swift
//  SocketChat
//
//  負責跟本機的 WebSocket 伺服器連線、送出文字、接收文字。
//  畫面不要直接操作 URLSession，只要聽 onStateChange 和 onMessage。
//

import Foundation

/// 連線的三個階段。畫面用它決定狀態文字和傳送按鈕能不能按。
// nonisolated ：「這個 Enum 不受任何執行區或 Actor 的隔離限制，它在任何地方都可以被自由讀取和使用
// Sendable：讓這個 Enum 遵守 Sendable 協定，這是一個純粹的值型別（Value Type），它安全無虞，可以放心地在不同的執行緒之間安全傳遞
nonisolated enum ChatConnectionState: Sendable {
    case connecting
    case connected
    case disconnected
}

final class ChatSocket: NSObject, URLSessionWebSocketDelegate {
    /// 連線狀態改變時通知畫面。例如連上了、斷線了。
    var onStateChange: ((ChatConnectionState) -> Void)?
    /// 收到「別人」傳來的文字時通知畫面。伺服器不會把自己剛送出的字再傳回來。
    var onMessage: ((String) -> Void)?

    /// 模擬器和 Mac 共用 127.0.0.1，所以連得到本機的 Node 伺服器。
    private let url = URL(string: "ws://127.0.0.1:8080")!
    /// URLSession 負責建立連線
    private var session: URLSession?
    /// 真正的 WebSocket 連線。nil 代表目前沒有連線
    private var task: URLSessionWebSocketTask?
    /// 斷線後等待 2 秒再重連的工作。避免每秒狂連
    private var reconnectTask: Task<Void, Never>?
    /// true 才會在斷線後自動重連。使用者離開畫面時會把它關掉
    private var shouldReconnect = false
    private var state: ChatConnectionState = .disconnected

    /// 開始連線。如果已經有連線，就不要再開一條。
    func connect() {
        shouldReconnect = true
        guard task == nil else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        open()
    }

    /// 主動斷線，而且不要再自動重連。
    func disconnect() {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        closeActiveTask()
        session?.invalidateAndCancel()
        session = nil
        updateState(.disconnected)
    }

    /// 把文字送給伺服器。伺服器會轉給其他連線，不會退回給自己。
    func send(_ text: String) {
        guard let task else { return }
        Task {
            do {
                try await task.send(.string(text))
            } catch {
                // send 的錯誤可能在背景執行緒回來，改畫面要回主執行緒。
                self.performOnMain {
                    self.handleFailure()
                }
            }
        }
    }

    /// 建立 URLSessionWebSocketTask 並開始連線
    /// resume() 才會真正連出去；只建立 task 還不會連
    private func open() {
        if session == nil {
            // delegateQueue 用 main，連上／關閉的回呼才會在主執行緒，方便改畫面。
            session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        }
        updateState(.connecting)
        let task = session!.webSocketTask(with: url)
        self.task = task
        task.resume()
        listen(to: task)
    }

    /// receive() 每次只拿「一則」訊息，所以要一直迴圈呼叫，才聽得到下一則。
    /// await 回來時常常在背景執行緒，不能在那裡改 UITableView 或約束。
    /// 用 === 確認還是同一條連線，避免舊連線斷線時把新連線也關掉。
    private func listen(to task: URLSessionWebSocketTask) {
        Task {
            do {
                while self.task === task {
                    let message = try await task.receive()
                    let text = self.text(from: message)
                    self.performOnMain {
                        guard self.task === task else { return }
                        if let text {
                            self.onMessage?(text)
                        }
                    }
                }
            } catch {
                self.performOnMain {
                    guard self.task === task else { return }
                    self.handleFailure()
                }
            }
        }
    }

    /// 保證後續的畫面更新發生在主執行緒。
    private func performOnMain(_ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async(execute: action)
    }

    /// WebSocket 訊息可能是文字，也可能是 Data。這裡統一轉成 String。
    private func text(from message: URLSessionWebSocketTask.Message) -> String? {
        switch message {
        case .string(let text):
            return text
        case .data(let data):
            return String(data: data, encoding: .utf8)
        @unknown default:
            return nil
        }
    }

    private func handleFailure() {
        guard task != nil else { return }
        closeActiveTask()
        updateState(.disconnected)
        scheduleReconnect()
    }

    private func closeActiveTask() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// 斷線後等 2 秒再連。同一時間只排一次，避免重複連線
    private func scheduleReconnect() {
        guard shouldReconnect, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            // 畫面如果已經被釋放，self 會是 nil，就不要再連。
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            guard self.shouldReconnect, self.task == nil else { return }
            self.open()
        }
    }

    /// 狀態沒變就不要通知畫面，避免重複刷新
    private func updateState(_ newState: ChatConnectionState) {
        guard !isSameState(state, newState) else { return }
        state = newState
        onStateChange?(newState)
    }

    private func isSameState(_ lhs: ChatConnectionState, _ rhs: ChatConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.connecting, .connecting), (.connected, .connected), (.disconnected, .disconnected):
            return true
        default:
            return false
        }
    }

    /// 握手成功，這時才算真正已連線，可以開始送字
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,didOpenWithProtocol _: String?) {
        guard webSocketTask === task else { return }
        updateState(.connected)
    }

    /// 連線被關掉。如果是目前這一條，就更新成斷線並安排重連
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return }
        task = nil
        updateState(.disconnected)
        scheduleReconnect()
    }
}
