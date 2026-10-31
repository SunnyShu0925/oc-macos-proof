import AppKit
import Vision

let args = CommandLine.arguments
guard args.count > 1 else { print("usage: ocr-url <image>"); exit(2) }
let path = args[1]
guard let image = NSImage(contentsOfFile: path),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("LOAD_FAIL \(path)"); exit(1)
}
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
let results = request.results ?? []
print("IMAGE \(path) \(cg.width)x\(cg.height) lines=\(results.count)")
for obs in results {
    guard let text = obs.topCandidates(1).first?.string else { continue }
    let b = obs.boundingBox
    let x = Int(b.minX * CGFloat(cg.width))
    let y = Int((1 - b.maxY) * CGFloat(cg.height))
    let w = Int(b.width * CGFloat(cg.width))
    let h = Int(b.height * CGFloat(cg.height))
    print("LINE x=\(x) y=\(y) w=\(w) h=\(h) :: \(text)")
}
