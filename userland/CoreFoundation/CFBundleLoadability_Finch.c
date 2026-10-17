/* SPDX-License-Identifier: Apache-2.0 */
/* Check the executable architecture in a bundle without loading its code. */
#include <CoreFoundation/CFBundle.h>
#include <fcntl.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <mach/machine.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

static uint32_t
swap32(uint32_t value)
{
	return ((value & 0x000000ffU) << 24) | ((value & 0x0000ff00U) << 8) |
	       ((value & 0x00ff0000U) >> 8) | ((value & 0xff000000U) >> 24);
}

Boolean
CFBundleIsArchitectureLoadable(cpu_type_t arch)
{
	/* Finch's host loader accepts Apple Silicon and translated Intel binaries. */
	if (arch == CPU_TYPE_ARM64 || arch == CPU_TYPE_X86_64)
		return true;
	return false;
}

static Boolean
file_has_loadable_architecture(const char *path)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return false;

	uint32_t magic = 0;
	ssize_t n = pread(fd, &magic, sizeof(magic), 0);
	if (n != sizeof(magic)) {
		close(fd);
		return false;
	}

	Boolean loadable = false;
	if (magic == MH_MAGIC_64 || magic == MH_CIGAM_64 || magic == MH_MAGIC || magic == MH_CIGAM) {
		struct mach_header header;
		if (pread(fd, &header, sizeof(header), 0) == sizeof(header))
			loadable = CFBundleIsArchitectureLoadable((cpu_type_t)header.cputype);
	} else if (magic == FAT_MAGIC || magic == FAT_CIGAM || magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64) {
		bool swapped = magic == FAT_CIGAM || magic == FAT_CIGAM_64;
		bool is64 = magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64;
		struct fat_header header;
		if (pread(fd, &header, sizeof(header), 0) == sizeof(header)) {
			uint32_t count = swapped ? swap32(header.nfat_arch) : header.nfat_arch;
			if (count > 128)
				count = 0;
			for (uint32_t i = 0; i < count && !loadable; i++) {
				cpu_type_t type;
				if (is64) {
					struct fat_arch_64 arch;
					if (pread(fd, &arch, sizeof(arch), (off_t)sizeof(header) + (off_t)i * sizeof(arch)) != sizeof(arch))
						break;
					type = (cpu_type_t)(swapped ? swap32((uint32_t)arch.cputype) : arch.cputype);
				} else {
					struct fat_arch arch;
					if (pread(fd, &arch, sizeof(arch), (off_t)sizeof(header) + (off_t)i * sizeof(arch)) != sizeof(arch))
						break;
					type = (cpu_type_t)(swapped ? swap32((uint32_t)arch.cputype) : arch.cputype);
				}
				loadable = CFBundleIsArchitectureLoadable(type);
			}
		}
	}
	close(fd);
	return loadable;
}

Boolean
CFBundleIsExecutableLoadableForURL(CFURLRef url)
{
	if (!url || CFGetTypeID(url) != CFURLGetTypeID())
		return false;
	char path[PATH_MAX];
	if (!CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, sizeof(path)))
		return false;
	return file_has_loadable_architecture(path);
}

Boolean
CFBundleIsExecutableLoadable(CFBundleRef bundle)
{
	if (!bundle || CFGetTypeID(bundle) != CFBundleGetTypeID())
		return false;
	CFURLRef url = CFBundleCopyExecutableURL(bundle);
	if (!url)
		return false;
	Boolean loadable = CFBundleIsExecutableLoadableForURL(url);
	CFRelease(url);
	return loadable;
}
