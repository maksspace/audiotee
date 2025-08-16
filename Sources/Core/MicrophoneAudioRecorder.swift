import AudioToolbox
import CoreAudio
import Foundation

public class MicrophoneAudioRecorder {
  private var inputDeviceID: AudioObjectID
  private var ioProcID: AudioDeviceIOProcID?
  private var finalFormat: AudioStreamBasicDescription!
  private var audioBuffer: AudioBuffer?
  private var outputHandler: AudioOutputHandler
  private var converter: AudioFormatConverter?
  
  init(
    outputHandler: AudioOutputHandler,
    convertToSampleRate: Double? = nil,
    chunkDuration: Double = 0.2
  ) throws {
    self.outputHandler = outputHandler
    
    // Get default input device
    self.inputDeviceID = try Self.getDefaultInputDeviceID()
    
    // Get source format and set up conversion if requested
    let sourceFormat = AudioFormatManager.getDeviceFormat(deviceID: inputDeviceID)
    
    // Set up the audio buffer using source format and configurable chunk duration
    self.audioBuffer = AudioBuffer(format: sourceFormat, chunkDuration: chunkDuration)
    
    if let targetSampleRate = convertToSampleRate {
      // Validate sample rate
      guard AudioFormatConverter.isValidSampleRate(targetSampleRate) else {
        Logger.error("Invalid sample rate", context: ["sample_rate": String(targetSampleRate)])
        self.converter = nil
        self.finalFormat = sourceFormat
        return
      }
      
      do {
        let converter = try AudioFormatConverter.toSampleRate(targetSampleRate, from: sourceFormat)
        self.converter = converter
        self.finalFormat = converter.targetFormatDescription
        Logger.info(
          "Microphone audio conversion enabled", context: ["target_sample_rate": String(targetSampleRate)])
      } catch {
        Logger.error(
          "Failed to create microphone audio converter, using original format",
          context: ["error": String(describing: error)])
        self.converter = nil
        self.finalFormat = sourceFormat
      }
    } else {
      self.converter = nil
      self.finalFormat = sourceFormat
    }
  }
  
  private static func getDefaultInputDeviceID() throws -> AudioObjectID {
    var deviceID: AudioObjectID = 0
    var address = getPropertyAddress(selector: kAudioHardwarePropertyDefaultInputDevice)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &deviceID
    )
    
    guard status == kAudioHardwareNoError && deviceID != kAudioObjectUnknown else {
      Logger.error("Failed to get default input device", context: ["status": String(status)])
      throw AudioTeeError.setupFailed
    }
    
    // Verify the device is valid and alive
    guard isAudioDeviceValid(deviceID) else {
      Logger.error("Default input device is not valid or alive", context: ["device_id": String(deviceID)])
      throw AudioTeeError.setupFailed
    }
    
    Logger.debug("Found default input device", context: ["device_id": String(deviceID)])
    return deviceID
  }
  
  func startRecording() throws {
    Logger.debug("Starting microphone recording")
    
    // Log format info and send metadata for final format
    AudioFormatManager.logFormatInfo(finalFormat)
    let metadata = AudioFormatManager.createMetadata(for: finalFormat)
    outputHandler.handleMetadata(metadata)
    outputHandler.handleStreamStart()
    
    try setupAndStartIOProc()
    
    Logger.info("Microphone started successfully")
  }
  
  private func setupAndStartIOProc() throws {
    Logger.debug("Creating microphone IO proc")
    
    // Double-check that the device is still valid before creating IO proc
    guard isAudioDeviceValid(inputDeviceID) else {
      Logger.error("Microphone device is no longer valid", context: ["device_id": String(inputDeviceID)])
      throw AudioTeeError.setupFailed
    }
    
    var status = AudioDeviceCreateIOProcID(
      inputDeviceID,
      {
        (inDevice, inNow, inInputData, inInputTime, outOutputData, inOutputTime, inClientData)
          -> OSStatus in
        let recorder = Unmanaged<MicrophoneAudioRecorder>.fromOpaque(inClientData!).takeUnretainedValue()
        return recorder.processAudio(inInputData)
      },
      Unmanaged.passUnretained(self).toOpaque(),
      &ioProcID
    )
    
    guard status == noErr else {
      Logger.error("Failed to create microphone IO proc", context: [
        "status": String(status),
        "device_id": String(inputDeviceID),
        "status_hex": String(format: "0x%08x", status)
      ])
      throw AudioTeeError.setupFailed
    }
    
    Logger.debug("Starting microphone device", context: ["device_id": String(inputDeviceID)])
    
    // Add a small delay to let the system settle
    usleep(100_000) // 100ms
    
    status = AudioDeviceStart(inputDeviceID, ioProcID)
    
    if status != noErr {
      cleanupIOProc()
      Logger.error("Failed to start microphone device", context: [
        "status": String(status),
        "device_id": String(inputDeviceID),
        "status_hex": String(format: "0x%08x", status)
      ])
      throw AudioTeeError.setupFailed
    }
  }
  
  private func processAudio(_ inputData: UnsafePointer<AudioBufferList>?) -> OSStatus {
    guard let inputData = inputData else {
      Logger.debug("Received null microphone input data")
      return noErr
    }
    
    let bufferList = inputData.pointee
    let firstBuffer = bufferList.mBuffers
    
    guard firstBuffer.mData != nil && firstBuffer.mDataByteSize > 0 else {
      // Empty buffer - this is normal for input devices during silence
      return noErr
    }
    
    // Append raw audio data to buffer
    let audioData = Data(bytes: firstBuffer.mData!, count: Int(firstBuffer.mDataByteSize))
    audioBuffer?.append(audioData)
    
    processAudioBuffer()
    
    return noErr
  }
  
  func stopRecording() {
    processAudioBuffer()
    outputHandler.handleStreamStop()
    cleanupIOProc()
  }
  
  private func processAudioBuffer() {
    // Process and send complete chunks, applying conversion if needed
    audioBuffer?.processChunks().forEach { packet in
      let processedPacket = converter?.transform(packet) ?? packet
      outputHandler.handleAudioPacket(processedPacket)
    }
  }
  
  private func cleanupIOProc() {
    if let ioProcID = ioProcID {
      AudioDeviceStop(inputDeviceID, ioProcID)
      AudioDeviceDestroyIOProcID(inputDeviceID, ioProcID)
      self.ioProcID = nil
    }
  }
}
