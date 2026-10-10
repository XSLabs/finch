/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Metal.framework, Finch's: what its files share (MTLRuntime.m). */
#import <Metal/Metal.h>

/* A new instance of a (public) class, as a property's starting value. */
void FinchMTLSetNew(id object, NSString *key, NSString *className);
/* The element at an index of a descriptor array (made on first use) and setting one. */
id FinchMTLArrayGet(id array, NSUInteger index, NSString *elementClass);
void FinchMTLArraySet(id array, NSUInteger index, id element);
/* (setting one that keeps the object itself, as the rasterization rate arrays do) */
void FinchMTLArrayStore(id array, NSUInteger index, id element);
/* One more than the highest index set. */
NSUInteger FinchMTLArrayCount(id array);
/* Descriptors as values: a copy with every property copied, equality and hash by them. */
id FinchMTLCopy(id object);
BOOL FinchMTLEqual(id object, id other);
NSUInteger FinchMTLHash(id object);
