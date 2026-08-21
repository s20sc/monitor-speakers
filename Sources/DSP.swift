import Foundation

/// One biquad section, a0-normalized: y = b0*x + b1*x1 + b2*x2 - a1*y1 - a2*y2.
/// Plain value type so it can live inside the realtime render context.
struct BiquadCoefficients {
    var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float

    /// RBJ-cookbook 2nd-order Butterworth (Q = 1/√2). Two cascaded sections
    /// of these form one half of a 4th-order Linkwitz-Riley crossover, whose
    /// low and high outputs sum flat — the standard 2.1 bass-management split.
    static func butterworthLowPass(frequency: Float, sampleRate: Float) -> BiquadCoefficients {
        let w = 2 * Float.pi * frequency / sampleRate
        let cosw = cos(w)
        let alpha = sin(w) / Float(2).squareRoot()
        let a0 = 1 + alpha
        return BiquadCoefficients(
            b0: ((1 - cosw) / 2) / a0, b1: (1 - cosw) / a0, b2: ((1 - cosw) / 2) / a0,
            a1: (-2 * cosw) / a0, a2: (1 - alpha) / a0
        )
    }

    static func butterworthHighPass(frequency: Float, sampleRate: Float) -> BiquadCoefficients {
        let w = 2 * Float.pi * frequency / sampleRate
        let cosw = cos(w)
        let alpha = sin(w) / Float(2).squareRoot()
        let a0 = 1 + alpha
        return BiquadCoefficients(
            b0: ((1 + cosw) / 2) / a0, b1: -(1 + cosw) / a0, b2: ((1 + cosw) / 2) / a0,
            a1: (-2 * cosw) / a0, a2: (1 - alpha) / a0
        )
    }
}

/// Processes one sample through two cascaded identical biquad sections (an
/// LR4 half). `state` holds 8 floats: x1,x2,y1,y2 per section. Free function
/// on raw pointers, no allocation — safe on the audio thread.
@inline(__always)
func processLR4(
    _ x: Float, coefficients c: BiquadCoefficients, state: UnsafeMutablePointer<Float>
) -> Float {
    var v = x
    for section in 0..<2 {
        let st = state + section * 4
        let y = c.b0 * v + c.b1 * st[0] + c.b2 * st[1] - c.a1 * st[2] - c.a2 * st[3]
        st[1] = st[0]; st[0] = v
        st[3] = st[2]; st[2] = y
        v = y
    }
    return v
}
