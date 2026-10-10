/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * GSS.framework, Finch's: the GSS-API (RFC 2743/2744). Finch has no Kerberos yet, so
 * it's GSS-API as a Mac without tickets answers: names, OIDs, buffers and sets work;
 * no mechanism is available, credentials are granted lazily (as Apple's are) and a
 * security context can't be established ("no credential"); per-message calls have no
 * context to use. Status text is composed as Apple's (Heimdal's) is.
 */
#include <GSS/GSS.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* (Heimdal's minor status for "no credential": what Apple's answers without tickets) */
#define MINOR_NO_CREDENTIAL 2529639053u

struct gss_name_t_desc_struct {
    gss_buffer_desc value;
    gss_OID_desc type;
};

struct gss_cred_id_t_desc_struct {
    int empty;
};

static int
copy_buffer(const void *data, size_t length, gss_buffer_t out)
{
    out->value = malloc(length + 1);
    if (!out->value) {
        out->length = 0;
        return 0;
    }
    memcpy(out->value, data, length);
    ((char *)out->value)[length] = 0;
    out->length = length;
    return 1;
}

static int
copy_oid(const gss_OID_desc *in, gss_OID_desc *out)
{
    out->length = in ? in->length : 0;
    out->elements = NULL;
    if (in && in->length) {
        out->elements = malloc(in->length);
        if (!out->elements)
            return 0;
        memcpy(out->elements, in->elements, in->length);
    }
    return 1;
}

static int
same_oid(const gss_OID_desc *a, const gss_OID_desc *b)
{
    if (!a || !b)
        return a == b;
    return a->length == b->length && !memcmp(a->elements, b->elements, a->length);
}

#define MINOR(v) \
    do {         \
        if (minor_status) \
            *minor_status = (v); \
    } while (0)

/* --- status text --- */

static const char *
calling_error(OM_uint32 v)
{
    static const char *const msgs[] = {"", "A required input parameter could not be read.",
                                       "A required output parameter could not be written.", "A parameter was malformed"};
    v >>= GSS_C_CALLING_ERROR_OFFSET;
    return v < sizeof msgs / sizeof msgs[0] ? msgs[v] : "unknown calling error";
}

static const char *
routine_error(OM_uint32 v)
{
    static const char *const msgs[] = {
        "Function completed successfully",
        "An unsupported mechanism was requested",
        "An invalid name was supplied",
        "A supplied name was of an unsupported type",
        "Incorrect channel bindings were supplied",
        "An invalid status code was supplied",
        "A token had an invalid MIC",
        "No credentials were supplied, or the credentials were unavailable or inaccessible.",
        "No context has been established",
        "A token was invalid",
        "A credential was invalid",
        "The referenced credentials have expired",
        "The context has expired",
        "Miscellaneous failure (see text)",
        "The quality-of-protection requested could not be provide",
        "The operation is forbidden by local security policy",
        "The operation or option is not available",
        "The requested credential element already exists",
        "The provided name was not a mechanism name.",
    };
    v >>= GSS_C_ROUTINE_ERROR_OFFSET;
    return v < sizeof msgs / sizeof msgs[0] ? msgs[v] : "unknown routine error";
}

/* (indexed by the supplementary value itself, as Heimdal's is) */
static const char *
supplementary_error(OM_uint32 v)
{
    static const char *const msgs[] = {"normal completion",
                                       "continuation call to routine required",
                                       "duplicate per-message token detected",
                                       "timed-out per-message token detected",
                                       "reordered (early) per-message token detected",
                                       "skipped predecessor token(s) detected"};
    v >>= GSS_C_SUPPLEMENTARY_OFFSET;
    return v < sizeof msgs / sizeof msgs[0] ? msgs[v] : "unknown routine error";
}

OM_uint32
gss_display_status(OM_uint32 *minor_status, OM_uint32 status_value, int status_type, const gss_OID mech_type,
                   OM_uint32 *message_context, gss_buffer_t status_string)
{
    MINOR(0);
    if (message_context)
        *message_context = 0;
    if (!status_string)
        return GSS_S_CALL_INACCESSIBLE_WRITE;
    char *text = NULL;
    if (status_type == GSS_C_GSS_CODE) {
        if (GSS_SUPPLEMENTARY_INFO(status_value))
            asprintf(&text, "%s", supplementary_error(GSS_SUPPLEMENTARY_INFO(status_value)));
        else
            asprintf(&text, "%s %s", calling_error(GSS_CALLING_ERROR(status_value)), routine_error(GSS_ROUTINE_ERROR(status_value)));
    } else if (status_type == GSS_C_MECH_CODE) {
        if (status_value == MINOR_NO_CREDENTIAL)
            asprintf(&text, "no credential");
        else
            asprintf(&text, "unknown mech-code %u", status_value);
    } else {
        status_string->length = 0;
        status_string->value = NULL;
        return GSS_S_BAD_STATUS;
    }
    if (!text || !copy_buffer(text, strlen(text), status_string)) {
        free(text);
        return GSS_S_FAILURE;
    }
    free(text);
    return GSS_S_COMPLETE;
}

/* --- buffers, OIDs, sets --- */

OM_uint32
gss_release_buffer(OM_uint32 *minor_status, gss_buffer_t buffer)
{
    MINOR(0);
    if (buffer) {
        free(buffer->value);
        buffer->value = NULL;
        buffer->length = 0;
    }
    return GSS_S_COMPLETE;
}

OM_uint32
gss_create_empty_oid_set(OM_uint32 *minor_status, gss_OID_set *oid_set)
{
    MINOR(0);
    *oid_set = calloc(1, sizeof **oid_set);
    return *oid_set ? GSS_S_COMPLETE : GSS_S_FAILURE;
}

OM_uint32
gss_test_oid_set_member(OM_uint32 *minor_status, gss_const_OID member, const gss_OID_set set, int *present)
{
    MINOR(0);
    *present = 0;
    for (size_t i = 0; set && i < set->count; i++)
        if (same_oid(&set->elements[i], member))
            *present = 1;
    return GSS_S_COMPLETE;
}

OM_uint32
gss_add_oid_set_member(OM_uint32 *minor_status, gss_const_OID member_oid, gss_OID_set *oid_set)
{
    MINOR(0);
    int present = 0;
    gss_test_oid_set_member(minor_status, member_oid, *oid_set, &present);
    if (present)
        return GSS_S_COMPLETE;
    gss_OID_set s = *oid_set;
    gss_OID e = realloc(s->elements, (s->count + 1) * sizeof *e);
    if (!e)
        return GSS_S_FAILURE;
    s->elements = e;
    if (!copy_oid(member_oid, &s->elements[s->count]))
        return GSS_S_FAILURE;
    s->count++;
    return GSS_S_COMPLETE;
}

OM_uint32
gss_release_oid_set(OM_uint32 *minor_status, gss_OID_set *set)
{
    MINOR(0);
    if (set && *set) {
        for (size_t i = 0; i < (*set)->count; i++)
            free((*set)->elements[i].elements);
        free((*set)->elements);
        free(*set);
        *set = GSS_C_NO_OID_SET;
    }
    return GSS_S_COMPLETE;
}

OM_uint32
gss_duplicate_oid(OM_uint32 *minor_status, gss_OID src_oid, gss_OID *dest_oid)
{
    MINOR(0);
    if (!src_oid) {
        *dest_oid = GSS_C_NO_OID;
        return GSS_S_COMPLETE;
    }
    *dest_oid = malloc(sizeof **dest_oid);
    if (!*dest_oid || !copy_oid(src_oid, *dest_oid))
        return GSS_S_FAILURE;
    return GSS_S_COMPLETE;
}

OM_uint32
gss_release_oid(OM_uint32 *minor_status, gss_OID *oid)
{
    MINOR(0);
    /* (the library's own OIDs aren't released: only those duplicated) */
    if (oid && *oid) {
        free((*oid)->elements);
        free(*oid);
        *oid = GSS_C_NO_OID;
    }
    return GSS_S_COMPLETE;
}

/* "1 2 840 113554 1 2 1 4", as Apple's writes it */
OM_uint32
gss_oid_to_str(OM_uint32 *minor_status, gss_OID oid, gss_buffer_t oid_str)
{
    MINOR(0);
    if (!oid || !oid->length)
        return GSS_S_FAILURE;
    char text[512] = "";
    const unsigned char *b = oid->elements;
    unsigned first = b[0] / 40 > 2 ? 2 : b[0] / 40;
    snprintf(text, sizeof text, "%u %u", first, b[0] - first * 40);
    unsigned long long v = 0;
    for (OM_uint32 i = 1; i < oid->length; i++) {
        v = (v << 7) | (b[i] & 0x7f);
        if (!(b[i] & 0x80)) {
            size_t n = strlen(text);
            snprintf(text + n, sizeof text - n, " %llu", v);
            v = 0;
        }
    }
    return copy_buffer(text, strlen(text), oid_str) ? GSS_S_COMPLETE : GSS_S_FAILURE;
}

OM_uint32
gss_create_empty_buffer_set(OM_uint32 *minor_status, gss_buffer_set_t *buffer_set)
{
    MINOR(0);
    *buffer_set = calloc(1, sizeof **buffer_set);
    return *buffer_set ? GSS_S_COMPLETE : GSS_S_FAILURE;
}

OM_uint32
gss_add_buffer_set_member(OM_uint32 *minor_status, const gss_buffer_t member_buffer, gss_buffer_set_t *buffer_set)
{
    MINOR(0);
    if (!*buffer_set && gss_create_empty_buffer_set(minor_status, buffer_set))
        return GSS_S_FAILURE;
    gss_buffer_set_t s = *buffer_set;
    gss_buffer_t e = realloc(s->elements, (s->count + 1) * sizeof *e);
    if (!e)
        return GSS_S_FAILURE;
    s->elements = e;
    if (!copy_buffer(member_buffer->value, member_buffer->length, &s->elements[s->count]))
        return GSS_S_FAILURE;
    s->count++;
    return GSS_S_COMPLETE;
}

OM_uint32
gss_release_buffer_set(OM_uint32 *minor_status, gss_buffer_set_t *buffer_set)
{
    MINOR(0);
    if (buffer_set && *buffer_set) {
        for (size_t i = 0; i < (*buffer_set)->count; i++)
            free((*buffer_set)->elements[i].value);
        free((*buffer_set)->elements);
        free(*buffer_set);
        *buffer_set = GSS_C_NO_BUFFER_SET;
    }
    return GSS_S_COMPLETE;
}

/* --- names --- */

OM_uint32
gss_import_name(OM_uint32 *minor_status, const gss_buffer_t input_name_buffer, gss_const_OID input_name_type,
                gss_name_t *output_name)
{
    MINOR(0);
    if (!output_name)
        return GSS_S_CALL_INACCESSIBLE_WRITE;
    *output_name = GSS_C_NO_NAME;
    if (!input_name_buffer)
        return GSS_S_CALL_INACCESSIBLE_READ | GSS_S_BAD_NAME;
    gss_name_t n = calloc(1, sizeof *n);
    if (!n || !copy_buffer(input_name_buffer->value, input_name_buffer->length, &n->value) ||
        !copy_oid(input_name_type, &n->type)) {
        free(n);
        return GSS_S_FAILURE;
    }
    *output_name = n;
    return GSS_S_COMPLETE;
}

OM_uint32
gss_release_name(OM_uint32 *minor_status, gss_name_t *input_name)
{
    MINOR(0);
    if (input_name && *input_name) {
        free((*input_name)->value.value);
        free((*input_name)->type.elements);
        free(*input_name);
        *input_name = GSS_C_NO_NAME;
    }
    return GSS_S_COMPLETE;
}

OM_uint32
gss_display_name(OM_uint32 *minor_status, const gss_name_t input_name, gss_buffer_t output_name_buffer,
                 gss_OID *output_name_type)
{
    MINOR(0);
    if (!input_name)
        return GSS_S_BAD_NAME;
    if (!copy_buffer(input_name->value.value, input_name->value.length, output_name_buffer))
        return GSS_S_FAILURE;
    if (output_name_type)
        *output_name_type = input_name->type.length ? &input_name->type : GSS_C_NO_OID;
    return GSS_S_COMPLETE;
}

OM_uint32
gss_compare_name(OM_uint32 *minor_status, const gss_name_t name1, const gss_name_t name2, int *name_equal)
{
    MINOR(0);
    if (!name1 || !name2)
        return GSS_S_BAD_NAME;
    *name_equal = name1->value.length == name2->value.length &&
                  !memcmp(name1->value.value, name2->value.value, name1->value.length) &&
                  (!name1->type.length || !name2->type.length || same_oid(&name1->type, &name2->type));
    return GSS_S_COMPLETE;
}

OM_uint32
gss_duplicate_name(OM_uint32 *minor_status, const gss_name_t src_name, gss_name_t *dest_name)
{
    if (!src_name)
        return GSS_S_BAD_NAME;
    return gss_import_name(minor_status, (gss_buffer_t)&src_name->value, src_name->type.length ? (gss_OID)&src_name->type : NULL,
                           dest_name);
}

/* A mechanism name needs a mechanism: there's none to make one. */
OM_uint32
gss_canonicalize_name(OM_uint32 *minor_status, const gss_name_t input_name, const gss_OID mech_type, gss_name_t *output_name)
{
    MINOR(0);
    if (output_name)
        *output_name = GSS_C_NO_NAME;
    return GSS_S_BAD_MECH;
}

OM_uint32
gss_export_name(OM_uint32 *minor_status, const gss_name_t input_name, gss_buffer_t exported_name)
{
    MINOR(0);
    if (exported_name)
        exported_name->length = 0, exported_name->value = NULL;
    return GSS_S_NAME_NOT_MN;
}

OM_uint32
gss_inquire_mechs_for_name(OM_uint32 *minor_status, const gss_name_t input_name, gss_OID_set *mech_types)
{
    return gss_create_empty_oid_set(minor_status, mech_types);
}

OM_uint32
gss_inquire_names_for_mech(OM_uint32 *minor_status, gss_const_OID mechanism, gss_OID_set *name_types)
{
    MINOR(0);
    if (name_types)
        *name_types = GSS_C_NO_OID_SET;
    return GSS_S_BAD_MECH;
}

/* --- mechanisms: none --- */

OM_uint32
gss_indicate_mechs(OM_uint32 *minor_status, gss_OID_set *mech_set)
{
    return gss_create_empty_oid_set(minor_status, mech_set);
}

/* --- credentials: granted, empty (tickets are looked for when a context is made) --- */

static struct gss_cred_id_t_desc_struct empty_cred;

OM_uint32
gss_acquire_cred(OM_uint32 *minor_status, const gss_name_t desired_name, OM_uint32 time_req, const gss_OID_set desired_mechs,
                 gss_cred_usage_t cred_usage, gss_cred_id_t *output_cred_handle, gss_OID_set *actual_mechs, OM_uint32 *time_rec)
{
    MINOR(0);
    if (output_cred_handle)
        *output_cred_handle = &empty_cred;
    if (actual_mechs)
        gss_create_empty_oid_set(minor_status, actual_mechs);
    if (time_rec)
        *time_rec = GSS_C_INDEFINITE;
    return GSS_S_COMPLETE;
}

OM_uint32
gss_acquire_cred_with_password(OM_uint32 *minor_status, const gss_name_t desired_name, const gss_buffer_t password,
                               OM_uint32 time_req, const gss_OID_set desired_mechs, gss_cred_usage_t cred_usage,
                               gss_cred_id_t *output_cred_handle, gss_OID_set *actual_mechs, OM_uint32 *time_rec)
{
    MINOR(MINOR_NO_CREDENTIAL);
    if (output_cred_handle)
        *output_cred_handle = GSS_C_NO_CREDENTIAL;
    return GSS_S_BAD_MECH;
}

OM_uint32
gss_add_cred(OM_uint32 *minor_status, const gss_cred_id_t input_cred_handle, const gss_name_t desired_name,
             const gss_OID desired_mech, gss_cred_usage_t cred_usage, OM_uint32 initiator_time_req, OM_uint32 acceptor_time_req,
             gss_cred_id_t *output_cred_handle, gss_OID_set *actual_mechs, OM_uint32 *initiator_time_rec,
             OM_uint32 *acceptor_time_rec)
{
    MINOR(0);
    if (output_cred_handle)
        *output_cred_handle = GSS_C_NO_CREDENTIAL;
    return GSS_S_BAD_MECH;
}

OM_uint32
gss_release_cred(OM_uint32 *minor_status, gss_cred_id_t *cred_handle)
{
    MINOR(0);
    if (cred_handle)
        *cred_handle = GSS_C_NO_CREDENTIAL;
    return GSS_S_COMPLETE;
}

OM_uint32
gss_inquire_cred(OM_uint32 *minor_status, const gss_cred_id_t cred_handle, gss_name_t *name, OM_uint32 *lifetime,
                 gss_cred_usage_t *cred_usage, gss_OID_set *mechanisms)
{
    MINOR(MINOR_NO_CREDENTIAL);
    if (name)
        *name = GSS_C_NO_NAME;
    if (mechanisms)
        *mechanisms = GSS_C_NO_OID_SET;
    return GSS_S_NO_CRED;
}

OM_uint32
gss_inquire_cred_by_mech(OM_uint32 *minor_status, const gss_cred_id_t cred_handle, const gss_OID mech_type, gss_name_t *name,
                         OM_uint32 *initiator_lifetime, OM_uint32 *acceptor_lifetime, gss_cred_usage_t *cred_usage)
{
    MINOR(MINOR_NO_CREDENTIAL);
    if (name)
        *name = GSS_C_NO_NAME;
    return GSS_S_NO_CRED;
}

/* --- contexts: none can be made --- */

OM_uint32
gss_init_sec_context(OM_uint32 *minor_status, const gss_cred_id_t initiator_cred_handle, gss_ctx_id_t *context_handle,
                     const gss_name_t target_name, const gss_OID mech_type, OM_uint32 req_flags, OM_uint32 time_req,
                     const gss_channel_bindings_t input_chan_bindings, const gss_buffer_t input_token, gss_OID *actual_mech_type,
                     gss_buffer_t output_token, OM_uint32 *ret_flags, OM_uint32 *time_rec)
{
    MINOR(MINOR_NO_CREDENTIAL);
    if (output_token)
        output_token->length = 0, output_token->value = NULL;
    if (actual_mech_type)
        *actual_mech_type = GSS_C_NO_OID;
    if (ret_flags)
        *ret_flags = 0;
    if (time_rec)
        *time_rec = 0;
    if (!target_name)
        return GSS_S_BAD_NAME;
    return GSS_S_FAILURE;
}

OM_uint32
gss_accept_sec_context(OM_uint32 *minor_status, gss_ctx_id_t *context_handle, const gss_cred_id_t acceptor_cred_handle,
                       const gss_buffer_t input_token_buffer, const gss_channel_bindings_t input_chan_bindings,
                       gss_name_t *src_name, gss_OID *mech_type, gss_buffer_t output_token, OM_uint32 *ret_flags,
                       OM_uint32 *time_rec, gss_cred_id_t *delegated_cred_handle)
{
    MINOR(MINOR_NO_CREDENTIAL);
    if (src_name)
        *src_name = GSS_C_NO_NAME;
    if (output_token)
        output_token->length = 0, output_token->value = NULL;
    if (delegated_cred_handle)
        *delegated_cred_handle = GSS_C_NO_CREDENTIAL;
    return GSS_S_NO_CRED;
}

OM_uint32
gss_delete_sec_context(OM_uint32 *minor_status, gss_ctx_id_t *context_handle, gss_buffer_t output_token)
{
    MINOR(0);
    if (context_handle)
        *context_handle = GSS_C_NO_CONTEXT;
    if (output_token)
        output_token->length = 0, output_token->value = NULL;
    return GSS_S_COMPLETE;
}

#define NO_CONTEXT(decl)            \
    OM_uint32 decl                  \
    {                               \
        MINOR(0);                   \
        return GSS_S_NO_CONTEXT;    \
    }
NO_CONTEXT(gss_process_context_token(OM_uint32 *minor_status, const gss_ctx_id_t context_handle, const gss_buffer_t token_buffer))
NO_CONTEXT(gss_context_time(OM_uint32 *minor_status, const gss_ctx_id_t context_handle, OM_uint32 *time_rec))
NO_CONTEXT(gss_get_mic(OM_uint32 *minor_status, const gss_ctx_id_t context_handle, gss_qop_t qop_req, const gss_buffer_t message_buffer,
                       gss_buffer_t message_token))
NO_CONTEXT(gss_verify_mic(OM_uint32 *minor_status, const gss_ctx_id_t context_handle, const gss_buffer_t message_buffer,
                          const gss_buffer_t token_buffer, gss_qop_t *qop_state))
NO_CONTEXT(gss_wrap(OM_uint32 *minor_status, const gss_ctx_id_t context_handle, int conf_req_flag, gss_qop_t qop_req,
                    const gss_buffer_t input_message_buffer, int *conf_state, gss_buffer_t output_message_buffer))
NO_CONTEXT(gss_unwrap(OM_uint32 *minor_status, const gss_ctx_id_t context_handle, const gss_buffer_t input_message_buffer,
                      gss_buffer_t output_message_buffer, int *conf_state, gss_qop_t *qop_state))
NO_CONTEXT(gss_wrap_size_limit(OM_uint32 *minor_status, const gss_ctx_id_t context_handle, int conf_req_flag, gss_qop_t qop_req,
                               OM_uint32 req_output_size, OM_uint32 *max_input_size))
NO_CONTEXT(gss_inquire_context(OM_uint32 *minor_status, const gss_ctx_id_t context_handle, gss_name_t *src_name, gss_name_t *targ_name,
                               OM_uint32 *lifetime_rec, gss_OID *mech_type, OM_uint32 *ctx_flags, int *locally_initiated, int *open_context))
NO_CONTEXT(gss_export_sec_context(OM_uint32 *minor_status, gss_ctx_id_t *context_handle, gss_buffer_t interprocess_token))
NO_CONTEXT(gss_import_sec_context(OM_uint32 *minor_status, const gss_buffer_t interprocess_token, gss_ctx_id_t *context_handle))
NO_CONTEXT(gss_pseudo_random(OM_uint32 *minor_status, gss_ctx_id_t context, int prf_key, const gss_buffer_t prf_in,
                             ssize_t desired_output_len, gss_buffer_t prf_out))
NO_CONTEXT(gss_inquire_sec_context_by_oid(OM_uint32 *minor_status, const gss_ctx_id_t context_handle, const gss_OID desired_object,
                                          gss_buffer_set_t *data_set))
NO_CONTEXT(gss_set_sec_context_option(OM_uint32 *minor_status, gss_ctx_id_t *context_handle, const gss_OID object,
                                      const gss_buffer_t value))

/* (the RFC 1964 names for the same calls) */
OM_uint32 gss_sign(OM_uint32 *minor_status, gss_ctx_id_t context_handle, int qop_req, gss_buffer_t message_buffer, gss_buffer_t message_token)
{
    return gss_get_mic(minor_status, context_handle, (gss_qop_t)qop_req, message_buffer, message_token);
}
OM_uint32 gss_verify(OM_uint32 *minor_status, gss_ctx_id_t context_handle, gss_buffer_t message_buffer, gss_buffer_t token_buffer, int *qop_state)
{
    return gss_verify_mic(minor_status, context_handle, message_buffer, token_buffer, (gss_qop_t *)qop_state);
}
OM_uint32 gss_seal(OM_uint32 *minor_status, gss_ctx_id_t context_handle, int conf_req_flag, int qop_req, gss_buffer_t input_message_buffer,
                   int *conf_state, gss_buffer_t output_message_buffer)
{
    return gss_wrap(minor_status, context_handle, conf_req_flag, (gss_qop_t)qop_req, input_message_buffer, conf_state, output_message_buffer);
}
OM_uint32 gss_unseal(OM_uint32 *minor_status, gss_ctx_id_t context_handle, gss_buffer_t input_message_buffer, gss_buffer_t output_message_buffer,
                     int *conf_state, int *qop_state)
{
    return gss_unwrap(minor_status, context_handle, input_message_buffer, output_message_buffer, conf_state, (gss_qop_t *)qop_state);
}
