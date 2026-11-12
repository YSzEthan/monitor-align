import AppKit
import CoreGraphics
import ServiceManagement

// 多螢幕游標修正：常駐選單列，游標跨過相鄰螢幕的交界時，依實體公釐換算沿邊位置再放到對面螢幕。
// 每組相鄰螢幕各自校正一條參考線（滑鼠為主的引導式校正），不移動螢幕、沒有 parent。
// 一律以 CGDirectDisplayID 為 key、CGDisplayBounds 座標（左上原點，整數 pt）。
// 用法：app 模式不帶參數；CLI：--selftest、--dump。

typealias ID = CGDirectDisplayID

// MARK: - 純幾何（不碰 CG 呼叫，--selftest 直接測）

struct R: Equatable {
  var x, y, w, h: Int
  var maxX: Int { x + w }
  var maxY: Int { y + h }
  func has(_ p: CGPoint) -> Bool { p.x >= CGFloat(x) && p.x < CGFloat(maxX) && p.y >= CGFloat(y) && p.y < CGFloat(maxY) }
  func hits(_ o: R) -> Bool { x < o.maxX && o.x < maxX && y < o.maxY && o.y < maxY }
}

/// b 在 a 的哪一側
enum Side: String, Codable {
  case left, right, above, below
  var opposite: Side {
    switch self { case .left: .right; case .right: .left; case .above: .below; case .below: .above }
  }
  /// 左右鄰居的參考線是橫線（沿邊軸是 y），上下鄰居是直線（沿邊軸是 x）
  var horizontalLine: Bool { self == .left || self == .right }
}

func along(_ r: R, _ s: Side) -> Int { s.horizontalLine ? r.y : r.x }
func span(_ r: R, _ s: Side) -> Int { s.horizontalLine ? r.h : r.w }

/// 兩台螢幕之間的一條參考邊（雙向各存一筆）。side = b 相對 a 的側；ref 是各自螢幕的區域座標（離上緣／左緣幾 pt）
struct Edge { let a, b: ID; let side: Side; let refA, refB: CGFloat }

/// 一組相鄰螢幕。side 固定 .right／.below（a 在左／上）
struct Pair: Equatable { let a, b: ID; let side: Side; var refA, refB: Int }

func makeEdges(_ pairs: [Pair]) -> [Edge] {
  pairs.flatMap { p in
    [Edge(a: p.a, b: p.b, side: p.side, refA: CGFloat(p.refA), refB: CGFloat(p.refB)),
     Edge(a: p.b, b: p.a, side: p.side.opposite, refA: CGFloat(p.refB), refB: CGFloat(p.refA))]
  }
}

/// 所有相鄰螢幕組：b 完全在 a 的右／下側、沿邊重疊 > 0、空隙小於兩台中較小的寬（高）且沒壓到第三台。
/// 預設參考線取重疊中點（兩台全域位置相同）；keep 裡 a、b、side 都沒變且 ref 仍在範圍內的沿用
func derivePairs(_ r: [ID: R], keep: [Pair]) -> [Pair] {
  let ids = r.keys.sorted()
  var out: [Pair] = []
  for (i, x) in ids.enumerated() {
    for y in ids[(i + 1)...] {
      var (a, b, side) = (x, y, Side.right)
      if r[a]!.maxX <= r[b]!.x {
      } else if r[b]!.maxX <= r[a]!.x { swap(&a, &b)
      } else if r[a]!.maxY <= r[b]!.y { side = .below
      } else if r[b]!.maxY <= r[a]!.y { swap(&a, &b); side = .below
      } else { continue }
      let ra = r[a]!, rb = r[b]!, h = side.horizontalLine
      let lo = h ? max(ra.y, rb.y) : max(ra.x, rb.x), hi = h ? min(ra.maxY, rb.maxY) : min(ra.maxX, rb.maxX)
      let gap = h ? R(x: ra.maxX, y: lo, w: rb.x - ra.maxX, h: hi - lo) : R(x: lo, y: ra.maxY, w: hi - lo, h: rb.y - ra.maxY)
      let gapLen = h ? gap.w : gap.h
      guard hi > lo, gapLen < (h ? min(ra.w, rb.w) : min(ra.h, rb.h)),
            gapLen == 0 || !r.contains(where: { $0.key != a && $0.key != b && $0.value.hits(gap) }) else { continue }
      let mid = (lo + hi) >> 1, d = Pair(a: a, b: b, side: side, refA: mid - along(ra, side), refB: mid - along(rb, side))
      if let k = keep.first(where: { $0.a == a && $0.b == b && $0.side == side }),
         (0..<span(ra, side)).contains(k.refA), (0..<span(rb, side)).contains(k.refB) { out.append(k) } else { out.append(d) }
    }
  }
  return out
}

/// 游標在 a 的 q 點，要跨到 b：全域沿邊座標 → a 區域 → 依兩台 pt/mm 比例以參考點為原點換算 → b 區域 → 全域。
/// 落點放進 b 面向 a 那側內 2 pt。換算後超出 b 範圍超過 slackMM 就回 nil（放行，不擋游標）
func crossPoint(_ edges: [Edge], _ r: [ID: R], _ pt: [ID: CGFloat], from a: ID, to b: ID, at q: CGPoint,
                slackMM: CGFloat = 0) -> CGPoint? {
  guard let e = edges.first(where: { $0.a == a && $0.b == b }) else { return nil }
  let rb = r[b]!, n = CGFloat(span(rb, e.side)) - 1, slack = slackMM * pt[b]!
  let u = (e.side.horizontalLine ? q.y : q.x) - CGFloat(along(r[a]!, e.side))
  let u2 = e.refB + (u - e.refA) * pt[b]! / pt[a]!
  guard u2 >= -slack, u2 <= n + slack else { return nil }
  let t = CGFloat(along(rb, e.side)) + min(max(u2, 0), n)
  switch e.side.opposite {
  case .left: return CGPoint(x: CGFloat(rb.x + 2), y: t)
  case .right: return CGPoint(x: CGFloat(rb.maxX - 3), y: t)
  case .above: return CGPoint(x: t, y: CGFloat(rb.y + 2))
  case .below: return CGPoint(x: t, y: CGFloat(rb.maxY - 3))
  }
}

/// a 的鄰居，以及該鄰居對著 a 的哪一側
func neighbors(_ edges: [Edge], _ a: ID) -> [(id: ID, edge: Side)] {
  edges.filter { $0.a == a }.map { ($0.b, $0.side) }
}

/// 貼著 a 的 e 邊、且朝外的 delta（pt）；不貼邊回 0
func outward(_ r: R, _ p: CGPoint, _ e: Side, dx: CGFloat, dy: CGFloat) -> CGFloat {
  switch e {
  case .left: return p.x <= CGFloat(r.x + 1) ? max(0, -dx) : 0
  case .right: return p.x >= CGFloat(r.maxX - 2) ? max(0, dx) : 0
  case .above: return p.y <= CGFloat(r.y + 1) ? max(0, -dy) : 0
  case .below: return p.y >= CGFloat(r.maxY - 2) ? max(0, dy) : 0
  }
}

/// 卡在邊上往外推時，要依序試的鄰居：朝外分量大的先，同分依 id，角落斜推順序才穩定
func pushOrder(_ r: R, _ p: CGPoint, _ nbs: [(id: ID, edge: Side)], dx: CGFloat, dy: CGFloat) -> [(id: ID, push: CGFloat)] {
  nbs.map { ($0.id, outward(r, p, $0.edge, dx: dx, dy: dy)) }.filter { $0.1 > 0 }
    .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
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

// MARK: - 校正檔 v2（純資料；key 與解析度對得上才沿用，與螢幕排列無關）

/// 同型號且序號為 0 的兩台 base 會撞號：只有撞到時才依位置（左→右、上→下）加 #1、#2
func uniqueKeys(_ base: [ID: String], _ r: [ID: R]) -> [ID: String] {
  var out = base
  for (k, ids) in Dictionary(grouping: base.keys, by: { base[$0]! }) where ids.count > 1 {
    let sorted = ids.sorted { (r[$0]!.x, r[$0]!.y, $0) < (r[$1]!.x, r[$1]!.y, $1) }
    for (i, id) in sorted.enumerated() { out[id] = "\(k)#\(i + 1)" }
  }
  return out
}

/// 校正檔裡認人的字串：唯一化後的 key + 解析度。解析度改了就不吻合，該組回預設
func calTags(_ base: [ID: String], _ r: [ID: R]) -> [ID: String] {
  uniqueKeys(base, r).reduce(into: [:]) { $0[$1.key] = "\($1.value)/\(r[$1.key]!.w)x\(r[$1.key]!.h)" }
}

struct CalPair: Codable, Equatable { let a: String; let b: String; let side: Side; let refA: Int; let refB: Int }
struct CalFile: Codable { let version: Int; let pairs: [CalPair] }

func encodeCalib(_ pairs: [CalPair]) -> Data {
  let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
  return (try? enc.encode(CalFile(version: 2, pairs: pairs))) ?? Data()
}

/// 不是 v2（含 #4／#5 的舊格式）一律當沒有校正
func decodeCalib(_ data: Data) -> [CalPair] {
  guard let f = try? JSONDecoder().decode(CalFile.self, from: data), f.version == 2 else { return [] }
  return f.pairs
}

/// 檔案裡的組對到目前螢幕（兩端 tag 都在才算）
func matchCalib(_ saved: [CalPair], live: [String: ID]) -> [Pair] {
  saved.compactMap { c in
    guard let a = live[c.a], let b = live[c.b] else { return nil }
    return Pair(a: a, b: b, side: c.side, refA: c.refA, refB: c.refB)
  }
}

/// 新校正的組覆蓋同兩台的舊紀錄；沒接著的螢幕的舊紀錄保留
func mergeCalib(_ old: [CalPair], _ new: [CalPair]) -> [CalPair] {
  old.filter { o in !new.contains { Set([$0.a, $0.b]) == Set([o.a, o.b]) } } + new
}

// MARK: - 版號與更新（純資料；不碰網路、檔案與 AppKit）

let releaseRepo = "YSzEthan/monitor-align"

/// 版號：X.Y.Z（stable）或 X.Y.Z-beta.N。其他 prerelease（-rc 等）一律拒絕
struct Semver: Comparable {
  let core: [Int]   // major、minor、patch
  let beta: Int?    // nil = stable
  var text: String { core.map(String.init).joined(separator: ".") + (beta.map { "-beta.\($0)" } ?? "") }
  /// semver 優先序：先比 X.Y.Z；相同時 stable 大於 beta，beta 之間比 N（數字）
  static func < (a: Semver, b: Semver) -> Bool {
    if a.core != b.core { return a.core.lexicographicallyPrecedes(b.core) }
    switch (a.beta, b.beta) {
    case let (x?, y?): return x < y
    case (_?, nil): return true
    default: return false
    }
  }
}

private func digits(_ s: Substring) -> Int? { !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber } ? Int(s) : nil }

/// `v` 前綴可有可無（CFBundleShortVersionString 不帶 v、tag 帶 v）
func parseSemver(_ s: String) -> Semver? {
  let t = s.hasPrefix("v") ? s.dropFirst() : Substring(s)
  let halves = t.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
  let nums = halves[0].split(separator: ".", omittingEmptySubsequences: false).map(digits)
  guard nums.count == 3, !nums.contains(where: { $0 == nil }) else { return nil }
  var beta: Int?
  if halves.count == 2 {
    let p = halves[1].split(separator: ".", omittingEmptySubsequences: false)
    guard p.count == 2, p[0] == "beta", let n = digits(p[1]) else { return nil }
    beta = n
  }
  return Semver(core: nums.compactMap { $0 }, beta: beta)
}

/// 只收標準寫法的 tag（`v` 開頭、沒有前導 0）：它會被拿去組下載網址，不能有任何額外字元
func canonicalTag(_ tag: String) -> Semver? {
  guard let v = parseSemver(tag), "v" + v.text == tag else { return nil }
  return v
}

func isNewer(_ latest: String, than current: String) -> Bool {
  guard let a = parseSemver(latest), let b = parseSemver(current) else { return false }
  return a > b
}

func assetName(_ tag: String) -> String? { canonicalTag(tag).map { "MonitorAlign-v\($0.text)-arm64.zip" } }

/// 下載網址由 app 自己用 tag 組，不採用 API 回傳的 browser_download_url
func downloadURL(_ tag: String, sha: Bool = false) -> URL? {
  guard let n = assetName(tag) else { return nil }
  return URL(string: "https://github.com/\(releaseRepo)/releases/download/\(tag)/\(n)\(sha ? ".sha256" : "")")
}

/// `/releases` 的 JSON 陣列 → 最新的 tag。略過 draft；includeBeta 為 false 時略過 beta；tag 不合標準寫法的整筆略過
func pickLatest(_ data: Data, includeBeta: Bool) -> String? {
  struct Rel: Decodable { let tag_name: String; let draft: Bool; let prerelease: Bool }
  guard let rels = try? JSONDecoder().decode([Rel].self, from: data) else { return nil }
  return rels.compactMap { r -> Semver? in
    guard !r.draft, let v = canonicalTag(r.tag_name), includeBeta || (!r.prerelease && v.beta == nil) else { return nil }
    return v
  }.max().map { "v" + $0.text }
}

/// `.sha256` 檔（`<64 位小寫十六進位>  <檔名>`）→ 雜湊；檔名不符或格式不對就是 nil
func parseSha256(_ text: String, file: String) -> String? {
  let f = text.split(whereSeparator: \.isWhitespace)
  guard f.count == 2, f[1] == file, f[0].count == 64, f[0].allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }) else { return nil }
  return String(f[0])
}

func selftest() -> Never {
  var fails = 0
  func check(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL: \(what)") } }
  let eps: CGFloat = 1e-6
  // Built-in(1) 在下，HP(2) 與 LEN(3) 並排在上，HP 右緣 642 剛好貼 LEN 左緣
  let u: [ID: R] = [1: R(x: 0, y: 0, w: 1470, h: 956), 3: R(x: 642, y: -1080, w: 1920, h: 1080),
                    2: R(x: -1278, y: -1080, w: 1920, h: 1080)]
  let pt: [ID: CGFloat] = [1: 5.06, 3: 3.61, 2: 4.00]
  let pu = derivePairs(u, keep: [])
  check(pu.count == 3, "三台各自相鄰得 3 組（沒有 tree 排除）")
  check(pu.contains(Pair(a: 2, b: 1, side: .below, refA: 1599, refB: 321)), "HP 在 Built-in 上方，參考線取重疊中點")
  check(pu.contains(Pair(a: 3, b: 1, side: .below, refA: 414, refB: 1056)), "LEN 在 Built-in 上方")
  check(pu.contains(Pair(a: 2, b: 3, side: .right, refA: 540, refB: 540)), "HP↔LEN 貼合也成組")
  let eu = makeEdges(pu)
  check(eu.count == 6, "每組雙向兩筆")
  check(crossPoint(eu, u, pt, from: 1, to: 3, at: CGPoint(x: 1056, y: 5)) == CGPoint(x: 1056, y: -3), "參考點跨界不偏移，落在 LEN 內側 2 pt")
  let off100 = crossPoint(eu, u, pt, from: 1, to: 3, at: CGPoint(x: 1156, y: 5))!
  check(abs(off100.x - (1056 + 100 * 3.61 / 5.06)) < eps, "離參考點 100 pt 依 pt/mm 比例換算")
  let back = crossPoint(eu, u, pt, from: 3, to: 1, at: CGPoint(x: off100.x, y: -5))!
  check(abs(back.x - 1156) < eps && back.y == 2, "來回換算還原，落在 Built-in 內側")
  check(crossPoint(eu, u, pt, from: 1, to: 3, at: CGPoint(x: 0, y: 5)) == nil, "換算後出 LEN 範圍要放行")
  check(crossPoint(eu, u, pt, from: 1, to: 3, at: CGPoint(x: 0, y: 5), slackMM: 600) != nil, "容許範圍內夾進 LEN")
  check(crossPoint(eu, u, pt, from: 2, to: 3, at: CGPoint(x: 641, y: -540)) == CGPoint(x: 644, y: -540), "HP→LEN（無縫）參考點不偏移")
  check(Set(neighbors(eu, 1).map { $0.id }) == [2, 3] && neighbors(eu, 3).contains { $0.id == 1 && $0.edge == .below }, "neighbors")
  // 配對：HP、LEN 中間有縫（HP 右緣 642、LEN 左緣 907）
  let ug: [ID: R] = [1: u[1]!, 2: u[2]!, 3: R(x: 907, y: -1080, w: 1920, h: 1080)]
  let hl = Pair(a: 2, b: 3, side: .right, refA: 540, refB: 540)
  let pr = derivePairs(ug, keep: [])
  check(pr.contains(hl), "HP↔LEN 有縫仍成組，預設取重疊中點")
  var pk = [hl]; pk[0].refB = 580
  let eg = makeEdges(pk)
  check(crossPoint(eg, ug, pt, from: 2, to: 3, at: CGPoint(x: 640, y: -540)) == CGPoint(x: 909, y: -500), "refB 調成 580 後同點落 -500")
  let far = crossPoint(eg, ug, pt, from: 2, to: 3, at: CGPoint(x: 640, y: -440))!
  check(abs(far.y - (-1080 + 580 + 100 * 3.61 / 4)) < eps, "離參考點 100 pt 依 pt/mm 比例")
  let back2 = crossPoint(eg, ug, pt, from: 3, to: 2, at: CGPoint(x: 909, y: -500))!
  check(abs(back2.y - (-540)) < eps && back2.x == 639, "LEN→HP 還原，落在 HP 右緣內側")
  check(derivePairs(ug, keep: pk).contains(pk[0]), "合法的舊值沿用")
  var bad = pk; bad[0].refB = 99999
  check(derivePairs(ug, keep: bad).contains(hl), "範圍外的舊值丟棄，回預設")
  var ug4 = ug; ug4[4] = R(x: 650, y: -1080, w: 200, h: 1080)
  check(!derivePairs(ug4, keep: []).contains { $0.a == 2 && $0.b == 3 }, "縫中有第三台就不成對")
  var ugf = ug; ugf[3] = R(x: 2640, y: -1080, w: 1920, h: 1080)
  check(!derivePairs(ugf, keep: []).contains { $0.a == 2 && $0.b == 3 }, "空隙超過螢幕寬不成對")
  check(derivePairs([1: R(x: 0, y: 0, w: 10, h: 10), 2: R(x: 10, y: 10, w: 10, h: 10)], keep: []).isEmpty, "只碰角不成組")
  let ur: [ID: R] = [1: u[1]!, 5: u[2]!, 3: ug[3]!]
  check(derivePairs(ur, keep: []).contains { $0.a == 5 && $0.b == 3 && $0.side == .right }, "id 順序相反仍是 a 在左")
  check(derivePairs([:], keep: []).isEmpty && derivePairs([1: u[1]!], keep: []).isEmpty, "0 台、1 台不 crash")
  let sh = ug.mapValues { R(x: $0.x + 100, y: $0.y + 50, w: $0.w, h: $0.h) }
  check(crossPoint(makeEdges(pk), sh, pt, from: 2, to: 3, at: CGPoint(x: 740, y: -490)) == CGPoint(x: 1009, y: -450), "整體平移：區域 ref 不變，結果跟著平移")
  // 角落斜推：右分量大先試右，下分量大先試下
  let rc = R(x: 0, y: 0, w: 100, h: 100), nb: [(id: ID, edge: Side)] = [(7, .below), (8, .right)]
  check(pushOrder(rc, CGPoint(x: 99, y: 99), nb, dx: 3, dy: 1).map { $0.id } == [8, 7], "角落往右下斜推，右分量大先試右")
  check(pushOrder(rc, CGPoint(x: 99, y: 99), nb, dx: 1, dy: 3).map { $0.id } == [7, 8], "下分量大先試下")
  check(pushOrder(rc, CGPoint(x: 50, y: 50), nb, dx: 3, dy: 3).isEmpty, "沒貼邊不算推")
  // 校正檔 v2
  let base: [ID: String] = [1: "1-2-0", 2: "1-2-0", 3: "9-9-9"]
  let ku = uniqueKeys(base, [1: R(x: 2560, y: 0, w: 10, h: 10), 2: R(x: 0, y: 0, w: 10, h: 10), 3: R(x: -100, y: 0, w: 10, h: 10)])
  check(ku[2] == "1-2-0#1" && ku[1] == "1-2-0#2" && ku[3] == "9-9-9", "key 撞號依位置加後綴，不撞的不動")
  let tg = calTags([1: "a", 2: "b", 3: "c"], ug)
  check(tg[3] == "c/1920x1080" && tg[1] == "a/1470x956", "tag = key/解析度")
  let live = Dictionary(uniqueKeysWithValues: tg.map { ($1, $0) })
  let saved = [CalPair(a: tg[2]!, b: tg[3]!, side: .right, refA: 540, refB: 580)]
  check(matchCalib(saved, live: live) == [Pair(a: 2, b: 3, side: .right, refA: 540, refB: 580)], "校正檔對回目前螢幕")
  var tg2 = tg; tg2[3] = "c/1280x720"
  check(matchCalib(saved, live: Dictionary(uniqueKeysWithValues: tg2.map { ($1, $0) })).isEmpty, "解析度改了不吻合")
  var moved = ug; moved[3] = R(x: 1000, y: -1060, w: 1920, h: 1080)
  check(derivePairs(moved, keep: matchCalib(saved, live: live)).contains(Pair(a: 2, b: 3, side: .right, refA: 540, refB: 580)), "系統設定移動排列後校正仍沿用")
  check(decodeCalib(encodeCalib(saved)) == saved, "v2 JSON 來回一致")
  check(decodeCalib(Data(#"{"entries":[],"pairs":[{"a":"x","b":"y","side":"right","refA":1,"refB":2}]}"#.utf8)).isEmpty, "舊格式（#5）忽略")
  check(decodeCalib(Data(#"[{"tag":"x"}]"#.utf8)).isEmpty && decodeCalib(Data("壞掉".utf8)).isEmpty, "舊陣列格式與壞檔忽略")
  let other = CalPair(a: "x", b: "y", side: .below, refA: 1, refB: 2), upd = CalPair(a: tg[2]!, b: tg[3]!, side: .right, refA: 1, refB: 2)
  check(mergeCalib(saved + [other], [upd]) == [other, upd], "合併：覆蓋同兩台、保留沒接著的")
  check(scale(2560, 1440, CGSize(width: 597, height: 336)) != nil, "scale 正常")
  check(scale(1440, 2560, CGSize(width: 597, height: 336)) != nil, "scale 旋轉")
  check(scale(1920, 1080, .zero) == nil, "scale mm=0")
  check(scale(1920, 1080, CGSize(width: 300, height: 300)) == nil, "scale 比例不合")
  // 版號與更新
  check(parseSemver("v0.1.0-beta.2") == Semver(core: [0, 1, 0], beta: 2) && parseSemver("1.2.3") == Semver(core: [1, 2, 3], beta: nil), "parseSemver：v 前綴可有可無、beta")
  for bad in ["dev", "", "v", "1.2", "1.2.3.4", "1.2.x", "v1.2.3-rc.1", "v1.2.3-beta", "v1.2.3-beta.", "v1.2.3-beta.x", "v1.2.3-", "v1.2.3-beta.1.2", "-1.2.3", "+1.2.3", "１.2.3", "1.2.3-Beta.1", "1..3"] {
    check(parseSemver(bad) == nil, "parseSemver 拒絕：\(bad)")
  }
  check(isNewer("v0.1.1", than: "0.1.0") && !isNewer("v0.1.0", than: "0.1.0") && !isNewer("v0.1.0", than: "0.1.1"), "isNewer：patch")
  check(isNewer("v0.10.0", than: "0.9.0") && isNewer("v1.0.0", than: "0.99.99"), "isNewer：數字比較，不是字串")
  check(isNewer("v0.2.0", than: "0.2.0-beta.9") && !isNewer("v0.2.0-beta.9", than: "0.2.0"), "isNewer：stable 大於同版 beta")
  check(isNewer("v0.2.0-beta.10", than: "0.2.0-beta.9") && !isNewer("v0.2.0-beta.2", than: "0.2.0-beta.10"), "isNewer：beta N 比數字")
  check(isNewer("v0.2.0-beta.1", than: "0.1.9") && !isNewer("v0.1.9", than: "0.2.0-beta.1"), "isNewer：下一版的 beta 大於上一版 stable")
  check(!isNewer("v9.9.9", than: "dev") && !isNewer("garbage", than: "0.1.0"), "isNewer：dev 版或壞版號不提示")
  check(assetName("v0.1.0-beta.1") == "MonitorAlign-v0.1.0-beta.1-arm64.zip" && assetName("v0.1.0") == "MonitorAlign-v0.1.0-arm64.zip", "assetName")
  for bad in ["0.1.0", "v01.2.3", "v0.1.0/../x", "v0.1.0?x=1", "v0.1.0 ", "v0.1.0-rc.1"] { check(assetName(bad) == nil && downloadURL(bad) == nil, "tag 不合標準寫法不組網址：\(bad)") }
  check(downloadURL("v0.1.0-beta.1")?.absoluteString == "https://github.com/YSzEthan/monitor-align/releases/download/v0.1.0-beta.1/MonitorAlign-v0.1.0-beta.1-arm64.zip", "downloadURL")
  check(downloadURL("v0.1.0", sha: true)?.absoluteString.hasSuffix("/v0.1.0/MonitorAlign-v0.1.0-arm64.zip.sha256") == true, "downloadURL .sha256")
  let rels = Data(#"""
    [{"tag_name":"v0.2.0-beta.3","draft":false,"prerelease":true},
     {"tag_name":"v0.2.0-beta.4","draft":true,"prerelease":true},
     {"tag_name":"v0.1.5","draft":false,"prerelease":false},
     {"tag_name":"v0.1.10","draft":false,"prerelease":false},
     {"tag_name":"v0.3.0-rc.1","draft":false,"prerelease":true},
     {"tag_name":"nightly","draft":false,"prerelease":false},
     {"tag_name":"v9.0.0","draft":false,"prerelease":true}]
    """#.utf8)
  check(pickLatest(rels, includeBeta: false) == "v0.1.10", "pickLatest：stable 通道略過 beta、draft、壞 tag；0.1.10 > 0.1.5")
  check(pickLatest(rels, includeBeta: true) == "v9.0.0", "pickLatest：beta 通道取最大（含 prerelease 旗標的 stable 形式 tag）")
  let rels2 = Data(#"[{"tag_name":"v0.2.0-beta.3","draft":false,"prerelease":true},{"tag_name":"v0.2.0","draft":false,"prerelease":false},{"tag_name":"v0.1.9","draft":false,"prerelease":false}]"#.utf8)
  check(pickLatest(rels2, includeBeta: true) == "v0.2.0", "pickLatest：stable 發出後，beta 通道選到 stable")
  check(pickLatest(Data("[]".utf8), includeBeta: true) == nil && pickLatest(Data("壞掉".utf8), includeBeta: false) == nil && pickLatest(Data(#"{"message":"rate limit"}"#.utf8), includeBeta: true) == nil, "pickLatest：空清單、壞 JSON、API 錯誤物件")
  let h = String(repeating: "ab", count: 32)
  check(parseSha256("\(h)  MonitorAlign-v0.1.0-arm64.zip\n", file: "MonitorAlign-v0.1.0-arm64.zip") == h, "parseSha256")
  check(parseSha256("\(h)  other.zip", file: "MonitorAlign-v0.1.0-arm64.zip") == nil && parseSha256("zz  MonitorAlign-v0.1.0-arm64.zip", file: "MonitorAlign-v0.1.0-arm64.zip") == nil && parseSha256(h.uppercased() + "  f", file: "f") == nil && parseSha256("", file: "f") == nil, "parseSha256：檔名不符、格式不對、大寫、空")
  print(fails == 0 ? "selftest 通過" : "selftest 失敗 \(fails) 項")
  exit(fails == 0 ? 0 : 1)
}

// MARK: - 讀系統狀態

struct Failure: Error, CustomStringConvertible { let msg: String; var description: String { msg } }

struct Model {
  var rects: [ID: R]
  var ptmm: [ID: CGFloat]
  var names: [ID: String]
  var tags: [ID: String]        // 校正檔用的 key/解析度
  var pairs: [Pair]
  var edges: [Edge]
  var uncal: Int                // 還沒校正（用預設中點）的組數
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

let calibDir = NSHomeDirectory() + "/.config/monitor-align"
let calibPath = calibDir + "/calib.json"

func readCalib() -> [CalPair] { FileManager.default.contents(atPath: calibPath).map(decodeCalib) ?? [] }

func writeCalib(_ pairs: [CalPair]) {
  try? FileManager.default.createDirectory(atPath: calibDir, withIntermediateDirectories: true)
  try? encodeCalib(pairs).write(to: URL(fileURLWithPath: calibPath), options: .atomic)
}

/// 讀系統螢幕與校正檔。不能用就丟 Failure（app 模式顯示在狀態行，不退出）
func load() throws -> Model {
  if displayIDs(online: true).contains(where: { CGDisplayIsInMirrorSet($0) != 0 }) {
    throw Failure(msg: "偵測到鏡像螢幕，請先到系統設定關閉鏡像")
  }
  let ids = displayIDs(online: false)
  guard ids.count > 1 else { throw Failure(msg: "需要至少兩台螢幕") }
  var names: [ID: String] = [:]
  for s in NSScreen.screens { if let id = screenID(s) { names[id] = s.localizedName } }
  var rects: [ID: R] = [:], ptmm: [ID: CGFloat] = [:], base: [ID: String] = [:]
  for id in ids {
    let b = CGDisplayBounds(id), name = names[id] ?? "螢幕\(id)"
    names[id] = name
    let r = R(x: Int(b.minX), y: Int(b.minY), w: Int(b.width), h: Int(b.height))
    let mm = CGDisplayScreenSize(id)
    guard let s = scale(r.w, r.h, mm) else {
      throw Failure(msg: "\(name) 回報的實體尺寸不合理（\(mm.width)x\(mm.height) mm，解析度 \(r.w)x\(r.h)）")
    }
    rects[id] = r; ptmm[id] = s
    base[id] = "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
  }
  let tags = calTags(base, rects)
  let saved = matchCalib(readCalib(), live: Dictionary(tags.map { ($1, $0) }, uniquingKeysWith: { a, _ in a }))
  let pairs = derivePairs(rects, keep: saved)
  guard !pairs.isEmpty else { throw Failure(msg: "沒有相鄰的螢幕組（要邊相接，或只隔一小段縫）") }
  return Model(rects: rects, ptmm: ptmm, names: names, tags: tags, pairs: pairs, edges: makeEdges(pairs),
               uncal: pairs.filter { !saved.contains($0) }.count)
}

func cm(_ pt: Int, _ id: ID, _ m: Model) -> String { String(format: "%.1f cm", Double(pt) / Double(m.ptmm[id]!) / 10) }

func dump() -> Never {
  do {
    let m = try load()
    for id in m.rects.keys.sorted() {
      let r = m.rects[id]!
      print("\(m.names[id]!) id=\(id) key=\(m.tags[id]!) (\(r.x),\(r.y)) \(r.w)x\(r.h) \(String(format: "%.2f", m.ptmm[id]!))pt/mm")
    }
    for p in m.pairs {
      print("相鄰 \(m.names[p.a]!) → \(m.names[p.b]!) side=\(p.side) refA=\(p.refA)pt(\(cm(p.refA, p.a, m))) refB=\(p.refB)pt(\(cm(p.refB, p.b, m)))")
    }
    print("未校正 \(m.uncal) 組；校正檔 \(calibPath)")
    exit(0)
  } catch { print("\(error)"); exit(1) }
}

// MARK: - 常駐：游標跨螢幕依實體公釐換算

var M: Model?                      // nil = 不支援（原因在 loadError），游標一律放行
var loadError: String?
var glidePaused = false            // 使用者在選單暫停
var calibrating = false            // 校正中暫停
var glideLast: CGPoint?, glidePush: CGFloat = 0, glideSkip = false
var glideTap: CFMachPort?

func reloadModel() {
  do { M = try load(); loadError = nil } catch { M = nil; loadError = "\(error)" }
}

func glideStep(_ ev: CGEvent) {
  let p = ev.location, last = glideLast
  glideLast = p
  if glideSkip { glideSkip = false; return }                  // warp 後第一個事件的 delta 不可靠
  guard !glidePaused, !calibrating, let m = M, let q = last,
        let a = m.rects.first(where: { $0.value.has(q) })?.key else { return }
  var target: CGPoint?
  if let b = m.rects.first(where: { $0.value.has(p) })?.key, b != a {
    target = crossPoint(m.edges, m.rects, m.ptmm, from: a, to: b, at: q)       // 系統自己跨過去：換算沿邊位置
  } else {                                                                      // 卡在邊上往外推：pt 沒接、實體有接
    let dx = CGFloat(ev.getDoubleValueField(.mouseEventDeltaX)), dy = CGFloat(ev.getDoubleValueField(.mouseEventDeltaY))
    let hits = pushOrder(m.rects[a]!, p, neighbors(m.edges, a), dx: dx, dy: dy)
    glidePush = hits.isEmpty ? 0 : glidePush + hits[0].push
    if glidePush > 8 {            // 同側有多個鄰居時依序試，取第一個換算得出來的
      target = hits.lazy.compactMap { crossPoint(m.edges, m.rects, m.ptmm, from: a, to: $0.id, at: p, slackMM: 30) }.first
    }
  }
  guard let t = target else { return }
  glidePush = 0; glideSkip = true; glideLast = t
  ev.location = t
  CGWarpMouseCursorPosition(t)
}

func makeTap() {
  CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
  let cb: CGEventTapCallBack = { _, type, ev, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let t = glideTap { CGEvent.tapEnable(tap: t, enable: true) }
    } else { glideStep(ev) }
    return Unmanaged.passUnretained(ev)
  }
  guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: 1 << CGEventType.mouseMoved.rawValue, callback: cb, userInfo: nil) else { return }
  glideTap = tap
  CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
}

// MARK: - 校正畫面

struct Mark { var horizontal: Bool; var pos: CGFloat; var text: String; var width: CGFloat }

final class V: NSView {
  var marks: [Mark] = []
  var badge = "", banner = "", hints: [String] = []
  override var isFlipped: Bool { true }
  func label(_ s: String, _ size: CGFloat, _ bg: NSColor) -> NSAttributedString {
    NSAttributedString(string: " \(s) ", attributes: [.font: NSFont.boldSystemFont(ofSize: size),
      .foregroundColor: NSColor.white, .backgroundColor: bg])
  }
  func t(_ s: String, _ p: NSPoint, _ bg: NSColor, size: CGFloat = 13) { label(s, size, bg).draw(at: p) }
  func line(_ a: NSPoint, _ b: NSPoint, _ c: NSColor, _ w: CGFloat) {
    c.setStroke(); let p = NSBezierPath(); p.move(to: a); p.line(to: b); p.lineWidth = w; p.stroke()
  }
  func centered(_ s: String, y: CGFloat, size: CGFloat, bg: NSColor) {
    let a = label(s, size, bg)
    a.draw(at: NSPoint(x: bounds.midX - a.size().width / 2, y: y))
  }
  override func draw(_ r: NSRect) {
    let W = bounds.width, H = bounds.height
    for m in marks {
      if m.horizontal {
        line(NSPoint(x: 0, y: m.pos), NSPoint(x: W, y: m.pos), .red, m.width)
        t(m.text, NSPoint(x: W / 2 - 150, y: m.pos - 28), .red)
      } else {
        line(NSPoint(x: m.pos, y: 0), NSPoint(x: m.pos, y: H), .red, m.width)
        t(m.text, NSPoint(x: m.pos + 8, y: H / 2), .red)
      }
    }
    t(badge, NSPoint(x: W / 2 - 80, y: 150), NSColor.blue.withAlphaComponent(0.8), size: 28)
    centered(banner, y: 30, size: 24, bg: NSColor.black.withAlphaComponent(0.8))
    for (i, h) in hints.enumerated() { centered(h, y: 72 + CGFloat(i) * 32, size: 16, bg: NSColor.black.withAlphaComponent(0.7)) }
  }
}

/// borderless 預設不能當 key window，收不到鍵盤
final class CalibWindow: NSWindow { override var canBecomeKey: Bool { true } }

func activateApp() {
  if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
}

func alert(_ msg: String, _ info: String = "") {
  activateApp()
  let a = NSAlert(); a.messageText = msg; a.informativeText = info; a.runModal()
}

/// 引導式校正：對每組相鄰螢幕，A 上畫固定線、B 上的線跟著游標，點一下（或 Enter）確認。
/// 游標位置用 60Hz 輪詢 CGEvent，點擊與按鍵用單一 local monitor（不用 event tap，避免 Input Monitoring 權限）
final class CalibSession {
  let m: Model
  var pairs: [Pair]
  var idx = 0, done: [Pair] = [], finishing = false, ended = false
  var wins: [ID: CalibWindow] = [:], views: [ID: V] = [:]
  var monitor: Any?, timer: Timer?, observers: [NSObjectProtocol] = []
  var prev: NSRunningApplication?, lastPoll: CGPoint?
  let onEnd: () -> Void

  init(_ m: Model, onEnd: @escaping () -> Void) { self.m = m; pairs = m.pairs; self.onEnd = onEnd }

  func begin() {
    calibrating = true
    prev = NSWorkspace.shared.frontmostApplication
    for s in NSScreen.screens {
      guard let id = screenID(s), m.rects[id] != nil else { continue }
      let w = CalibWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
      w.isReleasedWhenClosed = false
      w.level = .screenSaver; w.isOpaque = false
      w.backgroundColor = NSColor.black.withAlphaComponent(0.01)     // alpha 0 的像素會讓點擊穿透
      w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
      let v = V(frame: NSRect(origin: .zero, size: s.frame.size))
      w.contentView = v; w.orderFrontRegardless()
      wins[id] = w; views[id] = v
    }
    wins.values.first?.makeKey()
    activateApp()
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] e in self?.handle(e); return nil }
    timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.track() }
    let nc = NotificationCenter.default                          // 失去焦點或螢幕變動：取消，不存，避免 overlay 困住使用者
    observers = [NSApplication.didResignActiveNotification, NSApplication.didChangeScreenParametersNotification].map {
      nc.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in self?.end() }
    }
    redraw()
  }

  func redraw() {
    guard idx < pairs.count else { return }
    let p = pairs[idx], h = p.side.horizontalLine, an = m.names[p.a]!, bn = m.names[p.b]!
    for (id, v) in views {
      v.badge = m.names[id]!
      v.banner = "校正 \(idx + 1)/\(pairs.count)：\(an) ↔ \(bn)"
      v.hints = ["移動滑鼠，讓 \(bn) 的紅線和 \(an) 的紅線在實體上連成一線，點一下確認",
                 "方向鍵微調 1 pt　Enter 確認　空白鍵跳過　Esc 取消　（校正中游標修正暫停，有縫的兩台請繞經別台）"]
      v.marks = []
    }
    views[p.a]?.marks = [Mark(horizontal: h, pos: CGFloat(p.refA), text: "\(an) 固定線 \(cm(p.refA, p.a, m))", width: 3)]
    views[p.b]?.marks = [Mark(horizontal: h, pos: CGFloat(p.refB), text: "\(bn) 跟著游標 \(cm(p.refB, p.b, m))", width: 3)]
    views.values.forEach { $0.needsDisplay = true }
  }

  /// 游標在 B 上：線跟著游標沿邊軸座標。只在游標真的動了才更新，不蓋掉方向鍵微調
  func track() {
    guard let q = CGEvent(source: nil)?.location else { return }
    defer { lastPoll = q }
    guard !finishing, q != lastPoll, idx < pairs.count else { return }
    let p = pairs[idx], rb = m.rects[p.b]!
    guard rb.has(q) else { return }
    setRefB(Int((p.side.horizontalLine ? q.y : q.x).rounded(.down)) - along(rb, p.side))
  }

  func setRefB(_ v: Int) {
    let p = pairs[idx]
    pairs[idx].refB = min(max(v, 0), span(m.rects[p.b]!, p.side) - 1)
    redraw()
  }

  func handle(_ e: NSEvent) {
    guard !finishing else { return }
    if e.type == .leftMouseDown { confirm(); return }          // 點擊不更新線：位置以最後一次輪詢為準
    switch e.keyCode {
    case 36, 76: confirm()
    case 49: advance()
    case 53: end()
    case 126, 123, 125, 124:
      let h = pairs[idx].side.horizontalLine
      guard h == (e.keyCode == 126 || e.keyCode == 125) else { return }   // 橫線只收上下，直線只收左右
      setRefB(pairs[idx].refB + (e.keyCode == 126 || e.keyCode == 123 ? -1 : 1))
    default: break
    }
  }

  func confirm() { done.append(pairs[idx]); advance() }

  func advance() {
    idx += 1
    if idx < pairs.count { redraw(); return }
    if !done.isEmpty {
      let new = done.map { CalPair(a: m.tags[$0.a]!, b: m.tags[$0.b]!, side: $0.side, refA: $0.refA, refB: $0.refB) }
      writeCalib(mergeCalib(readCalib(), new))
    }
    finishing = true
    for v in views.values { v.marks = []; v.hints = []; v.banner = done.isEmpty ? "沒有變更" : "校正完成，已儲存"; v.needsDisplay = true }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.end() }
  }

  func end() {
    guard !ended else { return }
    ended = true
    if let mo = monitor { NSEvent.removeMonitor(mo) }
    timer?.invalidate()
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    wins.values.forEach { $0.orderOut(nil) }
    calibrating = false
    prev?.activate()
    onEnd()
  }
}

// MARK: - 選單列

final class AppCtl: NSObject {
  let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  let statusI = NSMenuItem(), calI = NSMenuItem(), pauseI = NSMenuItem(), loginI = NSMenuItem()
  var session: CalibSession?
  var prompted = false

  func start() {
    if let img = NSImage(systemSymbolName: "display.2", accessibilityDescription: "monitor-align") {
      img.isTemplate = true; item.button?.image = img
    } else { item.button?.title = "MA" }
    let menu = NSMenu(); menu.autoenablesItems = false
    calI.title = "校正…"
    for (i, sel) in [(statusI, #selector(openAX)), (calI, #selector(calibrate)), (pauseI, #selector(togglePause)),
                     (loginI, #selector(toggleLogin))] { i.action = sel; i.target = self; menu.addItem(i) }
    menu.insertItem(.separator(), at: 1)
    menu.addItem(.separator())
    let q = NSMenuItem(title: "結束", action: #selector(quit), keyEquivalent: "q"); q.target = self; menu.addItem(q)
    item.menu = menu
    reloadModel()
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { reloadModel(); self?.refresh() }
    }
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
    tick()
  }

  /// 每 2 秒：授權後自動建 tap（不用重開）；授權被收回就收掉 tap
  func tick() {
    var trusted = AXIsProcessTrusted()
    if !trusted && !prompted {
      prompted = true
      trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }
    if trusted && glideTap == nil { makeTap() }
    if !trusted, let t = glideTap { CFMachPortInvalidate(t); glideTap = nil }
    refresh()
  }

  func refresh() {
    let trusted = AXIsProcessTrusted()
    let s: String
    if !trusted { s = "需要輔助使用權限（點此開啟設定）" }
    else if let e = loadError { s = "不支援：\(e)" }
    else if glideTap == nil { s = "游標修正：無法啟動（請移除再重新授權）" }
    else if calibrating { s = "校正中（游標修正暫停）" }
    else if glidePaused { s = "游標修正：已暫停" }
    else { s = "游標修正：啟用" + (M.map { $0.uncal > 0 ? "（\($0.uncal) 組未校正）" : "" } ?? "") }
    statusI.title = s; statusI.isEnabled = !trusted
    calI.isEnabled = M != nil && !calibrating
    pauseI.title = glidePaused ? "啟用游標修正" : "暫停游標修正"
    switch SMAppService.mainApp.status {
    case .enabled: loginI.state = .on; loginI.title = "開機自動啟動"
    case .requiresApproval: loginI.state = .mixed; loginI.title = "開機自動啟動（需到系統設定核准）"
    default: loginI.state = .off; loginI.title = "開機自動啟動"
    }
  }

  @objc func openAX() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
  }

  @objc func calibrate() {
    guard !calibrating, let m = M else { return }
    session = CalibSession(m) { [weak self] in
      self?.session = nil
      DispatchQueue.main.async { reloadModel(); self?.refresh() }
    }
    session?.begin()
    refresh()
  }

  @objc func togglePause() { glidePaused.toggle(); refresh() }

  @objc func toggleLogin() {
    let s = SMAppService.mainApp
    if s.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems(); return }
    do { if s.status == .enabled { try s.unregister() } else { try s.register() } }
    catch { alert("開機自動啟動設定失敗", error.localizedDescription) }
    if s.status == .requiresApproval {
      alert("需要核准", "請到 系統設定 → 一般 → 登入項目與擴充功能，允許 MonitorAlign。")
      SMAppService.openSystemSettingsLoginItems()
    }
    refresh()
  }

  @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - 進入點

let args = CommandLine.arguments
if args.contains("--selftest") { selftest() }
if args.contains("--dump") { dump() }

// 已有同 bundle id 的實例在跑就退出：兩個 tap 會重複 warp
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) { exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let ctl = AppCtl()          // NSMenuItem 的 target 是 weak，全域常數保留
ctl.start()
app.run()
