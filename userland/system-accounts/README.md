# Finch system account merge

This small helper adds Finch's locked `_notifyd` user and group to an offline
system image. It reads the account row from a trusted template, checks the
whole set of account names and IDs, and refuses to overwrite a different user
or group. It also rebuilds public `passwd` from `master.passwd`, with password
hashes removed.

An updater can load a plan from the new image before it copies the old
`master.passwd`, `group`, and `passwd` files over that image. After that copy,
it can apply the saved plan to the staged image. The plan holds only the
`_notifyd` row and IDs; it does not hold or copy the source password database.
The optional loader lets old payloads pass when the account directory is
missing or when no present account file has an `_notifyd` row. It still rejects
a partial account or malformed file. The command-line tool uses the strict
loader and requires `_notifyd` in its template.

The target must be a separate, disposable staging directory. The helper swaps
files one at a time, so a power loss or write error can leave that staging
copy partly changed. If that happens, discard the staging copy and keep the
active system. The helper rejects paths with symlinks, unsafe file modes,
ownership it cannot keep, and macOS mounts that ignore file ownership. Do not
run it against a live account directory or a no-owners mount.

The template must give `_notifyd` a user ID and group ID from 2 through 499.
The helper rejects root, nobody, and IDs outside that reserved system range.

Run the host checks with:

```sh
make -C userland/system-accounts test
```

Build artifacts go under `/private/tmp/finch-system-accounts` by default.
