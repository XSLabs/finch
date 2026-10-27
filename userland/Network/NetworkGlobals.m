// SPDX-License-Identifier: MIT OR Apache-2.0
// The objects and blocks Network's header macros name: the well-known content contexts
// (made by CAPI.swift), the default-configuration and disable-protocol blocks (told apart
// by identity), idempotent sends and the default privacy context. Their headers declare
// them const; they are set once as the framework loads, so this file goes without them.
#import <Foundation/Foundation.h>
#import <stdbool.h>
#import <stdint.h>

extern void *finch_nw_well_known_context(int which);
extern void *finch_nw_default_privacy_context(void);

void *_nw_content_context_default_message;
void *_nw_content_context_final_send;
void *_nw_content_context_default_stream;
void *_nw_privacy_context_default_context;
const uint32_t _nw_data_transfer_report_all_paths = UINT32_MAX;

typedef void (^FinchNWOptionsBlock)(id options);
typedef void (^FinchNWErrorBlock)(id error);

const FinchNWOptionsBlock _nw_parameters_configure_protocol_default_configuration = ^(id options) { (void)options; };
const FinchNWOptionsBlock _nw_parameters_configure_protocol_disable = ^(id options) { (void)options; };
const FinchNWErrorBlock _nw_connection_send_idempotent_content = ^(id error) { (void)error; };

bool finch_nw_configure_is_disable(id block) { return block == (id)_nw_parameters_configure_protocol_disable; }
bool finch_nw_configure_is_default(id block) { return block == (id)_nw_parameters_configure_protocol_default_configuration; }
bool finch_nw_send_is_idempotent(id block) { return block == (id)_nw_connection_send_idempotent_content; }

__attribute__((constructor)) static void
finch_nw_make_well_known(void)
{
    _nw_content_context_default_message = finch_nw_well_known_context(0);
    _nw_content_context_final_send = finch_nw_well_known_context(1);
    _nw_content_context_default_stream = finch_nw_well_known_context(2);
    _nw_privacy_context_default_context = finch_nw_default_privacy_context();
}
