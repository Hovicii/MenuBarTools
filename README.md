# MenuBarTools

A lightweight macOS utility that runs your most-used functions **with a single mouse click** from the menu bar.
It lives only in the menu bar with no Dock icon (single Swift file, almost no dependencies).

## Features
Click the **⊞ icon** in the menu bar for:

- **System health score** (🩺 /100) — approximate indicator based on free space · memory · swap · junk · uptime
- **Mission Control / Dark Mode toggle / Volume mute**
- **Screenshots** — region (⌘⇧4) · full (⌘⇧3) · capture tool (⌘⇧5)
- **Display arrangement** — identify monitors (shows 1·2), swap left/right, save/restore layout, 90° rotation*
- **Finder launcher** — open Home · Desktop · Downloads · Documents · Applications
- **My Apps** — register 3 frequently-used apps in Settings and launch them
- **Pomodoro** (focus 20 min / break 5 min) — menu-bar countdown + notification
- **Posture reminder** — stretch alert every 20 min (🪑 shows remaining time)
- **System** — lock screen (⌘⌃Q) · sleep · screen saver
- **Cleanup/optimize** — clear caches · logs · trash, open Update settings
- **iPhone remote** — built-in mini HTTP server for sleep/lock/mute etc. from iPhone (token-protected)

> \* 90° rotation and layout save/restore appear in the menu only when `displayplacer` is installed.
> **Right-click** the menu-bar icon = instantly apply the saved display layout.

## Requirements
- macOS 13 or later (Apple Silicon / Intel)
- Build: **Xcode Command Line Tools** (`xcode-select --install`)
- (Optional) display rotation/layout: `brew install displayplacer`

## Build & Install
```bash
git clone https://github.com/Hovicii/MenuBarTools.git
cd MenuBarTools
./build.sh
cp -R build/MenuBarTools.app /Applications/
open /Applications/MenuBarTools.app
```

> **On a managed (MDM) Mac, downloading and running an unsigned .app may be blocked by Gatekeeper.**
> That's why building from source is recommended (a locally compiled binary carries no quarantine flag).
> On a company/managed device, first confirm that installing dev tools and running unsigned apps doesn't violate IT policy.

### Download a prebuilt binary
A universal build (Apple Silicon + Intel) is attached to the [latest release](https://github.com/Hovicii/MenuBarTools/releases).
After downloading, remove the quarantine flag before launching:
```bash
xattr -dr com.apple.quarantine ~/Downloads/MenuBarTools.app
```

## Permissions
Some features need approval in **System Settings → Privacy & Security**:
- **Screen Recording** — screenshots
- **Accessibility** — lock screen (sends ⌘⌃Q)
- **Notifications** — on first alert

## Launch at login (optional)
System Settings → General → Login Items → `+` → add `MenuBarTools.app`

## License
Personal utility. Use and modify freely.

---

# MenuBarTools (한국어)

macOS 메뉴바에서 자주 쓰는 기능을 **마우스 클릭만으로** 실행하는 가벼운 유틸리티.
Dock 아이콘 없이 메뉴바에만 떠 있습니다 (단일 Swift 파일, 의존성 거의 없음).

## 기능
메뉴바의 **⊞ 아이콘**을 클릭하면:

- **시스템 상태 점수** (🩺 /100) — 여유공간·메모리·스왑·정크·가동시간 기반 근사 지표
- **미션 컨트롤 / 다크 모드 전환 / 볼륨 음소거**
- **화면 캡쳐** — 영역(⌘⇧4) · 전체(⌘⇧3) · 캡쳐 도구(⌘⇧5)
- **디스플레이 정렬** — 모니터 식별(1·2 표시), 좌우 위치 바꾸기, 배치 저장/복원, 90° 회전*
- **Finder 런처** — 홈·데스크탑·다운로드·문서·앱 바로 열기
- **내 앱** — 자주 쓰는 앱 3개를 설정창에서 등록해 실행
- **포모도로** (집중 20분 / 휴식 5분) — 메뉴바 카운트다운 + 알림
- **자세 교정 알림** — 20분마다 스트레칭 알림(🪑 남은시간 표시)
- **시스템** — 화면 잠금(⌘⌃Q) · 절전 · 화면 보호기
- **정리/최적화** — 캐시·로그·휴지통 비우기, 업데이트 설정 열기
- **아이폰 원격** — 앱 내장 미니 HTTP 서버로 아이폰에서 잠자기/잠금/음소거 등 (토큰 보호)

> \* 90° 회전과 배치 저장/복원은 `displayplacer`가 설치돼 있을 때만 메뉴에 나타납니다.
> 메뉴바 아이콘 **우클릭** = 저장된 디스플레이 배치로 즉시 정렬.

## 요구 사양
- macOS 13 이상 (Apple Silicon / Intel)
- 빌드: **Xcode Command Line Tools** (`xcode-select --install`)
- (선택) 디스플레이 회전/배치: `brew install displayplacer`

## 빌드 & 설치
```bash
git clone https://github.com/Hovicii/MenuBarTools.git
cd MenuBarTools
./build.sh
cp -R build/MenuBarTools.app /Applications/
open /Applications/MenuBarTools.app
```

> **관리(MDM) 맥에서 미서명 .app을 다운로드해 실행하면 Gatekeeper가 막을 수 있습니다.**
> 그래서 위처럼 **소스를 받아 직접 빌드**하는 방식을 권장합니다 (로컬 컴파일 바이너리는 격리 플래그가 안 붙음).
> 회사/관리 기기라면 개발도구 설치·실행이 IT 정책에 어긋나지 않는지 먼저 확인하세요.

### 미리 빌드된 바이너리 다운로드
유니버설 빌드(Apple Silicon + Intel)가 [최신 릴리스](https://github.com/Hovicii/MenuBarTools/releases)에 첨부돼 있습니다.
다운로드 후 실행 전 격리 플래그를 해제하세요:
```bash
xattr -dr com.apple.quarantine ~/Downloads/MenuBarTools.app
```

## 권한
일부 기능은 **시스템 설정 → 개인정보 보호 및 보안**에서 허용이 필요합니다:
- **화면 기록** — 화면 캡쳐
- **손쉬운 사용** — 화면 잠금(⌘⌃Q 전송)
- 첫 알림 시 **알림** 권한

## 로그인 시 자동 실행 (선택)
시스템 설정 → 일반 → 로그인 항목 → `+` → `MenuBarTools.app` 추가

## 라이선스
개인 유틸리티. 자유롭게 사용·수정하세요.
