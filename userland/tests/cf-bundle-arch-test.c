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
    return 0;
}
