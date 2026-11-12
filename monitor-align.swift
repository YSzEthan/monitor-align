import AppKit
import CoreGraphics

// 多螢幕對齊：用眼睛對齊相鄰螢幕的物理位置，工具算出精確 origin，游標跨螢幕不跳位。
// 每台非主螢幕貼著它的 parent（從主螢幕沿「邊相接」推導），只有一條垂直於貼合邊的可動線；
// parent 上同一位置畫一條參考線。把兩條線調到「看起來連成一線」後按 Enter。
// 一律以 CGDirectDisplayID 為 key、CGDisplayBounds 座標（左上原點，整數 pt）。

typealias ID = CGDirectDisplayID

// MARK: - 純幾何（不碰 CG 呼叫，--selftest 直接測）

struct R: Equatable {
  var x, y, w, h: Int
  var maxX: Int { x + w }
  var maxY: Int { y + h }
  func has(_ p: CGPoint) -> Bool { p.x >= CGFloat(x) && p.x < CGFloat(maxX) && p.y >= CGFloat(y) && p.y < CGFloat(maxY) }
  func hits(_ o: R) -> Bool { x < o.maxX && o.x < maxX && y < o.maxY && o.y < maxY }
}

/// child 在 parent 的哪一側
enum Side: String, Codable {
  case left, right, above, below
  var opposite: Side { [.left: .right, .right: .left, .above: .below, .below: .above][self]! }
  /// 左右鄰居調橫線（改 y），上下鄰居調直線（改 x）
  var horizontalLine: Bool { self == .left || self == .right }
}

/// anchor：參考線在 parent 區域座標（沿邊軸，離上／左緣的 pt），貼合邊重疊區段中點
struct Link { let parent: ID; let side: Side; let anchor: Int }

func along(_ r: R, _ s: Side) -> Int { s.horizontalLine ? r.y : r.x }
func span(_ r: R, _ s: Side) -> Int { s.horizontalLine ? r.h : r.w }

/// b 相對 a 的貼合側與沿邊重疊區間 [lo, hi)；邊不相接或只碰角回 nil
func contact(_ a: R, _ b: R) -> (Side, Int, Int)? {
  let (y0, y1) = (max(a.y, b.y), min(a.maxY, b.maxY))
  let (x0, x1) = (max(a.x, b.x), min(a.maxX, b.maxX))
  if y1 > y0 {
    if b.x == a.maxX { return (.right, y0, y1) }
    if b.maxX == a.x { return (.left, y0, y1) }
  }
  if x1 > x0 {
    if b.y == a.maxY { return (.below, x0, x1) }
    if b.maxY == a.y { return (.above, x0, x1) }
  }
  return nil
}

/// v 貼著 u 時的 link（參考線取重疊中點）與重疊長度；不相接回 nil
func link(_ r: [ID: R], parent u: ID, child v: ID) -> (len: Int, link: Link)? {
  guard let (s, lo, hi) = contact(r[u]!, r[v]!) else { return nil }
  return (hi - lo, Link(parent: u, side: s, anchor: ((lo + hi) >> 1) - along(r[u]!, s)))
}

/// 每條 link 的 child 仍貼在 parent 的同一側
func sidesHold(_ r: [ID: R], _ links: [ID: Link]) -> Bool {
  links.allSatisfy { contact(r[$0.value.parent]!, r[$0.key]!)?.0 == $0.value.side }
}

/// 從 root 一層一層長樹：每輪只讓「上一輪以前已加入」的螢幕當 parent，所以直接貼 root 的都以 root 為 parent；
/// 同一輪內挑沿邊重疊最長者。不連通回 nil。
func derive(_ r: [ID: R], root: ID) -> (order: [ID], links: [ID: Link])? {
  guard r[root] != nil else { return nil }
  var order = [root], links: [ID: Link] = [:]
  let ids = r.keys.sorted()
  while order.count < r.count {
    let joined = order
    for v in ids where !joined.contains(v) {
      var best: (len: Int, link: Link)?
      for u in joined {
        guard let c = link(r, parent: u, child: v), c.len > (best?.len ?? 0) else { continue }
        best = c
      }
      if let b = best { links[v] = b.link; order.append(v) }
    }
    if order.count == joined.count { return nil }
  }
  return (order, links)
}

/// links 是否仍描述 rects：同一批螢幕、root 沒換、每條貼合側沒變、無重疊且參考線在範圍內
func stillValid(_ r: [ID: R], order: [ID], links: [ID: Link], root: ID) -> Bool {
  order.first == root && Set(order) == Set(r.keys) && links.count == order.count - 1
    && sidesHold(r, links) && valid(r, links)
}

/// 由 links 拓樸排序（parent 一定在前）；有環回 nil
func topo(_ root: ID, _ links: [ID: Link]) -> [ID]? {
  var o = [root], rest = links
  while !rest.isEmpty {
    let ready = rest.filter { o.contains($0.value.parent) }.keys.sorted()
    if ready.isEmpty { return nil }
    o += ready; ready.forEach { rest[$0] = nil }
  }
  return o
}

/// child 與 parent 的沿邊偏移（調整期間唯一會變的量）
func offsets(_ r: [ID: R], _ links: [ID: Link]) -> [ID: Int] {
  links.reduce(into: [:]) { $0[$1.key] = along(r[$1.key]!, $1.value.side) - along(r[$1.value.parent]!, $1.value.side) }
}

/// 由偏移算出所有絕對 rect；主螢幕固定 (0,0)，垂直軸直接 flush 到 parent 邊緣（整數，不會有 1pt 縫）
func layout(_ order: [ID], _ links: [ID: Link], _ dims: [ID: R], _ off: [ID: Int]) -> [ID: R] {
  var out: [ID: R] = [order[0]: R(x: 0, y: 0, w: dims[order[0]]!.w, h: dims[order[0]]!.h)]
  for id in order.dropFirst() {
    let l = links[id]!, p = out[l.parent]!, d = dims[id]!, o = off[id]!
    switch l.side {
    case .right: out[id] = R(x: p.maxX, y: p.y + o, w: d.w, h: d.h)
    case .left: out[id] = R(x: p.x - d.w, y: p.y + o, w: d.w, h: d.h)
    case .below: out[id] = R(x: p.x + o, y: p.maxY, w: d.w, h: d.h)
    case .above: out[id] = R(x: p.x + o, y: p.y - d.h, w: d.w, h: d.h)
    }
  }
  return out
}

/// 任兩台不重疊，且每條參考線都落在它的 child 範圍內（等於重疊 >= 1，兩邊的線都畫得出來）
func valid(_ r: [ID: R], _ links: [ID: Link]) -> Bool {
  let v = Array(r.values)
  for i in v.indices { for j in v.indices where j > i && v[i].hits(v[j]) { return false } }
  for (c, l) in links {
    let ref = along(r[l.parent]!, l.side) + l.anchor, lo = along(r[c]!, l.side)
    if ref < lo || ref >= lo + span(r[c]!, l.side) { return false }
  }
  return true
}

/// 把 a 貼到 b 的 side 側，沿邊軸對齊起點
func place(_ a: R, beside b: R, _ s: Side) -> R {
  var a = a
  switch s {
  case .right: a.x = b.maxX; a.y = b.y
  case .left: a.x = b.x - a.w; a.y = b.y
  case .below: a.y = b.maxY; a.x = b.x
  case .above: a.y = b.y - a.h; a.x = b.x
  }
  return a
}

struct Plan { var rects: [ID: R]; var order: [ID]; var links: [ID: Link] }

/// 排列：a 貼到 b 的 side 側。只改 a 的 link（直接寫死，不重推），其餘沿用；
/// 沿用的 link 失效（貼合側變了、有環、參考線出範圍）才整棵重推。重疊或不連通回 nil
func arranged(_ cur: [ID: R], order: [ID], links: [ID: Link], a: ID, side: Side, b: ID) -> Plan? {
  guard a != b, let ra = cur[a], let rb = cur[b] else { return nil }
  var n = cur
  n[a] = place(ra, beside: rb, side)
  guard !n.contains(where: { $0.key != a && $0.value.hits(n[a]!) }) else { return nil }
  func plan(_ o: [ID], _ l: [ID: Link]) -> Plan? {
    let rects = layout(o, l, n, offsets(n, l))
    return valid(rects, l) ? Plan(rects: rects, order: o, links: l) : nil
  }
  var l = links
  if a != order[0], let c = link(n, parent: b, child: a) { l[a] = c.link }
  if sidesHold(n, l),
     let o = topo(order[0], l), let p = plan(o, l) { return p }
  guard let d = derive(n, root: order[0]) else { return nil }
  return plan(d.order, d.links)
}

/// pt/mm。mm 為 0、寬高比對不上（旋轉會自動換邊比對）或不合理就回 nil
func scale(_ w: Int, _ h: Int, _ mm: CGSize) -> CGFloat? {
  guard mm.width > 0, mm.height > 0 else { return nil }
  var best: (d: CGFloat, s: CGFloat)?
  for (mw, mh) in [(mm.width, mm.height), (mm.height, mm.width)] {
    let sx = CGFloat(w) / mw, sy = CGFloat(h) / mh
    let d = abs(sx - sy) / max(sx, sy)
    if best == nil || d < best!.d { best = (d, (sx + sy) / 2) }
  }
  guard let b = best, b.d <= 0.05, (1.5...15).contains(b.s) else { return nil }
  return b.s
}

/// tree 連結 a↔b（任一方向）。非 tree 鄰居回 nil
func edgeLink(_ links: [ID: Link], _ a: ID, _ b: ID) -> (link: Link, child: ID)? {
  if let l = links[b], l.parent == a { return (l, b) }
  if let l = links[a], l.parent == b { return (l, a) }
  return nil
}

/// 游標在 a 的 q 點，要跨到 b：沿邊座標以參考點為共同實體原點，按兩邊 pt/mm 比例換算（參考點在兩邊的全域沿邊座標相同）。
/// 落點放進 b 內側 2 pt。換算後超出 b 的沿邊範圍超過 slackMM 就回 nil（放行，不擋游標）
func crossPoint(_ links: [ID: Link], _ r: [ID: R], _ pt: [ID: CGFloat], from a: ID, to b: ID, at q: CGPoint,
                slackMM: CGFloat = 0) -> CGPoint? {
  guard let (l, c) = edgeLink(links, a, b) else { return nil }
  let g = l.side.horizontalLine ? q.y : q.x
  let ref = CGFloat(along(r[l.parent]!, l.side) + l.anchor)
  let g2 = ref + (g - ref) * pt[b]! / pt[a]!
  let rb = r[b]!, lo = CGFloat(along(rb, l.side)), hi = lo + CGFloat(span(rb, l.side)) - 1, slack = slackMM * pt[b]!
  guard g2 >= lo - slack, g2 <= hi + slack else { return nil }
  let t = min(max(g2, lo), hi)
  switch b == c ? l.side.opposite : l.side {      // 進入 b 的哪一側
  case .left: return CGPoint(x: CGFloat(rb.x + 2), y: t)
  case .right: return CGPoint(x: CGFloat(rb.maxX - 3), y: t)
  case .above: return CGPoint(x: t, y: CGFloat(rb.y + 2))
  case .below: return CGPoint(x: t, y: CGFloat(rb.maxY - 3))
  }
}

/// a 在 tree 上的鄰居，以及該鄰居對著 a 的哪一側
func neighbors(_ links: [ID: Link], _ a: ID) -> [(id: ID, edge: Side)] {
  links.compactMap { c, l in
    if l.parent == a { return (c, l.side) }
    if c == a { return (l.parent, l.side.opposite) }
    return nil
  }
}

func selftest() -> Never {
  var fails = 0
  func check(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL: \(what)") } }
  // 使用者機器：BenQ(1) 主、ASUS(2) 在左、FHD(3) 在下
  let r: [ID: R] = [1: R(x: 0, y: 0, w: 2560, h: 1440), 2: R(x: -1920, y: 200, w: 1920, h: 1080),
                    3: R(x: 320, y: 1440, w: 1920, h: 1080)]
  let d = derive(r, root: 1)!
  check(d.order.first == 1 && Set(d.order) == [1, 2, 3], "order")
  check(d.links[2]?.parent == 1 && d.links[2]?.side == .left && d.links[2]?.anchor == 740, "ASUS link")
  check(d.links[3]?.parent == 1 && d.links[3]?.side == .below && d.links[3]?.anchor == 1280, "FHD link")
  var off = offsets(r, d.links)
  check(layout(d.order, d.links, r, off) == r, "layout 還原原排列")
  check(valid(r, d.links), "原排列有效")
  off[2]! += 100
  let moved = layout(d.order, d.links, r, off), l2 = d.links[2]!
  check(along(moved[1]!, l2.side) + l2.anchor - along(moved[2]!, l2.side) == l2.anchor - off[2]!, "線位置 = anchor - off")
  check(valid(layout(d.order, d.links, r, off), d.links), "ASUS 下移 100 有效")
  off[2]! += 500
  check(!valid(layout(d.order, d.links, r, off), d.links), "參考線出 ASUS 範圍要拒絕")
  check(derive([1: R(x: 0, y: 0, w: 10, h: 10), 2: R(x: 10, y: 10, w: 10, h: 10)], root: 1) == nil, "只碰角不連通")
  check(derive([1: R(x: 0, y: 0, w: 10, h: 10), 2: R(x: 50, y: 0, w: 10, h: 10)], root: 1) == nil, "有縫不連通")
  check(!valid([1: R(x: 0, y: 0, w: 10, h: 10), 2: R(x: 5, y: 5, w: 10, h: 10)], [:]), "重疊無效")
  // 排列：FHD 貼到 ASUS 下方 → parent 變 ASUS
  let a = arranged(r, order: d.order, links: d.links, a: 3, side: .below, b: 2)!
  check(a.links[3]?.parent == 2 && a.links[3]?.side == .below, "排列後 FHD 掛 ASUS 下（寫死，不被 BFS 改回 BenQ）")
  check(stillValid(a.rects, order: a.order, links: a.links, root: 1), "排列結果 stillValid")
  check(arranged(r, order: d.order, links: d.links, a: 2, side: .above, b: 3) == nil, "ASUS 搬到 FHD 上方會與 BenQ 重疊或斷線")
  // 主螢幕被搬走時整體平移回 (0,0)
  check(arranged(r, order: d.order, links: d.links, a: 1, side: .right, b: 2) == nil, "搬主螢幕壓到 FHD 要拒絕")
  let two: [ID: R] = [1: r[1]!, 2: r[2]!], d3 = derive(two, root: 1)!
  let m = arranged(two, order: d3.order, links: d3.links, a: 1, side: .right, b: 2)!.rects
  check(m[1] == R(x: 0, y: 0, w: 2560, h: 1440) && m[2] == R(x: -1920, y: 0, w: 1920, h: 1080), "主螢幕回 (0,0) 並整體平移")
  // 內建在下、HP 與 LEN 並排在上：兩台都直接掛內建，且調整時 parent／anchor 不變
  let u: [ID: R] = [1: R(x: 0, y: 0, w: 1470, h: 956), 3: R(x: 642, y: -1080, w: 1920, h: 1080),
                    2: R(x: -1278, y: -1080, w: 1920, h: 1080)]
  let du = derive(u, root: 1)!
  check(du.links[2]?.parent == 1 && du.links[3]?.parent == 1 && du.links[2]?.side == .above, "HP、LEN 都掛 Built-in")
  var ou = offsets(u, du.links)
  ou[3]! += 400
  let lu = layout(du.order, du.links, u, ou)
  check(valid(lu, du.links) && stillValid(lu, order: du.order, links: du.links, root: 1), "LEN 右移後 links 仍成立")
  var cl = du.links; cl[2] = Link(parent: 3, side: .left, anchor: 540)
  check(topo(1, cl) == [1, 3, 2], "HP 改掛 LEN 後 topo 排序")
  cl[3] = Link(parent: 2, side: .right, anchor: 540)
  check(topo(1, cl) == nil, "互為 parent 成環要擋")
  var oh = offsets(u, du.links); oh[2]! -= 1300
  check(!valid(layout(du.order, du.links, u, oh), du.links), "HP 左移到參考線出範圍要擋")
  oh = offsets(u, du.links); oh[2]! += 1
  check(!valid(layout(du.order, du.links, u, oh), du.links), "HP 右移撞到 LEN 要擋")
  let pt: [ID: CGFloat] = [1: 5.06, 3: 3.61, 2: 4.00]
  let eps: CGFloat = 1e-6
  let atRef = crossPoint(du.links, u, pt, from: 1, to: 3, at: CGPoint(x: 1056, y: 5))
  check(atRef == CGPoint(x: 1056, y: -3), "參考點跨界不偏移，落在 LEN 內側 2 pt")
  let off100 = crossPoint(du.links, u, pt, from: 1, to: 3, at: CGPoint(x: 1156, y: 5))!
  check(abs(off100.x - (1056 + 100 * 3.61 / 5.06)) < eps, "離參考點 100 pt 依 pt/mm 比例換算")
  let back = crossPoint(du.links, u, pt, from: 3, to: 1, at: CGPoint(x: off100.x, y: -5))!
  check(abs(back.x - 1156) < eps && back.y == 2, "來回換算還原，落在 Built-in 內側")
  check(crossPoint(du.links, u, pt, from: 1, to: 3, at: CGPoint(x: 0, y: 5)) == nil, "換算後出 LEN 範圍要放行")
  check(crossPoint(du.links, u, pt, from: 1, to: 3, at: CGPoint(x: 0, y: 5), slackMM: 600) != nil, "容許範圍內夾進 LEN")
  check(crossPoint(du.links, u, pt, from: 2, to: 3, at: CGPoint(x: 641, y: -500)) == nil, "HP↔LEN 非 tree 鄰居不處理")
  check(Set(neighbors(du.links, 1).map { $0.id }) == [2, 3] && neighbors(du.links, 3).first?.edge == .below, "neighbors")
  check(scale(2560, 1440, CGSize(width: 597, height: 336)) != nil, "scale 正常")
  check(scale(1440, 2560, CGSize(width: 597, height: 336)) != nil, "scale 旋轉")
  check(scale(1920, 1080, .zero) == nil, "scale mm=0")
  check(scale(1920, 1080, CGSize(width: 300, height: 300)) == nil, "scale 比例不合")
  print(fails == 0 ? "selftest 通過" : "selftest 失敗 \(fails) 項")
  exit(fails == 0 ? 0 : 1)
}

// MARK: - 讀系統狀態

struct Failure: Error { let msg: String }

struct Model {
  var rects: [ID: R]            // 系統目前實際的 rect
  var ptmm: [ID: CGFloat]
  var names: [ID: String]
  var num: [ID: Int]            // 畫面編號：主螢幕 1，其餘依 ID 排序
  var order: [ID]
  var links: [ID: Link]
  var off: [ID: Int]            // 調整中的沿邊偏移（未套用）
  var calibrated = false        // links 來自校正檔
  var kids: [ID] { Array(order.dropFirst()) }
}

func displayIDs(online: Bool) -> [ID] {
  var n: UInt32 = 0
  _ = online ? CGGetOnlineDisplayList(0, nil, &n) : CGGetActiveDisplayList(0, nil, &n)
  var a = [ID](repeating: 0, count: Int(n))
  _ = online ? CGGetOnlineDisplayList(n, &a, &n) : CGGetActiveDisplayList(n, &a, &n)
  return Array(a.prefix(Int(n)))
}

func screenID(_ s: NSScreen) -> ID? {
  (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
}

// MARK: - 校正檔（參考點 anchor 校完後無法從 rects 推回，必須存）

let calibDir = NSHomeDirectory() + "/.config/monitor-align"
let calibPath = calibDir + "/calib.json", lockPath = calibDir + "/calibrating"

/// 同型號螢幕靠 rect 區分；換插孔 DisplayID 會變，所以不用 ID
func tag(_ id: ID, _ r: R) -> String {
  "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))@\(r.x),\(r.y),\(r.w)x\(r.h)"
}
struct CalEntry: Codable { let tag: String; let parent: String?; let side: Side?; let anchor: Int? }

func writeCalib(_ rects: [ID: R], _ order: [ID], _ links: [ID: Link]) {
  let es = order.map { id in
    CalEntry(tag: tag(id, rects[id]!), parent: links[id].map { tag($0.parent, rects[$0.parent]!) },
             side: links[id]?.side, anchor: links[id]?.anchor)
  }
  try? FileManager.default.createDirectory(atPath: calibDir, withIntermediateDirectories: true)
  try? JSONEncoder().encode(es).write(to: URL(fileURLWithPath: calibPath))
}

/// 檔案與目前所有螢幕（tag 含 rect）完全吻合才採用
func readCalib(_ rects: [ID: R], root: ID) -> (order: [ID], links: [ID: Link])? {
  guard let data = FileManager.default.contents(atPath: calibPath),
        let es = try? JSONDecoder().decode([CalEntry].self, from: data) else { return nil }
  let ids = Dictionary(rects.map { (tag($0.key, $0.value), $0.key) }, uniquingKeysWith: { a, _ in a })
  guard es.count == rects.count, Set(es.map { $0.tag }) == Set(ids.keys) else { return nil }
  var links: [ID: Link] = [:]
  for e in es {
    guard let c = ids[e.tag], let p = e.parent.flatMap({ ids[$0] }), let s = e.side,
          let a = e.anchor else { continue }
    links[c] = Link(parent: p, side: s, anchor: a)
  }
  return topo(root, links).map { ($0, links) }
}

func load(keeping: (order: [ID], links: [ID: Link])? = nil) throws -> Model {
  if displayIDs(online: true).contains(where: { CGDisplayIsInMirrorSet($0) != 0 }) {
    throw Failure(msg: "偵測到鏡像螢幕，請先到系統設定關閉鏡像")
  }
  let ids = displayIDs(online: false)
  guard ids.count > 1 else { throw Failure(msg: "需要至少兩台螢幕") }
  var names: [ID: String] = [:]
  for s in NSScreen.screens { if let id = screenID(s) { names[id] = s.localizedName } }
  var rects: [ID: R] = [:], ptmm: [ID: CGFloat] = [:]
  for id in ids {
    let b = CGDisplayBounds(id), name = names[id] ?? "螢幕\(id)"
    names[id] = name
    let r = R(x: Int(b.minX), y: Int(b.minY), w: Int(b.width), h: Int(b.height))
    guard let s = scale(r.w, r.h, CGDisplayScreenSize(id)) else {
      let mm = CGDisplayScreenSize(id)
      throw Failure(msg: "\(name) 回報的實體尺寸不合理（\(mm.width)x\(mm.height) mm，解析度 \(r.w)x\(r.h)），無法對齊")
    }
    rects[id] = r; ptmm[id] = s
  }
  let root = CGMainDisplayID()
  var d: (order: [ID], links: [ID: Link]), cal = false
  let kept = keeping ?? readCalib(rects, root: root)
  if let k = kept, stillValid(rects, order: k.order, links: k.links, root: root) {
    d = k                                       // 沿用：parent／anchor 不因重疊長度變動而換
    cal = keeping == nil
  } else if let n = derive(rects, root: root) {
    d = n
  } else {
    throw Failure(msg: "螢幕排列不連通（需要邊相接），請先到系統設定修正")
  }
  var num = [root: 1]
  for (i, id) in ids.filter({ $0 != root }).sorted().enumerated() { num[id] = i + 2 }
  return Model(rects: rects, ptmm: ptmm, names: names, num: num, order: d.order, links: d.links,
               off: offsets(rects, d.links), calibrated: cal)
}

func cm(_ pt: Int, _ id: ID) -> String { String(format: "%.1f cm", Double(pt) / Double(M.ptmm[id]!) / 10) }

let args = CommandLine.arguments
if args.contains("--selftest") { selftest() }

var M: Model
do { M = try load() } catch let e as Failure { print(e.msg); exit(1) } catch { exit(1) }

if args.contains("--dump") {
  for id in M.order {
    let r = M.rects[id]!, l = M.links[id]
    let rel = l.map { "parent=\(M.names[$0.parent]!) side=\($0.side) anchor=\($0.anchor)pt(\(cm($0.anchor, $0.parent)))" } ?? "root"
    print("#\(M.num[id]!) \(M.names[id]!) id=\(id) (\(r.x),\(r.y)) \(r.w)x\(r.h) \(String(format: "%.2f", M.ptmm[id]!))pt/mm \(rel)")
  }
  print(M.calibrated ? "校正檔：使用 \(calibPath)" : "校正檔：無或與目前排列不符（參考點取重疊中點）")
  exit(0)
}

// MARK: - 常駐：游標跨螢幕依實體公釐換算

var glideLast: CGPoint?, glidePush: CGFloat = 0, glideSkip = false, glideOn = true
var glideTap: CFMachPort?

/// 貼著 a 的 e 邊、且朝外的 delta（pt）；不貼邊回 0
func outward(_ r: R, _ p: CGPoint, _ e: Side, dx: CGFloat, dy: CGFloat) -> CGFloat {
  switch e {
  case .left: return p.x <= CGFloat(r.x + 1) ? max(0, -dx) : 0
  case .right: return p.x >= CGFloat(r.maxX - 2) ? max(0, dx) : 0
  case .above: return p.y <= CGFloat(r.y + 1) ? max(0, -dy) : 0
  case .below: return p.y >= CGFloat(r.maxY - 2) ? max(0, dy) : 0
  }
}

func glideStep(_ ev: CGEvent) {
  let p = ev.location, last = glideLast
  glideLast = p
  if glideSkip { glideSkip = false; return }                  // warp 後第一個事件的 delta 不可靠
  guard glideOn, !FileManager.default.fileExists(atPath: lockPath), let q = last,
        let a = M.rects.first(where: { $0.value.has(q) })?.key else { return }
  var target: CGPoint?
  if let b = M.rects.first(where: { $0.value.has(p) })?.key, b != a {
    target = crossPoint(M.links, M.rects, M.ptmm, from: a, to: b, at: q)       // 系統自己跨過去：換算沿邊位置
  } else {                                                                      // 卡在邊上往外推：pt 沒接、實體有接
    let dx = CGFloat(ev.getDoubleValueField(.mouseEventDeltaX)), dy = CGFloat(ev.getDoubleValueField(.mouseEventDeltaY))
    let hits = neighbors(M.links, a).map { ($0, outward(M.rects[a]!, p, $0.edge, dx: dx, dy: dy)) }.filter { $0.1 > 0 }
    glidePush = hits.isEmpty ? 0 : glidePush + hits.map { $0.1 }.max()!
    if glidePush > 8, let n = hits.first?.0 { target = crossPoint(M.links, M.rects, M.ptmm, from: a, to: n.id, at: p, slackMM: 30) }
  }
  guard let t = target else { return }
  glidePush = 0; glideSkip = true; glideLast = t
  ev.location = t
  CGWarpMouseCursorPosition(t)
}

func glideReload() {
  do { M = try load(); glideOn = true } catch { glideOn = false }
}

func runGlide() -> Never {
  guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) else {
    print("需要輔助使用權限：系統設定 → 隱私權與安全性 → 輔助使用，允許此程式後重新執行（重新編譯後可能要重新授權）")
    exit(1)
  }
  if !M.calibrated { print("警告：沒有校正檔或與目前排列不符，參考點取重疊中點。請先執行 monitor-align 校正並套用") }
  CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
  let cb: CGEventTapCallBack = { _, type, ev, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let t = glideTap { CGEvent.tapEnable(tap: t, enable: true) }
    } else { glideStep(ev) }
    return Unmanaged.passUnretained(ev)
  }
  guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: 1 << CGEventType.mouseMoved.rawValue, callback: cb, userInfo: nil) else {
    print("無法建立 event tap（輔助使用權限未生效？）"); exit(1)
  }
  glideTap = tap
  CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
  var mtime = (try? FileManager.default.attributesOfItem(atPath: calibPath)[.modificationDate]) as? Date
  Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in           // 校正檔更新就重讀，停用中也能自己恢復
    let m = (try? FileManager.default.attributesOfItem(atPath: calibPath)[.modificationDate]) as? Date
    if m != mtime { mtime = m; glideReload() }
  }
  NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                         queue: .main) { _ in
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { glideReload() }
  }
  print("glide 執行中（\(M.names.count) 台螢幕）。Ctrl-C 離開；校正模式開著時自動暫停")
  let app = NSApplication.shared; app.setActivationPolicy(.prohibited); app.run()
  exit(0)
}
if args.contains("--glide") { runGlide() }

// MARK: - 畫面

struct Mark { var horizontal: Bool; var pos: CGFloat; var text: String; var width: CGFloat }

/// 排列示意圖中一台螢幕的角色：normal 一般、mover 要搬的、target 貼靠的、ghost 搬完後的預覽
enum Role { case normal, mover, target, ghost }
struct MapItem { let num: Int; let name: String; let r: R; let role: Role }

final class V: NSView {
  var pm: CGFloat = 1
  var badge = ""
  var marks: [Mark] = []
  var map: [MapItem] = []              // 非空 = 排列模式，在螢幕中央畫縮小的排列示意圖
  var hints: [String] = []
  var banner = "", bannerBG = NSColor.black
  override var isFlipped: Bool { true }
  func t(_ s: String, _ p: NSPoint, _ bg: NSColor, size: CGFloat = 13) {
    NSAttributedString(string: " \(s) ", attributes: [.font: NSFont.boldSystemFont(ofSize: size),
      .foregroundColor: NSColor.white, .backgroundColor: bg]).draw(at: p)
  }
  func line(_ a: NSPoint, _ b: NSPoint, _ c: NSColor, _ w: CGFloat) {
    c.setStroke(); let p = NSBezierPath(); p.move(to: a); p.line(to: b); p.lineWidth = w; p.stroke()
  }
  func centered(_ s: String, in rc: NSRect, size: CGFloat, color: NSColor = .white) {
    let a = NSAttributedString(string: s, attributes: [.font: NSFont.boldSystemFont(ofSize: size), .foregroundColor: color])
    let z = a.size()
    a.draw(at: NSPoint(x: rc.midX - z.width / 2, y: rc.midY - z.height / 2))
  }
  func drawMap() {
    guard !map.isEmpty else { return }
    let minX = map.map { $0.r.x }.min()!, minY = map.map { $0.r.y }.min()!
    let spanX = CGFloat(map.map { $0.r.maxX }.max()! - minX), spanY = CGFloat(map.map { $0.r.maxY }.max()! - minY)
    let box = NSRect(x: bounds.midX - 330, y: bounds.midY - 230, width: 660, height: 460)
    NSColor.black.withAlphaComponent(0.9).setFill()
    NSBezierPath(roundedRect: box, xRadius: 16, yRadius: 16).fill()
    let area = NSRect(x: box.minX + 40, y: box.minY + 30, width: box.width - 80, height: box.height - 150)
    let k = min(area.width / spanX, area.height / spanY)
    let ox = area.midX - spanX * k / 2, oy = area.midY - spanY * k / 2
    for it in map {
      let rc = NSRect(x: ox + CGFloat(it.r.x - minX) * k, y: oy + CGFloat(it.r.y - minY) * k,
                      width: CGFloat(it.r.w) * k, height: CGFloat(it.r.h) * k).insetBy(dx: 2, dy: 2)
      let color: NSColor
      switch it.role {
      case .normal: color = .lightGray
      case .mover: color = .yellow
      case .target: color = .green
      case .ghost: color = .orange
      }
      let path = NSBezierPath(rect: rc)
      color.withAlphaComponent(it.role == .normal ? 0.25 : 0.5).setFill(); path.fill()
      color.setStroke(); path.lineWidth = 3
      if it.role == .ghost { path.setLineDash([8, 5], count: 2, phase: 0) }
      path.stroke()
      centered("\(it.num)", in: rc.offsetBy(dx: 0, dy: -12), size: min(44, max(16, rc.height * 0.4)))
      centered(it.name, in: rc.offsetBy(dx: 0, dy: 20), size: 12)
    }
    for (i, h) in hints.enumerated() {
      centered(h, in: NSRect(x: box.minX, y: box.maxY - 100 + CGFloat(i) * 34, width: box.width, height: 30),
               size: i == hints.count - 1 ? 18 : 14, color: i == hints.count - 1 ? .cyan : .white)
    }
  }
  override func draw(_ r: NSRect) {
    let W = bounds.width, H = bounds.height
    let bg = NSColor.black.withAlphaComponent(0.7)
    for c in 0...Int(H / (10 * pm)) {                        // 左右邊緣：離上緣幾公分
      let y = CGFloat(c * 10) * pm, len: CGFloat = c % 5 == 0 ? 60 : 30
      line(NSPoint(x: 0, y: y), NSPoint(x: len, y: y), .cyan, 2)
      line(NSPoint(x: W, y: y), NSPoint(x: W - len, y: y), .cyan, 2)
      t("\(c)", NSPoint(x: 64, y: y - 9), bg); t("\(c)", NSPoint(x: W - 100, y: y - 9), bg)
    }
    for c in 0...Int(W / (10 * pm)) {                        // 上下邊緣：離左緣幾公分
      let x = CGFloat(c * 10) * pm, len: CGFloat = c % 5 == 0 ? 60 : 30
      line(NSPoint(x: x, y: 0), NSPoint(x: x, y: len), .yellow, 2)
      line(NSPoint(x: x, y: H), NSPoint(x: x, y: H - len), .yellow, 2)
      t("\(c)", NSPoint(x: x - 12, y: 64), bg); t("\(c)", NSPoint(x: x - 12, y: H - 90), bg)
    }
    for m in marks {
      if m.horizontal {
        line(NSPoint(x: 0, y: m.pos), NSPoint(x: W, y: m.pos), .red, m.width)
        t(m.text, NSPoint(x: W / 2 - 150, y: m.pos - 28), .red)
      } else {
        line(NSPoint(x: m.pos, y: 0), NSPoint(x: m.pos, y: H), .red, m.width)
        t(m.text, NSPoint(x: m.pos + 8, y: H / 2), .red)
      }
    }
    t(badge, NSPoint(x: W / 2 - 80, y: 100), NSColor.blue.withAlphaComponent(0.8), size: 28)
    drawMap()
    let b = NSAttributedString(string: " \(banner) ", attributes: [.font: NSFont.boldSystemFont(ofSize: 22),
      .foregroundColor: NSColor.white, .backgroundColor: bannerBG])
    b.draw(at: NSPoint(x: W / 2 - b.size().width / 2, y: 30))
  }
}

var wins: [ID: NSWindow] = [:]     // 保留強參照
var views: [ID: V] = [:]
var active = 0                     // M.kids 的索引
var expected: [ID: R]?             // 上次送出的預期值，reload 時比對
var expectedPermanent = false
var arranging = false              // 空白鍵切換：false = 校正模式、true = 排列模式
var aSel: ID = 0, bSel: ID?, sideSel: Side?   // 排列：要搬的螢幕、貼靠的螢幕、貼在它的哪一側

/// 排列預覽：A 貼到 B 的 side 側後的完整排列；還沒選齊或不可行回 nil
func preview() -> Plan? {
  guard arranging, let b = bSel, let side = sideSel else { return nil }
  return arranged(layout(M.order, M.links, M.rects, M.off), order: M.order, links: M.links, a: aSel, side: side, b: b)
}

func rebuildWindows() {
  wins.values.forEach { $0.orderOut(nil) }
  wins = [:]; views = [:]
  for s in NSScreen.screens {
    guard let id = screenID(s), M.rects[id] != nil else { continue }
    let v = V(frame: NSRect(origin: .zero, size: s.frame.size)); v.pm = M.ptmm[id]!
    let w = NSWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.level = .screenSaver; w.backgroundColor = .clear; w.isOpaque = false; w.ignoresMouseEvents = true
    w.collectionBehavior = [.canJoinAllSpaces, .stationary]; w.contentView = v; w.orderFrontRegardless()
    wins[id] = w; views[id] = v
  }
}

func redraw() {
  var marks: [ID: [Mark]] = [:], items: [MapItem] = [], hints: [String] = []
  if arranging {
    let pv = preview()
    func role(_ id: ID) -> Role {
      if id == aSel { return pv != nil ? .ghost : .mover }
      return id == bSel ? .target : .normal
    }
    items = (pv?.rects ?? layout(M.order, M.links, M.rects, M.off)).map { id, r in
      MapItem(num: M.num[id]!, name: M.names[id]!, r: r, role: role(id))
    }
    let status: String
    if let b = bSel {
      if sideSel == nil { status = "→ 現在：按方向鍵，選貼在 \(M.num[b]!) 號的上／下／左／右" }
      else if pv == nil { status = "× 這個位置不可用（會重疊或造成不連通）" }
      else { status = "✓ 橘色虛線是搬完後的位置，按 Enter 確認" }
    } else {
      status = "→ 現在：按編號，選要貼靠的螢幕（綠）"
    }
    hints = ["① Tab 選要搬的螢幕（黃）　② 編號選貼靠的螢幕（綠）　③ 方向鍵選貼哪一側　④ Enter 確認", status]
  } else {
    for (i, c) in M.kids.enumerated() {
      let l = M.links[c]!, h = l.side.horizontalLine, on = i == active
      let mine = l.anchor - M.off[c]!          // 線在 child 區域座標的位置（layout: child 沿邊座標 = parent + off）
      marks[l.parent, default: []].append(Mark(horizontal: h, pos: CGFloat(l.anchor),
        text: "對 \(M.names[c]!) 參考線 \(cm(l.anchor, l.parent))", width: on ? 3 : 1.5))
      marks[c, default: []].append(Mark(horizontal: h, pos: CGFloat(mine),
        text: "\(M.names[c]!) \(h ? "橫線" : "直線") \(cm(mine, c))\(on ? "  <== 調這台" : "")", width: on ? 3 : 1.5))
    }
  }
  for (id, v) in views {
    v.marks = marks[id] ?? []; v.badge = "\(M.num[id]!)  \(M.names[id]!)"
    v.map = items; v.hints = hints
    v.banner = arranging ? "【排列模式】空白鍵／Esc → 回校正模式　q 離開程式" : "【校正模式】空白鍵 → 排列模式　Enter 套用　p 永久　f 換定位"
    v.bannerBG = arranging ? NSColor.systemBlue : NSColor.black.withAlphaComponent(0.7)
    v.needsDisplay = true
  }
}

// MARK: - 套用

try? FileManager.default.createDirectory(atPath: calibDir, withIntermediateDirectories: true)
FileManager.default.createFile(atPath: lockPath, contents: nil)          // 校正中：glide 看到就暫停
atexit { unlink(lockPath) }
var old = termios(); tcgetattr(0, &old)
var raw = old; cfmakeraw(&raw); tcsetattr(0, TCSANOW, &raw)
func quit(_ msg: String = "") -> Never { tcsetattr(0, TCSANOW, &old); print("\r\n\(msg)"); exit(msg.isEmpty ? 0 : 1) }
func say(_ s: String) { print("\r\u{1b}[K\(s)", terminator: ""); fflush(stdout) }

/// 單一交易送出所有螢幕（含主螢幕）。不在這裡讀回——重排通知是非同步的，由 reload() 統一處理。
func commit(_ r: [ID: R], permanent: Bool = false) {
  var cfg: CGDisplayConfigRef?
  guard CGBeginDisplayConfiguration(&cfg) == .success else { say("無法開始設定"); return }
  for (id, rect) in r {
    guard CGConfigureDisplayOrigin(cfg, id, Int32(rect.x), Int32(rect.y)) == .success else {
      CGCancelDisplayConfiguration(cfg); say("設定 \(M.names[id] ?? "\(id)") 失敗"); return
    }
  }
  guard CGCompleteDisplayConfiguration(cfg, permanent ? .permanently : .forSession) == .success else { say("套用失敗"); return }
  expected = r; expectedPermanent = permanent
  scheduleReload(0.5)
}

var reloadItem: DispatchWorkItem?
func scheduleReload(_ delay: Double) {
  reloadItem?.cancel()
  let item = DispatchWorkItem { reload() }
  reloadItem = item
  DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
}

func reload() {
  do { M = try load(keeping: (M.order, M.links)) } catch let e as Failure { quit(e.msg) } catch { quit("\(error)") }
  active = min(active, M.kids.count - 1)
  if arranging && (M.rects[aSel] == nil || bSel.map({ M.rects[$0] == nil }) == true) {
    arranging = false; bSel = nil; sideSel = nil      // 排列中拔掉螢幕：選取已失效，退回校正模式
  }
  rebuildWindows(); redraw()
  guard let want = expected else { return }
  expected = nil
  let diff = want.filter { M.rects[$0.key] != $0.value }
  if diff.isEmpty { writeCalib(M.rects, M.order, M.links); say(expectedPermanent ? "已永久套用（重開機後仍保留）" : "已套用（僅本次登入有效，登出後還原；按 p 可永久儲存）"); return }
  say("系統調整了位置：" + diff.map { id, w in
    let g = M.rects[id]!
    return "\(M.names[id]!) 預期(\(w.x),\(w.y)) 實際(\(g.x),\(g.y))"
  }.joined(separator: " "))
}

let start = M.rects                // r 還原用：啟動時所有螢幕的位置（含主螢幕）

// MARK: - 鍵盤

enum Key { case up, down, left, right, esc, tab, enter, space, quit, ch(UInt8) }

func parse(_ c: [UInt8]) -> [Key] {
  var out: [Key] = [], i = 0
  while i < c.count {
    if c[i] == 27, i + 2 < c.count, c[i + 1] == 91 {
      switch c[i + 2] {
      case 65: out.append(.up)
      case 66: out.append(.down)
      case 67: out.append(.right)
      case 68: out.append(.left)
      default: break
      }
      i += 3; continue
    }
    switch c[i] {
    case 27: out.append(.esc)
    case 9: out.append(.tab)
    case 13: out.append(.enter)
    case 32: out.append(.space)
    case 3, UInt8(ascii: "q"): out.append(.quit)
    default: out.append(.ch(c[i]))
    }
    i += 1
  }
  return out
}

/// delta > 0：線往上／左移（child 的 off 變大 → 線在 child 區域座標變小）
func nudge(_ delta: Int) {
  let id = M.kids[active]
  var o = M.off; o[id]! += delta
  guard valid(layout(M.order, M.links, M.rects, o), M.links) else { say("到底了（線不能離開螢幕或撞到其他螢幕）"); return }
  M.off = o
  redraw()
  say("\(M.names[id]!) \(cm(M.links[id]!.anchor - o[id]!, id))（Enter 套用）")
}

/// f：把目前這台的定位螢幕（parent）換成下一台與它邊相接的螢幕。位置不動，只改紅線相對誰。
/// 一律用「含未套用調整」的位置 cur 算，這樣先調再換不會丟掉調整。
func cycleParent() {
  let x = M.kids[active], cur = layout(M.order, M.links, M.rects, M.off), nums = M.num.sorted { $0.value < $1.value }.map { $0.key }
  let from = nums.firstIndex(of: M.links[x]!.parent)!
  for k in 1..<nums.count {
    let u = nums[(from + k) % nums.count]
    guard u != x, let c = link(cur, parent: u, child: x) else { continue }
    var l = M.links
    l[x] = c.link
    guard let o = topo(M.order[0], l) else { continue }      // 選到自己的子孫會成環，跳過
    M.order = o; M.links = l; M.off = offsets(cur, l)
    redraw()
    say("\(M.names[x]!) 改對 \(M.names[u]!) 調整（\(c.link.side.horizontalLine ? "橫線，上下鍵" : "直線，左右鍵")）")
    return
  }
  say("沒有其他可當定位的相接螢幕")
}

func setArranging(_ on: Bool) {
  arranging = on; bSel = nil; sideSel = nil
  if on { aSel = M.kids[active] }
  redraw()
  say(on ? "排列模式：照螢幕中央的示意圖操作" : "校正模式")
}

/// 排列模式的按鍵：Tab 換要搬的螢幕、編號選貼靠的螢幕、方向鍵選哪一側、Enter 確認
func handleArrange(_ k: Key) {
  switch k {
  case .tab:
    let order = M.num.sorted { $0.value < $1.value }.map { $0.key }
    aSel = order[(order.firstIndex(of: aSel)! + 1) % order.count]
    if bSel == aSel { bSel = nil }
    say("要搬的螢幕：\(M.names[aSel]!)")
  case .up: sideSel = .above
  case .down: sideSel = .below
  case .left: sideSel = .left
  case .right: sideSel = .right
  case .ch(let c) where (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(c):
    guard let id = M.num.first(where: { $0.value == Int(c - UInt8(ascii: "0")) })?.key else { say("沒有這個編號"); return }
    guard id != aSel else { say("不能貼到自己，請選另一台"); return }
    bSel = id
  case .enter:
    guard let p = preview() else { say("先選貼靠的螢幕與方向，看到橘色虛線再按 Enter"); return }
    setArranging(false)
    M.order = p.order; M.links = p.links; M.off = offsets(p.rects, p.links)   // 新拓樸先記下，reload 才會沿用
    commit(p.rects); return
  case .esc: setArranging(false); return
  case .quit: quit()
  default: break
  }
  redraw()
}

func handle(_ k: Key) {
  if case .space = k { setArranging(!arranging); return }
  if arranging { handleArrange(k); return }
  let kid = M.kids[active]
  let step = max(1, Int((2 * M.ptmm[kid]!).rounded()))
  let h = M.links[kid]!.side.horizontalLine
  switch k {
  case .up where h, .left where !h: nudge(step)
  case .down where h, .right where !h: nudge(-step)
  case .up, .down, .left, .right: say(h ? "這台只能調橫線：用上下鍵" : "這台只能調直線：用左右鍵")
  case .tab: active = (active + 1) % M.kids.count; redraw(); say("調 \(M.names[M.kids[active]]!)")
  case .enter: commit(layout(M.order, M.links, M.rects, M.off))
  case .quit: quit()
  case .esc, .space: break
  case .ch(let c):
    switch c {
    case UInt8(ascii: ","): nudge(1)
    case UInt8(ascii: "."): nudge(-1)
    case UInt8(ascii: "f"): cycleParent()
    case UInt8(ascii: "p"): commit(layout(M.order, M.links, M.rects, M.off), permanent: true)
    case UInt8(ascii: "r"):
      if Set(start.keys) == Set(M.rects.keys) { commit(start) } else { say("螢幕組合已改變，無法還原") }
    default: break
    }
  }
}

rebuildWindows(); redraw()
NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                       object: nil, queue: .main) { _ in scheduleReload(0.3) }
print("【校正模式】Tab 換螢幕  f 換定位螢幕  上下／左右=移線(約 2mm)  , . 微調 1pt  Enter 套用(僅本次登入)  p 永久套用  r 還原  q 離開\r")
print("【排列模式】空白鍵切換：Tab 選要搬的螢幕 → 編號選貼靠的螢幕 → 方向鍵選哪一側 → Enter（螢幕中央有示意圖）\r")
print("注意：Enter 只在本次登入有效（登出後還原），要保留請按 p。游標只在參考線那一點完全不跳。\r")

FileHandle.standardInput.readabilityHandler = { h in
  let d = h.availableData; if d.isEmpty { return }
  let keys = parse([UInt8](d))
  DispatchQueue.main.async { keys.forEach(handle) }
}
let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.run()
