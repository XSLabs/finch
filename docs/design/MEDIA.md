# Media: Finch's audio and video stack

Apple keeps its media frameworks closed, so Finch writes its own, bottom up, each
checked against Apple's with a comparison test (`tools/host-tests.sh`) before the next
is built on it.

```
AVKit                          playback views
AVFoundation                   assets, players, readers and writers, capture, metadata
AVFAudio                       formats, buffers, files, players, the engine graph, speech
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

## The order from here

1. **AudioToolbox**: `AudioFormat` properties (format info, channel layouts and their
   names), `AudioFile` (WAV, AIFF/AIFC, CAF read and write, laid out as Apple's writes
   them; MP3 and MPEG-4 audio read), `AudioConverter` (PCM to PCM: sample formats,
   interleaving, channel maps, sample rates; codecs as they come), `ExtAudioFile`,
   `AudioComponent`/`AudioUnit` (the output, converter and mixer units), `AudioQueue`.
   With no audio devices yet, output units and queues run against a silent clock.
2. **AVFAudio** over AudioToolbox.
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
