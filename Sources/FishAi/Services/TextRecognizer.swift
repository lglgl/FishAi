@preconcurrency import Vision
import Foundation
import os

/// 性能日志：log show --predicate 'subsystem == "com.lglgl.FishAi"' --last 5m
let perfLog = Logger(subsystem: "com.lglgl.FishAi", category: "perf")

enum TextRecognizer {
    /// 常用识别语言列表（优先中英日韩等主流语言）
    private static let recognitionLanguages = [
        "zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES"
    ]

    /// 预热：Vision 首次识别要加载模型（约 200ms），在用户框选期间提前跑一次空识别
    static func prewarm() {
        DispatchQueue.global(qos: .utility).async {
            let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            guard let image = context?.makeImage() else { return }
            let request = VNRecognizeTextRequest()
            configure(request)
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        }
    }

    private static func configure(_ request: VNRecognizeTextRequest) {
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = recognitionLanguages
    }

    /// 使用 macOS 本地 Vision 框架进行高精度离线文字识别（OCR）
    static func recognize(_ image: CGImage) async throws -> String {
        let start = ContinuousClock.now
        defer { perfLog.notice("ocr \(image.width)x\(image.height): \(start.duration(to: .now))") }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                let result = formatRecognizedLines(lines)
                continuation.resume(returning: result)
            }

            configure(request)

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 智能合并与清洗 OCR 输出的行文本：
    /// - 过滤孤立噪点符号（如 •, ·, |, —, _ 等单字符噪点）
    /// - 针对换行截断的中日韩 (CJK) 字符无缝拼接
    /// - 针对西文添加合理空格拼接，避免单词断裂
    /// - 保留自然段落与明显断句
    static func formatRecognizedLines(_ rawLines: [String]) -> String {
        // 过滤空行以及纯标点符号/孤立噪点行
        let noiseCharacters = CharacterSet(charactersIn: "•·|—_~*#-=+`'\"^/\\")
        let lines = rawLines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty else { return false }
                // 如果整行去噪后为空，且长度不超过 2，判定为 OCR 识别伪影噪点并剔除
                let stripped = line.trimmingCharacters(in: noiseCharacters.union(.whitespacesAndNewlines))
                if stripped.isEmpty && line.count <= 2 { return false }
                return true
            }

        guard !lines.isEmpty else { return "" }

        var result = ""
        for (index, line) in lines.enumerated() {
            if index == 0 {
                result += line
                continue
            }

            let previousLine = lines[index - 1]
            guard let prevLastChar = previousLine.last, let currFirstChar = line.first else {
                result += "\n" + line
                continue
            }

            // 判断前后字符是否为中日韩字符 (CJK)
            let isPrevCJK = isCJKCharacter(prevLastChar)
            let isCurrCJK = isCJKCharacter(currFirstChar)

            // 如果上一行以句号、问号、感叹号、冒号结尾，或者包含明显的段落断句，则保留换行
            let isSentenceEnding = "。！？!?：:;\n".contains(prevLastChar)

            if isSentenceEnding {
                result += "\n" + line
            } else if isPrevCJK || isCurrCJK {
                // 中日韩字符间直接连接，不添加多余空格
                result += line
            } else {
                // 西文字符间添加空格连接，避免单行折断造成的单词拼贴
                result += " " + line
            }
        }

        return result
    }

    /// 检测单个字符是否为中日韩文字
    private static func isCJKCharacter(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x4E00...0x9FFF,   // CJK Unified Ideographs
             0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
             0x20000...0x2A6DF, // Extension B
             0x3040...0x309F,   // Hiragana
             0x30A0...0x30FF,   // Katakana
             0xAC00...0xD7AF:   // Hangul Syllables
            return true
        default:
            return false
        }
    }
}
