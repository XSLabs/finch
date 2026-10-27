/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * finch-images: print every image loaded in this process (what a minimal
 * libSystem program pulls in), one path per line, optionally after dlopen()ing
 * extra libraries given as arguments.
 *
 * finch-images --all (as root): every image every running process has loaded,
 * dlopen()ed ones included, as "pid<TAB>program<TAB>image" lines, read from
 * each process's dyld_all_image_infos over a read-only task port. Processes
 * whose port is refused are listed with the image "?" (tools/vm/check-loaded-images.py).
 * finch-images --all --addresses puts each image's load address before its path.
 *
 * finch-images --stack PID (as root): each thread's backtrace, walked by frame
 * pointer over the read-only task port, as "image+offset" frames to symbolicate
 * offline (atos -o IMAGE -l 0 OFFSET).
 */

#include <dlfcn.h>
#include <libproc.h>
#include <mach-o/dyld.h>
#include <mach-o/dyld_images.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/thread_status.h>
#include <ptrauth.h>

/* A read-only task port (a Mach trap libsystem_kernel exports; the SDK header leaves it out). */
kern_return_t task_read_for_pid(mach_port_name_t target, int pid, mach_port_name_t *task);

static int
read_task(task_t task, mach_vm_address_t address, void *buffer, mach_vm_size_t size)
{
	mach_vm_size_t got = 0;
	return mach_vm_read_overwrite(task, address, size, (mach_vm_address_t)buffer, &got) == KERN_SUCCESS &&
	    got == size ? 0 : -1;
}

/* A NUL-terminated path in the task, read a page-bounded piece at a time. */
static int
read_path(task_t task, mach_vm_address_t address, char *path, size_t size)
{
	size_t done = 0;
	while (done + 1 < size) {
		size_t chunk = 4096 - (size_t)((address + done) & 4095);
		if (chunk > size - 1 - done)
			chunk = size - 1 - done;
		if (read_task(task, address + done, path + done, chunk) != 0)
			return -1;
		if (memchr(path + done, '\0', chunk))
			return 0;
		done += chunk;
	}
	path[size - 1] = '\0';
	return 0;
}

static bool addresses;

static void
list_process(pid_t pid)
{
	char program[PROC_PIDPATHINFO_MAXSIZE];
	if (proc_pidpath(pid, program, sizeof(program)) <= 0)
		return;
	task_read_t task = MACH_PORT_NULL;
	struct task_dyld_info dinfo;
	mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
	struct dyld_all_image_infos infos;
	if (task_read_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS ||
	    task_info(task, TASK_DYLD_INFO, (task_info_t)&dinfo, &count) != KERN_SUCCESS ||
	    read_task(task, dinfo.all_image_info_addr, &infos, sizeof(infos)) != 0) {
		printf("%d\t%s\t?\n", pid, program);
		if (task != MACH_PORT_NULL)
			mach_port_deallocate(mach_task_self(), task);
		return;
	}
	printf("%d\t%s\t%s\n", pid, program, program);
	struct dyld_image_info *images = calloc(infos.infoArrayCount, sizeof(*images));
	if (images && infos.infoArray &&
	    read_task(task, (mach_vm_address_t)infos.infoArray, images,
	        infos.infoArrayCount * sizeof(*images)) == 0) {
		for (uint32_t i = 0; i < infos.infoArrayCount; i++) {
			char path[PATH_MAX];
			if (images[i].imageFilePath &&
			    read_path(task, (mach_vm_address_t)images[i].imageFilePath, path, sizeof(path)) == 0 &&
			    strcmp(path, program) != 0) {
				if (addresses)
					printf("%d\t%s\t0x%llx %s\n", pid, program,
					    (unsigned long long)(uintptr_t)images[i].imageLoadAddress, path);
				else
					printf("%d\t%s\t%s\n", pid, program, path);
			}
		}
	}
	free(images);
	mach_port_deallocate(mach_task_self(), task);
}

struct loaded {
	uint64_t address;
	char path[PATH_MAX];
};

static int
by_address(const void *a, const void *b)
{
	const struct loaded *x = a, *y = b;
	return x->address < y->address ? -1 : x->address > y->address;
}

/* "image+offset" for an address: the loaded image starting at or below it. */
static void
print_frame(int n, uint64_t pc, const struct loaded *images, uint32_t count)
{
	const struct loaded *best = NULL;
	for (uint32_t i = 0; i < count && images[i].address <= pc; i++)
		best = &images[i];
	const char *name = best ? strrchr(best->path, '/') : NULL;
	if (best)
		printf("  %2d 0x%llx %s+0x%llx\n", n, (unsigned long long)pc, name ? name + 1 : best->path,
		    (unsigned long long)(pc - best->address));
	else
		printf("  %2d 0x%llx\n", n, (unsigned long long)pc);
}

static int
stack(pid_t pid)
{
	task_read_t task = MACH_PORT_NULL;
	struct task_dyld_info dinfo;
	mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
	struct dyld_all_image_infos infos;
	if (task_read_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS ||
	    task_info(task, TASK_DYLD_INFO, (task_info_t)&dinfo, &count) != KERN_SUCCESS ||
	    read_task(task, dinfo.all_image_info_addr, &infos, sizeof(infos)) != 0) {
		fprintf(stderr, "finch-images: can't read process %d\n", pid);
		return 1;
	}
	struct dyld_image_info *raw = calloc(infos.infoArrayCount, sizeof(*raw));
	struct loaded *images = calloc(infos.infoArrayCount + 1, sizeof(*images));
	uint32_t n = 0;
	if (raw && images && read_task(task, (mach_vm_address_t)infos.infoArray, raw, infos.infoArrayCount * sizeof(*raw)) == 0)
		for (uint32_t i = 0; i < infos.infoArrayCount; i++)
			if (raw[i].imageFilePath &&
			    read_path(task, (mach_vm_address_t)raw[i].imageFilePath, images[n].path, sizeof(images[n].path)) == 0)
				images[n++].address = (uint64_t)(uintptr_t)raw[i].imageLoadAddress;
	qsort(images, n, sizeof(*images), by_address);

	thread_act_array_t threads;
	mach_msg_type_number_t thread_count;
	if (task_threads(task, &threads, &thread_count) != KERN_SUCCESS) {
		fprintf(stderr, "finch-images: can't list process %d's threads\n", pid);
		return 1;
	}
	for (mach_msg_type_number_t t = 0; t < thread_count; t++) {
		arm_thread_state64_t state;
		mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
		printf("thread %u\n", t);
		if (thread_get_state(threads[t], ARM_THREAD_STATE64, (thread_state_t)&state, &sc) != KERN_SUCCESS) {
			printf("  (no state)\n");
			continue;
		}
		uint64_t pc = (uint64_t)ptrauth_strip((void *)arm_thread_state64_get_pc(state), ptrauth_key_asia);
		uint64_t lr = (uint64_t)ptrauth_strip((void *)arm_thread_state64_get_lr(state), ptrauth_key_asia);
		uint64_t fp = arm_thread_state64_get_fp(state);
		print_frame(0, pc, images, n);
		print_frame(1, lr, images, n);
		for (int depth = 2; fp && depth < 64; depth++) {
			uint64_t frame[2];
			if (read_task(task, fp, frame, sizeof(frame)) != 0 || frame[1] == 0)
				break;
			print_frame(depth, (uint64_t)ptrauth_strip((void *)frame[1], ptrauth_key_asia), images, n);
			if (frame[0] <= fp)
				break;
			fp = frame[0];
		}
	}
	return 0;
}

int
main(int argc, char **argv)
{
	if (argc == 3 && strcmp(argv[1], "--stack") == 0)
		return stack((pid_t)atoi(argv[2]));
	if (argc >= 2 && strcmp(argv[1], "--all") == 0) {
		addresses = argc == 3 && strcmp(argv[2], "--addresses") == 0;
		int n = proc_listallpids(NULL, 0);
		pid_t *pids = calloc((size_t)n + 64, sizeof(pid_t));
		n = proc_listallpids(pids, (int)(((size_t)n + 64) * sizeof(pid_t)));
		for (int i = 0; i < n; i++)
			if (pids[i] > 0)
				list_process(pids[i]);
		free(pids);
		return 0;
	}
	for (int i = 1; i < argc; i++) {
		if (dlopen(argv[i], RTLD_NOW) == NULL) {
			fprintf(stderr, "finch-images: %s\n", dlerror());
		}
	}
	for (uint32_t i = 0; i < _dyld_image_count(); i++) {
		printf("%s\n", _dyld_get_image_name(i));
	}
	return 0;
}
