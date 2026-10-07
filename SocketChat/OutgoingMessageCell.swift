//
//  OutgoingMessageCell.swift
//  SocketChat
//
//  Created by kai on 2026/10/6.
//

import UIKit

final class OutgoingMessageCell: UITableViewCell {
    static let reuseIdentifier = "OutgoingMessageCell"

    @IBOutlet private(set) var bubbleView: UIView!
    @IBOutlet private(set) var messageLabel: UILabel!
    @IBOutlet private(set) var timeLabel: UILabel!

    override func awakeFromNib() {
        super.awakeFromNib()
        selectionStyle = .none
        bubbleView.layer.cornerRadius = 16
        bubbleView.layer.masksToBounds = true
    }

    func configure(message: String, time: String) {
        messageLabel.text = message
        timeLabel.text = time
    }
}
