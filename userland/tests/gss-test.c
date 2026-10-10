/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-gss-test: the GSS-API as an account without Kerberos tickets meets it, run
 * against Apple's GSS and Finch's to compare (tools/host-tests.sh): status text, names,
 * OIDs, sets, credentials and a context that can't be made. (Which mechanisms there are,
 * and the text of the minor status, are left out: Apple's has Kerberos.)
 */
#include <GSS/GSS.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

static void
status(const char *t, OM_uint32 major)
{
    OM_uint32 minor, ctx = 0;
    gss_buffer_desc b;
    gss_display_status(&minor, major, GSS_C_GSS_CODE, GSS_C_NO_OID, &ctx, &b);
    printf("%s: major %x '%.*s' more %u\n", t, major, (int)b.length, (char *)b.value, ctx);
    gss_release_buffer(&minor, &b);
}

int
main(void)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    Dl_info info;
    dladdr((void *)gss_import_name, &info);
    printf("%s\n", info.dli_fname);
    for (OM_uint32 r = 0; r <= 19; r++)
        status("routine", r << GSS_C_ROUTINE_ERROR_OFFSET);
    for (OM_uint32 c = 1; c <= 4; c++)
        status("calling", c << GSS_C_CALLING_ERROR_OFFSET);
    status("calling and routine", GSS_S_CALL_INACCESSIBLE_READ | GSS_S_BAD_NAME);
    for (OM_uint32 s = 0; s <= 5; s++)
        status("supplementary", 1u << s);
    status("supplementary 3", 3);
    status("supplementary with routine", GSS_S_CONTINUE_NEEDED | GSS_S_FAILURE);

    OM_uint32 major, minor;
    gss_name_t name = GSS_C_NO_NAME;
    gss_buffer_desc in = {strlen("HTTP@example.com"), "HTTP@example.com"};
    major = gss_import_name(&minor, &in, GSS_C_NT_HOSTBASED_SERVICE, &name);
    printf("import %x minor %u\n", major, minor);
    gss_buffer_desc out;
    gss_OID type;
    major = gss_display_name(&minor, name, &out, &type);
    gss_buffer_desc typeText = {0, NULL};
    if (type)
        gss_oid_to_str(&minor, type, &typeText);
    printf("display %x '%.*s' type '%.*s'\n", major, (int)out.length, (char *)out.value, (int)typeText.length,
           (char *)typeText.value);
    gss_release_buffer(&minor, &out);
    gss_release_buffer(&minor, &typeText);

    gss_name_t a, b, c;
    gss_buffer_desc u = {4, "user"}, v = {5, "other"};
    gss_import_name(&minor, &u, GSS_C_NT_USER_NAME, &a);
    gss_import_name(&minor, &u, GSS_C_NT_USER_NAME, &b);
    gss_import_name(&minor, &v, GSS_C_NT_USER_NAME, &c);
    int equal = -1;
    major = gss_compare_name(&minor, a, b, &equal);
    printf("compare same %x %d", major, equal);
    gss_compare_name(&minor, a, c, &equal);
    printf(", different %d\n", equal);
    gss_name_t d;
    major = gss_duplicate_name(&minor, a, &d);
    gss_compare_name(&minor, a, d, &equal);
    printf("duplicate %x equal %d\n", major, equal);
    gss_release_name(&minor, &a);
    gss_release_name(&minor, &b);
    gss_release_name(&minor, &c);
    gss_release_name(&minor, &d);
    printf("released %p\n", (void *)a);

    gss_OID oids[] = {GSS_C_NT_HOSTBASED_SERVICE, GSS_C_NT_USER_NAME, GSS_C_NT_EXPORT_NAME, GSS_KRB5_MECHANISM, GSS_SPNEGO_MECHANISM,
                      GSS_C_NT_ANONYMOUS, GSS_KRB5_NT_PRINCIPAL_NAME};
    for (size_t i = 0; i < sizeof oids / sizeof oids[0]; i++) {
        gss_buffer_desc s;
        gss_oid_to_str(&minor, oids[i], &s);
        printf("oid %u bytes: '%.*s'\n", oids[i]->length, (int)s.length, (char *)s.value);
        gss_release_buffer(&minor, &s);
    }
    gss_OID_set set;
    gss_create_empty_oid_set(&minor, &set);
    gss_add_oid_set_member(&minor, GSS_KRB5_MECHANISM, &set);
    gss_add_oid_set_member(&minor, GSS_SPNEGO_MECHANISM, &set);
    gss_add_oid_set_member(&minor, GSS_KRB5_MECHANISM, &set);
    int present = 0, absent = 1;
    gss_test_oid_set_member(&minor, GSS_SPNEGO_MECHANISM, set, &present);
    gss_test_oid_set_member(&minor, GSS_C_NT_USER_NAME, set, &absent);
    printf("oid set: %zu, spnego %d, user name %d\n", set->count, present, absent);
    gss_release_oid_set(&minor, &set);
    printf("released set %p\n", (void *)set);
    gss_buffer_set_t bs = GSS_C_NO_BUFFER_SET;
    gss_buffer_desc one = {3, "abc"};
    gss_add_buffer_set_member(&minor, &one, &bs);
    gss_add_buffer_set_member(&minor, &one, &bs);
    printf("buffer set: %zu '%.*s'\n", bs->count, (int)bs->elements[1].length, (char *)bs->elements[1].value);
    gss_release_buffer_set(&minor, &bs);

    gss_cred_id_t cred = GSS_C_NO_CREDENTIAL;
    major = gss_acquire_cred(&minor, GSS_C_NO_NAME, GSS_C_INDEFINITE, GSS_C_NO_OID_SET, GSS_C_INITIATE, &cred, NULL, NULL);
    printf("acquire %x cred %d\n", major, cred != GSS_C_NO_CREDENTIAL);
    gss_ctx_id_t ctx = GSS_C_NO_CONTEXT;
    gss_buffer_desc tok = {0, NULL};
    OM_uint32 flags = 0;
    major = gss_init_sec_context(&minor, GSS_C_NO_CREDENTIAL, &ctx, name, GSS_C_NO_OID, GSS_C_MUTUAL_FLAG, 0,
                                 GSS_C_NO_CHANNEL_BINDINGS, GSS_C_NO_BUFFER, NULL, &tok, &flags, NULL);
    printf("init %x context %p token %zu minor set %d\n", major, (void *)ctx, tok.length, minor != 0);
    major = gss_delete_sec_context(&minor, &ctx, GSS_C_NO_BUFFER);
    printf("delete %x\n", major);
    major = gss_release_cred(&minor, &cred);
    printf("release cred %x %p\n", major, (void *)cred);
    gss_release_name(&minor, &name);
    return 0;
}
