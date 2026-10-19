# Finch data-volume helper

`finch-data-volume` checks for Finch's one configured APFS data volume and
mounts it at `/private/var/rw`. Run it before the boot script creates or changes
anything under `/private/var/rw`, `/Users`, or `/private/var/db`.

The helper reads one UUID line from `/private/etc/finch/data-volume`. The file
and its parent folders must be real, root-owned folders or files with no group
or other write access. The UUID must name exactly one registered
`AppleAPFSVolume` attached below `AppleVirtIOBlockStorageDevice`. The helper
checks that the registry BSD name is a disk partition, then verifies the block
and raw device nodes before it uses them.

Before mounting, it runs `fsck_apfs -n -W` against the raw device. `-n` keeps
the check read-only, and a failed check stops startup. It then mounts the
volume read-only and checks its source, APFS type, mount flags, UUID, and
pre-created layout. If those checks pass, it unmounts the volume and mounts it
again for normal read-write use. It checks the source, flags, UUID, and layout
again. Any failed check after a new mount triggers an unmount attempt. Filesystem
checks have a two-minute limit; mount and unmount commands have a 30-second
limit. On timeout, the helper kills only the command it started and waits up to
one second for it to stop.

The volume root and its `accounts`, `Users`, `db`, and `root` folders must be
pre-created, root-owned, and on that same volume. The three account files must
be regular root-owned files with one link each: `master.passwd` mode `0600`,
and `passwd` and `group` mode `0644`.

The helper never formats or repairs a disk, creates the mount folder, seeds
account files, or fills in missing directories. Its final mount is read-write
so Finch can use the prepared data. Set up the data volume and UUID setting as
an explicit image-preparation step. The image builder must preserve uid and
gid 0 on the setting file and its parent folders.

Build the helper with `make -C userland/data-volume`. Run its policy checks
with `make -C userland/data-volume test`. The build places the signed helper in
`build/root/usr/sbin/finch-data-volume`; the boot image must include it and
trust its code hash before Finch calls `/usr/sbin/finch-data-volume`.
