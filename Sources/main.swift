import Cocoa
import Network
import Darwin
import UniformTypeIdentifiers

// MARK: - CPU 사용률 샘플러

final class CPUSampler {
    private var prevTotal: Double = 0
    private var prevIdle: Double = 0

    func usage() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let user = Double(info.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3)
        let total = user + system + idle + nice

        let totalDelta = total - prevTotal
        let idleDelta = idle - prevIdle
        prevTotal = total
        prevIdle = idle

        guard totalDelta > 0 else { return nil }
        return (1.0 - idleDelta / totalDelta) * 100.0
    }
}

// MARK: - 네트워크 속도 샘플러

final class NetSampler {
    private var prevIn: UInt64 = 0
    private var prevOut: UInt64 = 0
    private var lastTime = Date()
    private var primed = false

    /// 초당 바이트 (다운, 업). 첫 호출은 기준값만 잡고 nil.
    func sample() -> (down: Double, up: Double)? {
        let (inB, outB) = readBytes()
        let now = Date()
        let dt = now.timeIntervalSince(lastTime)
        defer { prevIn = inB; prevOut = outB; lastTime = now }
        guard primed, dt > 0 else { primed = true; return nil }
        let down = inB >= prevIn ? Double(inB - prevIn) / dt : 0
        let up = outB >= prevOut ? Double(outB - prevOut) / dt : 0
        return (down, up)
    }

    private func readBytes() -> (UInt64, UInt64) {
        var inB: UInt64 = 0, outB: UInt64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return (0, 0) }
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            guard let interface = ptr?.pointee else { continue }
            let name = String(cString: interface.ifa_name)
            if interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               name.hasPrefix("en"), let raw = interface.ifa_data {
                let data = raw.assumingMemoryBound(to: if_data.self)
                inB += UInt64(data.pointee.ifi_ibytes)
                outB += UInt64(data.pointee.ifi_obytes)
            }
        }
        freeifaddrs(ifaddr)
        return (inB, outB)
    }
}

func fmtSpeed(_ bps: Double) -> String {
    if bps >= 1_000_000 { return String(format: "%.1fM", bps / 1_000_000) }
    if bps >= 1_000 { return String(format: "%.0fK", bps / 1_000) }
    return String(format: "%.0fB", bps)
}

// MARK: - 아이폰 원격용 미니 HTTP 서버

final class MiniServer {
    private var listener: NWListener?
    let port: UInt16
    let token: String
    /// 명령 이름을 받아 "인식된 명령인지" 반환. 실제 실행은 콜백 내부에서 메인 큐로 디스패치.
    var onCommand: ((String) -> Bool)?

    init(port: UInt16, token: String) {
        self.port = port
        self.token = token
    }

    func start() {
        do {
            listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            listener?.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener?.start(queue: .global())
        } catch {
            NSLog("원격 서버 시작 실패: \(error)")
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self = self,
                  let data = data,
                  let req = String(data: data, encoding: .utf8) else {
                conn.cancel(); return
            }

            var status = "400 Bad Request"
            var message = "잘못된 요청"

            let firstLine = req.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            if parts.count >= 2 {
                let pathFull = String(parts[1])
                let comps = URLComponents(string: "http://x" + pathFull)
                let path = comps?.path ?? ""
                let tokenParam = comps?.queryItems?.first(where: { $0.name == "token" })?.value
                let cmd = path.replacingOccurrences(of: "/", with: "")

                if tokenParam != self.token {
                    status = "401 Unauthorized"; message = "🔒 토큰이 올바르지 않습니다"
                } else if self.onCommand?(cmd) == true {
                    status = "200 OK"; message = "✅ \(cmd) 실행됨"
                } else {
                    status = "404 Not Found"; message = "알 수 없는 명령: \(cmd)"
                }
            }

            let html = """
            <html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>\
            <body style="font-family:-apple-system;text-align:center;padding-top:60px;font-size:28px">\
            \(message)</body></html>
            """
            let resp = "HTTP/1.1 \(status)\r\n"
                + "Content-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(html.utf8.count)\r\n"
                + "Connection: close\r\n\r\n" + html
            conn.send(content: resp.data(using: .utf8),
                      completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}

// MARK: - 로컬 IP 조회

func localIPAddress() -> String? {
    var address: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return nil }
    var ptr = ifaddr
    while ptr != nil {
        defer { ptr = ptr?.pointee.ifa_next }
        guard let interface = ptr?.pointee else { continue }
        let family = interface.ifa_addr.pointee.sa_family
        if family == UInt8(AF_INET) {
            let name = String(cString: interface.ifa_name)
            if name == "en0" || name == "en1" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                            &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                address = String(cString: host)
            }
        }
    }
    freeifaddrs(ifaddr)
    return address
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let cpu = CPUSampler()
    private let net = NetSampler()
    private var statusTimer: Timer?
    private var lastNet: (down: Double, up: Double) = (0, 0)
    private var menuOpen = false
    private weak var netMenuItem: NSMenuItem?
    private weak var healthHeader: NSMenuItem?
    private weak var healthSub: NSMenu?
    private var lastJunkBytes: Int64 = 0
    private var identifyWindows: [NSWindow] = []

    // 포모도로 (집중 20분 · 휴식 5분)
    private enum Phase { case idle, work, breakTime }
    private var phase: Phase = .idle
    private var remaining = 0
    private let workLen = 20 * 60
    private let breakLen = 5 * 60

    // 자세 교정 알림
    private var postureOn = false
    private var postureRemaining = 0

    private let remotePort: UInt16 = 51888
    private lazy var remoteToken: String = {
        let key = "remoteToken"
        if let t = UserDefaults.standard.string(forKey: key) { return t }
        let t = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
        UserDefaults.standard.set(t, forKey: key)
        return t
    }()
    private var server: MiniServer!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.grid.2x2",
                                   accessibilityDescription: "빠른 도구")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        rebuildMenu()

        startRemoteServer()
        startStatusMonitor()
        if UserDefaults.standard.bool(forKey: "postureOn") { startPosture() }
        measureJunk()
    }

    // MARK: 사용자 지정 앱 저장/조회

    /// 항상 길이 3 (빈 문자열 = 미설정)
    private func rawCustomApps() -> [String] {
        var a = UserDefaults.standard.array(forKey: "customApps") as? [String] ?? []
        while a.count < 3 { a.append("") }
        return Array(a.prefix(3))
    }

    private func displayName(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    // MARK: Menu

    private var mainMenu: NSMenu?
    private func rebuildMenu() { mainMenu = buildMenu() }

    /// 좌클릭 = 메뉴, 우클릭 = 저장된 배치로 즉시 정렬
    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            applyLayout()
        } else {
            statusItem.menu = mainMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil   // 다음 클릭도 이 핸들러로 받도록 해제
        }
    }

    private func netTitleString() -> String {
        "네트워크  ⬇\(fmtSpeed(lastNet.down))  ⬆\(fmtSpeed(lastNet.up))"
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let s = systemScore()
        let head = NSMenuItem(title: "🩺 시스템 상태  \(s.total) / 100", action: nil, keyEquivalent: "")
        head.isEnabled = false
        healthHeader = head
        menu.addItem(head)
        let detail = NSMenuItem(title: "상태 자세히", action: nil, keyEquivalent: "")
        detail.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: nil)
        let sub = NSMenu()
        healthSub = sub
        fillHealth(sub, s)
        detail.submenu = sub
        menu.addItem(detail)
        menu.addItem(.separator())

        let netItem = NSMenuItem(title: netTitleString(), action: nil, keyEquivalent: "")
        netItem.isEnabled = false
        netItem.image = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
        netMenuItem = netItem
        menu.addItem(netItem)
        menu.addItem(.separator())

        menu.addItem(item("미션 컨트롤", "square.grid.3x3", #selector(missionControl)))
        menu.addItem(item("다크 모드 전환", "circle.lefthalf.filled", #selector(toggleDarkMode)))
        menu.addItem(item("볼륨 음소거 전환", "speaker.slash", #selector(toggleMute)))
        menu.addItem(displaySubmenu())

        menu.addItem(.separator())
        menu.addItem(header("화면 캡쳐"))
        menu.addItem(item("영역 캡쳐  ⌘⇧4", "camera.viewfinder", #selector(captureRegion)))
        menu.addItem(item("전체 캡쳐  ⌘⇧3", "camera", #selector(captureFull)))
        menu.addItem(item("캡쳐 도구  ⌘⇧5", "camera.badge.ellipsis", #selector(captureTool)))

        menu.addItem(.separator())
        menu.addItem(header("바로 열기"))
        menu.addItem(launcherSubmenu())

        // 사용자 지정 앱
        let myApps = rawCustomApps().enumerated().filter { !$0.element.isEmpty }
        if !myApps.isEmpty {
            menu.addItem(header("내 앱"))
            for (_, path) in myApps {
                let mi = item(displayName(path), "app", #selector(openPath(_:)))
                mi.representedObject = path
                menu.addItem(mi)
            }
        }

        menu.addItem(.separator())
        menu.addItem(header("포모도로 (집중 20분 · 휴식 5분)"))
        menu.addItem(item(phase == .idle ? "시작" : "정지",
                          phase == .idle ? "timer" : "stop.circle",
                          #selector(togglePomodoro)))

        menu.addItem(.separator())
        menu.addItem(header("건강"))
        menu.addItem(item(postureOn ? "자세 알림 끄기 (20분마다)" : "자세 알림 켜기 (20분마다)",
                          postureOn ? "bell.slash" : "bell",
                          #selector(togglePosture)))

        menu.addItem(.separator())
        menu.addItem(header("시스템"))
        menu.addItem(item("화면 잠금  ⌘⌃Q", "lock", #selector(lockScreen)))
        menu.addItem(item("절전", "moon.zzz", #selector(sleepNow)))
        menu.addItem(item("화면 보호기", "display", #selector(screenSaver)))

        menu.addItem(.separator())
        menu.addItem(header("정리 / 최적화"))
        menu.addItem(item("캐시·정크 정리", "trash", #selector(cleanCaches)))
        menu.addItem(item("업데이트 설정 열기", "gearshape.2", #selector(openUpdateSettings)))

        menu.addItem(.separator())
        menu.addItem(remoteSubmenu())
        menu.addItem(item("설정…", "gearshape", #selector(openSettings)))

        menu.addItem(.separator())
        menu.addItem(item("종료", "power", #selector(quit)))

        return menu
    }

    /// Finder 바로 열기 서브메뉴
    private func launcherSubmenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Finder 런처", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        let sub = NSMenu()
        let home = NSHomeDirectory()
        let folders: [(String, String, String)] = [
            ("홈", "house", home),
            ("데스크탑", "menubar.dock.rectangle", home + "/Desktop"),
            ("다운로드", "arrow.down.circle", home + "/Downloads"),
            ("문서", "doc", home + "/Documents"),
            ("응용 프로그램", "app.badge", "/Applications"),
        ]
        for (name, symbol, path) in folders {
            let mi = NSMenuItem(title: name, action: #selector(openPath(_:)), keyEquivalent: "")
            mi.target = self
            mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
            mi.representedObject = path
            sub.addItem(mi)
        }
        parent.submenu = sub
        return parent
    }

    /// 아이폰 원격 서브메뉴 (주소·토큰 표시 + URL 복사)
    private func remoteSubmenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "아이폰 원격", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "iphone.gen3", accessibilityDescription: nil)
        let sub = NSMenu()

        let ip = localIPAddress() ?? "네트워크 없음"
        sub.addItem(header("주소  \(ip):\(remotePort)"))
        sub.addItem(header("토큰  \(remoteToken)"))
        sub.addItem(.separator())

        var cmds: [(String, String)] = [
            ("잠자기 URL 복사", "sleep"),
            ("화면 잠금 URL 복사", "lock"),
            ("화면 보호기 URL 복사", "screensaver"),
            ("음소거 URL 복사", "mute"),
        ]
        for (i, path) in rawCustomApps().enumerated() where !path.isEmpty {
            cmds.append(("\(displayName(path)) URL 복사", "app\(i + 1)"))
        }

        for (label, cmd) in cmds {
            let mi = NSMenuItem(title: label, action: #selector(copyRemoteURL(_:)), keyEquivalent: "")
            mi.target = self
            mi.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
            mi.representedObject = "http://\(ip):\(remotePort)/\(cmd)?token=\(remoteToken)"
            sub.addItem(mi)
        }
        parent.submenu = sub
        return parent
    }

    private func item(_ title: String, _ symbol: String, _ action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return mi
    }

    private func header(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    // MARK: 설정 창

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 250),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "MenuBarTools 설정"
            w.center()
            w.isReleasedWhenClosed = false

            let content = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 250))

            let title = NSTextField(labelWithString: "메뉴·원격에서 실행할 앱 3개를 등록하세요")
            title.frame = NSRect(x: 20, y: 210, width: 430, height: 22)
            title.font = .boldSystemFont(ofSize: 13)
            content.addSubview(title)

            let apps = rawCustomApps()
            for i in 0..<3 {
                let y = 160 - i * 44
                let label = NSTextField(labelWithString: "앱 \(i + 1)")
                label.frame = NSRect(x: 20, y: CGFloat(y), width: 44, height: 22)
                content.addSubview(label)

                let field = NSTextField(frame: NSRect(x: 68, y: CGFloat(y) - 1, width: 258, height: 24))
                field.isEditable = false
                field.isSelectable = false
                field.placeholderString = "선택 안 됨"
                field.stringValue = apps[i].isEmpty ? "" : displayName(apps[i])
                field.tag = 100 + i
                content.addSubview(field)

                let pick = NSButton(frame: NSRect(x: 334, y: CGFloat(y) - 3, width: 66, height: 28))
                pick.title = "선택…"
                pick.bezelStyle = .rounded
                pick.tag = i
                pick.target = self
                pick.action = #selector(pickApp(_:))
                content.addSubview(pick)

                let clear = NSButton(frame: NSRect(x: 402, y: CGFloat(y) - 3, width: 52, height: 28))
                clear.title = "지움"
                clear.bezelStyle = .rounded
                clear.tag = i
                clear.target = self
                clear.action = #selector(clearApp(_:))
                content.addSubview(clear)
            }

            let note = NSTextField(labelWithString:
                "등록한 앱은 메뉴 '내 앱'과 아이폰 원격(app1~app3)에서 실행됩니다.")
            note.frame = NSRect(x: 20, y: 18, width: 434, height: 34)
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            content.addSubview(note)

            w.contentView = content
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func setCustomApp(index: Int, path: String) {
        var apps = rawCustomApps()
        apps[index] = path
        UserDefaults.standard.set(apps, forKey: "customApps")
        if let field = settingsWindow?.contentView?.viewWithTag(100 + index) as? NSTextField {
            field.stringValue = path.isEmpty ? "" : displayName(path)
        }
        rebuildMenu()
    }

    @objc private func pickApp(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] resp in
            guard let self = self, resp == .OK, let url = panel.url else { return }
            self.setCustomApp(index: sender.tag, path: url.path)
        }
    }

    @objc private func clearApp(_ sender: NSButton) {
        setCustomApp(index: sender.tag, path: "")
    }

    // MARK: 상태 모니터 (CPU · 네트워크 · 포모도로)

    private func startStatusMonitor() {
        _ = cpu.usage()  // 첫 델타 기준값 확보
        _ = net.sample() // 첫 델타 기준값 확보
        // .common 모드로 등록해야 메뉴가 열려 있는 동안에도 타이머가 계속 동작함
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        statusTimer = t
    }

    private func tick() {
        if let n = net.sample() { lastNet = n }
        if phase != .idle {
            remaining -= 1
            if remaining <= 0 { advancePomodoro() }
        }
        if postureOn {
            postureRemaining -= 1
            if postureRemaining <= 0 {
                notify("자세 바꾸기 🧘", "20분 지났어요. 일어나서 스트레칭하고 허리를 펴세요!")
                postureRemaining = 20 * 60
            }
        }
        updateStatusTitle()
        if menuOpen { netMenuItem?.title = netTitleString() }
    }

    private func updateStatusTitle() {
        var parts: [String] = []
        if phase != .idle {
            let m = remaining / 60, s = remaining % 60
            parts.append(String(format: "%@%d:%02d", phase == .work ? "🍅" : "☕️", m, s))
        }
        if postureOn {
            let m = postureRemaining / 60, s = postureRemaining % 60
            parts.append(String(format: "🪑%d:%02d", m, s))
        }
        if let c = cpu.usage() {
            parts.append(String(format: "%.0f%%", c))
        }
        statusItem.button?.title = parts.isEmpty ? "" : " " + parts.joined(separator: "  ")
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        netMenuItem?.title = netTitleString()
        let s = systemScore()
        healthHeader?.title = "🩺 시스템 상태  \(s.total) / 100"
        if let sub = healthSub { fillHealth(sub, s) }
        measureJunk() // 다음 열람을 위해 백그라운드 갱신
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
    }

    // MARK: 포모도로

    @objc private func togglePomodoro() {
        if phase == .idle {
            phase = .work
            remaining = workLen
            notify("포모도로", "집중 시작 (20분) 🍅")
        } else {
            phase = .idle
            remaining = 0
            statusItem.button?.title = ""
        }
        rebuildMenu()
        updateStatusTitle()
    }

    private func advancePomodoro() {
        if phase == .work {
            phase = .breakTime
            remaining = breakLen
            notify("포모도로", "휴식 시간 (5분) ☕️")
        } else {
            phase = .work
            remaining = workLen
            notify("포모도로", "집중 시작 (20분) 🍅")
        }
    }

    private func notify(_ title: String, _ body: String) {
        run("/usr/bin/osascript", ["-e", "display notification \"\(body)\" with title \"\(title)\""])
        NSSound(named: "Glass")?.play()
    }

    // MARK: 자세 교정 알림

    private func startPosture() {
        postureOn = true
        UserDefaults.standard.set(true, forKey: "postureOn")
        postureRemaining = 20 * 60
    }

    private func stopPosture() {
        postureOn = false
        UserDefaults.standard.set(false, forKey: "postureOn")
        postureRemaining = 0
    }

    @objc private func togglePosture() {
        if postureOn {
            stopPosture()
        } else {
            startPosture()
            notify("자세 교정 알림 시작", "20분마다 알려드릴게요. 허리 조심하세요! 🧘")
        }
        rebuildMenu()
    }

    // MARK: 정리 / 최적화

    @objc private func cleanCaches() {
        let s = systemScore()
        guard confirm("캐시·정크 정리",
            String(format: "현재 상태 점수: %d / 100 (정크 %.1fGB)\n\n아래를 비웁니다:\n· ~/Library/Caches\n· ~/Library/Logs\n· 휴지통\n\n정리하면 점수가 최대 +25까지 오릅니다.\n열려있는 앱은 잠시 느려질 수 있어요. 계속할까요?", s.total, s.junkGB)) else { return }
        let home = NSHomeDirectory()
        let cmd = "rm -rf \"\(home)/Library/Caches/\"* \"\(home)/Library/Logs/\"* \"\(home)/.Trash/\"* 2>/dev/null; true"
        runAsync("/bin/sh", ["-c", cmd]) { [weak self] _ in
            self?.measureJunk()
            self?.infoAlert("정리 완료", "캐시·로그·휴지통을 정리했습니다.\n메뉴를 다시 열면 갱신된 점수가 보입니다.")
        }
    }

    @objc private func openUpdateSettings() {
        run("/usr/bin/open", ["x-apple.systempreferences:com.apple.Software-Update-Settings.extension"])
    }

    // MARK: 디스플레이 정렬

    private func displaySubmenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "디스플레이 정렬", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: nil)
        let sub = NSMenu()
        sub.addItem(item("모니터 식별 (1·2 표시)", "1.square", #selector(identifyDisplays)))
        sub.addItem(item("좌우 위치 바꾸기", "arrow.left.arrow.right", #selector(swapDisplays)))

        sub.addItem(.separator())
        if loadPreset() != nil {
            sub.addItem(item("★ 내 배치로 정렬 (아이콘 우클릭)", "rectangle.3.group", #selector(applyLayout)))
        }
        sub.addItem(item("현재 배치 저장", "square.and.arrow.down", #selector(saveLayout)))

        let displays = dpList()
        if !displays.isEmpty {
            sub.addItem(.separator())
            for (idx, d) in displays.enumerated() {
                let m = NSMenuItem(title: "회전 · 모니터 \(idx + 1)  (현재 \(d.deg)°)",
                                   action: nil, keyEquivalent: "")
                m.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
                let rsub = NSMenu()
                for deg in [0, 90, 180, 270] {
                    let mi = NSMenuItem(title: "\(deg)°", action: #selector(rotateDisplay(_:)), keyEquivalent: "")
                    mi.target = self
                    mi.representedObject = "\(d.id)|\(deg)"
                    if deg == d.deg { mi.state = .on }
                    rsub.addItem(mi)
                }
                rsub.addItem(.separator())
                let q = NSMenuItem(title: "+90° 돌리기", action: #selector(rotateDisplay(_:)), keyEquivalent: "")
                q.target = self
                q.representedObject = "\(d.id)|\((d.deg + 90) % 360)"
                rsub.addItem(q)
                m.submenu = rsub
                sub.addItem(m)
            }
        }

        sub.addItem(.separator())
        sub.addItem(item("디스플레이 설정 열기", "gearshape", #selector(openDisplaySettings)))
        parent.submenu = sub
        return parent
    }

    // MARK: 디스플레이 회전 (displayplacer)

    private struct DPD { let id: String; let type: String; let deg: Int }
    private let displayplacerPath = "/opt/homebrew/bin/displayplacer"

    private func shellOutput(_ launch: String, _ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: launch) else { return nil }
        let t = Process()
        t.executableURL = URL(fileURLWithPath: launch)
        t.arguments = args
        let pipe = Pipe(); t.standardOutput = pipe; t.standardError = Pipe()
        do { try t.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        t.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private func dpList() -> [DPD] {
        guard let out = shellOutput(displayplacerPath, ["list"]) else { return [] }
        var res: [DPD] = []
        var id: String?; var type = ""; var deg = 0
        for raw in out.split(separator: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("Persistent screen id:") {
                if let i = id { res.append(DPD(id: i, type: type, deg: deg)) }
                id = l.replacingOccurrences(of: "Persistent screen id:", with: "").trimmingCharacters(in: .whitespaces)
                type = ""; deg = 0
            } else if l.hasPrefix("Type:") {
                type = l.replacingOccurrences(of: "Type:", with: "").trimmingCharacters(in: .whitespaces)
            } else if l.hasPrefix("Rotation:") {
                deg = Int(l.replacingOccurrences(of: "Rotation:", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        if let i = id { res.append(DPD(id: i, type: type, deg: deg)) }
        return res
    }

    /// displayplacer list 마지막 줄(전체 설정 명령)에서 따옴표 세그먼트들을 추출
    private func dpFullSegments() -> [String]? {
        guard let out = shellOutput(displayplacerPath, ["list"]) else { return nil }
        guard let line = out.split(separator: "\n").last(where: { $0.hasPrefix("displayplacer ") }) else { return nil }
        var segs: [String] = []; var inside = false; var cur = ""
        for ch in line {
            if ch == "\"" { if inside { segs.append(cur); cur = "" }; inside.toggle() }
            else if inside { cur.append(ch) }
        }
        return segs
    }

    /// 대상 세그먼트의 degree를 바꾸고, 90° 전환이면 res W×H 스왑
    private func mutateSegment(_ seg: String, newDeg: Int) -> String {
        var out = seg
        let curDeg = Int((seg.range(of: "degree:\\d+", options: .regularExpression)
            .map { String(seg[$0]).dropFirst(7) }) ?? "0") ?? 0
        let flips = (curDeg % 180 == 0) != (newDeg % 180 == 0)
        if let r = seg.range(of: "res:\\d+x\\d+", options: .regularExpression) {
            let token = String(seg[r]).dropFirst(4).split(separator: "x")
            if token.count == 2, let w = Int(token[0]), let h = Int(token[1]) {
                out.replaceSubrange(r, with: flips ? "res:\(h)x\(w)" : "res:\(w)x\(h)")
            }
        }
        if let r = out.range(of: "degree:\\d+", options: .regularExpression) {
            out.replaceSubrange(r, with: "degree:\(newDeg)")
        }
        return out
    }

    private var presetURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuBarTools", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("display_preset.json")
    }

    private func loadPreset() -> [String]? {
        guard let data = try? Data(contentsOf: presetURL),
              let segs = try? JSONDecoder().decode([String].self, from: data),
              !segs.isEmpty else { return nil }
        return segs
    }

    @objc private func saveLayout() {
        guard let segs = dpFullSegments(), !segs.isEmpty else {
            infoAlert("배치 저장", "displayplacer 정보를 읽지 못했습니다."); return
        }
        if let data = try? JSONEncoder().encode(segs) { try? data.write(to: presetURL) }
        rebuildMenu()
        infoAlert("배치 저장됨", "현재 모니터 배치를 저장했습니다.\n메뉴 '★ 내 배치로 정렬' 또는 아이콘 우클릭으로 언제든 복원할 수 있어요.")
    }

    @objc private func applyLayout() {
        guard let segs = loadPreset() else {
            infoAlert("배치", "저장된 배치가 없습니다. 먼저 '현재 배치 저장'을 누르세요."); return
        }
        runAsync(displayplacerPath, segs) { [weak self] ok in
            if ok { self?.rebuildMenu() }
            else { self?.infoAlert("정렬 실패", "저장된 배치를 적용하지 못했습니다.\n(연결된 모니터 구성이 저장 때와 다를 수 있어요)") }
        }
    }

    @objc private func rotateDisplay(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        let p = s.split(separator: "|")
        guard p.count == 2, let newDeg = Int(p[1]) else { return }
        let targetId = String(p[0])
        guard var segs = dpFullSegments(), !segs.isEmpty else {
            infoAlert("회전", "displayplacer 정보를 읽지 못했습니다."); return
        }
        for i in segs.indices where segs[i].contains(targetId) {
            segs[i] = mutateSegment(segs[i], newDeg: newDeg)
        }
        runAsync(displayplacerPath, segs) { [weak self] ok in
            if ok { self?.rebuildMenu() }
            else { self?.infoAlert("회전 실패", "이 방향을 적용하지 못했습니다.\n'디스플레이 설정 열기'에서 시도해 주세요.") }
        }
    }

    @objc private func openDisplaySettings() {
        run("/usr/bin/open", ["x-apple.systempreferences:com.apple.Displays-Settings.extension"])
    }

    @objc private func identifyDisplays() {
        identifyWindows.forEach { $0.orderOut(nil) }
        identifyWindows.removeAll()
        for (i, screen) in NSScreen.screens.enumerated() {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.level = .screenSaver
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

            let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 320))
            box.wantsLayer = true
            box.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.88).cgColor
            box.layer?.cornerRadius = 36

            let label = NSTextField(labelWithString: "\(i + 1)")
            label.font = .systemFont(ofSize: 200, weight: .bold)
            label.textColor = .white
            label.alignment = .center
            label.frame = NSRect(x: 0, y: 40, width: 320, height: 240)
            box.addSubview(label)

            let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            box.frame.origin = NSPoint(x: (screen.frame.width - 320) / 2,
                                       y: (screen.frame.height - 320) / 2)
            content.addSubview(box)
            w.contentView = content
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            identifyWindows.append(w)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.identifyWindows.forEach { $0.orderOut(nil) }
            self?.identifyWindows.removeAll()
        }
    }

    @objc private func swapDisplays() {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count >= 2 else {
            infoAlert("디스플레이 정렬", "외부 모니터가 2개 이상 연결됐을 때 사용하세요.")
            return
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let main: CGDirectDisplayID = ids.first(where: { CGDisplayIsMain($0) != 0 }) ?? ids[0]
        let other: CGDirectDisplayID = ids.first(where: { $0 != main }) ?? ids[1]
        let mb = CGDisplayBounds(main)
        let ob = CGDisplayBounds(other)

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        if ob.origin.x >= mb.maxX - 1 {
            // 현재 오른쪽 → 왼쪽으로
            CGConfigureDisplayOrigin(config, other, Int32(-ob.width), 0)
        } else {
            // 현재 왼쪽/기타 → 오른쪽으로
            CGConfigureDisplayOrigin(config, other, Int32(mb.width), 0)
        }
        CGCompleteDisplayConfiguration(config, .permanently)
    }

    // MARK: 정리용 헬퍼

    private func confirm(_ title: String, _ info: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.alertStyle = .warning
        a.addButton(withTitle: "실행")
        a.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }

    private func infoAlert(_ title: String, _ info: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.addButton(withTitle: "확인")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    private func runAsync(_ launch: String, _ args: [String], done: ((Bool) -> Void)? = nil) {
        DispatchQueue.global().async {
            let t = Process()
            t.executableURL = URL(fileURLWithPath: launch)
            t.arguments = args
            do { try t.run(); t.waitUntilExit() }
            catch { DispatchQueue.main.async { done?(false) }; return }
            let ok = t.terminationStatus == 0
            DispatchQueue.main.async { done?(ok) }
        }
    }

    // MARK: 시스템 상태 점수 (근사 지표)

    private typealias Score = (total: Int, disk: Double, mem: Double, swap: Double, junkGB: Double, up: Double)

    /// 캐시/로그/휴지통 총량을 백그라운드에서 측정해 캐시
    private func measureJunk() {
        let home = NSHomeDirectory()
        let cmd = "du -sk \"\(home)/Library/Caches\" \"\(home)/Library/Logs\" \"\(home)/.Trash\" 2>/dev/null | awk '{s+=$1} END{print s}'"
        DispatchQueue.global().async {
            let t = Process()
            t.executableURL = URL(fileURLWithPath: "/bin/sh")
            t.arguments = ["-c", cmd]
            let pipe = Pipe(); t.standardOutput = pipe
            try? t.run(); t.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let kb = Double(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            DispatchQueue.main.async { self.lastJunkBytes = Int64(kb * 1024) }
        }
    }

    private func diskFreeFraction() -> Double {
        let url = URL(fileURLWithPath: "/")
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                     .volumeTotalCapacityKey]),
           let total = v.volumeTotalCapacity, total > 0,
           let avail = v.volumeAvailableCapacityForImportantUsage {
            return min(1, Double(avail) / Double(total))
        }
        return 0.5
    }

    private func memAvailableFraction() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0.5 }
        let page = Double(vm_kernel_page_size)
        let available = (Double(stats.free_count) + Double(stats.inactive_count)
                         + Double(stats.speculative_count) + Double(stats.purgeable_count)) * page
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return total > 0 ? min(1, available / total) : 0.5
    }

    private func swapUsedMB() -> Double {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return Double(usage.xsu_used) / 1_048_576.0
    }

    private func systemScore() -> Score {
        let diskPct = diskFreeFraction() * 100
        let memPct = memAvailableFraction() * 100
        let swap = swapUsedMB()
        let junkGB = Double(lastJunkBytes) / 1_073_741_824.0
        let upDays = ProcessInfo.processInfo.systemUptime / 86_400.0

        let sDisk = max(0, min(25, diskPct / 20 * 25))          // 20%+ 여유 = 만점
        let sMem  = max(0, min(25, memPct / 40 * 25))           // 40%+ 여유 = 만점
        let sSwap = swap <= 256 ? 15 : max(0, 15 - (swap - 256) / 512 * 15)
        let sJunk = junkGB <= 1 ? 25 : max(0, 25 - (junkGB - 1) / 9 * 25) // 1GB↓ 만점, 10GB 0
        let sUp   = upDays <= 2 ? 10 : max(0, 10 - (upDays - 2) / 12 * 10) // 2일↓ 만점, 14일 0
        let total = Int((sDisk + sMem + sSwap + sJunk + sUp).rounded())
        return (total, diskPct, memPct, swap, junkGB, upDays)
    }

    private func fillHealth(_ sub: NSMenu, _ s: Score) {
        sub.removeAllItems()
        sub.addItem(header(String(format: "여유 공간   %.0f%%", s.disk)))
        sub.addItem(header(String(format: "메모리 여유  %.0f%%", s.mem)))
        sub.addItem(header(String(format: "스왑 사용   %.0f MB", s.swap)))
        sub.addItem(header(String(format: "정크(캐시 등)  %.1f GB", s.junkGB)))
        sub.addItem(header(String(format: "가동 시간   %.1f일", s.up)))
        sub.addItem(.separator())
        sub.addItem(header("깨끗할수록 100에 가까움 (근사치)"))
    }

    // MARK: 원격 서버

    private func startRemoteServer() {
        server = MiniServer(port: remotePort, token: remoteToken)
        server.onCommand = { [weak self] cmd in
            guard let self = self else { return false }
            let known: [String: () -> Void] = [
                "sleep": self.sleepNow,
                "lock": self.lockScreen,
                "screensaver": self.screenSaver,
                "mute": self.toggleMute,
                "app1": { self.launchCustom(0) },
                "app2": { self.launchCustom(1) },
                "app3": { self.launchCustom(2) },
            ]
            guard let action = known[cmd] else { return false }
            DispatchQueue.main.async(execute: action)
            return true
        }
        server.start()
    }

    private func launchCustom(_ index: Int) {
        let apps = rawCustomApps()
        guard index < apps.count, !apps[index].isEmpty else { return }
        run("/usr/bin/open", [apps[index]])
    }

    // MARK: Actions

    @objc private func missionControl() { run("/usr/bin/open", ["-a", "Mission Control"]) }

    @objc private func toggleDarkMode() {
        run("/usr/bin/osascript", ["-e",
            "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"])
    }

    @objc private func toggleMute() {
        run("/usr/bin/osascript", ["-e",
            "set volume output muted (not (output muted of (get volume settings)))"])
    }

    @objc private func captureRegion() { run("/usr/sbin/screencapture", ["-i", screenshotPath()]) }
    @objc private func captureFull()   { run("/usr/sbin/screencapture", [screenshotPath()]) }
    @objc private func captureTool()   { run("/usr/bin/open", ["-a", "Screenshot"]) }

    @objc private func lockScreen()  { sendKey(keyCode: 12 /* Q */, flags: [.maskCommand, .maskControl]) }
    @objc private func sleepNow()    { run("/usr/bin/pmset", ["sleepnow"]) }
    @objc private func screenSaver() { run("/usr/bin/open", ["-a", "ScreenSaverEngine"]) }

    @objc private func openPath(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { run("/usr/bin/open", [path]) }
    }

    @objc private func copyRemoteURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Helpers

    private func run(_ launchPath: String, _ args: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        do { try task.run() } catch { NSLog("실행 실패 \(launchPath): \(error)") }
    }

    private func screenshotPath() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let desktop = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return desktop.appendingPathComponent("스크린샷 \(df.string(from: Date())).png").path
    }

    private func sendKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
