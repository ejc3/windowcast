import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreImage
import AppKit

// windowcast — scriptable, window-isolated screen recorder (ScreenCaptureKit) that
// composites the captured window onto a clean styled backdrop (gradient/solid +
// padding + rounded corners + soft shadow), Screen-Studio-style. Records ONLY the
// chosen window's pixels — never the desktop behind it.
//
//   windowcast --list
//   windowcast --match "cmux DEV lv-all" --out demo.mov [--fps 60] [--seconds 20]
//              [--padding 60] [--radius 14] [--no-shadow]
//              [--background "#16161e"]                 (solid)
//              [--background "#3a3a52,#16161e"]         (vertical gradient top,bottom)
//
// Stops on --seconds, or on SIGINT (Ctrl-C). Needs Screen Recording permission for
// the terminal/app you run it from (System Settings ▸ Privacy & Security ▸ Screen
// Recording) — first run will prompt.

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
func argValue(_ name: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return nil
}
func hasFlag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

func ciColor(_ hex: String) -> CIColor {
    var h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
    var v: UInt64 = 0
    Scanner(string: h).scanHexInt64(&v)
    return CIColor(red: CGFloat((v >> 16) & 0xff) / 255,
                   green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255)
}

func shareableContent() -> SCShareableContent {
    let sem = DispatchSemaphore(value: 0)
    var out: SCShareableContent?
    var e: Error?
    SCShareableContent.getWithCompletionHandler { content, error in out = content; e = error; sem.signal() }
    sem.wait()
    if let e { err("error: could not read shareable content: \(e.localizedDescription)"); exit(1) }
    guard let out else { err("error: no shareable content"); exit(1) }
    return out
}

let content = shareableContent()
let windows = content.windows.filter { $0.isOnScreen }

if hasFlag("--list") {
    for w in windows.sorted(by: { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }) {
        print("app=\(w.owningApplication?.applicationName ?? "?")  title=\(w.title ?? "")  \(Int(w.frame.width))x\(Int(w.frame.height))  id=\(w.windowID)")
    }
    exit(0)
}

guard let match = argValue("--match") else {
    err("usage: windowcast --list | --match <app-or-title> [--out f.mov] [--fps 60] [--seconds N] [--padding 60] [--radius 14] [--no-shadow] [--background \"#3a3a52,#16161e\"]")
    exit(2)
}
let outPath = argValue("--out") ?? "windowcast.mov"
let fps = Int32(argValue("--fps") ?? "60") ?? 60
let seconds = argValue("--seconds").flatMap { Double($0) }
let padArg = argValue("--padding") ?? "3%"   // fixed points, or "%": proportional to window
let radius = CGFloat(Int(argValue("--radius") ?? "14") ?? 14)
let drawShadow = !hasFlag("--no-shadow")

// Background: solid "#hex" or vertical gradient "#top,#bottom" (default: dark gradient).
let bgArg = argValue("--background") ?? "#3a3a52,#16161e"
let bgColors = bgArg.split(separator: ",").map { ciColor(String($0).trimmingCharacters(in: .whitespaces)) }
let bgTop = bgColors.first ?? ciColor("#3a3a52")
let bgBottom = bgColors.count > 1 ? bgColors[1] : bgTop

let needle = match.lowercased()
guard let window = windows.first(where: {
    ($0.owningApplication?.applicationName.lowercased().contains(needle) ?? false)
        || ($0.title?.lowercased().contains(needle) ?? false)
}) else {
    err("no on-screen window matches \"\(match)\". Try: windowcast --list")
    exit(1)
}

// Native-resolution window pixels; canvas adds even padding on all sides.
let scale = NSScreen.main?.backingScaleFactor ?? 2.0
func even(_ n: Int) -> Int { (n / 2) * 2 }
// Padding: fixed points, or "%": proportional to the larger window edge (what
// polished recorders do, so the border scales with the window rather than being
// a fat fixed margin on big windows).
let padPoints: CGFloat = {
    if padArg.hasSuffix("%") {
        let pct = Double(padArg.dropLast()) ?? 3
        return CGFloat(pct / 100.0) * max(window.frame.width, window.frame.height)
    }
    return CGFloat(Double(padArg) ?? 32)
}()
let winW = even(Int(window.frame.width * scale))
let winH = even(Int(window.frame.height * scale))
let canvasW = even(winW + 2 * Int(padPoints * scale))
let canvasH = even(winH + 2 * Int(padPoints * scale))
let padPx = CGFloat((canvasW - winW) / 2)
let canvasRect = CGRect(x: 0, y: 0, width: canvasW, height: canvasH)

// Precompute the gradient backdrop and a rounded-corner mask once (reused per frame).
let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

let background: CIImage = {
    let g = CIFilter(name: "CILinearGradient", parameters: [
        "inputPoint0": CIVector(x: 0, y: CGFloat(canvasH)), "inputColor0": bgTop,
        "inputPoint1": CIVector(x: 0, y: 0), "inputColor1": bgBottom,
    ])!.outputImage!
    return g.cropped(to: canvasRect)
}()

// White rounded rect on opaque black → reliable luminance mask for CIBlendWithMask.
let cornerMask: CIImage = {
    let ctx = CGContext(data: nil, width: winW, height: winH, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let full = CGRect(x: 0, y: 0, width: winW, height: winH)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(full)
    ctx.addPath(CGPath(roundedRect: full, cornerWidth: radius * scale, cornerHeight: radius * scale, transform: nil))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
    return CIImage(cgImage: ctx.makeImage()!)
}()

// Soft drop shadow: the rounded shape, tinted black @ ~0.35 alpha, blurred + offset down.
let shadowImage: CIImage? = drawShadow ? {
    cornerMask.applyingFilter("CIMaskToAlpha")
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.35),
        ])
        .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 24.0 * Double(scale)])
        .transformed(by: CGAffineTransform(translationX: padPx, y: padPx - 14 * scale))
}() : nil

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var started = false
    let queue = DispatchQueue(label: "windowcast.capture")

    init(url: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        super.init()
        if writer.canAdd(input) { writer.add(input) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]], let info = attachments.first,
              let rawStatus = info[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
            started = true
        }
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }

        // Composite: rounded window over shadow over gradient, positioned with padding.
        let win = CIImage(cvPixelBuffer: pixelBuffer)
        let rounded = win.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: win.extent),
            kCIInputMaskImageKey: cornerMask,
        ]).transformed(by: CGAffineTransform(translationX: padPx, y: padPx))

        var composite = rounded.composited(over: background)
        if let shadowImage { composite = rounded.composited(over: shadowImage.composited(over: background)) }
        composite = composite.cropped(to: canvasRect)

        var outBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer) == kCVReturnSuccess, let outBuffer else { return }
        ciContext.render(composite, to: outBuffer, bounds: canvasRect, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        adaptor.append(outBuffer, withPresentationTime: pts)
    }

    func finish(_ done: @escaping () -> Void) {
        input.markAsFinished()
        writer.finishWriting(completionHandler: done)
    }
}

let url = URL(fileURLWithPath: outPath)
try? FileManager.default.removeItem(at: url)
let recorder: Recorder
do { recorder = try Recorder(url: url, width: canvasW, height: canvasH) }
catch { err("error: could not create writer: \(error.localizedDescription)"); exit(1) }

let config = SCStreamConfiguration()
config.width = winW
config.height = winH
config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
config.pixelFormat = kCVPixelFormatType_32BGRA
config.showsCursor = true
config.queueDepth = 6

let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: recorder)
do { try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue) }
catch { err("error: addStreamOutput: \(error.localizedDescription)"); exit(1) }

func stopAndExit() {
    stream.stopCapture { _ in recorder.finish { err("✓ saved \(outPath)  (\(canvasW)x\(canvasH))"); exit(0) } }
}

let startSem = DispatchSemaphore(value: 0)
stream.startCapture { e in
    if let e { err("error: startCapture failed: \(e.localizedDescription) — grant Screen Recording permission to this terminal."); exit(1) }
    startSem.signal()
}
startSem.wait()
err("● recording \(window.owningApplication?.applicationName ?? "?") / \(window.title ?? "")  →  \(outPath)" + (seconds != nil ? "  for \(seconds!)s" : "  (Ctrl-C to stop)"))

signal(SIGINT, SIG_IGN)
let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sig.setEventHandler { stopAndExit() }
sig.resume()
if let seconds { DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { stopAndExit() } }
RunLoop.main.run()
