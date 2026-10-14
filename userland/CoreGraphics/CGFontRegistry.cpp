/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The installed fonts, by PostScript name: the files under the system,
 * local and user font directories (or FINCH_FONT_DIRS), indexed once on
 * first use. Apple's font names that match no font resolve to the open fonts
 * Finch ships, as in CoreText (../fonts/FinchFonts.h).
 */
#include "CGFontInternal.h"
#include "../fonts/FinchFonts.h"
#include <dirent.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <map>
#include <string>

static pthread_once_t once = PTHREAD_ONCE_INIT;
static std::map<std::string, std::pair<std::string, uint32_t>> *by_name; /* -> file, face of a collection */

static uint16_t be16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }

/* The PostScript name (name ID 6) of a face of a font file. */
static std::string
postscript_name(const uint8_t *d, size_t n, uint32_t face)
{
    size_t base = finch_font_face_offset(d, n, face);
    if (base == SIZE_MAX)
        return "";
    uint16_t count = be16(d + base + 4);
    for (uint16_t i = 0; i < count && base + 12 + 16 * (size_t)(i + 1) <= n; i++) {
        const uint8_t *rec = d + base + 12 + 16 * i;
        if (be32(rec) != 'name')
            continue;
        size_t off = be32(rec + 8), len = be32(rec + 12);
        if (off + len > n || len < 6)
            return "";
        const uint8_t *t = d + off;
        uint16_t records = be16(t + 2), storage = be16(t + 4);
        for (uint16_t r = 0; r < records && 6 + 12 * (size_t)(r + 1) <= len; r++) {
            const uint8_t *e = t + 6 + 12 * r;
            if (be16(e + 6) != 6)
                continue;
            size_t length = be16(e + 8), offset = be16(e + 10);
            if (storage + offset + length > len)
                continue;
            const uint8_t *s = t + storage + offset;
            std::string out;
            if (be16(e) == 3 || be16(e) == 0) {
                for (size_t k = 0; k + 1 < length; k += 2)
                    out += (char)s[k + 1];
            } else {
                out.assign((const char *)s, length);
            }
            return out;
        }
    }
    return "";
}

static void
scan(const std::string &dir, int depth)
{
    DIR *d = opendir(dir.c_str());
    if (!d)
        return;
    while (struct dirent *e = readdir(d)) {
        if (e->d_name[0] == '.')
            continue;
        std::string path = dir + "/" + e->d_name;
        struct stat st;
        if (stat(path.c_str(), &st))
            continue;
        if (S_ISDIR(st.st_mode)) {
            if (depth < 3)
                scan(path, depth + 1);
            continue;
        }
        const char *dot = strrchr(e->d_name, '.');
        if (!dot || (strcasecmp(dot, ".ttf") && strcasecmp(dot, ".otf") && strcasecmp(dot, ".ttc")))
            continue;
        int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
        if (fd < 0)
            continue;
        /* mapped whole: a collection's later faces keep their names anywhere in the file */
        void *map = st.st_size > 0 ? mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0) : MAP_FAILED;
        close(fd);
        if (map == MAP_FAILED)
            continue;
        const uint8_t *buf = (const uint8_t *)map;
        size_t got = (size_t)st.st_size;
        uint32_t faces = finch_font_face_count(buf, got);
        for (uint32_t i = 0; i < faces; i++) {
            std::string ps = postscript_name(buf, got, i);
            if (!ps.empty() && !by_name->count(ps))
                (*by_name)[ps] = {path, i};
        }
        munmap(map, got);
    }
    closedir(d);
}

static void
build(void)
{
    by_name = new std::map<std::string, std::pair<std::string, uint32_t>>();
    for (const std::string &dir : finch_font_dirs())
        scan(dir, 0);
}

CFDataRef
CGFontRegistryCopyDataForName(CFStringRef name)
{
    char buf[512];
    if (!CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8))
        return NULL;
    pthread_once(&once, build);
    auto it = by_name->find(buf);
    if (it == by_name->end()) {
        const char *alias = finch_font_alias(buf);
        if (alias)
            it = by_name->find(alias);
    }
    if (it == by_name->end())
        return NULL;
    CGDataProviderRef p = CGDataProviderCreateWithFilename(it->second.first.c_str());
    CFDataRef data = p ? CGDataProviderCopyData(p) : NULL;
    if (p)
        CFRelease(p);
    if (data && it->second.second) {
        std::vector<uint8_t> one = finch_font_face_file(CFDataGetBytePtr(data), (size_t)CFDataGetLength(data), it->second.second);
        CFRelease(data);
        data = one.empty() ? NULL : CFDataCreate(NULL, one.data(), (CFIndex)one.size());
    }
    return data;
}
