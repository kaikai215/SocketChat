//
//  ViewController.swift
//  SocketChat
//
//  負責聊天畫面：狀態、訊息列表、輸入與傳送。
//  連線細節在 ChatSocket，這裡只根據它的回呼更新畫面。
//

import UIKit


class ViewController: UIViewController {

    @IBOutlet private weak var contentStackView: UIStackView!
    @IBOutlet private var contentBottomConstraint: NSLayoutConstraint!
    @IBOutlet private weak var tableView: UITableView!
    @IBOutlet private weak var statusDotView: UIView!
    @IBOutlet private weak var statusLabel: UILabel!
    @IBOutlet private weak var disconnectBanner: UIView!
    @IBOutlet private weak var typingLabel: UILabel!
    @IBOutlet private weak var messageTextField: UITextField!
    @IBOutlet private weak var sendButton: UIButton!

    /// 一則聊天訊息。isOutgoing 為 true 代表自己送的，氣泡靠右。
    private struct ChatMessage {
        let text: String
        let sentAt: Date
        let isOutgoing: Bool
    }

    private let socket = ChatSocket()
    private var connectionState: ChatConnectionState = .disconnected
    /// 畫面上的訊息。表格的每一列對應這裡的一筆。
    private var messages: [ChatMessage] = []

    private let emptyLabel: UILabel = {
        let label = UILabel()
        label.text = "傳一則訊息開始聊天"
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 16)
        return label
    }()

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        statusDotView.layer.cornerRadius = 4
        // 打字中那一行先留著高度，文字等之後有「對方正在輸入」再填。
        typingLabel.text = nil
        tableView.dataSource = self
        tableView.backgroundView = emptyLabel
        tableView.keyboardDismissMode = .interactive
        // 列高依氣泡裡的文字自動撐開。
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 80
        messageTextField.delegate = self
        messageTextField.addTarget(self, action: #selector(messageTextChanged), for: .editingChanged)
        sendButton.addTarget(self, action: #selector(sendButtonTapped), for: .touchUpInside)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        // [weak self]：畫面被釋放時不要再被這個閉包抓住，避免循環參考。
        // 回呼一律排到主執行緒再改畫面，避免背景執行緒碰到 Auto Layout。
        socket.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.apply(state)
            }
        }
        socket.onMessage = { [weak self] text in
            DispatchQueue.main.async {
                self?.appendIncoming(text)
            }
        }
        updateEmptyState()
        pinContentAboveKeyboard()
        apply(.connecting)
        socket.connect()
    }

    deinit {
        socket.disconnect()
    }

    /// 原本輸入列貼著安全區域底部。改貼鍵盤上方，鍵盤彈起時輸入列會跟著上去。
    private func pinContentAboveKeyboard() {
        contentBottomConstraint.isActive = false
        view.keyboardLayoutGuide.usesBottomSafeArea = true
        contentStackView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor).isActive = true
    }

    @objc private func messageTextChanged() {
        updateSendButtonState()
    }

    @objc private func sendButtonTapped() {
        sendCurrentMessage()
    }

    /// App 從背景回到前景時，如果當時沒連上，就再試一次。
    @objc private func appWillEnterForeground() {
        socket.connect()
    }

    /// 把連線狀態反映到上方圓點、文字和斷線橫幅。
    /// 斷線橫幅藏在 Stack View 裡，isHidden 為 true 時不會佔高度。
    private func apply(_ state: ChatConnectionState) {
        connectionState = state
        switch state {
        case .connecting:
            statusLabel.text = "連線中"
            statusDotView.backgroundColor = .systemOrange
            disconnectBanner.isHidden = true
        case .connected:
            statusLabel.text = "已連線"
            statusDotView.backgroundColor = .systemGreen
            disconnectBanner.isHidden = true
        case .disconnected:
            statusLabel.text = "已斷線"
            statusDotView.backgroundColor = .systemRed
            disconnectBanner.isHidden = false
        }
        updateSendButtonState()
    }

    /// 沒連上，或輸入是空白，傳送按鈕都不能按。
    private func updateSendButtonState() {
        let text = messageTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        sendButton.isEnabled = connectionState == .connected && !text.isEmpty
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = !messages.isEmpty
    }

    /// 自己的訊息先畫在右邊，再送給伺服器。
    /// 伺服器不會把這則字退回來，所以不會出現兩次。
    private func sendCurrentMessage() {
        let text = messageTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard connectionState == .connected, !text.isEmpty else { return }

        append(ChatMessage(text: text, sentAt: Date(), isOutgoing: true))
        messageTextField.text = nil
        updateSendButtonState()
        socket.send(text)
    }

    /// 從伺服器收到的字，是對方傳來的，氣泡靠左。
    private func appendIncoming(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        append(ChatMessage(text: trimmed, sentAt: Date(), isOutgoing: false))
    }

    /// 加進陣列後，只插入新的一列，並捲到最底。不用整張表重載。
    private func append(_ message: ChatMessage) {
        messages.append(message)
        updateEmptyState()
        let indexPath = IndexPath(row: messages.count - 1, section: 0)
        tableView.insertRows(at: [indexPath], with: .automatic)
        tableView.scrollToRow(at: indexPath, at: .bottom, animated: true)
    }
}

extension ViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        messages.count
    }

    /// 自己的訊息用靠右的 cell，對方的用靠左的 cell。
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let message = messages[indexPath.row]
        let time = timeFormatter.string(from: message.sentAt)

        if message.isOutgoing {
            let cell = tableView.dequeueReusableCell(
                withIdentifier: OutgoingMessageCell.reuseIdentifier,
                for: indexPath
            ) as! OutgoingMessageCell
            cell.configure(message: message.text, time: time)
            return cell
        }

        let cell = tableView.dequeueReusableCell(
            withIdentifier: IncomingMessageCell.reuseIdentifier,
            for: indexPath
        ) as! IncomingMessageCell
        cell.configure(message: message.text, time: time)
        return cell
    }
}

extension ViewController: UITextFieldDelegate {
    /// 鍵盤的送出鍵也走同一條傳送流程。回傳 false 代表不要收起鍵盤，方便連續打字。
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendCurrentMessage()
        return false
    }
}
