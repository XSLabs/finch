// SPDX-License-Identifier: MIT OR Apache-2.0
#include <sandbox.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <unistd.h>

typedef int (*sandbox_check_fn)(pid_t, const char *, int, ...);
typedef char *(*sandbox_extension_issue_file_fn)(const char *, const char *, unsigned int);
typedef int (*sandbox_extension_consume_fn)(const char *);
typedef int (*sandbox_extension_release_fn)(int);
typedef void *(*sandbox_create_params_fn)(void);
typedef int (*sandbox_set_param_fn)(void *, const char *, const char *);
typedef void (*sandbox_free_params_fn)(void *);
typedef void *(*sandbox_compile_string_fn)(const char *, void *, char **);
typedef void *(*sandbox_compile_file_fn)(const char *, void *, char **);
typedef void (*sandbox_free_profile_fn)(void *);

int main(void)
{
    Dl_info info = {0};
    if (dladdr((const void *)sandbox_init, &info) && info.dli_fname)
        puts(info.dli_fname);
    else puts("(libsandbox image unavailable)");

    char *error = NULL;
    int init = sandbox_init("finch-test-invalid-profile", SANDBOX_NAMED, &error);
    int hasError = error != NULL;
    sandbox_free_error(error);
    sandbox_check_fn check = (sandbox_check_fn)dlsym(RTLD_DEFAULT, "sandbox_check");
    sandbox_extension_issue_file_fn issueFile = (sandbox_extension_issue_file_fn)
        dlsym(RTLD_DEFAULT, "sandbox_extension_issue_file");
    sandbox_extension_consume_fn consume = (sandbox_extension_consume_fn)
        dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    sandbox_extension_release_fn releaseExtension = (sandbox_extension_release_fn)
        dlsym(RTLD_DEFAULT, "sandbox_extension_release");
    int checked = check ? check(getpid(), "file-read-data", 0) : -1;
    char *token = issueFile ? issueFile("com.apple.app-sandbox.read", "/etc/hosts", 0) : NULL;
    int handle = token && consume ? consume(token) : -1;
    int released = handle >= 0 && releaseExtension ? releaseExtension(handle) : -1;
    printf("init=%d error=%d check=%d token=%d consumed=%d released=%d\n",
        init, hasError, checked, token != NULL, handle >= 0, released == 0);
    free(token);

    sandbox_create_params_fn createParams =
        (sandbox_create_params_fn)dlsym(RTLD_DEFAULT, "sandbox_create_params");
    sandbox_set_param_fn setParam =
        (sandbox_set_param_fn)dlsym(RTLD_DEFAULT, "sandbox_set_param");
    sandbox_free_params_fn freeParams =
        (sandbox_free_params_fn)dlsym(RTLD_DEFAULT, "sandbox_free_params");
    sandbox_compile_string_fn compileString =
        (sandbox_compile_string_fn)dlsym(RTLD_DEFAULT, "sandbox_compile_string");
    sandbox_compile_file_fn compileFile =
        (sandbox_compile_file_fn)dlsym(RTLD_DEFAULT, "sandbox_compile_file");
    sandbox_free_profile_fn freeProfile =
        (sandbox_free_profile_fn)dlsym(RTLD_DEFAULT, "sandbox_free_profile");
    void *params = createParams ? createParams() : NULL;
    int set = params && setParam ? setParam(params, "FINCH_TEST", "yes") : -1;
    char *compileError = NULL;
    void *stringProfile = compileString ?
        compileString("(version 1) (allow", params, &compileError) : NULL;
    int stringError = compileError != NULL;
    if (stringProfile && freeProfile) freeProfile(stringProfile);
    sandbox_free_error(compileError);
    compileError = NULL;
    void *fileProfile = compileFile ?
        compileFile("/__finch_no_such_profile__", params, &compileError) : NULL;
    int fileError = compileError != NULL;
    if (fileProfile && freeProfile) freeProfile(fileProfile);
    sandbox_free_error(compileError);
    if (freeParams) freeParams(params);
    printf("params=%d set=%d string=%d stringError=%d file=%d fileError=%d\n",
        params != NULL, set, stringProfile != NULL, stringError, fileProfile != NULL, fileError);
    return 0;
}
