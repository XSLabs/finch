# Signal grants for notify registrations

**Status: design only.** This note describes a possible way to keep the old
`notify_register_signal` behavior after notifyd runs without root. It has not
been built or tested, and it does not close the other gaps in the non-root
notifyd plan.

## Grant only what the client asked for

The client must ask PID1 directly to create a grant. The request carries the
signal number and a fresh, ordinary Mach port made for this registration. It
must not carry a PID or audit token for PID1 to trust. PID1 reads the caller's
real audit token from the kernel-attached XPC message trailer, as
`bootstrapd` already does in [`bootstrapd.c`](../../userland/finch-init/bootstrapd.c#L267-L283).
It records that token, including the process version, with the one signal the
client requested. The kernel checks that the signal number is valid in
[`proc_info.c`](../../build/xnu-work/xnu/bsd/kern/proc_info.c#L3595-L3619).

The grant's port is the authority. Notifyd gets only its send right and sends
an empty trigger message. It cannot put a PID or signal in that message, and it
cannot ask PID1 to change the grant later. The helper gets the matching
receive right and trusted grant record from PID1 over a private control path.
The receiving port tells the helper which grant fired.

This changes the old server path. Today `notify_register_signal` sends the
signal number to notifyd, and notifyd stores it with the caller's audit data
([`notify_client.c`](../../build/src/Libnotify/notify_client.c#L3919-L3963),
[`notify_proc.c`](../../build/src/Libnotify/notifyd/notify_proc.c#L928-L965)).
Notifyd later calls `kill` with a PID
([`libnotify.c`](../../build/src/Libnotify/libnotify.c#L491-L498)). The grant
design replaces that free-standing PID-and-signal request with one right that
can trigger only the signal already bound to the caller.

## Keep the same right across a worker restart

PID1 keeps the grant record and a send right to every grant port. Before it
hands a receive right to the signal worker, it asks Mach to return that right
to PID1 if the worker destroys it. Finch's bootstrap server already does this
for service ports: it arms `MACH_NOTIFY_PORT_DESTROYED` before moving the
receive right, then uses the returned port name to find the same service
([`bootstrapd.c`](../../userland/finch-init/bootstrapd.c#L178-L210),
[`bootstrapd.c`](../../userland/finch-init/bootstrapd.c#L516-L550)). XNU defines
the notice as carrying the receive right
([`notify.defs`](../../build/xnu-work/xnu/osfmk/mach/notify.defs#L102-L108)),
and the normal anonymous port type allows this notice
([`ipc_policy.c`](../../build/xnu-work/xnu/osfmk/ipc/ipc_policy.c#L1519-L1528),
[`ipc_policy.c`](../../build/xnu-work/xnu/osfmk/ipc/ipc_policy.c#L1600-L1608)).
Use ordinary ports from `mach_port_allocate`; do not use a Mach service port
or a kernel object port.

When the worker exits, PID1 receives the same receive right and re-arms the
notice before passing it to a replacement worker. The port remains alive, so
messages that were still queued can wait for the replacement. Set a small
queue limit and cap the number of grants. The kernel queue has a hard upper
bound even for notification messages
([`ipc_mqueue.c`](../../build/xnu-work/xnu/osfmk/ipc/ipc_mqueue.c#L441-L470)).

This only covers a worker restart while PID1 remains alive. If notifyd exits,
its registrations and send rights go away. The signal worker must not rebuild
them from records supplied by a restarted notifyd. Recovering those
registrations needs a separate client re-registration or recovery protocol.

## Limit the privileged worker

The worker must be a small, separate process. It should accept triggers only
on the per-grant ports, use only the grant record delivered by PID1, and call
only the audit-token signal operation. It should have no request that accepts
an arbitrary PID, signal, shell command, or replacement grant. It should not
inherit unrelated file descriptors or start client callback threads.

The target audit token prevents PID reuse: XNU checks its embedded process
version when it looks up the target
([`kern_proc.c`](../../build/xnu-work/xnu/bsd/kern/kern_proc.c#L519-L546)).
The available API is `proc_signal_with_audittoken`
([`libproc.h`](../../build/xnu-work/xnu/libsyscall/wrappers/libproc/libproc.h#L130-L135),
[`libproc.c`](../../build/xnu-work/xnu/libsyscall/wrappers/libproc/libproc.c#L486-L495)).
But the kernel still checks the caller's signal rights. A non-root worker
cannot signal an unrelated user's process; XNU permits root to signal other
processes, except PID1 itself
([`kern_sig.c`](../../build/xnu-work/xnu/bsd/kern/kern_sig.c#L301-L350)).

So a root worker with a narrow message interface is only a first limit. The
existing signal syscall does not make its root authority specific to the
grant ports: compromised worker code could ask it to signal another process.
A real least-authority boundary needs a Finch kernel check that ties the
worker's signal request to an active grant, or another trusted component that
enforces that tie. Until then, this design must not be described as a fully
restricted root worker.

## Bound lifetime and resource use

PID1 should charge every grant to both the caller's effective user ID and the
caller's `(PID, process version)`. Set per-user and per-process limits, plus a
system-wide limit for live grants and queued triggers. This prevents one
client from filling PID1's records, worker state, or Mach queues.

Cancel must revoke one exact grant, not accept a target PID or signal from
notifyd. The client should ask PID1 directly to cancel, so PID1 can check the
canceling client's kernel audit token against the grant owner. PID1 marks the
grant closed; the worker stops new sends, drains any in-flight send, and
destroys the receive right. PID1 then gets that right back and drops both it
and its retained send right. Target exit must also remove its grants. PID1 can
watch the exact `(PID, process version)`; even before that cleanup runs, the
kernel's version check makes a stale grant fail instead of reaching a new
process that reused the PID.

Worker death has one unavoidable edge: it can receive a trigger, then die
before it sends the signal. That message is no longer queued when the receive
right comes back, so the signal may be lost. If it sends first and dies before
recording completion, a retry may send it twice. Traditional signals can
coalesce, but the design does not promise exactly-once delivery. Tests must
cover both crash points, cancellation during delivery, target exit and PID
reuse, per-owner limits, queued triggers during worker restart, and the
separate notifyd-restart case.

## Release boundary

This grant plan addresses only legacy signal delivery. The current notifyd
launch plist has no `UserName`
([`com.apple.notifyd.plist`](../../userland/LaunchDaemons/com.apple.notifyd.plist#L9-L19));
the reserved `_notifyd` account is only an account entry
([`master.passwd`](../../userland/release/etc/master.passwd#L3-L6)).
Running notifyd as that user still needs separate checks for shared memory,
bootstrap access, logging, path watches, sockets, and the rest of its sandbox.
