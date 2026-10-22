import Foundation

/// 1D 相位相关：从两帧的像素列里估计垂直偏移。
///
/// 原理（业界标准，参考 screen-stitch 的算法链）：
/// 两幅图之间的平移，在频域表现为**相位差**而非幅度差。
/// 把互功率谱归一化后做逆变换，峰值位置就是偏移量。
///
/// 相比逐像素 SAD 模板匹配（我之前用的），它有三个优势：
/// 1. **全局最优**：FFT 搜遍所有可能偏移，不会像模板匹配那样陷入局部最优
/// 2. **抗噪、抗亮度变化**：只看相位，不看幅度
/// 3. **对重复纹理不敏感**：聊天记录这种相似内容，SAD 会匹配错位置，相位相关不会
enum PhaseCorrelator {

    /// 估计 `next` 相对 `prev` 向下滚了多少像素。
    /// 正值 = 向下滚（看到下面的内容）。
    static func verticalShift(
        prevPixels: [UInt8],
        nextPixels: [UInt8],
        width: Int,
        height: Int,
        maxShift: Int
    ) -> Int? {
        guard width > 0, height >= 64 else { return nil }

        // FFT 要求长度是 2 的幂
        let n = 1 << Int(log2(Float(height)).rounded(.down))
        guard n >= 64 else { return nil }

        // 多列投票：单列可能是纯白背景（无特征），取多列降低风险
        let columnCount = 16
        let step = max(1, width / columnCount)
        var votes: [Int] = []

        for x in stride(from: 0, to: width, by: step) {
            var colPrev = [Float](repeating: 0, count: n)
            var colNext = [Float](repeating: 0, count: n)
            for y in 0..<n {
                colPrev[y] = Float(prevPixels[y * width + x])
                colNext[y] = Float(nextPixels[y * width + x])
            }
            if let shift = correlate1D(colPrev, colNext), abs(shift) <= maxShift {
                votes.append(shift)
            }
        }

        // 至少三分之一的列给出一致结果，才认为可信
        guard votes.count >= max(4, columnCount / 3) else { return nil }
        votes.sort()
        return votes[votes.count / 2]
    }

    /// 1D 相位相关，返回 b 相对 a 的平移
    private static func correlate1D(_ a: [Float], _ b: [Float]) -> Int? {
        let n = a.count

        // 去均值 + Hanning 窗，减少边界效应（相位相关对此敏感）
        var x = a
        var y = b
        let meanX = x.reduce(0, +) / Float(n)
        let meanY = y.reduce(0, +) / Float(n)
        for i in 0..<n {
            let w = 0.5 - 0.5 * cos(2 * .pi * Float(i) / Float(max(n - 1, 1)))
            x[i] = (x[i] - meanX) * w
            y[i] = (y[i] - meanY) * w
        }

        let (aRe, aIm) = fft(re: x, im: [Float](repeating: 0, count: n))
        let (bRe, bIm) = fft(re: y, im: [Float](repeating: 0, count: n))

        // 互功率谱归一化：R = A * conj(B) / |A * conj(B)|
        var re = [Float](repeating: 0, count: n)
        var im = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let r = aRe[i] * bRe[i] + aIm[i] * bIm[i]
            let imag = aIm[i] * bRe[i] - aRe[i] * bIm[i]
            let mag = max(sqrt(r * r + imag * imag), 1e-6)
            re[i] = r / mag
            im[i] = imag / mag
        }

        // 逆变换：IFFT(X) = conj(FFT(conj(X))) / n
        var conjIm = im.map { -$0 }
        let (cRe, cIm) = fft(re: re, im: conjIm)
        conjIm = cIm.map { -$0 / Float(n) }
        let corr = cRe.map { $0 / Float(n) }
        _ = conjIm   // 只用实部找峰值

        // 找峰值位置
        var maxIdx = 0
        var maxVal = -Float.greatestFiniteMagnitude
        for i in 0..<n where corr[i] > maxVal {
            maxVal = corr[i]
            maxIdx = i
        }

        // 可靠性检查：峰值必须显著高于其它位置（PSR，peak-to-sidelobe ratio）。
        // 不加这个，纯色/噪点图会给出毫无意义的峰值，拼出来高度就错了
        //（实测无特征场景拼成 844px，实际该是 1376px）。
        // screen-stitch 的算法链里，这一步对应「validate with overlap NCC」。
        var sum: Float = 0
        for i in 0..<n { sum += corr[i] }
        let mean = sum / Float(n)
        var variance: Float = 0
        for i in 0..<n {
            let d = corr[i] - mean
            variance += d * d
        }
        let std = sqrt(variance / Float(max(n, 1)))
        let psr = (maxVal - mean) / max(std, 1e-6)
        guard psr > 6 else { return nil }

        // 循环平移 → 有符号偏移
        var shift = maxIdx
        if shift > n / 2 {
            shift -= n
        }
        // 长截图只往下滚（看到下面的内容），向上的偏移视为不可信
        guard shift >= 0 else { return nil }
        return shift
    }

    /// 迭代基-2 Cooley-Tukey FFT（复数输入）
    static func fft(re: [Float], im inputIm: [Float]) -> (re: [Float], im: [Float]) {
        let n = re.count
        assert(n.nonzeroBitCount == 1, "长度必须是 2 的幂")

        var reOut = re
        var imOut = inputIm

        // 位反转置换
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j {
                reOut.swapAt(i, j)
                imOut.swapAt(i, j)
            }
        }

        // 蝶形运算
        var length = 2
        while length <= n {
            let angle = -2 * Float.pi / Float(length)
            let wRe = cos(angle)
            let wIm = sin(angle)

            var i = 0
            while i < n {
                var curRe: Float = 1
                var curIm: Float = 0
                let half = length / 2

                for k in 0..<half {
                    let uRe = reOut[i + k]
                    let uIm = imOut[i + k]
                    let vRe = reOut[i + k + half] * curRe - imOut[i + k + half] * curIm
                    let vIm = reOut[i + k + half] * curIm + imOut[i + k + half] * curRe

                    reOut[i + k] = uRe + vRe
                    imOut[i + k] = uIm + vIm
                    reOut[i + k + half] = uRe - vRe
                    imOut[i + k + half] = uIm - vIm

                    let nextRe = curRe * wRe - curIm * wIm
                    curIm = curRe * wIm + curIm * wRe
                    curRe = nextRe
                }
                i += length
            }
            length <<= 1
        }

        return (reOut, imOut)
    }
}
