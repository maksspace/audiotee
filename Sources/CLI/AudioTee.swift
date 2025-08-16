import CoreAudio
import Foundation

struct AudioTee {
  var includeProcesses: [Int32] = []
  var excludeProcesses: [Int32] = []
  var mute: Bool = false
  var stereo: Bool = false
  var sampleRate: Double?
  var chunkDuration: Double = 0.2
  var captureMicrophone: Bool = false

  init() {}

  static func main() {
    let parser = SimpleArgumentParser(
      programName: "audiotee",
      abstract: "Capture system audio and/or microphone input and stream to stdout",
      discussion: """
        AudioTee captures system audio using Core Audio taps and optionally microphone input, streaming as structured output.

        Process filtering:
        • include-processes: Only tap specified process IDs (empty = all processes)
        • exclude-processes: Tap all processes except specified ones
        • mute: How to handle processes being tapped
        • mic: Also capture microphone input alongside system audio

        Examples:
          audiotee                              # Auto format, tap all processes
          audiotee --sample-rate 16000          # Convert to 16kHz mono for ASR
          audiotee --sample-rate 8000           # Convert to 8kHz for telephony
          audiotee --include-processes 1234     # Only tap process 1234
          audiotee --include-processes 1234 5678 9012  # Tap only these processes
          audiotee --exclude-processes 1234 5678       # Tap everything except these
          audiotee --mute                       # Mute processes being tapped
          audiotee --mic                        # Also capture microphone input
        """
    )

    // Configure arguments
    parser.addArrayOption(
      name: "include-processes",
      help: "Process IDs to include (space-separated, empty = all processes)")
    parser.addArrayOption(
      name: "exclude-processes", help: "Process IDs to exclude (space-separated)")
    parser.addFlag(name: "mute", help: "Mute processes being tapped")
    parser.addFlag(name: "stereo", help: "Records in stereo")
    parser.addFlag(name: "mic", help: "Also capture microphone input")
    parser.addOption(
      name: "sample-rate",
      help: "Target sample rate (8000, 16000, 22050, 24000, 32000, 44100, 48000)")
    parser.addOption(
      name: "chunk-duration", help: "Audio chunk duration in seconds", defaultValue: "0.2")

    // Parse arguments
    do {
      try parser.parse()

      var audioTee = AudioTee()

      // Extract values
      audioTee.includeProcesses = try parser.getArrayValue("include-processes", as: Int32.self)
      audioTee.excludeProcesses = try parser.getArrayValue("exclude-processes", as: Int32.self)
      audioTee.mute = parser.getFlag("mute")
      audioTee.stereo = parser.getFlag("stereo")
      audioTee.captureMicrophone = parser.getFlag("mic")
      audioTee.sampleRate = try parser.getOptionalValue("sample-rate", as: Double.self)
      audioTee.chunkDuration = try parser.getValue("chunk-duration", as: Double.self)

      // Validate
      try audioTee.validate()

      // Run
      try audioTee.run()

    } catch ArgumentParserError.helpRequested {
      parser.printHelp()
      exit(0)
    } catch ArgumentParserError.validationFailed(let message) {
      print("Error: \(message)", to: &standardError)
      exit(1)
    } catch let error as ArgumentParserError {
      print("Error: \(error.description)", to: &standardError)
      parser.printHelp()
      exit(1)
    } catch {
      print("Error: \(error)", to: &standardError)
      exit(1)
    }
  }

  func validate() throws {
    if !includeProcesses.isEmpty && !excludeProcesses.isEmpty {
      throw ArgumentParserError.validationFailed(
        "Cannot specify both --include-processes and --exclude-processes")
    }
  }

  func run() throws {
    setupSignalHandlers()

    Logger.info("Starting AudioTee...")

    // Validate chunk duration
    guard chunkDuration > 0 && chunkDuration <= 5.0 else {
      Logger.error(
        "Invalid chunk duration",
        context: ["chunk_duration": String(chunkDuration), "valid_range": "0.0 < duration <= 5.0"])
      throw ExitCode.failure
    }

    // Convert include/exclude processes to TapConfiguration format
    let (processes, isExclusive) = convertProcessFlags()

    let tapConfig = TapConfiguration(
      processes: processes,
      muteBehavior: mute ? .muted : .unmuted,
      isExclusive: isExclusive,
      isMono: !stereo,
      captureMicrophone: captureMicrophone
    )

    let outputHandler = BinaryAudioOutputHandler()
    var systemAudioRecorder: AudioRecorder?
    var microphoneRecorder: MicrophoneAudioRecorder?
    
    // Setup system audio recording (always enabled unless only microphone is requested)
    if !captureMicrophone || true { // For now, always capture system audio when available
      let audioTapManager = AudioTapManager()
      do {
        try audioTapManager.setupAudioTap(with: tapConfig)
      } catch AudioTeeError.pidTranslationFailed(let failedPIDs) {
        Logger.error(
          "Failed to translate process IDs to audio objects",
          context: [
            "failed_pids": failedPIDs.map(String.init).joined(separator: ", "),
            "suggestion": "Check that the process IDs exist and are running",
          ])
        throw ExitCode.failure
      } catch {
        Logger.error(
          "Failed to setup audio tap", context: ["error": String(describing: error)])
        throw ExitCode.failure
      }

      guard let deviceID = audioTapManager.getDeviceID() else {
        Logger.error("Failed to get device ID from audio tap manager")
        throw ExitCode.failure
      }

      systemAudioRecorder = AudioRecorder(
        deviceID: deviceID, outputHandler: outputHandler, convertToSampleRate: sampleRate,
        chunkDuration: chunkDuration)
    }
    
    // Setup microphone recording if requested
    if captureMicrophone {
      do {
        microphoneRecorder = try MicrophoneAudioRecorder(
          outputHandler: outputHandler, convertToSampleRate: sampleRate, chunkDuration: chunkDuration)
        Logger.info("Microphone capture enabled")
      } catch {
        Logger.error("Failed to setup microphone recording", context: ["error": String(describing: error)])
        Logger.info("Continuing with system audio only...")
        // Don't throw - continue with system audio only
      }
    }
    
    // Start recording from both sources
    if let sysRecorder = systemAudioRecorder {
      do {
        try sysRecorder.startRecording()
      } catch {
        Logger.error("Failed to start system audio recording", context: ["error": String(describing: error)])
        Logger.info("Continuing with microphone only (if enabled) or exiting...")
        systemAudioRecorder = nil  // Clear the recorder so we don't try to stop it later
        
        // If microphone is not enabled and system audio failed, we have nothing to record
        if !captureMicrophone || microphoneRecorder == nil {
          Logger.error("No audio sources available - exiting")
          throw ExitCode.failure
        }
      }
    }
    
    if let micRecorder = microphoneRecorder {
      do {
        try micRecorder.startRecording()
      } catch {
        Logger.error("Failed to start microphone recording", context: ["error": String(describing: error)])
        Logger.info("Continuing with system audio only (if enabled) or exiting...")
        microphoneRecorder = nil  // Clear the recorder so we don't try to stop it later
        
        // If system audio is not available and microphone failed, we have nothing to record
        if systemAudioRecorder == nil {
          Logger.error("No audio sources available - exiting")
          throw ExitCode.failure
        }
      }
    }

    // Run until the run loop is stopped (by signal handler)
    while true {
      let result = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.1, false)
      if result == CFRunLoopRunResult.stopped || result == CFRunLoopRunResult.finished {
        break
      }
    }

    Logger.info("Shutting down...")
    systemAudioRecorder?.stopRecording()
    microphoneRecorder?.stopRecording()
  }

  private func setupSignalHandlers() {
    signal(SIGINT) { _ in
      Logger.info("Received SIGINT, initiating graceful shutdown...")
      CFRunLoopStop(CFRunLoopGetMain())
    }
    signal(SIGTERM) { _ in
      Logger.info("Received SIGTERM, initiating graceful shutdown...")
      CFRunLoopStop(CFRunLoopGetMain())
    }
  }

  private func convertProcessFlags() -> ([Int32], Bool) {
    if !includeProcesses.isEmpty {
      // Include specific processes only
      return (includeProcesses, false)
    } else if !excludeProcesses.isEmpty {
      // Exclude specific processes (tap everything except these)
      return (excludeProcesses, true)
    } else {
      // Default: tap everything
      return ([], true)
    }
  }
}

// Helper for stderr output
var standardError = FileHandle.standardError

extension FileHandle: TextOutputStream {
  public func write(_ string: String) {
    let data = Data(string.utf8)
    self.write(data)
  }
}

// Exit code handling
enum ExitCode: Error {
  case failure
}

extension ExitCode {
  var code: Int32 {
    switch self {
    case .failure:
      return 1
    }
  }
}
