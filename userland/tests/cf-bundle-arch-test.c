/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <mach/machine.h>
#include <stdio.h>

cpu_type_t _CFBundleGetPreferredExecutableArchitecture(CFBundleRef bundle);

int
main(void)
{
	Dl_info info;
	if (dladdr((void *)CFBundleGetMainBundle, &info))
		printf("CoreFoundation: %s\n", info.dli_fname);
    printf("preferred architecture: %d\n", (int)_CFBundleGetPreferredExecutableArchitecture(CFBundleGetMainBundle()));
    printf("loadable architectures: arm64 %u x86_64 %u i386 %u arm64_32 %u unknown %u\n",
        (unsigned)CFBundleIsArchitectureLoadable(CPU_TYPE_ARM64),
        (unsigned)CFBundleIsArchitectureLoadable(CPU_TYPE_X86_64),
        (unsigned)CFBundleIsArchitectureLoadable(CPU_TYPE_I386),
        (unsigned)CFBundleIsArchitectureLoadable(CPU_TYPE_ARM64_32),
        (unsigned)CFBundleIsArchitectureLoadable((cpu_type_t)0x12345678));
    CFBundleRef main = CFBundleGetMainBundle();
    CFURLRef executable = main ? CFBundleCopyExecutableURL(main) : NULL;
    CFURLRef missing = CFURLCreateWithFileSystemPath(NULL, CFSTR("/definitely/not/a/finch/executable"),
        kCFURLPOSIXPathStyle, false);
    printf("executable loadable: bundle %u url %u missing %u\n",
        (unsigned)(main ? CFBundleIsExecutableLoadable(main) : false),
        (unsigned)(executable ? CFBundleIsExecutableLoadableForURL(executable) : false),
        (unsigned)CFBundleIsExecutableLoadableForURL(missing));
    if (executable) CFRelease(executable);
    if (missing) CFRelease(missing);
    return 0;
}
