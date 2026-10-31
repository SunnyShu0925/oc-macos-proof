import AppKit
import Foundation
import Vision

// OCR a captured PNG so the proof carries machine-readable text of what the
// shipped window actually rendered (the screenshot alone is not verifiable in
// a headless log).
guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: ocr-window.swift <png>\n".utf8))
    exit(2)
}
let path = CommandLine.arguments[1]
guard let image = NSImage(contentsOfFile: path),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write(Data("cannot load image \(path)\n".utf8))
    exit(3)
}
let request = VNRecognizeTextRequest { request, error in
    if let error {
        FileHandle.standardError.write(Data("vision error: \(error)\n".utf8))
    }
    guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
    for observation in observations {
        if let candidate = observation.topCandidates(1).first {
            print(candidate.string)
        }
    }
}
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
do {
    try handler.perform([request])
} catch {
    FileHandle.standardError.write(Data("perform failed: \(error)\n".utf8))
    exit(4)
}
