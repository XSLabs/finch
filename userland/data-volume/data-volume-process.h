/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_DATA_VOLUME_PROCESS_H
#define FINCH_DATA_VOLUME_PROCESS_H

enum finch_dv_process_result {
	FINCH_DV_PROCESS_OK = 0,
	FINCH_DV_PROCESS_NONZERO,
	FINCH_DV_PROCESS_SIGNALED,
	FINCH_DV_PROCESS_TIMEOUT,
	FINCH_DV_PROCESS_REAP_TIMEOUT,
	FINCH_DV_PROCESS_SYSTEM_ERROR
};

enum finch_dv_process_result finch_dv_run_program(const char *path,
    char *const arguments[], unsigned int timeout_milliseconds);

#endif
