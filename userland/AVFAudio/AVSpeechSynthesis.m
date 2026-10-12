/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Speech synthesis, Finch's. Finch has no voices yet (a speech engine is to come), so
 * the list of voices is empty; a synthesizer still works through each utterance at
 * speaking pace, word by word, telling its delegate (on the main thread) as Apple's
 * does, without making a sound. Writing an utterance to buffers gives the empty buffer
 * that ends one.
 */
#import <AVFAudio/AVFAudio.h>
#include <dispatch/dispatch.h>
#import <objc/message.h>

/* --- voices (none yet) --- */

@implementation AVSpeechSynthesisVoice

+ (NSArray<AVSpeechSynthesisVoice *> *)speechVoices
{
    return @[];
}

+ (NSString *)currentLanguageCode
{
    NSString *l = [NSLocale preferredLanguages].firstObject ?: @"en-US";
    return [l stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
}

+ (AVSpeechSynthesisVoice *)voiceWithLanguage:(NSString *)languageCode
{
    return nil;
}

+ (AVSpeechSynthesisVoice *)voiceWithIdentifier:(NSString *)identifier
{
    return nil;
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    [self release];
    return nil;
}

- (NSString *)language { return @""; }
- (NSString *)identifier { return @""; }
- (NSString *)name { return @""; }
- (AVSpeechSynthesisVoiceQuality)quality { return AVSpeechSynthesisVoiceQualityDefault; }
- (AVSpeechSynthesisVoiceGender)gender { return AVSpeechSynthesisVoiceGenderUnspecified; }
- (NSDictionary *)audioFileSettings { return @{}; }
- (AVSpeechSynthesisVoiceTraits)voiceTraits { return AVSpeechSynthesisVoiceTraitNone; }

@end

/* --- utterances --- */

@implementation AVSpeechUtterance {
    NSAttributedString *_string;
    AVSpeechSynthesisVoice *_voice;
    float _rate, _pitch, _volume;
    BOOL _assistive;
    NSTimeInterval _pre, _post;
}

+ (instancetype)speechUtteranceWithString:(NSString *)string
{
    return [[[self alloc] initWithString:string] autorelease];
}

+ (instancetype)speechUtteranceWithAttributedString:(NSAttributedString *)string
{
    return [[[self alloc] initWithAttributedString:string] autorelease];
}

+ (instancetype)speechUtteranceWithSSMLRepresentation:(NSString *)string
{
    return [[[self alloc] initWithSSMLRepresentation:string] autorelease];
}

- (instancetype)initWithAttributedString:(NSAttributedString *)string
{
    if ((self = [super init])) {
        _string = [string copy] ?: [[NSAttributedString alloc] initWithString:@""];
        _rate = AVSpeechUtteranceDefaultSpeechRate;
        _pitch = 1;
        _volume = 1;
    }
    return self;
}

- (instancetype)initWithString:(NSString *)string
{
    NSAttributedString *a = [[[NSAttributedString alloc] initWithString:string ?: @""] autorelease];
    return [self initWithAttributedString:a];
}

/* (the SSML's text, its tags left out; nil if it isn't SSML) */
- (instancetype)initWithSSMLRepresentation:(NSString *)string
{
    NSString *trimmed = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![trimmed hasPrefix:@"<"] || [trimmed rangeOfString:@"<speak"].location == NSNotFound) {
        [self release];
        return nil;
    }
    NSRegularExpression *tags = [NSRegularExpression regularExpressionWithPattern:@"<[^>]*>" options:0 error:nil];
    NSString *text = [tags stringByReplacingMatchesInString:trimmed options:0 range:NSMakeRange(0, trimmed.length) withTemplate:@""];
    text = [text stringByReplacingOccurrencesOfString:@"&lt;" withString:@"<"];
    text = [text stringByReplacingOccurrencesOfString:@"&gt;" withString:@">"];
    text = [text stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    return [self initWithString:[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
}

- (void)dealloc
{
    [_string release];
    [_voice release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    AVSpeechUtterance *u = [[AVSpeechUtterance alloc] initWithAttributedString:_string];
    u.voice = _voice;
    u->_rate = _rate, u->_pitch = _pitch, u->_volume = _volume, u->_assistive = _assistive, u->_pre = _pre, u->_post = _post;
    return u;
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_string forKey:@"AVSpeechUtteranceAttributedString"];
    [coder encodeFloat:_rate forKey:@"AVSpeechUtteranceRate"];
    [coder encodeFloat:_pitch forKey:@"AVSpeechUtterancePitch"];
    [coder encodeFloat:_volume forKey:@"AVSpeechUtteranceVolume"];
    [coder encodeDouble:_pre forKey:@"AVSpeechUtterancePreDelay"];
    [coder encodeDouble:_post forKey:@"AVSpeechUtterancePostDelay"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSAttributedString *s = [coder decodeObjectOfClass:[NSAttributedString class] forKey:@"AVSpeechUtteranceAttributedString"];
    if ((self = [self initWithAttributedString:s])) {
        _rate = [coder decodeFloatForKey:@"AVSpeechUtteranceRate"];
        _pitch = [coder decodeFloatForKey:@"AVSpeechUtterancePitch"];
        _volume = [coder decodeFloatForKey:@"AVSpeechUtteranceVolume"];
        _pre = [coder decodeDoubleForKey:@"AVSpeechUtterancePreDelay"];
        _post = [coder decodeDoubleForKey:@"AVSpeechUtterancePostDelay"];
    }
    return self;
}

- (AVSpeechSynthesisVoice *)voice { return _voice; }
- (void)setVoice:(AVSpeechSynthesisVoice *)v { [_voice autorelease]; _voice = [v retain]; }
- (NSString *)speechString { return _string.string; }
- (NSAttributedString *)attributedSpeechString { return _string; }
- (float)rate { return _rate; }
- (void)setRate:(float)v { _rate = v < AVSpeechUtteranceMinimumSpeechRate ? AVSpeechUtteranceMinimumSpeechRate : v > AVSpeechUtteranceMaximumSpeechRate ? AVSpeechUtteranceMaximumSpeechRate : v; }
- (float)pitchMultiplier { return _pitch; }
- (void)setPitchMultiplier:(float)v { _pitch = v < 0.5f ? 0.5f : v > 2 ? 2 : v; }
- (float)volume { return _volume; }
- (void)setVolume:(float)v { _volume = v < 0 ? 0 : v > 1 ? 1 : v; }
- (BOOL)prefersAssistiveTechnologySettings { return _assistive; }
- (void)setPrefersAssistiveTechnologySettings:(BOOL)v { _assistive = v; }
- (NSTimeInterval)preUtteranceDelay { return _pre; }
- (void)setPreUtteranceDelay:(NSTimeInterval)v { _pre = v; }
- (NSTimeInterval)postUtteranceDelay { return _post; }
- (void)setPostUtteranceDelay:(NSTimeInterval)v { _post = v; }

@end

/* --- markers --- */

@implementation AVSpeechSynthesisMarker {
    AVSpeechSynthesisMarkerMark _mark;
    NSUInteger _offset;
    NSRange _range;
    NSString *_bookmark, *_phoneme;
}

- (instancetype)initWithMarkerType:(AVSpeechSynthesisMarkerMark)type forTextRange:(NSRange)range atByteSampleOffset:(NSUInteger)byteSampleOffset
{
    if ((self = [super init])) {
        _mark = type;
        _range = range;
        _offset = byteSampleOffset;
    }
    return self;
}

- (instancetype)initWithWordRange:(NSRange)range atByteSampleOffset:(NSInteger)o
{
    return [self initWithMarkerType:AVSpeechSynthesisMarkerMarkWord forTextRange:range atByteSampleOffset:(NSUInteger)o];
}

- (instancetype)initWithSentenceRange:(NSRange)range atByteSampleOffset:(NSInteger)o
{
    return [self initWithMarkerType:AVSpeechSynthesisMarkerMarkSentence forTextRange:range atByteSampleOffset:(NSUInteger)o];
}

- (instancetype)initWithParagraphRange:(NSRange)range atByteSampleOffset:(NSInteger)o
{
    return [self initWithMarkerType:AVSpeechSynthesisMarkerMarkParagraph forTextRange:range atByteSampleOffset:(NSUInteger)o];
}

- (instancetype)initWithPhonemeString:(NSString *)phoneme atByteSampleOffset:(NSInteger)o
{
    if ((self = [self initWithMarkerType:AVSpeechSynthesisMarkerMarkPhoneme forTextRange:NSMakeRange(0, 0) atByteSampleOffset:(NSUInteger)o]))
        _phoneme = [phoneme copy];
    return self;
}

- (instancetype)initWithBookmarkName:(NSString *)mark atByteSampleOffset:(NSInteger)o
{
    if ((self = [self initWithMarkerType:AVSpeechSynthesisMarkerMarkBookmark forTextRange:NSMakeRange(0, 0) atByteSampleOffset:(NSUInteger)o]))
        _bookmark = [mark copy];
    return self;
}

- (void)dealloc
{
    [_bookmark release];
    [_phoneme release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    AVSpeechSynthesisMarker *m = [[AVSpeechSynthesisMarker alloc] initWithMarkerType:_mark forTextRange:_range atByteSampleOffset:_offset];
    m.bookmarkName = _bookmark;
    m.phoneme = _phoneme;
    return m;
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInteger:_mark forKey:@"mark"];
    [coder encodeInteger:(NSInteger)_offset forKey:@"byteSampleOffset"];
    [coder encodeInteger:(NSInteger)_range.location forKey:@"location"];
    [coder encodeInteger:(NSInteger)_range.length forKey:@"length"];
    [coder encodeObject:_bookmark forKey:@"bookmarkName"];
    [coder encodeObject:_phoneme forKey:@"phoneme"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSRange r = NSMakeRange((NSUInteger)[coder decodeIntegerForKey:@"location"], (NSUInteger)[coder decodeIntegerForKey:@"length"]);
    if ((self = [self initWithMarkerType:[coder decodeIntegerForKey:@"mark"] forTextRange:r
                      atByteSampleOffset:(NSUInteger)[coder decodeIntegerForKey:@"byteSampleOffset"]])) {
        _bookmark = [[coder decodeObjectOfClass:[NSString class] forKey:@"bookmarkName"] copy];
        _phoneme = [[coder decodeObjectOfClass:[NSString class] forKey:@"phoneme"] copy];
    }
    return self;
}

- (AVSpeechSynthesisMarkerMark)mark { return _mark; }
- (void)setMark:(AVSpeechSynthesisMarkerMark)v { _mark = v; }
- (NSUInteger)byteSampleOffset { return _offset; }
- (void)setByteSampleOffset:(NSUInteger)v { _offset = v; }
- (NSRange)textRange { return _range; }
- (void)setTextRange:(NSRange)v { _range = v; }
- (NSString *)bookmarkName { return _bookmark; }
- (void)setBookmarkName:(NSString *)v { [_bookmark autorelease]; _bookmark = [v copy]; }
- (NSString *)phoneme { return _phoneme; }
- (void)setPhoneme:(NSString *)v { [_phoneme autorelease]; _phoneme = [v copy]; }

@end

/* --- the synthesizer --- */

@implementation AVSpeechSynthesizer {
    __unsafe_unretained id<AVSpeechSynthesizerDelegate> _delegate;
    NSMutableArray *_queue;
    AVSpeechUtterance *_current;
    NSArray *_words; /* (NSValue ranges of the current utterance's words) */
    NSUInteger _next;
    BOOL _paused, _pauseAtWord, _stopAtWord;
    NSArray *_channels;
    BOOL _usesSession, _uplink;
    NSUInteger _generation;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _queue = [NSMutableArray new];
        _usesSession = YES;
    }
    return self;
}

- (void)dealloc
{
    [_queue release];
    [_current release];
    [_words release];
    [_channels release];
    [super dealloc];
}

- (id<AVSpeechSynthesizerDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<AVSpeechSynthesizerDelegate>)d { _delegate = d; }
- (BOOL)isSpeaking { return _current != nil || _queue.count; }
- (BOOL)isPaused { return _paused; }
- (NSArray *)outputChannels { return _channels; }
- (void)setOutputChannels:(NSArray *)c { [_channels autorelease]; _channels = [c copy]; }
- (BOOL)usesApplicationAudioSession { return _usesSession; }
- (void)setUsesApplicationAudioSession:(BOOL)v { _usesSession = v; }
- (BOOL)mixToTelephonyUplink { return _uplink; }
- (void)setMixToTelephonyUplink:(BOOL)v { _uplink = v; }

+ (AVSpeechSynthesisPersonalVoiceAuthorizationStatus)personalVoiceAuthorizationStatus
{
    return AVSpeechSynthesisPersonalVoiceAuthorizationStatusUnsupported;
}

+ (void)requestPersonalVoiceAuthorizationWithCompletionHandler:(void (^)(AVSpeechSynthesisPersonalVoiceAuthorizationStatus))handler
{
    if (handler) {
        void (^h)(AVSpeechSynthesisPersonalVoiceAuthorizationStatus) = [[handler copy] autorelease];
        dispatch_async(dispatch_get_main_queue(), ^{
          h(AVSpeechSynthesisPersonalVoiceAuthorizationStatusUnsupported);
        });
    }
}

/* How long a word takes at the utterance's rate (about 180 words a minute at the default). */
static NSTimeInterval
word_time(AVSpeechUtterance *u)
{
    double pace = 0.5 + u.rate * 1.5 / AVSpeechUtteranceMaximumSpeechRate;
    return 60.0 / (180.0 * (pace > 0.1 ? pace : 0.1));
}

static NSArray *
words_of(NSString *s)
{
    NSMutableArray *a = [NSMutableArray array];
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByWords
                       usingBlock:^(NSString *word, NSRange range, NSRange enclosing, BOOL *stop) {
                         [a addObject:[NSValue valueWithRange:range]];
                       }];
    return a;
}

- (void)_after:(NSTimeInterval)delay do:(void (^)(void))block
{
    NSUInteger generation = _generation;
    [self retain];
    void (^b)(void) = [[block copy] autorelease];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      if (generation == self->_generation)
          b();
      [self release];
    });
}

- (void)_startNext
{
    if (_current || !_queue.count)
        return;
    _current = [_queue[0] retain];
    [_queue removeObjectAtIndex:0];
    [_words release];
    _words = [words_of(_current.speechString) retain];
    _next = 0;
    [self _after:_current.preUtteranceDelay do:^{
      id<AVSpeechSynthesizerDelegate> d = self->_delegate;
      if ([d respondsToSelector:@selector(speechSynthesizer:didStartSpeechUtterance:)])
          [d speechSynthesizer:self didStartSpeechUtterance:self->_current];
      [self _speakWord];
    }];
}

- (void)_speakWord
{
    if (_paused || !_current)
        return;
    if (_next >= _words.count) {
        [self _after:_current.postUtteranceDelay do:^{
          [self _finish:YES];
        }];
        return;
    }
    NSRange r = [_words[_next++] rangeValue];
    id<AVSpeechSynthesizerDelegate> d = _delegate;
    if ([d respondsToSelector:@selector(speechSynthesizer:willSpeakRangeOfSpeechString:utterance:)])
        [d speechSynthesizer:self willSpeakRangeOfSpeechString:r utterance:_current];
    [self _after:word_time(_current) do:^{
      if (self->_stopAtWord) {
          self->_stopAtWord = NO;
          [self _cancelAll];
          return;
      }
      if (self->_pauseAtWord) {
          self->_pauseAtWord = NO;
          [self _pauseNow];
          return;
      }
      [self _speakWord];
    }];
}

- (void)_finish:(BOOL)spoken
{
    AVSpeechUtterance *u = [_current autorelease];
    _current = nil;
    id<AVSpeechSynthesizerDelegate> d = _delegate;
    SEL s = spoken ? @selector(speechSynthesizer:didFinishSpeechUtterance:) : @selector(speechSynthesizer:didCancelSpeechUtterance:);
    if ([d respondsToSelector:s])
        ((void (*)(id, SEL, id, id))objc_msgSend)(d, s, self, u);
    [self _startNext];
}

- (void)speakUtterance:(AVSpeechUtterance *)utterance
{
    if (!utterance)
        return;
    if (utterance == _current || [_queue containsObject:utterance])
        [NSException raise:NSInvalidArgumentException format:@"An AVSpeechUtterance shall not be enqueued twice"];
    [_queue addObject:utterance];
    [self _startNext];
}

- (void)writeUtterance:(AVSpeechUtterance *)utterance toBufferCallback:(AVSpeechSynthesizerBufferCallback)bufferCallback
{
    [self writeUtterance:utterance toBufferCallback:bufferCallback toMarkerCallback:^(NSArray *markers){
    }];
}

/* (no voice to speak with: the empty buffer that ends an utterance) */
- (void)writeUtterance:(AVSpeechUtterance *)utterance toBufferCallback:(AVSpeechSynthesizerBufferCallback)bufferCallback
      toMarkerCallback:(AVSpeechSynthesizerMarkerCallback)markerCallback
{
    if (!utterance || !bufferCallback)
        return;
    AVSpeechSynthesizerBufferCallback b = [[bufferCallback copy] autorelease];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
      AVAudioFormat *f = [[[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:22050 channels:1 interleaved:NO] autorelease];
      AVAudioPCMBuffer *empty = [[[AVAudioPCMBuffer alloc] initWithPCMFormat:f frameCapacity:1] autorelease];
      empty.frameLength = 0;
      b(empty);
    });
}

- (void)_cancelAll
{
    _generation++;
    _paused = NO;
    NSArray *pending = [[_queue copy] autorelease];
    [_queue removeAllObjects];
    if (_current)
        [self _finish:NO];
    id<AVSpeechSynthesizerDelegate> d = _delegate;
    for (AVSpeechUtterance *u in pending)
        if ([d respondsToSelector:@selector(speechSynthesizer:didCancelSpeechUtterance:)])
            [d speechSynthesizer:self didCancelSpeechUtterance:u];
}

- (void)_pauseNow
{
    _paused = YES;
    id<AVSpeechSynthesizerDelegate> d = _delegate;
    if (_current && [d respondsToSelector:@selector(speechSynthesizer:didPauseSpeechUtterance:)])
        [d speechSynthesizer:self didPauseSpeechUtterance:_current];
}

- (BOOL)stopSpeakingAtBoundary:(AVSpeechBoundary)boundary
{
    if (!self.speaking)
        return NO;
    if (boundary == AVSpeechBoundaryWord && _current && !_paused)
        _stopAtWord = YES;
    else
        [self _cancelAll];
    return YES;
}

- (BOOL)pauseSpeakingAtBoundary:(AVSpeechBoundary)boundary
{
    if (!_current || _paused)
        return NO;
    if (boundary == AVSpeechBoundaryWord)
        _pauseAtWord = YES;
    else {
        _generation++;
        [self _pauseNow];
    }
    return YES;
}

- (BOOL)continueSpeaking
{
    if (!_paused)
        return NO;
    _paused = NO;
    id<AVSpeechSynthesizerDelegate> d = _delegate;
    if ([d respondsToSelector:@selector(speechSynthesizer:didContinueSpeechUtterance:)])
        [d speechSynthesizer:self didContinueSpeechUtterance:_current];
    [self _speakWord];
    return YES;
}

@end
