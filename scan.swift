// scan: a small CLI for USB document scanners via macOS ImageCaptureCore.
// Built for the Epson ES-50 (sheet-fed), works with any ICA scanner driver.

import AppKit
import Foundation
import ImageCaptureCore
import PDFKit

// MARK: - Options

struct Options {
    var command = "scan"
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
}

let usage = """
usage: scan [options] [output]
       scan info            show scanner capabilities

Scans sheets from the attached USB scanner. Insert a sheet and run, or run
first: it waits for paper.

options:
  -o, --output PATH   output file (default: ~/Documents/Scans/scan-<time>.pdf)
  -r, --dpi N         resolution (default 300)
  -m, --mode MODE     color | gray | bw (default color)
  -f, --format FMT    pdf | jpg | png (default: output extension, else pdf)
  -s, --size SIZE     a4 | letter | legal | a5 | b5 | default (default letter)
  -b, --batch         keep scanning sheets into one PDF; press Enter (or Ctrl+C)
                      to finish, or it finishes when no sheet arrives in --wait
  -w, --wait SECS     how long to wait for each sheet (default 30)
  -d, --duplex        scan both sides, if supported
      --open          open the result when done
  -v, --verbose       log scanner events
  -h, --help          show this help

examples:
  scan                         one page to a PDF in ~/Documents/Scans
  scan -b receipts.pdf         feed sheets one by one into receipts.pdf
  scan -m gray -r 200 note.jpg one grayscale page as JPEG
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
        case "-v", "--verbose": o.verbose = true
        case "info", "scan": o.command = a
        default:
            if a.hasPrefix("-") { die("unknown option \(a)\n\n\(usage)") }
            o.output = a
        }
    }
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
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Scans")
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
        if let f = fu as? ICScannerFunctionalUnitDocumentFeeder {
            if let t = docType(opts.size), f.supportedDocumentTypes.contains(Int(t.rawValue)) {
                f.documentType = t
            } else if opts.size != "default" {
                log("note: size \(opts.size) not offered by this scanner, using its default")
            }
            if opts.duplex {
                if f.supportsDuplexScanning { f.duplexScanningEnabled = true } else { log("note: duplex not supported") }
            }
        }
        let (w, h) = pageInches(opts.size)
        fu.scanArea = NSRect(x: 0, y: 0, width: w, height: h)
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
            v("requesting scan")
            scanDone = { [weak self] err in
                guard let self else { return }
                let got = self.pages.count > before
                if got {
                    completion(true)
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
    var n = 0
    func loop() {
        let prompt = n == 0 ? "insert a sheet into the scanner…"
            : "insert the next sheet, or press Enter to finish…"
        scanner.scanOne(dev, prompt: prompt) { got in
            if got {
                n += 1
                log("page \(n) done")
                if opts.batch && !scanner.stopRequested { loop(); return }
            } else if n == 0 {
                if scanner.stopRequested { log("cancelled, nothing scanned"); exit(130) }
                die("no sheet detected within \(Int(opts.waitSeconds))s")
            }
            log("saving \(n) page\(n == 1 ? "" : "s")…")
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
