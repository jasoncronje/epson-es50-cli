// scan: a small CLI for USB document scanners via macOS ImageCaptureCore.
// Built for the Epson ES-50 (sheet-fed), works with any ICA scanner driver.

import AppKit
import Foundation
import CoreImage
import ImageCaptureCore
import PDFKit
import Vision

// MARK: - Options

struct Options {
    var command = "scan"
    var input: String?          // for `scan clean`
    var output: String?
    var dpi = 300
    var mode = "color"          // color | gray | bw
    var format: String?         // pdf | jpg | png (default: from output extension, else pdf)
    var size = "letter"           // a4 | letter | legal | a5 | b5 | default
    var duplex = false
    var batch = false           // keep scanning sheets into one file
    var waitSeconds = 30.0      // how long to wait for a sheet
    var open = false
    var verbose = false
    var raw = false             // skip straighten/clean-up
    var keepBlank = false
    var long = false            // long printouts: scan up to the feeder's max length
    var split = true            // split long scans into pages
    var pageLength = 11.0       // inches per printout page
}

let usage = """
usage: scan [options] [output]
       scan info                  show scanner capabilities
       scan clean INPUT [OUTPUT]  straighten and clean an existing PDF or image

Scans sheets from the attached USB scanner. Insert a sheet and run, or run
first: it waits for paper.

options:
  -o, --output PATH   output file (default: ./scan-<time>.pdf in the current folder)
  -r, --dpi N         resolution (default 300)
  -m, --mode MODE     color | gray | bw (default color)
  -f, --format FMT    pdf | jpg | png (default: output extension, else pdf)
  -s, --size SIZE     a4 | letter | legal | a5 | b5 | default (default letter)
  -b, --batch         keep scanning sheets into one PDF; press Enter (or Ctrl+C)
                      to finish, or it finishes when no sheet arrives in --wait
  -w, --wait SECS     how long to wait for each sheet (default 30)
  -d, --duplex        scan both sides, if supported
      --raw           keep pages as scanned: no straightening, cropping or clean-up
      --keep-blank    keep blank pages (skipped by default)
  -l, --long          long printout (fanfold, dot matrix): scans up to 72", trims
                      the unused tail, splits into pages, removes greenbar stripes
      --page-length IN  page length for --long splitting (default 11)
      --no-split      with --long, keep the printout as one tall page
      --open          open the result when done
  -v, --verbose       log scanner events
  -h, --help          show this help

feeding (ES-50): one sheet at a time, face up, top edge first, against the
left side of the slot. In a batch, start with page 1: pages are saved in the
order you feed them.

examples:
  scan                         one page to a PDF in the current folder
  scan -b receipts.pdf         feed sheets one by one into receipts.pdf
  scan -m gray -r 200 note.jpg one grayscale page as JPEG
  scan clean old.pdf           straighten an old scan into old-clean.pdf
  scan -l -b printout.pdf      fanfold printout, up to 6 pages per stretch

long printouts: tear off the tractor-hole strips first (max width 8.5"),
feed at most 72" (6 pages) at a time and guide the paper in and out by hand.

Pages are straightened, cropped to the sheet, turned upright, and cleaned up
(white paper, darker text) unless you pass --raw.
"""

func die(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(("scan: " + msg + "\n").data(using: .utf8)!)
    exit(code)
}

func log(_ msg: String) {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
}

func parseArgs() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    func next(_ flag: String) -> String {
        guard !args.isEmpty else { die("\(flag) needs a value") }
        return args.removeFirst()
    }
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "-h", "--help": print(usage); exit(0)
        case "-o", "--output": o.output = next(a)
        case "-r", "--dpi": guard let n = Int(next(a)) else { die("bad --dpi") }; o.dpi = n
        case "-m", "--mode": o.mode = next(a).lowercased()
        case "-f", "--format": o.format = next(a).lowercased()
        case "-s", "--size": o.size = next(a).lowercased()
        case "-w", "--wait": guard let w = Double(next(a)) else { die("bad --wait") }; o.waitSeconds = w
        case "-b", "--batch": o.batch = true
        case "-d", "--duplex": o.duplex = true
        case "--open": o.open = true
        case "--raw": o.raw = true
        case "--keep-blank": o.keepBlank = true
        case "-l", "--long": o.long = true
        case "--no-split": o.split = false
        case "--page-length": guard let l = Double(next(a)), l > 1 else { die("bad --page-length") }; o.pageLength = l
        case "-v", "--verbose": o.verbose = true
        case "info", "scan", "clean": o.command = a
        default:
            if a.hasPrefix("-") { die("unknown option \(a)\n\n\(usage)") }
            if o.command == "clean" && o.input == nil { o.input = a } else { o.output = a }
        }
    }
    if o.command == "clean" && o.input == nil { die("clean needs an input file") }
    guard ["color", "gray", "grey", "bw"].contains(o.mode) else { die("--mode must be color, gray or bw") }
    if o.mode == "grey" { o.mode = "gray" }
    return o
}

// MARK: - Output paths

func resolveOutput(_ o: inout Options) -> URL {
    let url: URL
    if let out = o.output {
        url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
    } else {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withFullDate, .withTime, .withDashSeparatorInDate])
        url = dir.appendingPathComponent("scan-\(stamp).\(o.format ?? "pdf")")
    }
    if o.format == nil {
        let ext = url.pathExtension.lowercased()
        o.format = ext == "jpeg" ? "jpg" : (["pdf", "jpg", "png"].contains(ext) ? ext : "pdf")
    }
    guard ["pdf", "jpg", "png"].contains(o.format!) else { die("--format must be pdf, jpg or png") }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    return url
}

// MARK: - Scanner controller

final class Scanner: NSObject, ICDeviceBrowserDelegate, ICScannerDeviceDelegate {
    let opts: Options
    let browser = ICDeviceBrowser()
    var device: ICScannerDevice?
    let tmpDir: URL
    var pages: [URL] = []
    var onReady: ((ICScannerDevice) -> Void)?
    var scanDone: ((Error?) -> Void)?
    var stopRequested = false   // Enter or Ctrl+C: finish after the current page
    var failure: String?        // a scan that fed paper but produced no image

    init(opts: Options) {
        self.opts = opts
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        super.init()
    }

    func v(_ s: String) { if opts.verbose { log("· " + s) } }

    func start(_ ready: @escaping (ICScannerDevice) -> Void) {
        onReady = ready
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.scanner.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            if self?.device == nil { die("no scanner found. Is it plugged in and switched on?") }
        }
    }

    // Browser
    func deviceBrowser(_ b: ICDeviceBrowser, didAdd d: ICDevice, moreComing: Bool) {
        guard device == nil, let s = d as? ICScannerDevice else { return }
        v("found \(s.name ?? "scanner") over \(s.transportType ?? "?")")
        device = s
        s.delegate = self
        s.requestOpenSession()
    }
    func deviceBrowser(_ b: ICDeviceBrowser, didRemove d: ICDevice, moreGoing: Bool) {}

    // Device
    func didRemove(_ d: ICDevice) { die("scanner disconnected") }
    func device(_ d: ICDevice, didOpenSessionWithError e: (any Error)?) {
        if let e { die("could not open scanner session: \(e.localizedDescription)") }
    }
    func device(_ d: ICDevice, didCloseSessionWithError e: (any Error)?) {}
    func deviceDidBecomeReady(_ d: ICDevice) {
        guard let s = d as? ICScannerDevice else { return }
        v("ready, selecting \(s.selectedFunctionalUnit.type.rawValue)")
        // Drivers often need an explicit select before they accept settings and scans.
        s.requestSelect(s.selectedFunctionalUnit.type)
    }
    func scannerDevice(_ s: ICScannerDevice, didSelect fu: ICScannerFunctionalUnit, error e: (any Error)?) {
        let cur = s.selectedFunctionalUnit
        v("selected unit \(fu.type.rawValue) (device has \(cur.type.rawValue), \(cur.supportedResolutions.count) resolutions)\(e.map { " error: \($0.localizedDescription)" } ?? "")")
        guard !cur.supportedResolutions.isEmpty else { return }
        onReady?(s); onReady = nil
    }
    func device(_ d: ICDevice, didReceiveStatusInformation status: [ICDeviceStatus: Any]) {
        if !status.isEmpty { v("status \(status)") }
    }

    // Scanner
    func scannerDevice(_ s: ICScannerDevice, didScanTo url: URL) {
        v("page → \(url.lastPathComponent)")
        pages.append(url)
    }
    func scannerDevice(_ s: ICScannerDevice, didCompleteScanWithError e: (any Error)?) {
        v("scan complete \(e.map { "error: \($0.localizedDescription)" } ?? "ok")")
        let cb = scanDone; scanDone = nil
        cb?(e)
    }

    // MARK: Configure

    func configure(_ s: ICScannerDevice) {
        let fu = s.selectedFunctionalUnit
        if !fu.supportedResolutions.contains(opts.dpi) {
            let options = fu.supportedResolutions.filter { [75, 100, 150, 200, 240, 300, 400, 600, 1200].contains($0) }
            die("\(opts.dpi) dpi not supported. Try one of: \(options.map(String.init).joined(separator: ", "))")
        }
        fu.resolution = opts.dpi
        fu.measurementUnit = .inches
        switch opts.mode {
        case "gray": fu.pixelDataType = .gray; fu.bitDepth = .depth8Bits
        case "bw": fu.pixelDataType = .BW; fu.bitDepth = .depth1Bit
        default: fu.pixelDataType = .RGB; fu.bitDepth = .depth8Bits
        }
        if let f = fu as? ICScannerFunctionalUnitDocumentFeeder, !opts.long {
            if let t = docType(opts.size), f.supportedDocumentTypes.contains(Int(t.rawValue)) {
                f.documentType = t
            } else if opts.size != "default" {
                log("note: size \(opts.size) not offered by this scanner, using its default")
            }
            if opts.duplex {
                if f.supportsDuplexScanning { f.duplexScanningEnabled = true } else { log("note: duplex not supported") }
            }
        }
        if opts.long {
            // No document type covers fanfold, so ask for the feeder's full width and length.
            fu.scanArea = NSRect(x: 0, y: 0, width: min(8.5, fu.physicalSize.width), height: fu.physicalSize.height)
            if opts.duplex, let f = fu as? ICScannerFunctionalUnitDocumentFeeder, f.supportsDuplexScanning { f.duplexScanningEnabled = true }
        } else {
            let (w, h) = pageInches(opts.size)
            fu.scanArea = NSRect(x: 0, y: 0, width: w, height: h)
        }
        v("dpi \(fu.resolution) area \(fu.scanArea) docType \((fu as? ICScannerFunctionalUnitDocumentFeeder)?.documentType.rawValue ?? 0)")
        s.transferMode = .fileBased
        s.downloadsDirectory = tmpDir
        s.documentUTI = opts.format == "png" ? "public.png" : "public.jpeg"
    }

    func docType(_ size: String) -> ICScannerDocumentType? {
        switch size {
        case "a4": return .typeA4
        case "letter": return .typeUSLetter
        case "legal": return .typeUSLegal
        case "a5": return .typeA5
        case "b5": return .typeB5
        default: return nil
        }
    }

    func pageInches(_ size: String) -> (Double, Double) {
        switch size {
        case "letter": return (8.5, 11)
        case "legal": return (8.5, 14)
        case "a5": return (5.83, 8.27)
        case "b5": return (6.93, 9.84)
        default: return (8.27, 11.69)
        }
    }

    // MARK: Scan loop

    /// Waits for a sheet, then scans it. Calls back with whether a page was scanned.
    /// The feeder's documentLoaded flag only refreshes per session, so instead keep
    /// requesting scans: with no paper the ES-50 driver completes at once with no page.
    func scanOne(_ s: ICScannerDevice, prompt: String, completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(opts.waitSeconds)
        var announced = false
        func attempt() {
            if stopRequested { completion(false); return }
            let before = pages.count
            let started = Date()
            v("requesting scan")
            scanDone = { [weak self] err in
                guard let self else { return }
                let got = self.pages.count > before
                let took = Date().timeIntervalSince(started)
                if got {
                    completion(true)
                } else if took > 3 {
                    // With no paper the driver returns at once; a slow empty result means a sheet
                    // was fed and the scan failed partway.
                    self.failure = String(format: "scan failed after %.0fs, driver returned no image%@", took,
                                          err.map { ": \($0.localizedDescription) (\(($0 as NSError).code))" } ?? "")
                    completion(false)
                } else if !self.stopRequested && Date() < deadline {
                    if !announced { log(prompt); announced = true }
                    if let err { self.v("no page yet: \(err.localizedDescription)") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: attempt)
                } else {
                    completion(false)
                }
            }
            s.requestScan()
        }
        attempt()
    }
}

// MARK: - Page clean-up

/// Straightens, crops, turns upright and cleans a scanned page with Vision and Core Image.
struct PageProcessor {
    let context = CIContext()
    let verbose: Bool
    let cleanUp: Bool           // false for 1-bit scans

    enum Result { case page(CIImage), blank }

    func v(_ s: String) { if verbose { log("· " + s) } }

    func process(_ input: CIImage) -> Result {
        var img = cropToSheet(input)
        let (lineCount, flipped) = readOrientation(img)
        if flipped {
            v("page is upside down, rotating")
            img = normalized(img.oriented(.down))
        }
        img = deskew(img)
        if cleanUp { img = enhance(img) }
        if lineCount == 0 && isBlank(img) { return .blank }
        return .page(img)
    }

    func normalized(_ img: CIImage) -> CIImage {
        img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
    }

    /// Finds the sheet's four corners and warps it to a flat rectangle.
    func cropToSheet(_ img: CIImage) -> CIImage {
        let req = VNDetectDocumentSegmentationRequest()
        try? VNImageRequestHandler(ciImage: img).perform([req])
        guard let quad = req.results?.first, quad.confidence > 0.5 else { v("no sheet outline found"); return img }
        let area = quadArea(quad)
        // Skip when the outline is tiny (likely a mis-detection) or already the whole image.
        guard area > 0.4, area < 0.97 else { v(String(format: "sheet covers %.0f%%, not cropping", area * 100)); return img }
        let w = img.extent.width, h = img.extent.height
        // Paper is rectangular: a skewed outline means the edge was misread (common on white
        // backgrounds), and warping to it would shear the page.
        let corners = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft].map { CGPoint(x: $0.x * w, y: $0.y * h) }
        let worst = (0..<4).map { i -> Double in
            let a = corners[(i + 3) % 4], b = corners[i], c = corners[(i + 1) % 4]
            let u = (Double(a.x - b.x), Double(a.y - b.y)), v = (Double(c.x - b.x), Double(c.y - b.y))
            let cosang = (u.0 * v.0 + u.1 * v.1) / (hypot(u.0, u.1) * hypot(v.0, v.1))
            return abs(acos(max(-1, min(1, cosang))) * 180 / .pi - 90)
        }.max() ?? 90
        guard worst < 1.5 else { v(String(format: "sheet outline not rectangular (%.1f° off), not cropping", worst)); return img }
        func pt(_ p: CGPoint) -> CIVector { CIVector(x: p.x * w + img.extent.minX, y: p.y * h + img.extent.minY) }
        v(String(format: "cropping to sheet (%.0f%% of scan)", area * 100))
        let out = img.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": pt(quad.topLeft), "inputTopRight": pt(quad.topRight),
            "inputBottomLeft": pt(quad.bottomLeft), "inputBottomRight": pt(quad.bottomRight),
        ])
        return normalized(out)
    }

    func quadArea(_ q: VNRectangleObservation) -> CGFloat {
        let p = [q.topLeft, q.topRight, q.bottomRight, q.bottomLeft]
        var a: CGFloat = 0
        for i in 0..<4 { let j = (i + 1) % 4; a += p[i].x * p[j].y - p[j].x * p[i].y }
        return abs(a) / 2
    }

    /// Reads text on a small copy. Accurate recognition reads upside-down text too, and
    /// reports those lines running right to left, which is how a flipped page shows up.
    func readOrientation(_ img: CIImage) -> (lines: Int, flipped: Bool) {
        let k = min(1, 1000 / img.extent.width)
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        try? VNImageRequestHandler(ciImage: img.transformed(by: CGAffineTransform(scaleX: k, y: k))).perform([req])
        let lines = req.results ?? []
        let backwards = lines.filter { $0.topRight.x < $0.topLeft.x }.count
        v("\(lines.count) text lines, \(backwards) reading upside down")
        return (lines.count, lines.count >= 3 && Double(backwards) > Double(lines.count) * 0.6)
    }

    /// Levels the page by projection profile: the angle at which dark pixels fall into the
    /// fewest, fullest rows is the angle of the text lines and table rules.
    func deskew(_ img: CIImage) -> CIImage {
        let k = min(1, 800 / img.extent.width)
        let small = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
        let w = Int(small.extent.width), h = Int(small.extent.height)
        guard w > 50, h > 50 else { return img }
        var px = [UInt8](repeating: 0, count: w * h)
        context.render(normalized(small), toBitmap: &px, rowBytes: w, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        // Dark pixels, skipping a 3% margin where sheet edges and scanner shadow live.
        let mx = w * 3 / 100, my = h * 3 / 100
        var xs: [Double] = [], ys: [Double] = []
        for y in my..<(h - my) { for x in mx..<(w - mx) where px[y * w + x] < 140 { xs.append(Double(x)); ys.append(Double(y)) } }
        guard xs.count > 200 else { return img }
        func score(_ deg: Double) -> Double {
            let t = deg * .pi / 180, c = cos(t), s = sin(t)
            var bins = [Double](repeating: 0, count: h * 2)
            for i in 0..<xs.count {
                let r = Int(ys[i] * c - xs[i] * s) + h / 2
                if r >= 0 && r < bins.count { bins[r] += 1 }
            }
            return bins.reduce(0) { $0 + $1 * $1 }
        }
        var best = 0.0, bestScore = score(0)
        for step in stride(from: -50, through: 50, by: 2) where step != 0 {
            let d = Double(step) / 10, sc = score(d)
            if sc > bestScore { best = d; bestScore = sc }
        }
        for step in stride(from: -10, through: 10, by: 1) {
            let d = best + Double(step) / 50, sc = score(d)
            if sc > bestScore { best = d; bestScore = sc }
        }
        // Bitmap rows run top to bottom, so the skew in Core Image's y-up space is -best.
        let skew = -best
        guard abs(skew) >= 0.1 else { return img }
        v(String(format: "straightening by %.2f°", -skew))
        let angle = -skew * .pi / 180
        let c = CGPoint(x: img.extent.midX, y: img.extent.midY)
        let t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle).translatedBy(x: -c.x, y: -c.y)
        // Fill the corners exposed by the rotation with white, keep the original frame.
        let white = CIImage(color: .white).cropped(to: img.extent)
        return img.transformed(by: t).composited(over: white).cropped(to: img.extent)
    }

    /// Printout clean-up: the brightest channel turns green/blue bar stripes white while
    /// black ribbon ink stays dark, then a curve whitens paper and darkens faint ink.
    func cleanPrintout(_ img: CIImage) -> CIImage {
        img.applyingFilter("CIMaximumComponent").applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.4, y: 0.12),
            "inputPoint2": CIVector(x: 0.6, y: 0.4), "inputPoint3": CIVector(x: 0.82, y: 1),
            "inputPoint4": CIVector(x: 1, y: 1),
        ])
    }

    /// Long printouts: trims what was scanned past the paper's end, then cuts pages every
    /// `pageInches`, nudging each cut to the emptiest band nearby (the gap at the perforation).
    func splitLong(_ input: CIImage, dpi: Int, pageInches: Double, split: Bool) -> [CIImage] {
        let img = cleanUp ? cleanPrintout(input) : input
        let k = min(1, 600 / img.extent.width)
        let small = normalized(img.transformed(by: CGAffineTransform(scaleX: k, y: k)))
        let w = Int(small.extent.width), h = Int(small.extent.height)
        guard w > 50, h > 50 else { return [img] }
        var px = [UInt8](repeating: 0, count: w * h)
        context.render(small, toBitmap: &px, rowBytes: w, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        // Per row (top to bottom): dark scanner background, and how much ink.
        let x0 = w * 3 / 100, x1 = w - x0
        var background = [Bool](repeating: false, count: h), ink = [Int](repeating: 0, count: h)
        for y in 0..<h {
            var sum = 0, dark = 0
            for x in x0..<x1 { let p = Int(px[y * w + x]); sum += p; if p < 128 { dark += 1 } }
            background[y] = Double(sum) / Double(x1 - x0) < 90
            ink[y] = background[y] ? 0 : dark
        }
        let rpi = Double(dpi) * k                      // rows per inch in the small copy
        let inkRow = { (y: Int) in Double(ink[y]) > Double(x1 - x0) * 0.003 }
        guard let lastInk = (0..<h).last(where: inkRow) else { return [] }
        var end = min(h, lastInk + Int(0.3 * rpi))
        // A dark run after the content is the scanner past the paper's end.
        let run = max(1, Int(0.2 * rpi))
        if let paperEnd = (Int(rpi)..<h).first(where: { y in (y..<min(h, y + run)).allSatisfy { background[$0] } }) {
            end = min(end, paperEnd)
        }
        var cuts = [0]
        if split {
            let pl = Int(pageInches * rpi), win = Int(0.4 * rpi), band = max(1, Int(0.08 * rpi))
            var next = pl
            while next < end - Int(0.5 * rpi) {
                var best = next, bestScore = Int.max
                for c in max(cuts.last! + pl / 2, next - win)...min(end - 1, next + win) {
                    let score = (c..<min(h, c + band)).reduce(0) { $0 + ink[$1] } * 1000 + abs(c - next)
                    if score < bestScore { best = c; bestScore = score }
                }
                cuts.append(best)
                next = best + pl
            }
        }
        cuts.append(end)
        v(String(format: "printout is %.1f\" long, %d page%@", Double(end) / rpi, cuts.count - 1, cuts.count == 2 ? "" : "s"))
        // Bitmap rows run top down; Core Image's y runs bottom up.
        let H = img.extent.height
        return zip(cuts, cuts.dropFirst()).map { top, bottom in
            let y0 = H - CGFloat(bottom) / k, y1 = H - CGFloat(top) / k
            return normalized(img.cropped(to: CGRect(x: img.extent.minX, y: img.extent.minY + y0,
                                                     width: img.extent.width, height: y1 - y0)))
        }
    }

    /// White paper, darker text: Core Image's document filter, then a levels stretch.
    func enhance(_ img: CIImage) -> CIImage {
        var out = img
        if let f = CIFilter(name: "CIDocumentEnhancer") {
            f.setValue(img, forKey: kCIInputImageKey)
            f.setValue(1.0, forKey: "inputAmount")
            out = f.outputImage ?? img
        }
        // Lift light-grey paper to white without touching mid tones (keeps colour logos).
        return out.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.25, y: 0.22),
            "inputPoint2": CIVector(x: 0.5, y: 0.5), "inputPoint3": CIVector(x: 0.86, y: 1),
            "inputPoint4": CIVector(x: 1, y: 1),
        ])
    }

    func isBlank(_ img: CIImage) -> Bool {
        // A blank sheet is bright and nearly uniform: check average and darkest tones on a small copy.
        let small = img.transformed(by: CGAffineTransform(scaleX: 200 / img.extent.width, y: 200 / img.extent.width))
        let avg = small.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: small.extent)])
        let min = small.applyingFilter("CIAreaMinimum", parameters: [kCIInputExtentKey: CIVector(cgRect: small.extent)])
        func lum(_ i: CIImage) -> Double {
            var px = [UInt8](repeating: 0, count: 4)
            context.render(i, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return (0.299 * Double(px[0]) + 0.587 * Double(px[1]) + 0.114 * Double(px[2])) / 255
        }
        let a = lum(avg), m = lum(min)
        v(String(format: "brightness avg %.2f, darkest %.2f", a, m))
        return a > 0.93 && m > 0.6
    }

    func write(_ img: CIImage, to url: URL, png: Bool) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        if png {
            try context.writePNGRepresentation(of: img, to: url, format: .RGBA8, colorSpace: cs)
        } else {
            try context.writeJPEGRepresentation(of: img, to: url, colorSpace: cs,
                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.85])
        }
    }
}

// MARK: - Output

func writeOutput(pages: [URL], to url: URL, format: String, dpi: Int) throws -> [URL] {
    if format == "pdf" {
        let doc = PDFDocument()
        for (i, p) in pages.enumerated() {
            guard let img = NSImage(contentsOf: p), let rep = img.representations.first else { continue }
            // Size the page in points from the scan dpi, not 1 pt per pixel.
            img.size = NSSize(width: CGFloat(rep.pixelsWide) * 72 / CGFloat(dpi),
                              height: CGFloat(rep.pixelsHigh) * 72 / CGFloat(dpi))
            guard let page = PDFPage(image: img) else { continue }
            doc.insert(page, at: i)
        }
        guard doc.write(to: url) else { throw NSError(domain: "scan", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not write \(url.path)"]) }
        return [url]
    }
    var written: [URL] = []
    for (i, p) in pages.enumerated() {
        var dest = url
        if pages.count > 1 {
            let base = url.deletingPathExtension().lastPathComponent
            dest = url.deletingLastPathComponent().appendingPathComponent("\(base)-\(i + 1).\(url.pathExtension)")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: p, to: dest)
        written.append(dest)
    }
    return written
}

// MARK: - Main

var opts = parseArgs()
let processor = PageProcessor(verbose: opts.verbose, cleanUp: opts.mode != "bw" && !opts.raw)

/// Cleans a page file in place. Returns false when the page is blank.
func cleanPage(_ url: URL) -> Bool {
    guard let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return true }
    switch processor.process(img) {
    case .blank: return false
    case .page(let out):
        do { try processor.write(out, to: url, png: url.pathExtension.lowercased() == "png") }
        catch { log("note: could not clean page: \(error.localizedDescription)") }
        return true
    }
}

/// Splits a long printout scan into page files next to it. Returns them in order.
func splitLongPage(_ url: URL) -> [URL] {
    guard let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return [url] }
    let parts = processor.splitLong(img, dpi: opts.dpi, pageInches: opts.pageLength, split: opts.split)
    let png = url.pathExtension.lowercased() == "png"
    var out: [URL] = []
    for (i, part) in parts.enumerated() {
        let dest = url.deletingPathExtension().appendingPathExtension("p\(i + 1).\(url.pathExtension)")
        do { try processor.write(part, to: dest, png: png); out.append(dest) }
        catch { log("note: could not write page: \(error.localizedDescription)") }
    }
    try? FileManager.default.removeItem(at: url)
    return out
}

/// `scan clean INPUT [OUTPUT]`: run the clean-up on an existing PDF or image.
func runClean() -> Never {
    let input = URL(fileURLWithPath: (opts.input! as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: input.path) else { die("no such file: \(input.path)") }
    if opts.output == nil {
        let ext = input.pathExtension.isEmpty ? "pdf" : input.pathExtension
        opts.output = input.deletingPathExtension().path + "-clean." + ext
    }
    let out = resolveOutput(&opts)
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scan-clean-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let ext = opts.format == "png" ? "png" : "jpg"
    var pages: [URL] = []

    if input.pathExtension.lowercased() == "pdf" {
        guard let doc = PDFDocument(url: input) else { die("could not read \(input.path)") }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            let scale = CGFloat(opts.dpi) / 72
            let size = NSSize(width: box.width * scale, height: box.height * scale)
            guard let cg = page.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { continue }
            let url = tmp.appendingPathComponent("page-\(i + 1).\(ext)")
            do { try processor.write(CIImage(cgImage: cg), to: url, png: ext == "png") } catch { die(error.localizedDescription) }
            pages.append(url)
        }
    } else {
        // Keep the image's own dpi so PDF pages come out at the right physical size.
        if let src = CGImageSourceCreateWithURL(input as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Double {
            let dpi = props[kCGImagePropertyDPIWidth] as? Double ?? 72
            // 72 is the generic default; if that would make the page wider than 14", assume 8.5" wide.
            opts.dpi = dpi == 72 && width / 72 > 14 ? Int(width / 8.5) : Int(dpi)
        }
        let url = tmp.appendingPathComponent("page-1.\(ext)")
        try? FileManager.default.copyItem(at: input, to: url)
        pages.append(url)
    }

    var kept: [URL] = []
    for (i, p) in pages.enumerated() {
        if opts.long { kept += splitLongPage(p); continue }
        if cleanPage(p) || opts.keepBlank { kept.append(p) } else { log("page \(i + 1) is blank, skipped") }
    }
    guard !kept.isEmpty else { die("every page was blank") }
    do {
        for f in try writeOutput(pages: kept, to: out, format: opts.format!, dpi: opts.dpi) { print(f.path) }
    } catch { die(error.localizedDescription) }
    if opts.open { NSWorkspace.shared.open(out) }
    exit(0)
}

if opts.command == "clean" { runClean() }

let outURL = opts.command == "scan" ? resolveOutput(&opts) : URL(fileURLWithPath: "/dev/null")
let scanner = Scanner(opts: opts)

// Ctrl+C finishes and saves pages scanned so far; a second Ctrl+C quits at once.
signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    if scanner.stopRequested { log("\ncancelled"); exit(130) }
    log("\nfinishing…")
    scanner.stopRequested = true
}
sigint.resume()

// Enter finishes a batch.
if opts.batch && isatty(STDIN_FILENO) != 0 {
    FileHandle.standardInput.readabilityHandler = { h in
        let data = h.availableData
        if data.isEmpty { h.readabilityHandler = nil; return }
        if data.contains(UInt8(ascii: "\n")) {
            DispatchQueue.main.async {
                if !scanner.stopRequested { log("finishing…") }
                scanner.stopRequested = true
            }
        }
    }
}

scanner.start { dev in
    if opts.command == "info" {
        let fu = dev.selectedFunctionalUnit
        print("device:      \(dev.name ?? "?") (\(dev.transportType ?? "?"))")
        print("units:       \(dev.availableFunctionalUnitTypes)  (0 flatbed, 1 transparency, 2 negative, 3 feeder)")
        let common = fu.supportedResolutions.filter { [75, 100, 150, 200, 300, 400, 600, 1200].contains($0) }
        print("resolutions: \(common.map(String.init).joined(separator: ", ")) dpi (and others)")
        if let f = fu as? ICScannerFunctionalUnitDocumentFeeder {
            print("paper in:    \(f.documentLoaded ? "yes" : "no")")
            print("duplex:      \(f.supportsDuplexScanning ? "yes" : "no")")
            print("doc types:   \(f.supportedDocumentTypes.map(String.init).joined(separator: ", "))  (1 A4, 2 B5, 3 Letter, 4 Legal, 5 A5)")
        }
        exit(0)
    }

    scanner.configure(dev)
    if opts.long {
        log("""
        long printout: tear off the tractor-hole strips, feed top edge first, face up
          up to 72" (6 pages) per stretch; guide the paper in and out by hand\(opts.batch ? "\n  after each stretch, feed the next one or press Enter to finish" : "")
        """)
    } else if opts.batch {
        log("""
        batch scan: feed page 1 first, then 2, 3… (saved in the order fed)
          face up, top edge first, against the left side of the slot
          press Enter after the last page
        """)
    }
    var n = 0
    func loop() {
        let prompt = opts.long ? (n == 0 ? "insert the printout, top edge first…" : "insert the next stretch, or press Enter to finish…")
            : !opts.batch ? "insert the sheet face up, top edge first…"
            : n == 0 ? "insert page 1…"
            : "insert page \(n + 1), or press Enter to finish…"
        scanner.scanOne(dev, prompt: prompt) { got in
            if got {
                n += 1
                if opts.long, let strip = scanner.pages.popLast() {
                    let parts = splitLongPage(strip)
                    scanner.pages += parts
                    log("stretch \(n) done: \(parts.count) page\(parts.count == 1 ? "" : "s"), \(scanner.pages.count) so far")
                } else if !opts.raw, let page = scanner.pages.last, !cleanPage(page), !opts.keepBlank {
                    scanner.pages.removeLast()
                    log("page \(n) is blank, skipped")
                } else {
                    log("page \(n) done")
                }
                if opts.batch && !scanner.stopRequested { loop(); return }
            } else if let failure = scanner.failure {
                if scanner.pages.isEmpty { die(failure) }
                log("\(failure); saving the pages scanned before it")
            } else if n == 0 {
                if scanner.stopRequested { log("cancelled, nothing scanned"); exit(130) }
                die("no sheet detected within \(Int(opts.waitSeconds))s")
            }
            let count = scanner.pages.count
            if count == 0 { die("every page was blank, nothing saved") }
            log("saving \(count) page\(count == 1 ? "" : "s")…")
            do {
                let files = try writeOutput(pages: scanner.pages, to: outURL, format: opts.format!, dpi: opts.dpi)
                try? FileManager.default.removeItem(at: scanner.tmpDir)
                for f in files { print(f.path) }
                if opts.open { NSWorkspace.shared.open(files[0]) }
                dev.requestCloseSession()
                exit(0)
            } catch {
                die(error.localizedDescription)
            }
        }
    }
    loop()
}

RunLoop.main.run()
