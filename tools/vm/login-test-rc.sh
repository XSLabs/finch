#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
# Test-image rc wrapper. The ordinary VM image keeps its normal rc and login.

/bin/sh /usr/local/share/finch/login-test/standard-rc || exit 1

finch_login_test_boot_args=$(/usr/sbin/sysctl -n kern.bootargs 2>/dev/null) || {
    echo "login-test rc: could not read boot arguments"
    exit 1
}
case " $finch_login_test_boot_args " in
    *" finch_login_test=1 "*) ;;
    *) exit 0 ;;
esac

set -eu
finch_login_test_fixture=/usr/local/share/finch/login-test

for finch_login_test_path in \
    "$finch_login_test_fixture/etc" \
    "$finch_login_test_fixture/etc/pam.d" \
    "$finch_login_test_fixture/etc/pam.d/login" \
    "$finch_login_test_fixture/account-fixture" \
    "$finch_login_test_fixture/account-fixture/master.passwd" \
    "$finch_login_test_fixture/account-fixture/group" \
    "$finch_login_test_fixture/pam" \
    "$finch_login_test_fixture/pam/pam_unix.so.2" \
    "$finch_login_test_fixture/pam/pam_nologin.so.2" \
    "$finch_login_test_fixture/pam/pam_launchd.so.2" \
    "$finch_login_test_fixture/pam/pam_uwtmp.so.2"; do
    if [ ! -e "$finch_login_test_path" ] || [ -L "$finch_login_test_path" ]; then
        echo "login-test rc: missing or unsafe fixture path $finch_login_test_path"
        exit 1
    fi
done

# Both mounts must succeed before anything is copied into these paths.
/sbin/mount_tmpfs /private/etc || {
    echo "login-test rc: could not mount account files"
    exit 1
}
/sbin/mount_tmpfs /usr/lib/pam || {
    echo "login-test rc: could not mount PAM modules"
    exit 1
}

finch_login_test_mounts=$(/sbin/mount) || exit 1
finch_login_test_check_mount() {
    finch_login_test_mount=$1
    if ! printf '%s\n' "$finch_login_test_mounts" |
        grep -Fq " on $finch_login_test_mount (tmpfs,"; then
        echo "login-test rc: expected tmpfs mount is missing: $finch_login_test_mount"
        exit 1
    fi
    if printf '%s\n' "$finch_login_test_mounts" |
        grep -F " on $finch_login_test_mount (tmpfs," |
        grep -Eq ', union(,|\))'; then
        echo "login-test rc: union mount is not allowed: $finch_login_test_mount"
        exit 1
    fi
}
finch_login_test_check_mount /private/etc
finch_login_test_check_mount /usr/lib/pam

cp -RNp "$finch_login_test_fixture/etc/." /private/etc/ || exit 1
cp -RNp "$finch_login_test_fixture/pam/." /usr/lib/pam/ || exit 1

for finch_login_test_path in \
    /private/etc/master.passwd \
    /private/etc/passwd \
    /private/etc/group; do
    if [ -e "$finch_login_test_path" ] || [ -L "$finch_login_test_path" ]; then
        echo "login-test rc: account tmpfs already contains $finch_login_test_path"
        exit 1
    fi
done
cp -Np "$finch_login_test_fixture/account-fixture/master.passwd" \
    /private/etc/master.passwd || exit 1
cp -Np "$finch_login_test_fixture/account-fixture/group" \
    /private/etc/group || exit 1

finch_login_test_read_account_record() {
    IFS=: read -r finch_login_test_name finch_login_test_password \
        finch_login_test_uid finch_login_test_gid finch_login_test_class \
        finch_login_test_change finch_login_test_expire finch_login_test_gecos \
        finch_login_test_home finch_login_test_shell <<EOF
$1
EOF
}

finch_login_test_account_valid=1
finch_login_test_account_seen=0
while IFS= read -r finch_login_test_account_line; do
    case "$finch_login_test_account_line" in
        \#*) continue ;;
    esac
    finch_login_test_read_account_record "$finch_login_test_account_line"
    case "$finch_login_test_shell" in
        *:*) finch_login_test_account_valid=0 ;;
    esac
    if [ "$finch_login_test_account_line" != \
        "$finch_login_test_name:$finch_login_test_password:$finch_login_test_uid:$finch_login_test_gid:$finch_login_test_class:$finch_login_test_change:$finch_login_test_expire:$finch_login_test_gecos:$finch_login_test_home:$finch_login_test_shell" ] ||
        [ "$finch_login_test_password" != "*" ]; then
        finch_login_test_account_valid=0
    fi
    finch_login_test_account_seen=$((finch_login_test_account_seen + 1))
done < "$finch_login_test_fixture/account-fixture/master.passwd"
# (the system accounts the release has: root and nobody at least; more, such as
# _notifyd, come with the services that need them)
if [ "$finch_login_test_account_valid" -ne 1 ] ||
    [ "$finch_login_test_account_seen" -lt 3 ] ||
    ! grep -q '^root:\*:0:0:' "$finch_login_test_fixture/account-fixture/master.passwd" ||
    ! grep -q '^nobody:\*:-2:-2:' "$finch_login_test_fixture/account-fixture/master.passwd" ||
    ! grep -Fxq 'staff:*:20:' "$finch_login_test_fixture/account-fixture/group"; then
    echo "login-test rc: release account templates are malformed"
    exit 1
fi

if [ -e /private/etc/passwd ] || [ -L /private/etc/passwd ]; then
    echo "login-test rc: public password file already exists"
    exit 1
fi
finch_login_test_account_valid=1
while IFS= read -r finch_login_test_account_line; do
    case "$finch_login_test_account_line" in
        \#*)
            printf '%s\n' "$finch_login_test_account_line"
            ;;
        *)
            finch_login_test_read_account_record "$finch_login_test_account_line"
            case "$finch_login_test_shell" in
                *:*) finch_login_test_account_valid=0 ;;
            esac
            if [ "$finch_login_test_account_line" != \
                "$finch_login_test_name:$finch_login_test_password:$finch_login_test_uid:$finch_login_test_gid:$finch_login_test_class:$finch_login_test_change:$finch_login_test_expire:$finch_login_test_gecos:$finch_login_test_home:$finch_login_test_shell" ]; then
                finch_login_test_account_valid=0
            else
                printf '%s:*:%s:%s:%s:%s:%s\n' \
                    "$finch_login_test_name" "$finch_login_test_uid" \
                    "$finch_login_test_gid" "$finch_login_test_gecos" \
                    "$finch_login_test_home" "$finch_login_test_shell"
            fi
            ;;
    esac
done < "$finch_login_test_fixture/account-fixture/master.passwd" \
    > /private/etc/passwd || {
        echo "login-test rc: could not create the public password file"
        exit 1
    }
if [ "$finch_login_test_account_valid" -ne 1 ]; then
    echo "login-test rc: release master password file could not be converted"
    exit 1
fi

finch_login_test_cksum_matches() {
    finch_login_test_source_cksum=$(cksum < "$1") || return 1
    finch_login_test_copy_cksum=$(cksum < "$2") || return 1
    [ "$finch_login_test_source_cksum" = "$finch_login_test_copy_cksum" ]
}
finch_login_test_verify_copy() {
    if ! finch_login_test_cksum_matches "$1" "$2"; then
        echo "login-test rc: copied file does not match: $2"
        exit 1
    fi
}
finch_login_test_verify_copy "$finch_login_test_fixture/account-fixture/master.passwd" \
    /private/etc/master.passwd
finch_login_test_verify_copy "$finch_login_test_fixture/account-fixture/group" \
    /private/etc/group
finch_login_test_verify_copy "$finch_login_test_fixture/etc/pam.d/login" \
    /private/etc/pam.d/login
finch_login_test_verify_copy "$finch_login_test_fixture/pam/pam_unix.so.2" \
    /usr/lib/pam/pam_unix.so.2
finch_login_test_verify_copy "$finch_login_test_fixture/pam/pam_nologin.so.2" \
    /usr/lib/pam/pam_nologin.so.2
finch_login_test_verify_copy "$finch_login_test_fixture/pam/pam_launchd.so.2" \
    /usr/lib/pam/pam_launchd.so.2
finch_login_test_verify_copy "$finch_login_test_fixture/pam/pam_uwtmp.so.2" \
    /usr/lib/pam/pam_uwtmp.so.2

chown 0:0 /private/etc /private/etc/pam.d /usr/lib/pam
chmod 755 /private/etc /private/etc/pam.d /usr/lib/pam
# Root's, as installed: the account tools look here for their store setting.
if [ -d /private/etc/finch ]; then
    chown -R 0:0 /private/etc/finch
    chmod 755 /private/etc/finch
fi
chown root:wheel /private/etc/master.passwd /private/etc/passwd \
    /private/etc/group /private/etc/pam.d/login \
    /usr/lib/pam/pam_unix.so.2 /usr/lib/pam/pam_nologin.so.2 \
    /usr/lib/pam/pam_launchd.so.2 /usr/lib/pam/pam_uwtmp.so.2
chmod 600 /private/etc/master.passwd
chmod 644 /private/etc/passwd /private/etc/group /private/etc/pam.d/login

finch_login_test_verify_metadata() {
    finch_login_test_metadata=$(stat -f %u:%g:%Lp "$1") || {
        echo "login-test rc: could not inspect $1"
        exit 1
    }
    if [ "$finch_login_test_metadata" != "$2" ]; then
        echo "login-test rc: wrong owner or mode for $1: $finch_login_test_metadata"
        exit 1
    fi
}
finch_login_test_verify_module_owner() {
    finch_login_test_module_owner=$(stat -f %u:%g "$1") || {
        echo "login-test rc: could not inspect module owner for $1"
        exit 1
    }
    if [ "$finch_login_test_module_owner" != "0:0" ]; then
        echo "login-test rc: wrong owner for $1: $finch_login_test_module_owner"
        exit 1
    fi
}
finch_login_test_verify_pam_module() {
    finch_login_test_source_mode=$(stat -f %Lp "$1") || {
        echo "login-test rc: could not inspect fixture mode for $1"
        exit 1
    }
    finch_login_test_copy_mode=$(stat -f %Lp "$2") || {
        echo "login-test rc: could not inspect copied mode for $2"
        exit 1
    }
    if [ "$finch_login_test_copy_mode" != "$finch_login_test_source_mode" ]; then
        echo "login-test rc: copied PAM module mode changed: $2"
        exit 1
    fi
    finch_login_test_copy_permissions=$(stat -f %Sp "$2") || {
        echo "login-test rc: could not inspect copied permissions for $2"
        exit 1
    }
    finch_login_test_copy_write_bits=$(printf '%s\n' \
        "$finch_login_test_copy_permissions" | cut -c 6,9) || {
        echo "login-test rc: could not inspect copied write permissions for $2"
        exit 1
    }
    if [ "$finch_login_test_copy_write_bits" != "--" ]; then
        echo "login-test rc: copied PAM module is writable by other users: $2"
        exit 1
    fi
}
finch_login_test_verify_metadata /private/etc 0:0:755
finch_login_test_verify_metadata /private/etc/pam.d 0:0:755
finch_login_test_verify_metadata /usr/lib/pam 0:0:755
finch_login_test_verify_metadata /private/etc/master.passwd 0:0:600
finch_login_test_verify_metadata /private/etc/passwd 0:0:644
finch_login_test_verify_metadata /private/etc/group 0:0:644
finch_login_test_verify_metadata /private/etc/pam.d/login 0:0:644
for finch_login_test_module in pam_unix.so.2 pam_nologin.so.2 \
    pam_launchd.so.2 pam_uwtmp.so.2; do
    finch_login_test_verify_module_owner \
        "/usr/lib/pam/$finch_login_test_module"
    finch_login_test_verify_pam_module \
        "$finch_login_test_fixture/pam/$finch_login_test_module" \
        "/usr/lib/pam/$finch_login_test_module"
done

mkdir -p /private/var/rw/Users/finchconsole
chown 6000:20 /private/var/rw/Users/finchconsole
chmod 700 /private/var/rw/Users/finchconsole
printf '%s\n' \
    'echo FINCH_LOGIN_PROFILE_READY' \
    "PS1='FINCH_LOGIN_USER> '" \
    'export PS1' > /private/var/rw/Users/finchconsole/.profile
chown 6000:20 /private/var/rw/Users/finchconsole/.profile
chmod 600 /private/var/rw/Users/finchconsole/.profile

/usr/local/bin/finch-login-test-account || {
    echo "login-test rc: could not create the disposable account"
    exit 1
}
finch_login_test_verify_metadata /private/etc/master.passwd 0:0:600
finch_login_test_verify_metadata /private/etc/passwd 0:0:644
finch_login_test_verify_metadata /private/etc/group 0:0:644
echo "FINCH_LOGIN_TEST_FIXTURE_READY"
