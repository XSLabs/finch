/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The class name of an IOKit object, for FinchSandbox's iokit filters
 * (finch_sandbox.c is C; IOKit's objects are C++).
 */
#include <libkern/c++/OSObject.h>
#include <libkern/c++/OSMetaClass.h>

extern "C" const char *finch_sandbox_iokit_class_name(OSObject *object);

const char *
finch_sandbox_iokit_class_name(OSObject *object)
{
	const OSMetaClass *meta;

	if (object == NULL) {
		return NULL;
	}
	meta = object->getMetaClass();
	return meta != NULL ? meta->getClassName() : NULL;
}
