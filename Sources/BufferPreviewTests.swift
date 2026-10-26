import AppKit
import AVFoundation

@MainActor enum BufferPreviewTests {
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = AppModel(preview: true)
        let root = model.libraryURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        model.saveBufferOnExit = false
        await model.previewBuffer()
        try SelfTest.require(model.bufferPreview == nil && model.clips.isEmpty, "Disabled replay cannot open a preview")
        model.minutes = 0.5; model.separateAudio = true
        model.systemVolume = 0.7; model.microphoneVolume = 0.4
        try model.engine.beginTest(seconds: 2, audio: true, microphone: true)
        model.recording = true
        func feed(_ frames: Range<Int>) async throws {
            for frame in frames {
                let pts = CMTime(value: 3000 + Int64(frame), timescale: 30)
                model.engine.testFrame(try SelfTest.pixel(frame: frame), at: pts)
                model.engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, frequency: 440))
                model.engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, rate: 44_100, channels: 1, frequency: 880), microphone: true)
                try await Task.sleep(nanoseconds: 8_000_000)
            }
            model.stats = model.engine.testStats()
        }
        try await feed(0..<60)
        await model.previewBuffer()
        guard let preview = model.bufferPreview else { throw SpyError.message("TEST FAILED: Preview not prepared: " + (model.error ?? "unknown")) }
        guard let pinned = preview.snapshot, let playback = preview.playback else { throw SpyError.message("TEST FAILED: Missing pinned composition") }
        let frozen = try pinned.urls.map { try Data(contentsOf: $0) }
        let frozenBytes = frozen.reduce(0) { $0 + $1.count }
        try SelfTest.require(model.recording && !model.saving && !model.preparingBufferPreview && model.clips.isEmpty, "Preview preserves capture and never publishes a library movie")
        try SelfTest.require(abs(preview.clip.duration - 2) < 0.06 && preview.clip.bytes == frozenBytes, "Preview contains the complete current buffer and accurate pinned-segment size")
        let filesBeforeSave = try FileManager.default.contentsOfDirectory(at: preview.directory, includingPropertiesForKeys: nil)
        try SelfTest.require(!FileManager.default.fileExists(atPath: preview.clip.url.path) && filesBeforeSave.filter { $0.pathExtension == "mov" }.count == pinned.urls.count, "Preview opens without creating Buffer.mov or any rendered export")
        let asset = preview.asset
        let video = try await asset.loadTracks(withMediaType: .video)[0]
        let audio = try await asset.loadTracks(withMediaType: .audio)
        try SelfTest.require(audio.count == 2, "Preview retains both selected audio tracks")
        let playerItem = playback.playerItem()
        try SelfTest.require(playerItem.audioMix?.inputParameters.count == 2, "Player enables both audio sources")
        let mixed = try await mixedSamples(asset: asset, mix: playerItem.audioMix)
        try SelfTest.require(abs(AudioTests.magnitude(mixed, frequency: 440) - 0.105) < 0.025 && abs(AudioTests.magnitude(mixed, frequency: 880) - 0.06) < 0.02, "Composition playback applies both frozen source gains without rendering AAC")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        try SelfTest.require(reader.startReading(), "Preview opens for real video decoding")
        var frames = 0
        while output.copyNextSampleBuffer() != nil { frames += 1 }
        try SelfTest.require(reader.status == .completed && frames == 60, "Every frame in the preview decodes")
        let thumbnails = try await TimelineThumbnailGenerator.generate(asset: asset, duration: preview.clip.duration)
        try SelfTest.require(thumbnails.count == 8 && thumbnails.allSatisfy { $0.image != nil }, "Real thumbnails load directly from the in-memory composition")
        try SelfTest.require(abs((playback.sourcePosition(100.5) ?? -1) - 0.5) < 0.02 && playback.sourcePosition(99) == nil, "Encoder-clock positions map to the frozen preview")
        let gapped = SpySnapshot(directory: pinned.directory, urls: pinned.urls, requestedSeconds: 1.5, sourceIntervals: [SpySourceInterval(start: 100, end: 101), SpySourceInterval(start: 105, end: 106)])
        let gappedPlayback = try await BufferPlayback.prepare(gapped, levels: AudioLevels())
        try SelfTest.require(abs((gappedPlayback.sourcePosition(100.75) ?? -1) - 0.25) < 0.02 && abs((gappedPlayback.sourcePosition(105.25) ?? -1) - 0.75) < 0.02 && gappedPlayback.sourcePosition(103) == nil, "Marker mapping honors an initially clipped segment and clock gaps")
        print("PASS: metadata-only preview, no pre-exported movie, 60 decoded frames, frozen source gains, composition thumbnails and marker timing")

        await model.previewBuffer()
        try SelfTest.require(model.bufferPreview?.id == preview.id, "Repeated requests cannot replace an open preview")
        try await feed(60..<240)
        try SelfTest.require(model.engine.testStats().frameCount > 60, "Encoder continues receiving frames during preview")
        let afterPruning = try pinned.urls.map { try Data(contentsOf: $0) }
        try SelfTest.require(afterPruning == frozen, "Ring pruning cannot change the preview")
        await model.stop()
        try SelfTest.require(pinned.urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "Stopping replay leaves every preview segment pinned")

        let offline = root.appendingPathComponent("OfflineLibrary")
        try FileManager.default.moveItem(at: model.libraryURL, to: offline)
        var failed = false
        do { _ = try await model.saveBufferPreview(preview) } catch { failed = true }
        try SelfTest.require(failed && model.bufferPreview?.id == preview.id && !model.saving, "Unavailable destination retains the preview for retry")
        try FileManager.default.moveItem(at: offline, to: model.libraryURL)
        model.systemVolume = 0.1; model.microphoneVolume = 0.1; model.separateAudio = false
        let saved = try await model.saveBufferPreview(preview)
        let savedAsset = AVURLAsset(url: saved)
        let savedDuration = try await savedAsset.load(.duration).seconds
        let savedAudio = try await savedAsset.loadTracks(withMediaType: .audio)
        let sourcePackets = try await AudioTests.packetHashes(pinned.urls)
        let savedPackets = try await AudioTests.packetHashes([saved])
        try SelfTest.require(abs(savedDuration - 2) < 0.06 && sourcePackets == savedPackets && savedAudio.count == 2, "Confirmed full save preserves every watched H.264 packet and frozen separate-audio setting")
        let savedSystem = try AudioTests.samples(savedAsset, track: savedAudio[0])
        let savedMic = try AudioTests.samples(savedAsset, track: savedAudio[1])
        try SelfTest.require(abs(AudioTests.magnitude(savedSystem, frequency: 440) - 0.105) < 0.025 && abs(AudioTests.magnitude(savedMic, frequency: 880) - 0.06) < 0.02, "Confirmed export matches frozen preview gains despite later preference changes")
        let duplicate = try await model.saveBufferPreview(preview)
        try SelfTest.require(duplicate == saved && model.clips.count == 1, "Double save does not create duplicates")
        let fragment = try await model.saveBufferPreview(preview, start: 0.4, end: 1.4)
        let fragmentAsset = AVURLAsset(url: fragment)
        let fragmentDuration = try await fragmentAsset.load(.duration).seconds
        let fragmentVideo = try await fragmentAsset.loadTracks(withMediaType: .video)[0]
        let fragmentAudio = try await fragmentAsset.loadTracks(withMediaType: .audio)
        try SelfTest.require(abs(fragmentDuration - 1) < 0.04 && fragmentAudio.count == 2 && model.clips.count == 2, "Selected fragment has exact duration and both audio sources after capture stops")
        let fragmentReader = try AVAssetReader(asset: fragmentAsset)
        let fragmentOutput = AVAssetReaderTrackOutput(track: fragmentVideo, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        fragmentReader.add(fragmentOutput)
        try SelfTest.require(fragmentReader.startReading(), "Selected fragment opens for decoding")
        var fragmentFrames = 0
        while fragmentOutput.copyNextSampleBuffer() != nil { fragmentFrames += 1 }
        try SelfTest.require(fragmentReader.status == .completed && (29...31).contains(fragmentFrames), "Every frame in the selected one-second fragment decodes")
        let fragmentPackets = try await AudioTests.packetHashes([fragment])
        try SelfTest.require(!fragmentPackets.isEmpty && fragmentPackets.isSubset(of: sourcePackets), "Fragment preserves the original compressed H.264 packets")
        let sameFragment = try await model.saveBufferPreview(preview, start: 0.400000001, end: 1.400000001)
        try SelfTest.require(sameFragment == fragment && model.clips.count == 2, "Sub-tick range differences cannot create accidental duplicates")
        for (badStart, badEnd) in [(Double.nan, 1.0), (0.0, Double.infinity), (-0.1, 1.0), (1.5, 1.4), (0.0, 3.0), (0.5, 0.51)] {
            var rejected = false
            do { _ = try await model.saveBufferPreview(preview, start: badStart, end: badEnd) } catch { rejected = true }
            try SelfTest.require(rejected && !model.saving && model.clips.count == 2, "Invalid fragment ranges fail without publishing files")
        }
        let tiny = try PreviewRange(start: 0, end: 1.0 / 60, duration: 1.0 / 60)
        try SelfTest.require(tiny.duration > 0, "A full buffer shorter than the minimum fragment still remains saveable")
        try FileManager.default.copyItem(at: fragment, to: directory.appendingPathComponent("preview-fragment.mov"))
        let afterTrimming = try pinned.urls.map { try Data(contentsOf: $0) }
        try SelfTest.require(afterTrimming == frozen, "Saving selected moments does not modify the full preview")
        print("PASS: exact selected range, both audio sources, decoded frames, original H.264, idempotent ranges, invalid-range guards")
        model.closeBufferPreview()
        try SelfTest.require(model.bufferPreview == nil && !FileManager.default.fileExists(atPath: preview.directory.path) && FileManager.default.fileExists(atPath: saved.path), "Close removes cache while preserving the saved video")
        try FileManager.default.copyItem(at: saved, to: directory.appendingPathComponent("preview-saved.mov"))
        print("PASS: recording continues, pinned segments survive ring rotation/stop, offline retry, frozen video/audio export, no duplicates")

        try await longPreviewFixture(source: saved, directory: directory)

        let discard = AppModel(preview: true)
        defer { try? FileManager.default.removeItem(at: discard.libraryURL.deletingLastPathComponent()) }
        discard.saveBufferOnExit = false
        try discard.engine.beginTest(seconds: 2)
        discard.recording = true
        for frame in 0..<30 {
            discard.engine.testFrame(try SelfTest.pixel(frame: frame), at: CMTime(value: 6000 + Int64(frame), timescale: 30))
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        discard.stats = discard.engine.testStats()
        await discard.previewBuffer()
        guard let unsaved = discard.bufferPreview else { throw SpyError.message("TEST FAILED: Silent preview") }
        discard.closeBufferPreview()
        try SelfTest.require(discard.clips.isEmpty && !FileManager.default.fileExists(atPath: unsaved.directory.path), "Closing without saving leaves the library empty and removes the temporary movie")
        await discard.previewBuffer()
        guard let pending = discard.bufferPreview else { throw SpyError.message("TEST FAILED: Reopen preview") }
        await discard.shutdown()
        try SelfTest.require(discard.bufferPreview == nil && !FileManager.default.fileExists(atPath: pending.directory.path) && discard.clips.isEmpty, "Quit cleans the open preview without silently saving it")

        let empty = AppModel(preview: true)
        defer { try? FileManager.default.removeItem(at: empty.libraryURL.deletingLastPathComponent()) }
        try empty.engine.beginTest(seconds: 2)
        empty.recording = true; empty.stats.frameCount = 1
        await empty.previewBuffer()
        let leftovers = try FileManager.default.contentsOfDirectory(at: empty.cacheURL, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("preview-") || $0.lastPathComponent.hasPrefix("save-") }
        try SelfTest.require(empty.bufferPreview == nil && empty.error != nil && !empty.saving && !empty.preparingBufferPreview && leftovers.isEmpty, "Empty buffer reports a recoverable error and leaves no temporary exports")
        await empty.stop()
        try await refreshedSnapshots(directory: directory.appendingPathComponent("explicit-refresh"))
        print("PASS: discard and quit cleanup, silent preview, empty-buffer error with no orphaned exports")
    }

    private static func refreshedSnapshots(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = AppModel(preview: true)
        let root = model.libraryURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        model.saveBufferOnExit = false; model.notificationsEnabled = false
        model.minutes = 0.5; model.systemVolume = 0.7; model.microphoneVolume = 0.3
        try model.engine.beginTest(seconds: 30, audio: true, microphone: true)
        model.recording = true
        func feed(_ frames: Range<Int>) async throws {
            for frame in frames {
                let pts = CMTime(value: 12_000 + Int64(frame), timescale: 30)
                model.engine.testFrame(try SelfTest.pixel(frame: frame), at: pts)
                model.engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, frequency: 440))
                model.engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, frequency: 997), microphone: true)
                try await Task.sleep(nanoseconds: 8_000_000)
            }
            model.stats = model.engine.testStats()
        }
        try await feed(0..<60)
        await model.previewBuffer()
        guard let original = model.bufferPreview, let originalSnapshot = original.snapshot else {
            throw SpyError.message("TEST FAILED: Initial refresh fixture preview missing")
        }
        let originalData = try originalSnapshot.urls.map { try Data(contentsOf: $0) }
        let originalDecoded = try await decodedPreview(asset: original.asset)
        let savedBeforeRefresh = try await model.saveBufferPreview(original, start: 0.2, end: 1.2, microphoneEnabled: false)
        try await feed(60..<120)
        await model.openBufferPreview()
        let stillFrozen = try await decodedPreview(asset: original.asset)
        try SelfTest.require(model.bufferPreview?.id == original.id && originalDecoded.frames == 60 &&
            stillFrozen.frames == 60 && stillFrozen.lastRed == originalDecoded.lastRed,
            "Capture activity and reopening the window cannot silently change the selected frozen video")
        let unchangedPins = try originalSnapshot.urls.map { try Data(contentsOf: $0) }
        try SelfTest.require(unchangedPins == originalData, "New capture frames never overwrite a frozen preview's pinned sources")

        let refreshed = try await model.refreshBufferPreview(original, microphoneEnabled: false)
        guard let refreshedSnapshot = refreshed.snapshot else { throw SpyError.message("TEST FAILED: Refreshed snapshot missing") }
        let newDecoded = try await decodedPreview(asset: refreshed.asset)
        try SelfTest.require(refreshed.id != original.id && abs(refreshed.clip.duration - 4) < 0.06 &&
            newDecoded.frames == 120 && newDecoded.lastRed >= originalDecoded.lastRed + 30,
            "Explicit refresh includes the subsequently encoded frames and replaces the old playback only after preparation")
        try SelfTest.require(!refreshed.initialMicrophoneEnabled && refreshed.savedRanges.isEmpty && refreshed.mutedSavedRanges.isEmpty,
            "Refresh carries the microphone choice while starting a distinct range/save identity")
        try SelfTest.require(!FileManager.default.fileExists(atPath: original.directory.path) &&
            FileManager.default.fileExists(atPath: savedBeforeRefresh.path) &&
            refreshedSnapshot.urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
            "Successful replacement releases only old cache pins and preserves previously published videos")
        let refreshedPins = try refreshedSnapshot.urls.map { try Data(contentsOf: $0) }
        var rejected = false
        do { _ = try await model.refreshBufferPreview(original) } catch { rejected = true }
        try SelfTest.require(rejected && model.bufferPreview?.id == refreshed.id, "An obsolete refresh request cannot replace a newer preview")

        let offline = root.appendingPathComponent("OfflineRefreshLibrary")
        try FileManager.default.moveItem(at: model.libraryURL, to: offline)
        rejected = false
        do { _ = try await model.refreshBufferPreview(refreshed) } catch { rejected = true }
        try SelfTest.require(rejected && model.bufferPreview?.id == refreshed.id && !model.saving,
            "An offline save destination cannot discard the current ready preview")
        try FileManager.default.moveItem(at: offline, to: model.libraryURL)
        model.manualPrivacyPause = true
        model.engine.requestPrivacyBlock(true)
        try await model.engine.pauseForPrivacy()
        model.privacyPaused = true
        rejected = false
        do { _ = try await model.refreshBufferPreview(refreshed) } catch { rejected = true }
        try SelfTest.require(rejected && model.bufferPreview?.id == refreshed.id && !model.saving,
            "Privacy-paused capture keeps the previous snapshot and blocks refresh")
        model.manualPrivacyPause = false
        model.engine.requestPrivacyBlock(false)
        try await model.engine.resumeAfterPrivacy(excluding: [])
        model.privacyPaused = false

        // Simulate the narrow interval after a stream ends but before its model
        // callback arrives. This reaches a real snapshot error after the guards.
        await model.engine.stop()
        model.recording = true; model.stats.frameCount = 1
        let foldersBefore = try previewDirectories(model.cacheURL)
        rejected = false
        do { _ = try await model.refreshBufferPreview(refreshed) } catch { rejected = true }
        let foldersAfter = try previewDirectories(model.cacheURL)
        let afterFailure = try refreshedSnapshot.urls.map { try Data(contentsOf: $0) }
        try SelfTest.require(rejected && model.bufferPreview?.id == refreshed.id && afterFailure == refreshedPins &&
            foldersBefore == foldersAfter && !model.saving && !model.preparingBufferPreview,
            "A real preparation failure keeps all prior pins byte-for-byte and leaves no partial refresh or stuck operation")
        await model.stop()
        rejected = false
        do { _ = try await model.refreshBufferPreview(refreshed) } catch { rejected = true }
        try SelfTest.require(rejected && model.bufferPreview?.id == refreshed.id,
            "Stopping capture does not remove the old preview and cannot refresh it")
        let muted = try await model.saveBufferPreview(refreshed, start: 0.2, end: 1.2, microphoneEnabled: false)
        let mutedAgain = try await model.saveBufferPreview(refreshed, start: 0.2, end: 1.2, microphoneEnabled: false)
        try SelfTest.require(muted != savedBeforeRefresh && mutedAgain == muted,
            "A refreshed preview has independent idempotent muted saves while old published selections remain available")
        model.closeBufferPreview()
        print("PASS: frozen cutoff excludes later activity, explicit refresh decodes new frames, atomic pin replacement, microphone choice and old saves preserved; offline/privacy/stopped/preparation failures keep the ready snapshot")
    }

    private static func decodedPreview(asset: AVAsset) async throws -> (frames: Int, lastRed: Int) {
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw SpyError.message("TEST FAILED: Preview has no video")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        try SelfTest.require(reader.startReading(), "Frozen/refreshed preview opens for real decoding")
        var frames = 0, lastRed = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let pixel = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            lastRed = Int(CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)[2])
            CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
            frames += 1
        }
        try SelfTest.require(reader.status == .completed, "Every frozen/refreshed frame decodes")
        return (frames, lastRed)
    }

    private static func previewDirectories(_ root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent).filter { $0.hasPrefix("preview-") || $0.hasPrefix("save-") }.sorted()
    }

    private static func mixedSamples(asset: AVAsset, mix: AVAudioMix?) async throws -> [Float] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        output.audioMix = mix
        reader.add(output)
        try SelfTest.require(reader.startReading(), "Composition mix opens for decoding")
        var values: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var data = Data(count: CMBlockBufferGetDataLength(block))
            let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            try SelfTest.require(status == noErr, "Mixed playback PCM is readable")
            data.withUnsafeBytes { buffer in
                let floats = buffer.bindMemory(to: Float.self)
                for index in stride(from: 0, to: floats.count, by: 2) { values.append(floats[index]) }
            }
        }
        try SelfTest.require(reader.status == .completed, "Composition mix completely decodes")
        return values
    }

    private static func longPreviewFixture(source: URL, directory: URL) async throws {
        let input = AVURLAsset(url: source)
        let sourceVideo = try await input.loadTracks(withMediaType: .video)[0]
        let sourceRange = try await sourceVideo.load(.timeRange)
        let composition = AVMutableComposition()
        let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let oneSecond = CMTimeRange(start: sourceRange.start, duration: CMTimeMinimum(sourceRange.duration, CMTime(seconds: 1, preferredTimescale: 600)))
        var cursor = CMTime.zero
        while cursor.seconds < 1800 - 0.001 {
            try video.insertTimeRange(oneSecond, of: sourceVideo, at: cursor)
            cursor = cursor + oneSecond.duration
        }
        let movie = directory.appendingPathComponent("long-preview-source.mov")
        let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        exporter.outputURL = movie; exporter.outputFileType = .mov
        await exporter.export()
        try SelfTest.require(exporter.status == .completed, "Thirty-minute compressed fixture exports without re-encoding")
        let started = Date()
        let snapshot = SpySnapshot(directory: directory, urls: [movie], requestedSeconds: 1800, sourceIntervals: [SpySourceInterval(start: 100, end: 1900)])
        let before = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count
        let preview = try await BufferPlayback.prepare(snapshot, levels: AudioLevels())
        let elapsed = Date().timeIntervalSince(started)
        let after = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count
        try SelfTest.require(abs(preview.duration - 1800) < 0.04 && before == after && elapsed < 8, "Thirty-minute preview prepares from headers promptly without producing another movie")
        let frames = try await TimelineThumbnailGenerator.generate(asset: preview.asset, duration: preview.duration)
        try SelfTest.require(frames.count == 8 && frames.allSatisfy { $0.image != nil }, "Long composition supports direct random-access thumbnails")
        print(String(format: "PASS: 30-minute preview prepared in %.3f s without video/audio rendering", elapsed))

        // Match the real ring layout: 360 independently addressed five-second
        // MOVs, pinned via hard links. This exercises metadata loading and edit
        // list construction across every segment instead of a single long file.
        let template = directory.appendingPathComponent("segment-template-5.mov")
        try await ClipTrimmer.export(source: movie, start: 0, end: 5, to: template)
        let templateDuration = try await AVURLAsset(url: template).load(.duration).seconds
        try SelfTest.require(abs(templateDuration - 5) < 0.001, "Ring benchmark fixture has exact five-second segments")
        let ring = directory.appendingPathComponent("long-preview-ring", isDirectory: true)
        try FileManager.default.createDirectory(at: ring, withIntermediateDirectories: true)
        var urls: [URL] = []
        var intervals: [SpySourceInterval] = []
        for index in 0..<360 {
            let start = 100 + Double(index) * 5
            let url = ring.appendingPathComponent(String(format: "%020lld.mov", Int64(start * 1_000_000)))
            try FileManager.default.linkItem(at: template, to: url)
            urls.append(url)
            intervals.append(SpySourceInterval(start: start, end: start + 5))
        }
        let ringSnapshot = SpySnapshot(directory: ring, urls: urls, requestedSeconds: 1800, sourceIntervals: intervals)
        let filesBefore = try FileManager.default.contentsOfDirectory(at: ring, includingPropertiesForKeys: nil).map(\.lastPathComponent).sorted()
        let ringStarted = Date()
        let ringPlayback = try await BufferPlayback.prepare(ringSnapshot, levels: AudioLevels())
        let ringElapsed = Date().timeIntervalSince(ringStarted)
        let filesAfter = try FileManager.default.contentsOfDirectory(at: ring, includingPropertiesForKeys: nil).map(\.lastPathComponent).sorted()
        try SelfTest.require(abs(ringPlayback.duration - 1800) < 0.04 && ringPlayback.sourceURLs.count == 360 && filesBefore == filesAfter && ringElapsed < 8, "Realistic 360-segment thirty-minute preview opens promptly with no exported movie")
        try SelfTest.require(abs((ringPlayback.sourcePosition(1899.5) ?? -1) - 1799.5) < 0.001, "Source marker timing reaches the final segment of the thirty-minute ring")
        let ringFrames = try await TimelineThumbnailGenerator.generate(asset: ringPlayback.asset, duration: ringPlayback.duration)
        try SelfTest.require(ringFrames.count == 8 && ringFrames.allSatisfy { $0.image != nil }, "All eight random-access thumbnails decode across the 360-segment composition")
        print(String(format: "PASS: realistic 30-minute/360-segment preview prepared in %.3f s with no export; eight thumbnails decode", ringElapsed))
    }
}
