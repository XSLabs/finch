/*
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * LinearAlgebra's object class. la_object_t is an OS_object subclass, as on
 * macOS, so ARC, collections and la_retain/la_release all work. Built without
 * ARC: lifetime is libdispatch's os_object reference count.
 */
#import <os/object.h>

#include "internal.h"

extern void *_os_object_alloc_realized(const void *cls, size_t size);

@interface OS_la_object : OS_object
@end

@implementation OS_la_object

- (void)dealloc
{
	la_object_dispose((struct la_s *)self);
	[super dealloc];
}

@end

struct la_s *la_object_alloc(void)
{
	return _os_object_alloc_realized((__bridge const void *)[OS_la_object class], sizeof(struct la_s));
}
