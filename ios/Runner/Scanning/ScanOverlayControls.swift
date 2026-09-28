import UIKit

protocol ScanOverlayControlsDelegate: AnyObject {
  func overlayDidTapStart()
  func overlayDidTapPause()
  func overlayDidTapReset()
  func overlayDidTapDone()
}

/// Native overlay for Start / Pause / Reset / Done + tracking feedback.
final class ScanOverlayControls: UIView {
  weak var delegate: ScanOverlayControlsDelegate?

  private let trackingLabel = UILabel()
  private let meshCountLabel = UILabel()
  private let statusLabel = UILabel()
  private let startButton = UIButton(type: .system)
  private let pauseButton = UIButton(type: .system)
  private let resetButton = UIButton(type: .system)
  private let doneButton = UIButton(type: .system)
  private let stack = UIStackView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  func updateTracking(_ text: String, level: String) {
    trackingLabel.text = text
    switch level {
    case "good":
      trackingLabel.textColor = UIColor(red: 0.55, green: 0.95, blue: 0.7, alpha: 1)
    case "warn":
      trackingLabel.textColor = UIColor(red: 1.0, green: 0.82, blue: 0.35, alpha: 1)
    default:
      trackingLabel.textColor = UIColor(red: 1.0, green: 0.45, blue: 0.4, alpha: 1)
    }
  }

  func updateMeshCount(_ count: Int) {
    meshCountLabel.text = count == 0
      ? "No mesh yet — point at nearby surfaces"
      : "Mesh anchors: \(count)"
  }

  func updateScanState(isRunning: Bool, isPaused: Bool, canFinish: Bool) {
    startButton.isEnabled = !isRunning || isPaused
    pauseButton.isEnabled = isRunning && !isPaused
    resetButton.isEnabled = isRunning || isPaused
    doneButton.isEnabled = canFinish
    statusLabel.text = {
      if !isRunning && !isPaused { return "Ready to scan" }
      if isPaused { return "Paused" }
      return "Scanning…"
    }()
  }

  func showError(_ message: String) {
    statusLabel.numberOfLines = 3
    statusLabel.text = message
    statusLabel.textColor = UIColor(red: 1.0, green: 0.45, blue: 0.4, alpha: 1)
  }

  func showCompleted(fileName: String) {
    statusLabel.numberOfLines = 2
    statusLabel.text = "Scan completed\n\(fileName)"
    statusLabel.textColor = UIColor(red: 0.55, green: 0.95, blue: 0.7, alpha: 1)
  }

  func clearError() {
    statusLabel.textColor = .white
  }

  private func setup() {
    backgroundColor = .clear
    isUserInteractionEnabled = true

    trackingLabel.font = .preferredFont(forTextStyle: .subheadline)
    trackingLabel.textColor = .white
    trackingLabel.numberOfLines = 2
    trackingLabel.text = "Waiting for AR session…"

    meshCountLabel.font = .preferredFont(forTextStyle: .footnote)
    meshCountLabel.textColor = UIColor.white.withAlphaComponent(0.85)
    meshCountLabel.text = "No mesh yet — point at nearby surfaces"

    statusLabel.font = .preferredFont(forTextStyle: .headline)
    statusLabel.textColor = .white
    statusLabel.text = "Ready to scan"

    configure(startButton, title: "Start", action: #selector(startTapped))
    configure(pauseButton, title: "Pause", action: #selector(pauseTapped))
    configure(resetButton, title: "Reset", action: #selector(resetTapped))
    configure(doneButton, title: "Done", action: #selector(doneTapped), prominent: true)

    let buttons = UIStackView(arrangedSubviews: [startButton, pauseButton, resetButton, doneButton])
    buttons.axis = .horizontal
    buttons.spacing = 10
    buttons.distribution = .fillEqually

    stack.axis = .vertical
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.addArrangedSubview(statusLabel)
    stack.addArrangedSubview(trackingLabel)
    stack.addArrangedSubview(meshCountLabel)
    stack.addArrangedSubview(buttons)

    let panel = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    panel.translatesAutoresizingMaskIntoConstraints = false
    panel.layer.cornerRadius = 16
    panel.clipsToBounds = true
    addSubview(panel)
    panel.contentView.addSubview(stack)

    NSLayoutConstraint.activate([
      panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      panel.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -12),
      stack.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: 14),
      stack.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -14),
    ])

    updateScanState(isRunning: false, isPaused: false, canFinish: false)
  }

  private func configure(_ button: UIButton, title: String, action: Selector, prominent: Bool = false) {
    button.setTitle(title, for: .normal)
    button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
    button.backgroundColor = prominent
      ? UIColor(red: 0.2, green: 0.65, blue: 0.85, alpha: 1)
      : UIColor.white.withAlphaComponent(0.18)
    button.setTitleColor(.white, for: .normal)
    button.setTitleColor(UIColor.white.withAlphaComponent(0.4), for: .disabled)
    button.layer.cornerRadius = 12
    button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
    button.addTarget(self, action: action, for: .touchUpInside)
  }

  @objc private func startTapped() { delegate?.overlayDidTapStart() }
  @objc private func pauseTapped() { delegate?.overlayDidTapPause() }
  @objc private func resetTapped() { delegate?.overlayDidTapReset() }
  @objc private func doneTapped() { delegate?.overlayDidTapDone() }
}
