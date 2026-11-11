import AppKit
import CoreGraphics

// 任意台數螢幕對齊。主螢幕為基準，固定畫一條橫線和一條直線（正中間）。
// 其餘每台螢幕各有一條可動橫線、一條可動直線，邊緣畫公分刻度。
// Tab 輪流切換要調哪台；上下鍵移橫線、左右鍵移直線。
// 把可動線調到「看起來和基準線連成一線」後按 Enter，座標就會被設成讓兩者在游標座標上相接。

func did(_ s: NSScreen) -> CGDirectDisplayID {
  CGDirectDisplayID((s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value)
}
func bounds(_ s: NSScreen) -> CGRect { CGDisplayBounds(did(s)) }
func mm(_ s: NSScreen) -> CGSize { CGDisplayScreenSize(did(s)) }
func ptmm(_ s: NSScreen) -> CGFloat { s.frame.width / mm(s).width }

let screens = NSScreen.screens
guard let ref = screens.first, screens.count > 1 else { print("需要至少兩台螢幕"); exit(1) }
let targets = Array(screens.dropFirst())

// 基準線位置（mm，離螢幕上緣／左緣），以及它在全域座標（pt）的位置
let refH = mm(ref).height / 2, refW = mm(ref).width / 2
let anchor = CGPoint(x: bounds(ref).minX + refW * ptmm(ref), y: bounds(ref).minY + refH * ptmm(ref))

let start = targets.map { bounds($0).origin }
// 起始線位置：讓「不動直接 Enter」等於目前的排列
var hMM = targets.indices.map { (anchor.y - start[$0].y) / ptmm(targets[$0]) }
var vMM = targets.indices.map { (anchor.x - start[$0].x) / ptmm(targets[$0]) }
var active = 0

final class V: NSView {
  var pm: CGFloat = 1
  var name = ""
  var h: CGFloat? = nil
  var v: CGFloat? = nil
  var isActive = false
  override var isFlipped: Bool { true }
  func t(_ s: String, _ p: NSPoint, _ bg: NSColor) {
    NSAttributedString(string: " \(s) ", attributes: [.font: NSFont.boldSystemFont(ofSize: 13),
      .foregroundColor: NSColor.white, .backgroundColor: bg]).draw(at: p)
  }
  func line(_ a: NSPoint, _ b: NSPoint, _ c: NSColor, _ w: CGFloat) {
    c.setStroke(); let p = NSBezierPath(); p.move(to: a); p.line(to: b); p.lineWidth = w; p.stroke()
  }
  override func draw(_ r: NSRect) {
    let W = bounds.width, H = bounds.height
    let bg = NSColor.black.withAlphaComponent(0.7)
    for cm in 0...Int(H / (10 * pm)) {                       // 左右邊緣：離上緣幾公分
      let y = CGFloat(cm * 10) * pm, len: CGFloat = cm % 5 == 0 ? 60 : 30
      line(NSPoint(x: 0, y: y), NSPoint(x: len, y: y), .cyan, 2)
      line(NSPoint(x: W, y: y), NSPoint(x: W - len, y: y), .cyan, 2)
      t("\(cm)", NSPoint(x: 64, y: y - 9), bg); t("\(cm)", NSPoint(x: W - 100, y: y - 9), bg)
    }
    for cm in 0...Int(W / (10 * pm)) {                       // 上下邊緣：離左緣幾公分
      let x = CGFloat(cm * 10) * pm, len: CGFloat = cm % 5 == 0 ? 60 : 30
      line(NSPoint(x: x, y: 0), NSPoint(x: x, y: len), .yellow, 2)
      line(NSPoint(x: x, y: H), NSPoint(x: x, y: H - len), .yellow, 2)
      t("\(cm)", NSPoint(x: x - 12, y: 64), bg); t("\(cm)", NSPoint(x: x - 12, y: H - 90), bg)
    }
    let col: NSColor = isActive ? .red : .orange
    let mark = isActive ? "  <== 調這台" : ""
    if let h = h {
      let y = h * pm
      line(NSPoint(x: 0, y: y), NSPoint(x: W, y: y), col, 3)
      t("\(name) 橫線 \(String(format: "%.1f", h / 10)) cm\(mark)", NSPoint(x: W / 2 - 150, y: y - 28), col)
    }
    if let v = v {
      let x = v * pm
      line(NSPoint(x: x, y: 0), NSPoint(x: x, y: H), col, 3)
      t("\(name) 直線 \(String(format: "%.1f", v / 10)) cm\(mark)", NSPoint(x: x + 8, y: H / 2), col)
    }
  }
}

var targetViews: [V] = []
var wins: [NSWindow] = []          // 保留視窗的強參照，避免被釋放
for s in screens {
  let v = V(frame: NSRect(origin: .zero, size: s.frame.size)); v.pm = ptmm(s); v.name = s.localizedName
  if s == ref { v.h = refH; v.v = refW } else { targetViews.append(v) }
  let w = NSWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
  w.level = .screenSaver; w.backgroundColor = .clear; w.isOpaque = false; w.ignoresMouseEvents = true
  w.collectionBehavior = [.canJoinAllSpaces, .stationary]; w.contentView = v; w.orderFrontRegardless()
  wins.append(w)
}

func setOrigins(_ o: [CGPoint]) {
  var cfg: CGDisplayConfigRef?
  CGBeginDisplayConfiguration(&cfg)
  for (s, p) in zip(targets, o) { CGConfigureDisplayOrigin(cfg, did(s), Int32(p.x.rounded()), Int32(p.y.rounded())) }
  CGCompleteDisplayConfiguration(cfg, .forSession)
}
func redraw() {
  for (i, v) in targetViews.enumerated() { v.h = hMM[i]; v.v = vMM[i]; v.isActive = active == i; v.needsDisplay = true }
}
redraw()

var old = termios(); tcgetattr(0, &old)
var raw = old; cfmakeraw(&raw); tcsetattr(0, TCSANOW, &raw)
func quit() { tcsetattr(0, TCSANOW, &old); print("\r\n"); exit(0) }
func say(_ s: String) { print("\r\(s)                    ", terminator: ""); fflush(stdout) }
func apply() {
  let o = targets.indices.map { CGPoint(x: anchor.x - vMM[$0] * ptmm(targets[$0]), y: anchor.y - hMM[$0] * ptmm(targets[$0])) }
  setOrigins(o)
  say("已套用 " + zip(targets, o).map { "\($0.localizedName)(\(Int($1.x.rounded())),\(Int($1.y.rounded())))" }.joined(separator: " "))
}
print("Tab 切換螢幕  上下=橫線 左右=直線 (2mm)  , . 微調橫線 0.5mm  Enter 套用  r 還原  q 離開\r")

FileHandle.standardInput.readabilityHandler = { h in
  let d = h.availableData; if d.isEmpty { return }
  let c = [UInt8](d)
  DispatchQueue.main.async {
    if c.count == 3 && c[0] == 27 && c[1] == 91 {
      switch c[2] {
      case 65: hMM[active] -= 2
      case 66: hMM[active] += 2
      case 67: vMM[active] += 2
      case 68: vMM[active] -= 2
      default: break
      }
    } else {
      switch c[0] {
      case UInt8(ascii: ","): hMM[active] -= 0.5
      case UInt8(ascii: "."): hMM[active] += 0.5
      case 9: active = (active + 1) % targets.count; say("調 \(targets[active].localizedName)")
      case 13: apply()
      case UInt8(ascii: "r"): setOrigins(start); say("已還原")
      case UInt8(ascii: "q"), 3: quit()
      default: break
      }
    }
    redraw()
  }
}
let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.run()
