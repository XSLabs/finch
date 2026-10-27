/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CoreSymbolication.framework (private), Finch's own: symbols for the running
 * kernel, which is what Apple's open-source zprint and zlog ask it for.
 *
 * The kernel's own file carries its symbol table. CSSymbolicatorCreateWithMachKernel
 * looks in /System/Library/Kernels (and /System/Library/KernelCollections) for
 * a kernel, or a kernel collection's kernel, whose UUID is the running
 * kernel's (kern.uuid). Addresses are the kernel's unslid ones, which is what
 * it hands out (zprint's memory sites and zlog's backtraces are unslid). A
 * kernel collection places each of the kernel's segments on its own, so each
 * segment's place comes from the kernel's header as the kernel reports it for
 * "__kernel__" (OSKextCopyLoadedKextInfo's OSBundleMachOHeaders, unslid), and
 * each symbol moves with its section's segment. No privilege is needed.
 *
 * Symbols are the symbol table's defined section symbols, named without the
 * leading underscore (as Apple's are), each running to the next. There is no
 * source information (no debug info is read), and kexts aren't symbol owners:
 * an address outside the kernel finds nothing.
 *
 * Objects are a pointer to a record whose first field is its kind. The
 * symbolicator is reference counted; its owner, segments and symbols live as
 * long as it does, as Apple's do, so retaining them does nothing.
 */
#include <CoreSymbolication/CoreSymbolication.h>
#include <dirent.h>
#include <fcntl.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <uuid/uuid.h>

/* IOKit's (<IOKit/kext/OSKext.h>). */
CFDictionaryRef OSKextCopyLoadedKextInfo(CFArrayRef kextIdentifiers, CFArrayRef infoKeys);

#ifndef LC_FILESET_ENTRY
#define LC_FILESET_ENTRY (0x35 | LC_REQ_DYLD)
#endif

enum kind { KIND_SYMBOLICATOR = 0x43535359, KIND_OWNER, KIND_SEGMENT, KIND_SYMBOL };

struct symbol {
    enum kind kind;
    mach_vm_address_t address;
    mach_vm_size_t size;
    const char *name;           /* without the leading underscore */
    const char *mangled;
    struct symbolicator *symbolicator;
};

struct segment {
    enum kind kind;
    char name[32];              /* "__TEXT SEGMENT" */
    CSRange range;
};

struct owner {
    enum kind kind;
    char name[64];
    char path[PATH_MAX];
    CFUUIDBytes uuid;
    mach_vm_address_t base;
    struct segment *segments;
    size_t segmentCount;
    mach_vm_address_t low, high;
};

struct symbolicator {
    enum kind kind;
    _Atomic long references;
    struct owner owner;
    struct symbol *symbols;     /* by address */
    size_t symbolCount;
    char *strings;
};

static CSTypeRef make(const void *p) { return (CSTypeRef){ (uintptr_t)p, 0 }; }
static const void *object(CSTypeRef cs, enum kind kind)
{
    const enum kind *p = (const enum kind *)cs._opaque_1;
    return p && *p == kind ? p : NULL;
}

bool CSIsNull(CSTypeRef cs) { return cs._opaque_1 == 0 && cs._opaque_2 == 0; }

static void destroy(struct symbolicator *s)
{
    free(s->owner.segments);
    free(s->symbols);
    free(s->strings);
    free(s);
}

CSTypeRef CSRetain(CSTypeRef cs)
{
    struct symbolicator *s = (struct symbolicator *)object(cs, KIND_SYMBOLICATOR);
    if (s)
        atomic_fetch_add(&s->references, 1);
    return cs;
}

void CSRelease(CSTypeRef cs)
{
    struct symbolicator *s = (struct symbolicator *)object(cs, KIND_SYMBOLICATOR);
    if (s && atomic_fetch_sub(&s->references, 1) == 1)
        destroy(s);
}

/* MARK: - Reading the kernel */

struct image {
    const uint8_t *file;
    size_t fileSize;
    const struct mach_header_64 *mh;    /* the kernel's header (in a collection, its entry's) */
};

static bool in_file(const struct image *im, uint64_t off, uint64_t len)
{
    return off <= im->fileSize && len <= im->fileSize - off;
}

/* The kernel in a file: the file itself, or a collection's com.apple.kernel. */
static bool find_kernel(struct image *im)
{
    if (!in_file(im, 0, sizeof(struct mach_header_64)))
        return false;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)im->file;
    if (mh->magic != MH_MAGIC_64 || !in_file(im, sizeof(*mh), mh->sizeofcmds))
        return false;
    if (mh->filetype == MH_EXECUTE) {
        im->mh = mh;
        return true;
    }
    if (mh->filetype != MH_FILESET)
        return false;
    const uint8_t *p = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_FILESET_ENTRY) {
            const struct fileset_entry_command *fe = (const struct fileset_entry_command *)lc;
            const char *id = (const char *)lc + fe->entry_id.offset;
            if (fe->entry_id.offset < lc->cmdsize && !strncmp(id, "com.apple.kernel", lc->cmdsize - fe->entry_id.offset) &&
                in_file(im, fe->fileoff, sizeof(struct mach_header_64))) {
                im->mh = (const struct mach_header_64 *)(im->file + fe->fileoff);
                return im->mh->magic == MH_MAGIC_64;
            }
        }
        p += lc->cmdsize;
    }
    return false;
}

static const struct load_command *command(const struct image *im, uint32_t want, uint32_t *index)
{
    const uint8_t *p = (const uint8_t *)(im->mh + 1);
    for (uint32_t i = 0; i < im->mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == want) {
            if (index)
                *index = i;
            return lc;
        }
        p += lc->cmdsize;
    }
    return NULL;
}

static bool image_uuid(const struct image *im, uuid_t uuid)
{
    const struct uuid_command *uc = (const struct uuid_command *)command(im, LC_UUID, NULL);
    if (!uc)
        return false;
    memcpy(uuid, uc->uuid, sizeof(uuid_t));
    return true;
}

static bool running_kernel_uuid(uuid_t uuid)
{
    char text[64];
    size_t size = sizeof(text);
    return sysctlbyname("kern.uuid", text, &size, NULL, 0) == 0 && uuid_parse(text, uuid) == 0;
}

/* Map the file and find a kernel in it with this UUID. */
static bool open_kernel(const char *path, const uuid_t want, struct image *im)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return false;
    struct stat st;
    void *map = MAP_FAILED;
    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size >= (off_t)sizeof(struct mach_header_64))
        map = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (map == MAP_FAILED)
        return false;
    im->file = map;
    im->fileSize = (size_t)st.st_size;
    uuid_t uuid;
    if (find_kernel(im) && image_uuid(im, uuid) && !uuid_compare(uuid, want))
        return true;
    munmap(map, (size_t)st.st_size);
    return false;
}

static bool search(const char *dir, const uuid_t want, struct image *im, char *path)
{
    DIR *d = opendir(dir);
    if (!d)
        return false;
    bool found = false;
    struct dirent *e;
    while (!found && (e = readdir(d))) {
        if (e->d_name[0] == '.')
            continue;
        snprintf(path, PATH_MAX, "%s/%s", dir, e->d_name);
        found = open_kernel(path, want, im);
    }
    closedir(d);
    return found;
}

static int by_address(const void *a, const void *b)
{
    const struct symbol *x = a, *y = b;
    return x->address < y->address ? -1 : x->address > y->address;
}

/* The running kernel's segments, unslid, from its header as the kernel reports
   it for "__kernel__". In a kernel collection each segment has its own place,
   so they're matched to the file's by name. */
struct placed {
    char name[16];
    uint64_t vmaddr, vmsize;
};

static size_t kernel_segments(struct placed **out)
{
    const void *id = CFSTR("__kernel__"), *key = CFSTR("OSBundleMachOHeaders");
    CFArrayRef ids = CFArrayCreate(NULL, &id, 1, &kCFTypeArrayCallBacks);
    CFArrayRef keys = CFArrayCreate(NULL, &key, 1, &kCFTypeArrayCallBacks);
    CFDictionaryRef info = OSKextCopyLoadedKextInfo(ids, keys);
    CFRelease(ids);
    CFRelease(keys);
    CFDictionaryRef kernel = info ? CFDictionaryGetValue(info, id) : NULL;
    CFDataRef data = kernel && CFGetTypeID(kernel) == CFDictionaryGetTypeID() ? CFDictionaryGetValue(kernel, key) : NULL;
    size_t count = 0;
    *out = NULL;
    if (data && CFGetTypeID(data) == CFDataGetTypeID() && (size_t)CFDataGetLength(data) >= sizeof(struct mach_header_64)) {
        const uint8_t *bytes = CFDataGetBytePtr(data);
        size_t length = (size_t)CFDataGetLength(data);
        const struct mach_header_64 *mh = (const struct mach_header_64 *)bytes;
        if (mh->magic == MH_MAGIC_64 && mh->sizeofcmds <= length - sizeof(*mh)) {
            *out = calloc(mh->ncmds ? mh->ncmds : 1, sizeof(struct placed));
            const uint8_t *p = bytes + sizeof(*mh), *end = p + mh->sizeofcmds;
            for (uint32_t i = 0; i < mh->ncmds && p + sizeof(struct load_command) <= end; i++) {
                const struct load_command *lc = (const struct load_command *)p;
                if (lc->cmdsize < sizeof(*lc) || p + lc->cmdsize > end)
                    break;
                if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
                    const struct segment_command_64 *sc = (const struct segment_command_64 *)lc;
                    memcpy((*out)[count].name, sc->segname, 16);
                    (*out)[count].vmaddr = sc->vmaddr;
                    (*out)[count].vmsize = sc->vmsize;
                    count++;
                }
                p += lc->cmdsize;
            }
        }
    }
    if (info)
        CFRelease(info);
    return count;
}

static const struct placed *placed_named(const struct placed *placed, size_t count, const char name[16])
{
    for (size_t i = 0; i < count; i++)
        if (!strncmp(placed[i].name, name, 16))
            return &placed[i];
    return NULL;
}

/* MARK: - The symbolicator */

CSSymbolicatorRef CSSymbolicatorCreateWithMachKernel(void)
{
    uuid_t want;
    if (!running_kernel_uuid(want))
        return kCSNull;
    struct placed *placed = NULL;
    size_t placedCount = kernel_segments(&placed);
    if (placedCount == 0) {
        free(placed);
        return kCSNull;
    }

    struct image im = { 0 };
    char path[PATH_MAX];
    const char *env = getenv("FINCH_KERNEL_SYMBOLS");   /* a kernel file elsewhere */
    bool found = (env && (strlcpy(path, env, sizeof(path)), open_kernel(path, want, &im))) ||
        search("/System/Library/Kernels", want, &im, path) ||
        search("/System/Library/KernelCollections", want, &im, path);
    if (!found) {
        free(placed);
        return kCSNull;
    }

    struct symbolicator *s = calloc(1, sizeof(*s));
    s->kind = KIND_SYMBOLICATOR;
    s->references = 1;
    struct owner *o = &s->owner;
    o->kind = KIND_OWNER;
    strlcpy(o->name, "kernel", sizeof(o->name));
    strlcpy(o->path, path, sizeof(o->path));
    image_uuid(&im, (uint8_t *)&o->uuid);
    o->low = UINT64_MAX;

    /* Each file segment's offset to where it is, and each section's segment
       (symbols name their section, numbered from 1 across all segments). */
    o->segments = calloc(im.mh->ncmds ? im.mh->ncmds : 1, sizeof(struct segment));
    uint64_t *offsets = calloc(im.mh->ncmds ? im.mh->ncmds : 1, sizeof(uint64_t));
    bool *placedSegment = calloc(im.mh->ncmds ? im.mh->ncmds : 1, sizeof(bool));
    uint32_t *sectionSegment = calloc(256, sizeof(uint32_t));
    uint32_t sections = 0, segmentIndex = 0;
    const uint8_t *p = (const uint8_t *)(im.mh + 1);
    for (uint32_t i = 0; i < im.mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sc = (const struct segment_command_64 *)lc;
            const struct placed *where = placed_named(placed, placedCount, sc->segname);
            if (where && where->vmsize) {
                offsets[segmentIndex] = where->vmaddr - sc->vmaddr;
                placedSegment[segmentIndex] = true;
                struct segment *seg = &o->segments[o->segmentCount++];
                seg->kind = KIND_SEGMENT;
                snprintf(seg->name, sizeof(seg->name), "%.16s SEGMENT", sc->segname);
                seg->range = (CSRange){ where->vmaddr, where->vmsize };
                if (!strncmp(sc->segname, "__TEXT", 16))
                    o->base = where->vmaddr;
                if (strncmp(sc->segname, "__LINKEDIT", 16)) {
                    if (where->vmaddr < o->low) o->low = where->vmaddr;
                    if (where->vmaddr + where->vmsize > o->high) o->high = where->vmaddr + where->vmsize;
                }
            }
            for (uint32_t k = 0; k < sc->nsects && sections < 255; k++)
                sectionSegment[++sections] = segmentIndex;
            segmentIndex++;
        }
        p += lc->cmdsize;
    }
    free(placed);

    /* Defined section symbols, each where its segment is, by address. */
    const struct symtab_command *st = (const struct symtab_command *)command(&im, LC_SYMTAB, NULL);
    if (st && in_file(&im, st->symoff, (uint64_t)st->nsyms * sizeof(struct nlist_64)) &&
        in_file(&im, st->stroff, st->strsize)) {
        const struct nlist_64 *nl = (const struct nlist_64 *)(im.file + st->symoff);
        s->strings = malloc(st->strsize + 1);
        memcpy(s->strings, im.file + st->stroff, st->strsize);
        s->strings[st->strsize] = 0;
        s->symbols = calloc(st->nsyms ? st->nsyms : 1, sizeof(struct symbol));
        for (uint32_t i = 0; i < st->nsyms; i++) {
            if ((nl[i].n_type & N_STAB) || (nl[i].n_type & N_TYPE) != N_SECT || nl[i].n_un.n_strx >= st->strsize ||
                nl[i].n_sect == NO_SECT || nl[i].n_sect > sections || !placedSegment[sectionSegment[nl[i].n_sect]])
                continue;
            const char *name = s->strings + nl[i].n_un.n_strx;
            if (!*name)
                continue;
            struct symbol *sym = &s->symbols[s->symbolCount++];
            sym->kind = KIND_SYMBOL;
            sym->address = nl[i].n_value + offsets[sectionSegment[nl[i].n_sect]];
            sym->mangled = name;
            sym->name = name[0] == '_' ? name + 1 : name;
            sym->symbolicator = s;
        }
        qsort(s->symbols, s->symbolCount, sizeof(struct symbol), by_address);
        /* Each runs to the next, or to the end of its segment. */
        for (size_t i = 0; i < s->symbolCount; i++) {
            mach_vm_address_t end = i + 1 < s->symbolCount ? s->symbols[i + 1].address : o->high;
            for (size_t k = 0; k < o->segmentCount; k++) {
                CSRange r = o->segments[k].range;
                if (s->symbols[i].address >= r.location && s->symbols[i].address < r.location + r.length &&
                    r.location + r.length < end)
                    end = r.location + r.length;
            }
            s->symbols[i].size = end > s->symbols[i].address ? end - s->symbols[i].address : 0;
        }
    }
    free(offsets);
    free(placedSegment);
    free(sectionSegment);
    munmap((void *)im.file, im.fileSize);
    return make(s);
}

static const struct owner *owner_at(const struct symbolicator *s, mach_vm_address_t address)
{
    return s && address >= s->owner.low && address < s->owner.high ? &s->owner : NULL;
}

CSSymbolOwnerRef CSSymbolicatorGetSymbolOwnerWithAddressAtTime(CSSymbolicatorRef symbolicator,
    mach_vm_address_t address, CSMachineTime time)
{
    (void)time;
    const struct owner *o = owner_at(object(symbolicator, KIND_SYMBOLICATOR), address);
    return o ? make(o) : kCSNull;
}

CSSymbolRef CSSymbolicatorGetSymbolWithAddressAtTime(CSSymbolicatorRef symbolicator, mach_vm_address_t address,
    CSMachineTime time)
{
    (void)time;
    const struct symbolicator *s = object(symbolicator, KIND_SYMBOLICATOR);
    if (!owner_at(s, address) || s->symbolCount == 0)
        return kCSNull;
    /* The last symbol at or before the address. */
    size_t lo = 0, hi = s->symbolCount;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (s->symbols[mid].address <= address)
            lo = mid + 1;
        else
            hi = mid;
    }
    if (lo == 0)
        return kCSNull;
    const struct symbol *sym = &s->symbols[lo - 1];
    return address < sym->address + (sym->size ? sym->size : 1) ? make(sym) : kCSNull;
}

CSSourceInfoRef CSSymbolicatorGetSourceInfoWithAddressAtTime(CSSymbolicatorRef symbolicator,
    mach_vm_address_t address, CSMachineTime time)
{
    (void)symbolicator;
    (void)address;
    (void)time;
    return kCSNull;
}

/* MARK: - Owners, symbols, regions */

const char *CSSymbolOwnerGetName(CSSymbolOwnerRef owner)
{
    const struct owner *o = object(owner, KIND_OWNER);
    return o ? o->name : NULL;
}

const char *CSSymbolOwnerGetPath(CSSymbolOwnerRef owner)
{
    const struct owner *o = object(owner, KIND_OWNER);
    return o ? o->path : NULL;
}

const CFUUIDBytes *CSSymbolOwnerGetCFUUIDBytes(CSSymbolOwnerRef owner)
{
    const struct owner *o = object(owner, KIND_OWNER);
    return o ? &o->uuid : NULL;
}

mach_vm_address_t CSSymbolOwnerGetBaseAddress(CSSymbolOwnerRef owner)
{
    const struct owner *o = object(owner, KIND_OWNER);
    return o ? o->base : 0;
}

size_t CSSymbolOwnerForeachSegment(CSSymbolOwnerRef owner, void (^block)(CSSegmentRef segment))
{
    const struct owner *o = object(owner, KIND_OWNER);
    if (!o)
        return 0;
    for (size_t i = 0; i < o->segmentCount; i++)
        block(make(&o->segments[i]));
    return o->segmentCount;
}

const char *CSSymbolGetName(CSSymbolRef symbol)
{
    const struct symbol *sym = object(symbol, KIND_SYMBOL);
    return sym ? sym->name : NULL;
}

const char *CSSymbolGetMangledName(CSSymbolRef symbol)
{
    const struct symbol *sym = object(symbol, KIND_SYMBOL);
    return sym ? sym->mangled : NULL;
}

CSRange CSSymbolGetRange(CSSymbolRef symbol)
{
    const struct symbol *sym = object(symbol, KIND_SYMBOL);
    return sym ? (CSRange){ sym->address, sym->size } : (CSRange){ 0, 0 };
}

CSSymbolOwnerRef CSSymbolGetSymbolOwner(CSSymbolRef symbol)
{
    const struct symbol *sym = object(symbol, KIND_SYMBOL);
    return sym ? make(&sym->symbolicator->owner) : kCSNull;
}

const char *CSRegionGetName(CSRegionRef region)
{
    const struct segment *seg = object(region, KIND_SEGMENT);
    return seg ? seg->name : NULL;
}

CSRange CSRegionGetRange(CSRegionRef region)
{
    const struct segment *seg = object(region, KIND_SEGMENT);
    return seg ? seg->range : (CSRange){ 0, 0 };
}

const char *CSSourceInfoGetPath(CSSourceInfoRef info)
{
    (void)info;
    return NULL;
}

uint32_t CSSourceInfoGetLineNumber(CSSourceInfoRef info)
{
    (void)info;
    return 0;
}
