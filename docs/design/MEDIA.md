# Media: Finch's audio and video stack

Apple keeps its media frameworks closed, so Finch writes its own, bottom up, each
checked against Apple's with a comparison test (`tools/host-tests.sh`) before the next
is built on it.

```
AVKit                          playback views
AVFoundation                   assets, players, readers and writers, capture, metadata
AVFAudio                       formats, buffers, files, players, the engine graph, units, speech
VideoToolbox                   decode, encode, pixel transfer
AudioToolbox / AudioUnit       formats, files, converters, queues, audio units
CoreMedia / CoreVideo          times, buffers, format descriptions, pixel buffers  (done)
CoreAudio (HAL)                devices: none until Finch has an audio driver
```

## What's done

- CoreVideo: pixel buffers laid out byte for byte as Apple's, pools, attachments, the
  pixel format table, color spaces from 'nclc' profiles.
- CoreMedia: times, block buffers, format descriptions (and from H.264/HEVC parameter
  sets, and to and from QuickTime/ISO image descriptions), sample buffers, clocks and
  timebases, queues, memory pools, metadata, tags.

- AudioToolbox: format properties and audio files (WAVE, AIFF/AIFC, CAF and
  NeXT/Sun). `AudioConverter` handles packed and unpacked integer PCM, float
  PCM, both byte orders, planar channels, channel maps and G.711 A-law/mu-law.
  Callback conversion can change sample rates with Finch's own filter. Output
  is stable across callback chunk sizes and resets; filtering passes DC, tone
  and alias-rejection checks. Its samples are not bit-for-bit copies of Apple's
  filter, and fractional-duration output may differ by one frame.
  The converter also supports dithering, buffer-size queries and preallocated
  PCM callback conversion. Its 76-line host comparison passes (2026-10-11),
  including all 65,536 signed 16-bit values through both G.711 encoders and all
  256 codes through both decoders. The test also passes in QEMU. Compressed
  audio conversion, minimum-phase filtering and the remaining codec properties
  are open. Unsupported minimum-phase requests return an error.
- `ExtAudioFile` reads and writes PCM and G.711 files, converts client PCM,
  seeks and flushes buffered sample-rate conversion when a file closes. The
  default host comparison passes in 59 lines; separate rate checks cover final
  samples, resets, chunk stability, bounds and errors. Both pass in QEMU.
- Software `AudioUnit` components provide callback-driven PCM conversion and
  multichannel mixing, with volume, pan and input enable controls. Tests cover
  integer/float inputs, changing sample rates, timestamps across render calls,
  resets and malformed callbacks. The host and QEMU runs pass. Default and
  System Output components report no connection; Finch has no audio device.
  Generic Output and the remaining unit properties are not implemented yet.
- Effect, time and instrument units under Apple's component descriptions:
  AUDelay, AUDistortion, AUNBandEQ, AUMatrixReverb, AUReverb2, the lowpass,
  highpass, bandpass, shelf and parametric filters, AUPeakLimiter,
  AUDynamicsProcessor, AUSampleDelay, AUNewTimePitch, AUNewPitch, AUVarispeed
  and AUSampler (sine voices or loaded audio files, played over MIDI). Their
  parameters, ranges and factory presets are Apple's, taken as data
  (`tools/audiotoolbox/gen-effect-tables.sh`); the signal processing is Finch's
  own (`AudioUnitEffects.c`) and is not a sample-for-sample copy. The comparison
  test checks what the units describe, and what they do in coarse terms: a filter
  cuts, a band gains 12 dB, a delay lands on its frame, time-pitch keeps the pitch
  at twice the rate. Sound banks (SF2/DLS), `.aupreset` instruments and saved unit
  state (`ClassInfo`) are open.
- `AudioQueue` owns PCM buffers and renders queued audio into memory through
  `AudioConverter`. Completed buffers can be queued again by the callback.
  Offline output requires interleaved PCM with the same rate and channel count;
  sample encoding can change. Input queues manage buffers but do not record.
  Starting either queue reports no device. Parameters, processing taps and
  dispatch-queue callbacks remain open. The focused host check covers partial
  reads, callback requeueing, ownership, reset and timeline state; it also passes
  with address and undefined-behavior checks enabled.
- AVFAudio now has format, channel-layout and PCM-buffer objects, including
  typed sample access, copies, caller-owned storage and secure archives.
  Ordinary paths match Apple's in the host test. Finch deliberately rejects
  truncated layouts and undersized PCM frames rather than accepting unsafe
  storage. `AVAudioFile` now reads and writes PCM/G.711 through ExtAudioFile,
  with seeking, short reads and format checks. `AVAudioConverter` wraps the
  software converter for PCM/G.711, including sample-rate conversion and reset.
  Both new checks match Apple's output on the host, in QEMU and in the VZ
  guest (2026-10-11). The engine graph (players, the mixer, source and sink
  nodes, taps, offline rendering), `AVAudioPlayer`, the session, speech timing
  and `AVAudioUnit` with every named unit (delay, distortion, EQ, reverb,
  time-pitch, varispeed, sampler) followed; `avaudio-unit-test` matches Apple's
  output, as do unit components and their manager. `AUAudioUnit` (the version 3
  interface), the environment node (3D mixing), the sequencer and MIDI player,
  the recorder and compressed buffers remain open, parked behind AVFoundation.

- CoreMedia's sound descriptions: audio format descriptions to and from QuickTime
  version 0, 1 and 2 sound descriptions and ISO audio sample entries, byte for byte as
  Apple's writes them (`sounddesc-test`), with each description keeping its original to
  write back verbatim.
- AVFoundation's first stage: Finch's own QuickTime/ISO reader (`AVFMovie.m`) under
  AVAsset, AVURLAsset, AVAssetTrack, AVAssetTrackSegment and AVMetadataItem. The test
  writes its own movie (JPEG frames and PCM audio with user data) so both systems read
  the same bytes, and the assets, tracks, format descriptions, metadata, loading and
  errors match Apple's (`avasset-test`, 2026-10-12).
- AVFoundation's second stage: AVAssetReader gives stored samples with the marker buffers
  Apple's does (EditBoundary, ResetDecoderBeforeDecoding, DrainAfterDecoding,
  PostNotificationWhenConsumed, EmptyMedia), JPEG frames decoded through ImageIO and PCM
  converted by AudioToolbox in 8192-frame buffers; AVAssetWriter writes QuickTime and
  MPEG-4 with Finch's own muxer (JPEG through ImageIO, PCM, stored samples, metadata);
  AVAssetImageGenerator picks the frame on screen at a time. `avreader-test`,
  `avwriter-test` and `avimage-test` match Apple's, and Apple's AVFoundation reads what
  Finch writes.
- Playback: AVPlayer, AVPlayerItem, AVQueuePlayer, AVPlayerLooper, AVPlayerItemVideoOutput
  and AVPlayerLayer, driven by the host clock and a 60 Hz main-thread timer (status and
  timeControlStatus as Apple's, seeks, time observers, the end notification); the layer
  shows decoded frames as its contents, so they reach the window server like any layer.
  `avplayer-test` matches Apple's; `appkit-avplayer-test` checks the screen. Audio waits
  for a device; H.264, HEVC and AAC for VideoToolbox and AudioToolbox.

The converter, extended-file, software-unit, queue and AVFAudio buffer checks
pass on the host, in QEMU and in the VZ guest (2026-10-11). These checks exercise
audio stored in memory and files; hardware playback and recording remain open.

## The order from here

1. **AudioToolbox**: `AudioFormat` properties (format info, channel layouts and their
   names) and `AudioFile` are started as described above. Remaining file work includes
   MP3 and MPEG-4 audio reads. Finish compressed `AudioConverter` formats and the remaining properties,
   then the remaining `ExtAudioFile`, `AudioUnit` and `AudioQueue` operations.
   Offline rendering can work without a device. Hardware playback and recording
   must report that no device is available until the driver exists.
2. **AVFAudio** files, players and engine operations over AudioToolbox.
3. **VideoToolbox**: pixel transfer (Finch's own conversion and scaling), then decoding
   and encoding through open codecs.
4. **AVFoundation**: Finch's own MP4/QuickTime reader and writer behind assets, readers
   and writers; players driven by CoreMedia timebases; capture with no devices.
5. **AVKit**.

## Codecs

Finch's own code does containers and PCM. Compressed formats come from open libraries,
dynamically linked where their licence asks for it (see `docs/LICENSING.md`):
H.264 (openh264, BSD-2), AV1 (dav1d, BSD-2), VP8/VP9 (libvpx, BSD-3), Opus, Vorbis and
FLAC (BSD), MP3 (minimp3, CC0); HEVC and AAC from LGPL decoders, linked dynamically.
Each is pinned to an exact release.

## 2026-10-15: CoreVideo and CoreMedia C APIs

CoreVideo now formats printable FourCC values and uses decimal text for control
codes. CoreMedia now builds summary PCM descriptions and reads text display flags,
justification, boxes, styles and font names from format extensions. The CoreVideo
and CoreMedia comparison tests match Apple's. The API audits report 270 of 302
CoreVideo declarations and 717 of 738 CoreMedia declarations exported. Remaining
CoreVideo gaps are OpenGL and Metal buffer APIs; CoreMedia still lacks multiview
HEVC tag extraction and the specialized big-endian text, timecode, metadata and
closed-caption bridge functions.

## 2026-10-15: AudioToolbox C API follow-up

AudioToolbox now creates built-in components through its asynchronous API, reports unit
property changes, and calls render notifications around each render. `AudioConverterPrepare`
builds and keeps a filter table for the common 44.1-to-48 kHz float PCM conversion; later
converters reuse it. AudioFile global queries now report supported file types, their names,
and their extensions. The comparison tests cover these calls and match Apple's. The audit
now reports 127 of 365 public functions and variables exported, up from 119.

The remaining gaps include audio-device services Finch cannot provide yet, old component
and graph APIs, codec plug-ins, and MIDI sequence/player support. The MIDI APIs need a real
track, event, tempo and playback model; Finch does not have that model yet, so those calls
remain absent rather than returning pretend success. MP3 and MPEG-4 audio reading also
waits for the open decoders listed above.
