/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The messages between Security.framework's Authorization calls and authd
 * (userland/authd): XPC dictionaries with an operation and its arguments;
 * every reply carries AUTHD_KEY_STATUS, an OSStatus.
 */
#ifndef AUTHD_PROTOCOL_H
#define AUTHD_PROTOCOL_H

#define AUTHD_SERVICE "com.apple.authd"
#define AUTHD_TOKEN_SIZE 32	/* kAuthorizationExternalFormLength */

/* In every message both ways: a reply without it isn't Finch's authd (a
   macOS host's has the same service name). */
#define AUTHD_KEY_VERSION "finch-authd"
#define AUTHD_VERSION 1

#define AUTHD_KEY_OP "op"
#define AUTHD_KEY_STATUS "status"
#define AUTHD_KEY_TOKEN "token"		/* data, AUTHD_TOKEN_SIZE */
#define AUTHD_KEY_RIGHTS "rights"	/* array of right names */
#define AUTHD_KEY_ENVIRONMENT "environment"	/* dictionary: name -> data */
#define AUTHD_KEY_FLAGS "flags"		/* AuthorizationFlags */
#define AUTHD_KEY_DESTROY "destroy"
#define AUTHD_KEY_INFO "info"		/* dictionary: name -> data */
#define AUTHD_KEY_NAME "name"
#define AUTHD_KEY_DEFINITION "definition"	/* binary plist */
#define AUTHD_KEY_PATH "path"
#define AUTHD_KEY_ARGUMENTS "arguments"
#define AUTHD_KEY_PIPE "pipe"		/* fd */

#define AUTHD_OP_CREATE "create"		/* -> token */
#define AUTHD_OP_COPY_RIGHTS "copy-rights"	/* token, rights, environment, flags -> rights */
#define AUTHD_OP_FREE "free"			/* token, destroy */
#define AUTHD_OP_EXTERNAL "external"		/* token: does it exist? */
#define AUTHD_OP_COPY_INFO "copy-info"		/* token -> info */
#define AUTHD_OP_RIGHT_GET "right-get"		/* name -> definition */
#define AUTHD_OP_RIGHT_SET "right-set"		/* token, name, definition */
#define AUTHD_OP_RIGHT_REMOVE "right-remove"	/* token, name */
#define AUTHD_OP_EXECUTE "execute"		/* token, path, arguments -> pipe */

#endif /* AUTHD_PROTOCOL_H */
