/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Parameter listeners and display helpers shared by Audio Unit clients. */
#include <AudioToolbox/AudioToolbox.h>
#include <Block.h>
#include <dispatch/dispatch.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define paramErr (-50)
#define memFullErr (-108)

typedef struct ListenerSubscription {
	void *object;
	AudioUnitParameter parameter;
	AudioUnitEvent event;
	bool eventSubscription;
	struct ListenerSubscription *next;
} ListenerSubscription;

typedef struct AUListenerBase AUListenerBase;
struct AUListenerBase {
	AUParameterListenerProc parameterProc;
	AUEventListenerProc eventProc;
	AUParameterListenerBlock parameterBlock;
	AUEventListenerBlock eventBlock;
	dispatch_queue_t queue;
	void *userData;
	ListenerSubscription *subscriptions;
	struct AUListenerBase *next;
};

typedef struct {
	AUListenerBase *listener;
	void *object;
	AudioUnitParameter parameter;
	AudioUnitEvent event;
	bool eventCallback;
	AudioUnitParameterValue value;
} Delivery;

static pthread_mutex_t listenerLock = PTHREAD_MUTEX_INITIALIZER;
static AUListenerBase *listeners;

static bool sameParameter(const AudioUnitParameter *a, const AudioUnitParameter *b)
{
	return a->mAudioUnit == b->mAudioUnit && a->mParameterID == b->mParameterID &&
	    a->mScope == b->mScope && a->mElement == b->mElement;
}

static OSStatus parameterInfo(const AudioUnitParameter *parameter, AudioUnitParameterInfo *info)
{
	if (!parameter || !parameter->mAudioUnit || !info)
		return paramErr;
	UInt32 size = sizeof(*info);
	return AudioUnitGetProperty(parameter->mAudioUnit, kAudioUnitProperty_ParameterInfo,
	    parameter->mScope, parameter->mParameterID, info, &size);
}

static AudioUnitParameterValue valueFor(const AudioUnitParameter *parameter)
{
	AudioUnitParameterValue value = 0;
	if (parameter && parameter->mAudioUnit)
		AudioUnitGetParameter(parameter->mAudioUnit, parameter->mParameterID, parameter->mScope,
		    parameter->mElement, &value);
	return value;
}

OSStatus AUListenerCreate(AUParameterListenerProc proc, void *userData, CFRunLoopRef runLoop,
    CFStringRef runLoopMode, Float32 interval, AUParameterListenerRef *outListener)
{
	(void)runLoop;
	(void)runLoopMode;
	if (!proc || !outListener || interval < 0)
		return paramErr;
	AUListenerBase *listener = calloc(1, sizeof(*listener));
	if (!listener)
		return memFullErr;
	listener->parameterProc = proc;
	listener->userData = userData;
	pthread_mutex_lock(&listenerLock);
	listener->next = listeners;
	listeners = listener;
	pthread_mutex_unlock(&listenerLock);
	*outListener = listener;
	return noErr;
}

OSStatus AUEventListenerCreate(AUEventListenerProc proc, void *userData, CFRunLoopRef runLoop,
    CFStringRef runLoopMode, Float32 interval, Float32 granularity, AUEventListenerRef *outListener)
{
	(void)runLoop;
	(void)runLoopMode;
	if (!proc || !outListener || interval < 0 || granularity < 0)
		return paramErr;
	AUListenerBase *listener = calloc(1, sizeof(*listener));
	if (!listener)
		return memFullErr;
	listener->eventProc = proc;
	listener->userData = userData;
	pthread_mutex_lock(&listenerLock);
	listener->next = listeners;
	listeners = listener;
	pthread_mutex_unlock(&listenerLock);
	*outListener = listener;
	return noErr;
}

OSStatus AUListenerCreateWithDispatchQueue(AUParameterListenerRef *outListener,
	Float32 interval, dispatch_queue_t queue, AUParameterListenerBlock block)
{
	if (!outListener || !queue || !block || !isfinite(interval) || interval < 0)
		return paramErr;
	AUListenerBase *listener = calloc(1, sizeof(*listener));
	if (!listener)
		return memFullErr;
	listener->parameterBlock = Block_copy(block);
	listener->queue = queue;
	dispatch_retain(queue);
	pthread_mutex_lock(&listenerLock);
	listener->next = listeners;
	listeners = listener;
	pthread_mutex_unlock(&listenerLock);
	*outListener = listener;
	return noErr;
}

OSStatus AUEventListenerCreateWithDispatchQueue(AUEventListenerRef *outListener,
	Float32 interval, Float32 granularity, dispatch_queue_t queue, AUEventListenerBlock block)
{
	if (!outListener || !queue || !block || !isfinite(interval) || !isfinite(granularity) ||
	    interval < 0 || granularity < 0)
		return paramErr;
	AUListenerBase *listener = calloc(1, sizeof(*listener));
	if (!listener)
		return memFullErr;
	listener->eventBlock = Block_copy(block);
	listener->queue = queue;
	dispatch_retain(queue);
	pthread_mutex_lock(&listenerLock);
	listener->next = listeners;
	listeners = listener;
	pthread_mutex_unlock(&listenerLock);
	*outListener = listener;
	return noErr;
}

OSStatus AUListenerDispose(AUParameterListenerRef reference)
{
	if (!reference)
		return paramErr;
	pthread_mutex_lock(&listenerLock);
	AUListenerBase **cursor = &listeners;
	while (*cursor && *cursor != reference)
		cursor = &(*cursor)->next;
	if (!*cursor) {
		pthread_mutex_unlock(&listenerLock);
		return paramErr;
	}
	AUListenerBase *listener = *cursor;
	*cursor = listener->next;
	pthread_mutex_unlock(&listenerLock);
	ListenerSubscription *subscription = listener->subscriptions;
	while (subscription) {
		ListenerSubscription *next = subscription->next;
		free(subscription);
		subscription = next;
	}
	if (listener->parameterBlock)
		Block_release(listener->parameterBlock);
	if (listener->eventBlock)
		Block_release(listener->eventBlock);
	if (listener->queue)
		dispatch_release(listener->queue);
	free(listener);
	return noErr;
}

OSStatus AUListenerAddParameter(AUParameterListenerRef reference, void *object,
    const AudioUnitParameter *parameter)
{
	if (!reference || !parameter || parameter->mParameterID == kAUParameterListener_AnyParameter)
		return paramErr;
	pthread_mutex_lock(&listenerLock);
	ListenerSubscription **cursor = &reference->subscriptions;
	while (*cursor) {
		if (!(*cursor)->eventSubscription && (*cursor)->object == object &&
		    sameParameter(&(*cursor)->parameter, parameter)) {
			pthread_mutex_unlock(&listenerLock);
			return noErr;
		}
		cursor = &(*cursor)->next;
	}
	ListenerSubscription *subscription = calloc(1, sizeof(*subscription));
	if (!subscription) {
		pthread_mutex_unlock(&listenerLock);
		return memFullErr;
	}
	subscription->object = object;
	subscription->parameter = *parameter;
	*cursor = subscription;
	pthread_mutex_unlock(&listenerLock);
	return noErr;
}

OSStatus AUListenerRemoveParameter(AUParameterListenerRef reference, void *object,
    const AudioUnitParameter *parameter)
{
	if (!reference || !parameter)
		return paramErr;
	pthread_mutex_lock(&listenerLock);
	ListenerSubscription **cursor = &reference->subscriptions;
	while (*cursor) {
		ListenerSubscription *current = *cursor;
		if (!current->eventSubscription && current->object == object && sameParameter(&current->parameter, parameter)) {
			*cursor = current->next;
			free(current);
			break;
		}
		cursor = &current->next;
	}
	pthread_mutex_unlock(&listenerLock);
	return noErr;
}

OSStatus AUEventListenerAddEventType(AUEventListenerRef reference, void *object, const AudioUnitEvent *event)
{
	if (!reference || (!reference->eventProc && !reference->eventBlock) || !event || event->mEventType > kAudioUnitEvent_PropertyChange)
		return paramErr;
	pthread_mutex_lock(&listenerLock);
	for (ListenerSubscription *s = reference->subscriptions; s; s = s->next) {
		if (s->eventSubscription && s->object == object && s->event.mEventType == event->mEventType &&
		    (event->mEventType == kAudioUnitEvent_PropertyChange ?
		        (s->event.mArgument.mProperty.mPropertyID == event->mArgument.mProperty.mPropertyID &&
		         s->event.mArgument.mProperty.mScope == event->mArgument.mProperty.mScope &&
		         s->event.mArgument.mProperty.mElement == event->mArgument.mProperty.mElement) :
		        sameParameter(&s->event.mArgument.mParameter, &event->mArgument.mParameter))) {
			pthread_mutex_unlock(&listenerLock);
			return noErr;
		}
	}
	ListenerSubscription *subscription = calloc(1, sizeof(*subscription));
	if (!subscription) {
		pthread_mutex_unlock(&listenerLock);
		return memFullErr;
	}
	subscription->object = object;
	subscription->event = *event;
	subscription->eventSubscription = true;
	subscription->next = reference->subscriptions;
	reference->subscriptions = subscription;
	pthread_mutex_unlock(&listenerLock);
	return noErr;
}

OSStatus AUEventListenerRemoveEventType(AUEventListenerRef reference, void *object, const AudioUnitEvent *event)
{
	if (!reference || !event)
		return paramErr;
	pthread_mutex_lock(&listenerLock);
	ListenerSubscription **cursor = &reference->subscriptions;
	while (*cursor) {
		ListenerSubscription *s = *cursor;
		if (s->eventSubscription && s->object == object && s->event.mEventType == event->mEventType &&
		    sameParameter(&s->event.mArgument.mParameter, &event->mArgument.mParameter)) {
			*cursor = s->next;
			free(s);
			break;
		}
		cursor = &s->next;
	}
	pthread_mutex_unlock(&listenerLock);
	return noErr;
}

static void notifyParameter(AUParameterListenerRef sender, void *senderObject, const AudioUnitParameter *parameter)
{
	if (!parameter)
		return;
	size_t count = 0;
	pthread_mutex_lock(&listenerLock);
	for (AUListenerBase *l = listeners; l; l = l->next) {
		if (l == sender)
			continue;
		for (ListenerSubscription *s = l->subscriptions; s; s = s->next) {
			AudioUnitParameter *watched = s->eventSubscription ? &s->event.mArgument.mParameter : &s->parameter;
			if (s->eventSubscription && s->event.mEventType != kAudioUnitEvent_ParameterValueChange)
				continue;
			if (watched->mAudioUnit != parameter->mAudioUnit ||
			    (watched->mParameterID != parameter->mParameterID && parameter->mParameterID != kAUParameterListener_AnyParameter))
				continue;
			if (l == sender && (!senderObject || s->object == senderObject))
				continue;
			count++;
		}
	}
	Delivery *deliveries = count ? calloc(count, sizeof(*deliveries)) : NULL;
	size_t index = 0;
	for (AUListenerBase *l = listeners; l && index < count; l = l->next) {
		if (l == sender)
			continue;
		for (ListenerSubscription *s = l->subscriptions; s && index < count; s = s->next) {
			AudioUnitParameter *watched = s->eventSubscription ? &s->event.mArgument.mParameter : &s->parameter;
			if (s->eventSubscription && s->event.mEventType != kAudioUnitEvent_ParameterValueChange)
				continue;
			if (watched->mAudioUnit != parameter->mAudioUnit ||
			    (watched->mParameterID != parameter->mParameterID && parameter->mParameterID != kAUParameterListener_AnyParameter))
				continue;
			if (l == sender && (!senderObject || s->object == senderObject))
				continue;
			Delivery *d = &deliveries[index++];
			d->listener = l;
			d->object = s->object;
			d->parameter = *watched;
			d->eventCallback = s->eventSubscription;
			if (s->eventSubscription)
				d->event = s->event;
		}
	}
	pthread_mutex_unlock(&listenerLock);
	for (size_t i = 0; i < index; i++) {
		Delivery *d = &deliveries[i];
		d->value = valueFor(&d->parameter);
		if (!d->eventCallback && d->listener->parameterBlock) {
			AUParameterListenerBlock callback = Block_copy(d->listener->parameterBlock);
			void *object = d->object;
			AudioUnitParameter watched = d->parameter;
			AudioUnitParameterValue value = d->value;
			dispatch_async(d->listener->queue, ^{ callback(object, &watched, value); });
			Block_release(callback);
		} else if (!d->eventCallback && d->listener->parameterProc)
			d->listener->parameterProc(d->listener->userData, d->object, &d->parameter, d->value);
		if (d->listener->eventBlock) {
			AUEventListenerBlock callback = Block_copy(d->listener->eventBlock);
			void *object = d->object;
			AudioUnitEvent event = d->eventCallback ? d->event : (AudioUnitEvent){.mEventType = kAudioUnitEvent_ParameterValueChange};
			if (!d->eventCallback)
				event.mArgument.mParameter = d->parameter;
			AudioUnitParameterValue value = d->value;
			dispatch_async(d->listener->queue, ^{ callback(object, &event, 0, value); });
			Block_release(callback);
		} else if (d->listener->eventProc) {
			AudioUnitEvent event = d->eventCallback ? d->event : (AudioUnitEvent){.mEventType = kAudioUnitEvent_ParameterValueChange};
			if (!d->eventCallback)
				event.mArgument.mParameter = d->parameter;
			d->listener->eventProc(d->listener->userData, d->object, &event, 0, d->value);
		}
	}
	free(deliveries);
}

OSStatus AUParameterSet(AUParameterListenerRef sender, void *senderObject, const AudioUnitParameter *parameter,
    AudioUnitParameterValue value, UInt32 offset)
{
	if (!parameter || !parameter->mAudioUnit)
		return paramErr;
	OSStatus status = AudioUnitSetParameter(parameter->mAudioUnit, parameter->mParameterID, parameter->mScope,
	    parameter->mElement, value, offset);
	if (status == noErr)
		notifyParameter(sender, senderObject, parameter);
	return status;
}

OSStatus AUParameterListenerNotify(AUParameterListenerRef sender, void *senderObject,
    const AudioUnitParameter *parameter)
{
	if (!parameter)
		return paramErr;
	notifyParameter(sender, senderObject, parameter);
	return noErr;
}

OSStatus AUEventListenerNotify(AUEventListenerRef sender, void *senderObject, const AudioUnitEvent *event)
{
	if (!event || event->mEventType > kAudioUnitEvent_EndParameterChangeGesture)
		return paramErr;
	const AudioUnitParameter *parameter = &event->mArgument.mParameter;
	AudioUnitParameterValue value = valueFor(parameter);
	size_t count = 0;
	pthread_mutex_lock(&listenerLock);
	for (AUListenerBase *l = listeners; l; l = l->next) {
		if (l == sender || (!l->eventProc && !l->eventBlock))
			continue;
		for (ListenerSubscription *s = l->subscriptions; s; s = s->next) {
			if (s->eventSubscription && s->event.mEventType == event->mEventType &&
			    sameParameter(&s->event.mArgument.mParameter, parameter) &&
			    !(l == sender && (!senderObject || s->object == senderObject)))
				count++;
		}
	}
	Delivery *deliveries = count ? calloc(count, sizeof(*deliveries)) : NULL;
	size_t index = 0;
	for (AUListenerBase *l = listeners; l && index < count; l = l->next) {
		if (l == sender || (!l->eventProc && !l->eventBlock))
			continue;
		for (ListenerSubscription *s = l->subscriptions; s && index < count; s = s->next) {
			if (!s->eventSubscription || s->event.mEventType != event->mEventType ||
			    !sameParameter(&s->event.mArgument.mParameter, parameter) ||
			    (l == sender && (!senderObject || s->object == senderObject)))
				continue;
			deliveries[index] = (Delivery){.listener = l, .object = s->object, .event = *event,
			    .eventCallback = true, .value = value};
			index++;
		}
	}
	pthread_mutex_unlock(&listenerLock);
	for (size_t i = 0; i < index; i++) {
		Delivery *d = &deliveries[i];
		if (d->listener->eventBlock) {
			AUEventListenerBlock callback = Block_copy(d->listener->eventBlock);
			void *object = d->object;
			AudioUnitEvent event = d->event;
			AudioUnitParameterValue value = d->value;
			dispatch_async(d->listener->queue, ^{ callback(object, &event, 0, value); });
			Block_release(callback);
		} else if (d->listener->eventProc)
			d->listener->eventProc(d->listener->userData, d->object, &d->event, 0, d->value);
	}
	free(deliveries);
	return noErr;
}

AudioUnitParameterValue AUParameterValueFromLinear(Float32 linear, const AudioUnitParameter *parameter)
{
	AudioUnitParameterInfo info = {0};
	if (parameterInfo(parameter, &info) != noErr || !isfinite(linear))
		return 0;
	if (linear < 0) linear = 0;
	if (linear > 1) linear = 1;
	if (AudioUnitDisplayTypeIsLogarithmic(info.flags) && info.minValue > 0 && info.maxValue > info.minValue)
		return info.minValue * powf(info.maxValue / info.minValue, linear);
	if (AudioUnitDisplayTypeIsSquareRoot(info.flags))
		linear *= linear;
	else if (AudioUnitDisplayTypeIsSquared(info.flags))
		linear = sqrtf(linear);
	else if (AudioUnitDisplayTypeIsCubed(info.flags))
		linear = cbrtf(linear);
	return info.minValue + linear * (info.maxValue - info.minValue);
}

Float32 AUParameterValueToLinear(AudioUnitParameterValue value, const AudioUnitParameter *parameter)
{
	AudioUnitParameterInfo info = {0};
	if (parameterInfo(parameter, &info) != noErr || !isfinite(value))
		return 0;
	if (info.maxValue <= info.minValue)
		return 0;
	Float32 linear;
	if (AudioUnitDisplayTypeIsLogarithmic(info.flags) && info.minValue > 0 && value > 0)
		linear = logf(value / info.minValue) / logf(info.maxValue / info.minValue);
	else
		linear = (value - info.minValue) / (info.maxValue - info.minValue);
	if (AudioUnitDisplayTypeIsSquareRoot(info.flags))
		linear = sqrtf(fmaxf(linear, 0));
	else if (AudioUnitDisplayTypeIsSquared(info.flags))
		linear *= linear;
	else if (AudioUnitDisplayTypeIsCubed(info.flags))
		linear = linear * linear * linear;
	if (linear < 0) return 0;
	if (linear > 1) return 1;
	return linear;
}

char *AUParameterFormatValue(Float64 value, const AudioUnitParameter *parameter, char *buffer, UInt32 digits)
{
	AudioUnitParameterInfo info = {0};
	bool hasInfo = parameterInfo(parameter, &info) == noErr;
	if (!hasInfo)
		return buffer;
	Float64 range = info.maxValue - info.minValue;
	Float64 scale = hasInfo && AudioUnitDisplayTypeIsLogarithmic(info.flags) ? value : range;
	int power = scale == 0 || !isfinite(scale) ? 0 : (int)floor(log10(fabs(scale)));
	int decimals = (int)digits - power - 1;
	if (decimals > 9) decimals = 9;
	if (decimals < -9) decimals = -9;
	if (decimals >= 0) {
		Float64 factor = pow(10.0, decimals);
		snprintf(buffer, 64, "%.*f", decimals, round(value * factor) / factor);
	} else {
		Float64 factor = pow(10.0, -decimals);
		snprintf(buffer, 64, "%.0f", round(value / factor) * factor);
	}
	return buffer;
}
