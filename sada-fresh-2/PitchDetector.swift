import Foundation
import AVFoundation
import Accelerate

class PitchDetector: ObservableObject {
    // Algorithm parameters from the research paper
    private let sampleRate: Float = 44100.0
    private let minFreq: Float = 10.0
    private let maxFreq: Float = 40.0
    private let freqAccuracy: Float = 0.025
    private let lowerFormantFreq: Float = 250.0
    private let decayRate: Float = 0.8
    private let minAmp: Float = 2.0E-4
    private let downsampleFactor: Int = 45
    private let minCorrelation: Float = 0.6
    
    @Published var currentPitch: Float = 0.0
    @Published var currentPressure: Float = 0.0
    @Published var isProcessing: Bool = false
    @Published var runLength: Int = 0
    
    // Moving averages for pitch tracking
    private var movingAvePeriod: Float = 0.0
    private var movingAveAmplitude: Float = 0.0
    private var movingAveDerivative: Float = 0.0
    private var lastDetectedPitch: Float = 0.0
    private var pitchRunLength: Int = 0
    private let maxRunLength: Int = 5 // round(1 - 1/0.8)
    
    // Audio processing buffers
    private var audioBuffer: [Float] = []
    private var processedSamples: Int = 0
    private let gaussianSigma: Float
    private var audioEnergyBuffer: [Float] = []
    
    init() {
        // Calculate Gaussian sigma for smoothing
        gaussianSigma = 0.2 * Float(downsampleFactor) * maxFreq / sampleRate
        resetSession()
    }
    
    func resetSession() {
        movingAvePeriod = 0.0
        movingAveAmplitude = 0.0
        movingAveDerivative = 0.0
        lastDetectedPitch = 0.0
        pitchRunLength = 0
        processedSamples = 0
        audioBuffer.removeAll()
        audioEnergyBuffer.removeAll()
        
        DispatchQueue.main.async {
            self.currentPitch = 0.0
            self.currentPressure = 0.0
            self.runLength = 0
        }
    }
    
    func processAudioChunk(_ audioData: [Float]) -> Float {
        // Step 1: Subtract smoothed version from raw audio
        let smoothedAudio = computeSmoothedSignal(audioData)
        var subtractedSignal = [Float](repeating: 0.0, count: audioData.count)
        vDSP_vsub(smoothedAudio, 1, audioData, 1, &subtractedSignal, 1, vDSP_Length(audioData.count))
        
        // Step 2: Compute square of the signal
        var squaredSignal = [Float](repeating: 0.0, count: subtractedSignal.count)
        vDSP_vsq(subtractedSignal, 1, &squaredSignal, 1, vDSP_Length(subtractedSignal.count))
        
        // Step 3: Downsample by averaging contiguous sets of 45 samples
        let downsampledSignal = downsampleSignal(squaredSignal)
        
        // Step 4: Apply Gaussian smoothing
        let smoothedEnergySignal = applyGaussianSmoothing(downsampledSignal)
        
        // Step 5: Compute autocorrelation and detect pitch
        let detectedPitch = detectPitchFromAutocorrelation(smoothedEnergySignal)
        
        // Step 6: Update moving averages and compute final pitch
        updateMovingAverages(detectedPitch)
        
        let finalPitch = computeFinalPitch()
        let pressure = computePressureFromPitch(finalPitch)
        
        DispatchQueue.main.async {
            self.currentPitch = finalPitch
            self.currentPressure = pressure
            self.runLength = self.pitchRunLength
        }
        
        return finalPitch
    }
    
    private func computeSmoothedSignal(_ signal: [Float]) -> [Float] {
        // Average over neighborhood equal to smallest formant frequency (176 samples)
        let windowSize = Int(sampleRate / lowerFormantFreq)
        var smoothed = [Float](repeating: 0.0, count: signal.count)
        
        for i in 0..<signal.count {
            let start = max(0, i - windowSize/2)
            let end = min(signal.count - 1, i + windowSize/2)
            var sum: Float = 0.0
            
            for j in start...end {
                sum += signal[j]
            }
            smoothed[i] = sum / Float(end - start + 1)
        }
        
        return smoothed
    }
    
    private func downsampleSignal(_ signal: [Float]) -> [Float] {
        let outputSize = signal.count / downsampleFactor
        var downsampled = [Float](repeating: 0.0, count: outputSize)
        
        for i in 0..<outputSize {
            var sum: Float = 0.0
            let startIdx = i * downsampleFactor
            let endIdx = min(startIdx + downsampleFactor, signal.count)
            
            for j in startIdx..<endIdx {
                sum += signal[j]
            }
            downsampled[i] = sum / Float(endIdx - startIdx)
        }
        
        return downsampled
    }
    
    private func applyGaussianSmoothing(_ signal: [Float]) -> [Float] {
        // Create Gaussian kernel
        let kernelSize = Int(gaussianSigma * 6.0) // 3 sigma on each side
        let halfKernel = kernelSize / 2
        var kernel = [Float](repeating: 0.0, count: kernelSize)
        
        var sum: Float = 0.0
        for i in 0..<kernelSize {
            let x = Float(i - halfKernel)
            let value = exp(-(x * x) / (2.0 * gaussianSigma * gaussianSigma))
            kernel[i] = value
            sum += value
        }
        
        // Normalize kernel
        for i in 0..<kernelSize {
            kernel[i] /= sum
        }
        
        // Apply convolution
        var smoothed = [Float](repeating: 0.0, count: signal.count)
        for i in 0..<signal.count {
            var convSum: Float = 0.0
            for j in 0..<kernelSize {
                let signalIdx = i + j - halfKernel
                if signalIdx >= 0 && signalIdx < signal.count {
                    convSum += signal[signalIdx] * kernel[j]
                }
            }
            smoothed[i] = convSum
        }
        
        return smoothed
    }
    
    private func detectPitchFromAutocorrelation(_ signal: [Float]) -> Float {
        guard signal.count > 0 else { return 0.0 }
        
        let downsampledRate = sampleRate / Float(downsampleFactor)
        let minPeriod = Int(downsampledRate / maxFreq)
        let maxPeriod = Int(downsampledRate / minFreq)
        
        guard maxPeriod < signal.count else { return 0.0 }
        
        var maxCorrelation: Float = 0.0
        var bestLag: Int = 0
        
        // Compute autocorrelation for each lag
        for lag in minPeriod...maxPeriod {
            var correlation: Float = 0.0
            var norm1: Float = 0.0
            var norm2: Float = 0.0
            
            for i in 0..<(signal.count - lag) {
                let val1 = signal[i]
                let val2 = signal[i + lag]
                correlation += val1 * val2
                norm1 += val1 * val1
                norm2 += val2 * val2
            }
            
            let normalizedCorr = correlation / sqrt(norm1 * norm2)
            
            if normalizedCorr > maxCorrelation {
                maxCorrelation = normalizedCorr
                bestLag = lag
            }
        }
        
        // Only accept correlation above threshold
        if maxCorrelation > minCorrelation {
            let pitch = downsampledRate / Float(bestLag)
            return pitch
        }
        
        return 0.0
    }
    
    private func updateMovingAverages(_ detectedPitch: Float) {
        guard detectedPitch > 0.0 else {
            // No valid pitch detected
            pitchRunLength = max(0, pitchRunLength - 1)
            return
        }
        
        // Check if pitch leap is reasonable
        if lastDetectedPitch > 0.0 {
            let pitchRatio = detectedPitch / lastDetectedPitch
            if pitchRatio < 0.5 || pitchRatio > 2.0 {
                // Large leap detected, reduce run length
                pitchRunLength = max(0, pitchRunLength - 2)
                return
            }
        }
        
        // Valid pitch detected, increment run length
        pitchRunLength = min(pitchRunLength + 1, maxRunLength)
        
        // Update moving averages
        let mix = min(decayRate, 1.0 - 1.0/Float(max(pitchRunLength, 1)))
        let newPeriod = 1.0 / detectedPitch
        
        movingAvePeriod = movingAvePeriod * mix + newPeriod * (1.0 - mix)
        movingAveAmplitude = movingAveAmplitude * mix + detectedPitch * (1.0 - mix)
        
        lastDetectedPitch = detectedPitch
    }
    
    private func computeFinalPitch() -> Float {
        guard movingAvePeriod > 0.0 && pitchRunLength > 0 else { return 0.0 }
        return 1.0 / movingAvePeriod
    }
    
    private func computePressureFromPitch(_ pitch: Float) -> Float {
        // Linear model from research paper: Pressure = a * Pitch + b
        // Based on the strong correlation (r² = 0.886) between 10-40Hz and 6-30 cmH2O
        // Approximated linear relationship from the paper's results
        let slope: Float = 0.6  // cmH2O per Hz (estimated from paper)
        let intercept: Float = 4.0  // cmH2O offset (estimated)
        
        guard pitch >= minFreq && pitch <= maxFreq else { return 0.0 }
        
        let pressure = slope * pitch + intercept
        return max(0.0, pressure)
    }
}
