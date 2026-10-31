import AppKit
import CoreGraphics
import Vision

func listWindows(pid: Int) {
    let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
    let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    var found = 0
    for w in info {
        guard let ownerPid = w[kCGWindowOwnerPID as String] as? Int, ownerPid == pid else { continue }
        found += 1
        let num = w[kCGWindowNumber as String] as? Int ?? -1
        let layer = w[kCGWindowLayer as String] as? Int ?? -1
        let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let x = bounds["X"] ?? 0
        let y = bounds["Y"] ?? 0
        let width = bounds["Width"] ?? 0
        let height = bounds["Height"] ?? 0
        let onscreen = w[kCGWindowIsOnscreen as String] ?? "?"
        print("WIN num=\(num) layer=\(layer) x=\(x) y=\(y) w=\(width) h=\(height) onscreen=\(onscreen)")
    }
    print("WINDOW_COUNT=\(found)")
}

func ocr(_ paths: [String]) {
    for path in paths {
        guard let image = NSImage(contentsOfFile: path),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("OCR_LOAD_FAIL \(path)")
            continue
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request])
        } catch {
            print("OCR_ERROR \(path) \(error)")
            continue
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        print("OCR \(path) lines=\(lines.count)")
        for line in lines {
            print("OCR_LINE \(line)")
        }
    }
}

func stats(_ paths: [String]) {
    for path in paths {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let rep = NSBitmapImageRep(data: data) else {
            print("STATS_LOAD_FAIL \(path)")
            continue
        }
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        var colors = Set<UInt32>()
        var light = 0
        var total = 0
        let stepX = max(1, width / 120)
        let stepY = max(1, height / 120)
        for y in stride(from: 0, to: height, by: stepY) {
            for x in stride(from: 0, to: width, by: stepX) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let r = UInt32(c.redComponent * 255)
                let g = UInt32(c.greenComponent * 255)
                let b = UInt32(c.blueComponent * 255)
                colors.insert(r << 16 | g << 8 | b)
                if Int(r) + Int(g) + Int(b) > 600 { light += 1 }
                total += 1
            }
        }
        print("STATS \(path) px=\(width)x\(height) sampled=\(total) unique=\(colors.count) light=\(light)")
    }
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: menu-probe windows <pid> | ocr <files...> | stats <files...>")
    exit(2)
}
switch args[1] {
case "windows":
    listWindows(pid: Int(args[2]) ?? -1)
case "ocr":
    ocr(Array(args.dropFirst(2)))
case "stats":
    stats(Array(args.dropFirst(2)))
default:
    print("unknown command \(args[1])")
    exit(2)
}
