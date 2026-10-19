# Account file storage

Default account writers read `/private/etc/finch/account-store`. The file must
be a root-owned regular file with no group or other write access. Its parent
folders must also be root-owned and must not allow group or other writes. The
file must contain one absolute path, followed by a newline. For the VM data
volume, that path can be `/private/var/rw/accounts`.

The account folder must already exist and pass the account tool's ownership,
permission, and no-symlink checks. The account tools do not create the folder,
seed account files, or copy changes back into `/private/etc`.

If the setting file or its parent folder is absent, default writers use
`/private/etc` for older images. A present setting that is linked, writable,
malformed, or unsafe makes the operation fail. `accountctl -d` still writes to
the exact folder named on the command line, which keeps staged and offline
account edits explicit.
