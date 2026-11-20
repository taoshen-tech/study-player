import UIKit
import AVFoundation
import MediaPlayer

/// 自定义播放器：基于 AVPlayer + AVPlayerLayer，完全接管手势与控件。
/// 手势：单击显隐控件 / 双击左右快退快进 / 长按递进倍速快进 /
///       左半屏竖滑调亮度 / 右半屏竖滑调音量 / 横滑拖进度 / 全屏 / 锁屏
final class PlayerViewController: UIViewController {

    // MARK: - 数据源
    let videos: [AlistFile]
    let courseName: String
    var index: Int
    let store = StudyStore.shared

    /// 播放结束/退出时的进度回调（由外部保存）
    var onStateChange: ((_ path: String, _ pos: Double, _ duration: Double, _ finished: Bool) -> Void)?

    // MARK: - 播放器
    var player: AVPlayer!
    var playerLayer: AVPlayerLayer!
    var timeObserver: Any?
    var isSeeking = false
    var didFinish = false

    // MARK: - 控件
    let topBar = UIView()
    let bottomBar = UIView()
    let titleLabel = UILabel()
    let backButton = UIButton(type: .system)
    let lockButton = UIButton(type: .system)
    let playButton = UIButton(type: .system)
    let prevButton = UIButton(type: .system)
    let nextButton = UIButton(type: .system)
    let fullscreenButton = UIButton(type: .system)
    let currentLabel = UILabel()
    let totalLabel = UILabel()
    let slider = UISlider()
    let speedButton = UIButton(type: .system)
    let hud = PlayerHUD()
    let volumeView = MPVolumeView(frame: .zero)

    var controlsVisible = true
    var isLocked = false
    var hideTimer: Timer?
    var originalBrightness: CGFloat = UIScreen.main.brightness

    // 长按倍速
    var longPressTimer: Timer?
    var speedLevel = 0
    let speedSteps: [Float] = [2.0, 3.0, 4.0]

    // MARK: - Init
    init(course: String, videos: [AlistFile], index: Int) {
        self.courseName = course
        self.videos = videos
        self.index = index
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let t = timeObserver, let p = player { p.removeTimeObserver(t) }
        UIScreen.main.brightness = originalBrightness
    }

    // MARK: - 生命周期
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildPlayer()
        buildUI()
        addGestures()
        loadCurrent()
        forcedLayout()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    // MARK: - 播放器初始化
    func buildPlayer() {
        player = AVPlayer()
        playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.frame = view.bounds
        view.layer.insertSublayer(playerLayer, at: 0)

        // 后台音频
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        // 隐藏的音量滑杆，用于系统音量调节
        volumeView.isHidden = true
        view.addSubview(volumeView)

        weak var weakSelf = self
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { time in
            weakSelf?.onTime(time)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(onEnd), name: .AVPlayerItemDidPlayToEndTime, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer.frame = view.bounds
    }

    // MARK: - 加载当前视频
    func loadCurrent() {
        guard videos.indices.contains(index) else { return }
        let file = videos[index]
        didFinish = false
        titleLabel.text = file.displayName

        // 恢复进度
        let st = store.get(course: courseName).state(for: file.path)
        Task { [weak self] in
            guard let self else { return }
            let urlStr = await AlistService.shared.videoURL(path: file.path, fileName: file.name)
            guard let u = URL(string: urlStr) else { return }
            let item = AVPlayerItem(url: u)
            self.player.replaceCurrentItem(with: item)
            if st.position > 0, st.duration > 0 {
                let t = CMTime(seconds: st.position, preferredTimescale: 600)
                self.player.seek(to: t) { _ in
                    self.player.play()
                }
            } else {
                self.player.play()
            }
            // 更新状态为在看
            var watching = st
            watching.status = .watching
            watching.duration = st.duration
            self.store.update(course: self.courseName, path: file.path, state: watching)
        }
    }

    func onTime(_ time: CMTime) {
        guard !isSeeking, let item = player.currentItem else { return }
        let cur = time.seconds
        let dur = item.duration.seconds
        if dur.isFinite && dur > 0 {
            slider.value = Float(cur / dur)
            totalLabel.text = ChapterState.fmt(dur)
        }
        currentLabel.text = ChapterState.fmt(cur)
        hud.setProgress(cur: cur, duration: dur)

        // 自动标记已看（播到 95%）
        if dur > 0, cur / dur >= 0.95, !didFinish {
            didFinish = true
            markDone()
        }
    }

    @objc func onEnd() { didFinish = true; markDone() }

    func markDone() {
        guard videos.indices.contains(index) else { return }
        let file = videos[index]
        var st = store.get(course: courseName).state(for: file.path)
        st.status = .done
        st.position = player.currentItem?.duration.seconds ?? st.position
        st.updatedAt = Int64(Date().timeIntervalSince1970 * 1000)
        store.update(course: courseName, path: file.path, state: st)
        onStateChange?(file.path, st.position, st.duration, true)
        hud.show(text: "✓ 已标记已看")
    }

    // MARK: - 手势
    func addGestures() {
        let single = UITapGestureRecognizer(target: self, action: #selector(onSingleTap(_:)))
        let double = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        view.addGestureRecognizer(single)
        view.addGestureRecognizer(double)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(onLongPress(_:)))
        longPress.minimumPressDuration = 0.4
        longPress.delegate = self
        view.addGestureRecognizer(longPress)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    @objc func onSingleTap(_ g: UITapGestureRecognizer) {
        if isLocked {
            hud.show(text: "🔒 已锁定，点解锁按钮")
            return
        }
        toggleControls()
    }

    @objc func onDoubleTap(_ g: UITapGestureRecognizer) {
        if isLocked { return }
        let x = g.location(in: view).x
        let delta: Double = x < view.bounds.width / 2 ? -10 : 10
        seekBy(delta)
        hud.show(text: delta < 0 ? "⏪ 快退 10 秒" : "⏩ 快进 10 秒")
    }

    @objc func onLongPress(_ g: UILongPressGestureRecognizer) {
        if isLocked { return }
        switch g.state {
        case .began:
            speedLevel = 0
            applySpeed()
            longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.speedLevel < self.speedSteps.count - 1 {
                    self.speedLevel += 1
                    self.applySpeed()
                }
            }
            hud.show(text: "⏩ \(Int(speedSteps[0]))x 快进")
        case .ended, .cancelled, .failed:
            longPressTimer?.invalidate()
            longPressTimer = nil
            player.rate = 1.0
            hud.hide()
        default: break
        }
    }

    func applySpeed() {
        let s = speedSteps[speedLevel]
        player.rate = s
        hud.show(text: "⏩ \(Int(s))x 快进")
    }

    // 滑动：水平=进度，左半屏竖=亮度，右半屏竖=音量
    enum PanMode { case none, seek, brightness, volume }
    var panMode: PanMode = .none
    var panStart: CGPoint = .zero
    var panStartBrightness: CGFloat = 0
    var panStartVolume: Float = 0
    var panStartTime: Double = 0
    var panStartDuration: Double = 0

    @objc func onPan(_ g: UIPanGestureRecognizer) {
        if isLocked { return }
        let p = g.location(in: view)
        switch g.state {
        case .began:
            // 滑动一开始就取消长按倍速
            longPressTimer?.invalidate(); longPressTimer = nil
            player.rate = 1.0
            panStart = p
            panStartBrightness = UIScreen.main.brightness
            panStartVolume = currentVolume
            panStartTime = player.currentTime().seconds
            panStartDuration = player.currentItem?.duration.seconds ?? 0
            panMode = .none
        case .changed:
            let dx = p.x - panStart.x
            let dy = p.y - panStart.y
            if panMode == .none {
                if abs(dx) > abs(dy) && abs(dx) > 12 {
                    panMode = .seek
                    isSeeking = true
                } else if abs(dy) > 12 {
                    panMode = p.x < view.bounds.width / 2 ? .brightness : .volume
                }
            }
            switch panMode {
            case .seek:
                let sensitivity = panStartDuration / Double(max(view.bounds.width, 1)) * 1.5
                let target = (panStartTime + Double(dx) * sensitivity).clamped(to: 0...max(panStartDuration - 0.1, 0))
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
                hud.show(text: "\(ChapterState.fmt(target)) / \(ChapterState.fmt(panStartDuration))")
            case .brightness:
                let v = panStartBrightness - CGFloat(dy / view.bounds.height) * 1.2
                UIScreen.main.brightness = v.clamped(to: 0.05...1.0)
                hud.show(text: "☀️ 亮度 \(Int(UIScreen.main.brightness * 100))%", icon: .brightness, value: Float(UIScreen.main.brightness))
            case .volume:
                let v = panStartVolume - Float(dy / view.bounds.height) * 1.5
                setVolume(v.clamped(to: 0...1))
                hud.show(text: "🔊 音量 \(Int(currentVolume * 100))%", icon: .volume, value: currentVolume)
            case .none: break
            }
        case .ended, .cancelled:
            if panMode == .seek {
                isSeeking = false
                saveProgress()
            }
            panMode = .none
            hud.hide()
        default: break
        }
    }

    func setVolume(_ v: Float) {
        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.setValue(v, animated: false)
    }

    func seekBy(_ delta: Double) {
        guard let dur = player.currentItem?.duration.seconds, dur.isFinite else { return }
        let target = (player.currentTime().seconds + delta).clamped(to: 0...max(dur - 0.1, 0))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        saveProgress()
    }

    // MARK: - 控件显隐
    func toggleControls() {
        controlsVisible.toggle()
        UIView.animate(withDuration: 0.2) {
            self.topBar.alpha = self.controlsVisible ? 1 : 0
            self.bottomBar.alpha = self.controlsVisible ? 1 : 0
        }
        if controlsVisible { scheduleHide() }
    }

    func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self, self.player.rate > 0 else { return }
            UIView.animate(withDuration: 0.2) {
                self.topBar.alpha = 0
                self.bottomBar.alpha = 0
            }
            self.controlsVisible = false
        }
    }

    // MARK: - 进度保存
    func saveProgress() {
        guard videos.indices.contains(index) else { return }
        let file = videos[index]
        let cur = player.currentTime().seconds
        let dur = player.currentItem?.duration.seconds ?? 0
        var st = store.get(course: courseName).state(for: file.path)
        st.position = cur
        st.duration = dur
        st.status = .watching
        st.updatedAt = Int64(Date().timeIntervalSince1970 * 1000)
        store.update(course: courseName, path: file.path, state: st)
        onStateChange?(file.path, cur, dur, false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveProgress()
        Task { await store.flush(course: courseName) }
    }

    // MARK: - 按钮动作
    @objc func onBack() { dismiss(animated: true) }
    @objc func onPlayToggle() {
        if player.rate > 0 { player.pause(); playButton.setImage(UIImage(systemName: "play.fill"), for: .normal) }
        else { player.play(); playButton.setImage(UIImage(systemName: "pause.fill"), for: .normal) }
    }
    @objc func onPrev() { if index > 0 { index -= 1; saveProgress(); loadCurrent() } }
    @objc func onNext() { if index < videos.count - 1 { index += 1; saveProgress(); loadCurrent() } }
    @objc func onSlider(_ s: UISlider) {
        guard let dur = player.currentItem?.duration.seconds, dur.isFinite else { return }
        let target = Double(s.value) * dur
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }
    @objc func onSpeed() {
        let all: [Float] = [1.0, 1.25, 1.5, 2.0]
        let cur = all.firstIndex(where: { abs($0 - player.rate) < 0.01 }) ?? 0
        let next = all[(cur + 1) % all.count]
        player.rate = next
        speedButton.setTitle(String(format: "%.2gx", next), for: .normal)
        hud.show(text: "倍速 \(next)x")
    }
    @objc func onLock() {
        isLocked.toggle()
        lockButton.setImage(UIImage(systemName: isLocked ? "lock.fill" : "lock.open.fill"), for: .normal)
        hud.show(text: isLocked ? "🔒 已锁定" : "🔓 已解锁")
    }
    @objc func onFullscreen() {
        let app = UIApplication.shared.delegate as? AppDelegate
        if view.bounds.width < view.bounds.height {
            app?.orientationMask = .landscapeRight
            UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
        } else {
            app?.orientationMask = .portrait
            UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
        }
        UIView.animate(withDuration: 0.2) { self.view.layoutIfNeeded() }
    }

    // UI 构建放在 extension（见 PlayerViews.swift）
}

// MARK: - 手势代理：长按与滑动共存（滑动优先取消长按）
extension PlayerViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { !isLocked }
}
