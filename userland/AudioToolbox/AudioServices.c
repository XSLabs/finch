/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AudioToolbox's system sounds (AudioServices.h). Sounds are registered
 * from files and keep their properties and completion procs as Apple's do.
 * Finch has no audio output yet, so playing one finishes at once: its
 * completions (procs on their run loop, blocks on the main queue) run, and
 * nothing is heard. kSystemSoundID_UserPreferredAlert is the alert sound.
 */
#include <AudioToolbox/AudioServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Block.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct Sound {
    SystemSoundID id;
    CFURLRef url;
    UInt32 is_ui;                  /* kAudioServicesPropertyIsUISound */
    UInt32 complete_if_dies;       /* kAudioServicesPropertyCompletePlaybackIfAppDies */
    AudioServicesSystemSoundCompletionProc proc;
    void *proc_data;
    CFRunLoopRef run_loop;
    CFStringRef run_loop_mode;
    struct Sound *next;
} Sound;

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static Sound *sounds;
static SystemSoundID next_id = 4097;

/* Apple's private alert-volume property and its value (Float32 bits) */
enum { kSystemSoundVolume = 'ssvl' };
static UInt32 alert_volume_bits = 0x3f800000;

static Sound *
find(SystemSoundID id)
{
    for (Sound *s = sounds; s; s = s->next)
        if (s->id == id)
            return s;
    return NULL;
}

/* The alert sound and the screen flash are always there. */
static Boolean
builtin(SystemSoundID id)
{
    return id == kSystemSoundID_UserPreferredAlert || id == kSystemSoundID_FlashScreen;
}

OSStatus
AudioServicesCreateSystemSoundID(CFURLRef inFileURL, SystemSoundID *outSystemSoundID)
{
    if (!inFileURL || !outSystemSoundID)
        return kAudioServicesSystemSoundUnspecifiedError;
    Sound *s = calloc(1, sizeof *s);
    s->url = CFRetain(inFileURL);
    s->is_ui = 1;
    pthread_mutex_lock(&lock);
    s->id = next_id++;
    s->next = sounds;
    sounds = s;
    pthread_mutex_unlock(&lock);
    *outSystemSoundID = s->id;
    return kAudioServicesNoError;
}

OSStatus
AudioServicesDisposeSystemSoundID(SystemSoundID inSystemSoundID)
{
    pthread_mutex_lock(&lock);
    for (Sound **pp = &sounds; *pp; pp = &(*pp)->next) {
        if ((*pp)->id == inSystemSoundID) {
            Sound *s = *pp;
            *pp = s->next;
            pthread_mutex_unlock(&lock);
            CFRelease(s->url);
            if (s->run_loop)
                CFRelease(s->run_loop);
            if (s->run_loop_mode)
                CFRelease(s->run_loop_mode);
            free(s);
            return kAudioServicesNoError;
        }
    }
    pthread_mutex_unlock(&lock);
    return builtin(inSystemSoundID) ? kAudioServicesNoError : kAudioServicesBadSpecifierSizeError;
}

/* Playback "finishes": the sound's completion proc on its run loop (the main one by default). */
static void
finished(SystemSoundID id)
{
    pthread_mutex_lock(&lock);
    Sound *s = find(id);
    AudioServicesSystemSoundCompletionProc proc = s ? s->proc : NULL;
    void *data = s ? s->proc_data : NULL;
    CFRunLoopRef rl = s && s->run_loop ? s->run_loop : CFRunLoopGetMain();
    CFStringRef mode = s && s->run_loop_mode ? s->run_loop_mode : kCFRunLoopCommonModes;
    pthread_mutex_unlock(&lock);
    if (!proc)
        return;
    CFRunLoopPerformBlock(rl, mode, ^{ proc(id, data); });
    CFRunLoopWakeUp(rl);
}

static void
play(SystemSoundID id, void (^completion)(void))
{
    if (!builtin(id)) {
        pthread_mutex_lock(&lock);
        Boolean known = find(id) != NULL;
        pthread_mutex_unlock(&lock);
        if (!known)
            return;
    }
    finished(id);
    if (completion) {
        void (^done)(void) = Block_copy(completion);
        dispatch_async(dispatch_get_main_queue(), ^{
            done();
            Block_release(done);
        });
    }
}

void AudioServicesPlayAlertSound(SystemSoundID inSystemSoundID) { play(inSystemSoundID, NULL); }
void AudioServicesPlaySystemSound(SystemSoundID inSystemSoundID) { play(inSystemSoundID, NULL); }

void
AudioServicesPlayAlertSoundWithCompletion(SystemSoundID inSystemSoundID, void (^inCompletionBlock)(void))
{
    play(inSystemSoundID, inCompletionBlock);
}

void
AudioServicesPlaySystemSoundWithCompletion(SystemSoundID inSystemSoundID, void (^inCompletionBlock)(void))
{
    play(inSystemSoundID, inCompletionBlock);
}

OSStatus
AudioServicesAddSystemSoundCompletion(SystemSoundID inSystemSoundID, CFRunLoopRef inRunLoop, CFStringRef inRunLoopMode,
                                      AudioServicesSystemSoundCompletionProc inCompletionRoutine, void *inClientData)
{
    pthread_mutex_lock(&lock);
    Sound *s = find(inSystemSoundID);
    if (!s) {
        pthread_mutex_unlock(&lock);
        return kAudioServicesBadSpecifierSizeError;
    }
    s->proc = inCompletionRoutine;
    s->proc_data = inClientData;
    if (s->run_loop)
        CFRelease(s->run_loop);
    if (s->run_loop_mode)
        CFRelease(s->run_loop_mode);
    s->run_loop = inRunLoop ? (CFRunLoopRef)CFRetain(inRunLoop) : NULL;
    s->run_loop_mode = inRunLoopMode ? CFStringCreateCopy(NULL, inRunLoopMode) : NULL;
    pthread_mutex_unlock(&lock);
    return kAudioServicesNoError;
}

void
AudioServicesRemoveSystemSoundCompletion(SystemSoundID inSystemSoundID)
{
    pthread_mutex_lock(&lock);
    Sound *s = find(inSystemSoundID);
    if (s)
        s->proc = NULL, s->proc_data = NULL;
    pthread_mutex_unlock(&lock);
}

/* The property's value for the sound named by the specifier (a SystemSoundID). */
/* Apple's private 'aurl': the user's alert sound, a CFURL (the caller's to release). As
   macOS's, the global default com.apple.sound.beep.sound names it; else Finch's own sound. */
#define kAudioServicesPropertyAlertSoundURL 'aurl'

static CFURLRef
alert_sound_url(void)
{
    CFStringRef path = CFPreferencesCopyAppValue(CFSTR("com.apple.sound.beep.sound"), kCFPreferencesAnyApplication);
    if (path && CFGetTypeID(path) != CFStringGetTypeID()) {
        CFRelease(path);
        path = NULL;
    }
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, path ? path : CFSTR("/System/Library/Sounds/Finch.aiff"),
                                                 kCFURLPOSIXPathStyle, false);
    if (path)
        CFRelease(path);
    return url;
}

static OSStatus
property(AudioServicesPropertyID inPropertyID, UInt32 inSpecifierSize, const void *inSpecifier, UInt32 **out)
{
    /* 'ssvl', the alert volume (a Float32, 1.0 to start, as Apple's): no specifier */
    if (inPropertyID == kSystemSoundVolume) {
        *out = &alert_volume_bits;
        return kAudioServicesNoError;
    }
    if (inPropertyID != kAudioServicesPropertyIsUISound && inPropertyID != kAudioServicesPropertyCompletePlaybackIfAppDies) {
        /* FINCH_TRACE_AUDIOSERVICES: the properties asked for that aren't here */
        if (getenv("FINCH_TRACE_AUDIOSERVICES"))
            fprintf(stderr, "AudioServices: property '%c%c%c%c' (%u-byte specifier) unsupported\n",
                    (char)(inPropertyID >> 24), (char)(inPropertyID >> 16), (char)(inPropertyID >> 8),
                    (char)inPropertyID, (unsigned)inSpecifierSize);
        return kAudioServicesUnsupportedPropertyError;
    }
    if (inSpecifierSize != sizeof(SystemSoundID) || !inSpecifier)
        return kAudioServicesBadSpecifierSizeError;
    Sound *s = find(*(const SystemSoundID *)inSpecifier);
    if (!s)
        return kAudioServicesBadSpecifierSizeError;
    *out = inPropertyID == kAudioServicesPropertyIsUISound ? &s->is_ui : &s->complete_if_dies;
    return kAudioServicesNoError;
}

OSStatus
AudioServicesGetPropertyInfo(AudioServicesPropertyID inPropertyID, UInt32 inSpecifierSize, const void *inSpecifier,
                             UInt32 *outPropertyDataSize, Boolean *outWritable)
{
    if (inPropertyID == kAudioServicesPropertyAlertSoundURL) {
        if (outPropertyDataSize)
            *outPropertyDataSize = sizeof(CFURLRef);
        if (outWritable)
            *outWritable = false;
        return kAudioServicesNoError;
    }
    UInt32 *v;
    pthread_mutex_lock(&lock);
    OSStatus err = property(inPropertyID, inSpecifierSize, inSpecifier, &v);
    pthread_mutex_unlock(&lock);
    if (err)
        return err;
    if (outPropertyDataSize)
        *outPropertyDataSize = sizeof(UInt32);
    if (outWritable)
        *outWritable = true;
    return kAudioServicesNoError;
}

OSStatus
AudioServicesGetProperty(AudioServicesPropertyID inPropertyID, UInt32 inSpecifierSize, const void *inSpecifier,
                         UInt32 *ioPropertyDataSize, void *outPropertyData)
{
    if (inPropertyID == kAudioServicesPropertyAlertSoundURL) {
        if (!ioPropertyDataSize || *ioPropertyDataSize < sizeof(CFURLRef) || !outPropertyData)
            return kAudioServicesBadPropertySizeError;
        *(CFURLRef *)outPropertyData = alert_sound_url();
        *ioPropertyDataSize = sizeof(CFURLRef);
        return kAudioServicesNoError;
    }
    UInt32 *v;
    pthread_mutex_lock(&lock);
    OSStatus err = property(inPropertyID, inSpecifierSize, inSpecifier, &v);
    if (!err && (!ioPropertyDataSize || *ioPropertyDataSize < sizeof(UInt32) || !outPropertyData))
        err = kAudioServicesBadPropertySizeError;
    if (!err) {
        *(UInt32 *)outPropertyData = *v;
        *ioPropertyDataSize = sizeof(UInt32);
    }
    pthread_mutex_unlock(&lock);
    return err;
}

OSStatus
AudioServicesSetProperty(AudioServicesPropertyID inPropertyID, UInt32 inSpecifierSize, const void *inSpecifier,
                         UInt32 inPropertyDataSize, const void *inPropertyData)
{
    UInt32 *v;
    pthread_mutex_lock(&lock);
    OSStatus err = property(inPropertyID, inSpecifierSize, inSpecifier, &v);
    if (!err && (inPropertyDataSize != sizeof(UInt32) || !inPropertyData))
        err = kAudioServicesBadPropertySizeError;
    if (!err)
        *v = *(const UInt32 *)inPropertyData;
    pthread_mutex_unlock(&lock);
    return err;
}
