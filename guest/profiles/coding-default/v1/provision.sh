#!/bin/sh
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
LC_ALL=C
export PATH LC_ALL
umask 077

mode=${1:-}
if [ "$#" -ne 1 ] || { [ "$mode" != provision ] && [ "$mode" != validate ]; }; then
    printf '%s\n' 'usage: ezvm-coding-profile provision|validate' >&2
    exit 2
fi
if [ "$(id -u)" != 0 ]; then
    printf '%s\n' 'coding profile validation requires noninteractive sudo' >&2
    exit 1
fi

failure_message='coding profile validation failed'
state_safe=0
venv_directory=''
ready_temporary=''

cleanup() {
    cleanup_status=$1
    trap - 0 HUP INT TERM
    set +e
    if [ -n "$venv_directory" ]; then
        rm -rf -- "$venv_directory"
    fi
    if [ -n "$ready_temporary" ]; then
        rm -f -- "$ready_temporary"
    fi
    if [ "$cleanup_status" -ne 0 ] && [ "$state_safe" -eq 1 ]; then
        rm -f -- /var/lib/ezvm/ready.json
        # A fixed diagnostic contains no command output, account secrets or seed.
        failure_temporary=$(mktemp /var/lib/ezvm/.failed.XXXXXX)
        if [ -n "$failure_temporary" ]; then
            printf '%s\n' "$failure_message" > "$failure_temporary"
            chmod 0644 "$failure_temporary"
            mv -f -- "$failure_temporary" /var/lib/ezvm/provisioning-failed
        fi
    fi
    exit "$cleanup_status"
}
trap 'cleanup $?' 0
trap 'failure_message="coding profile validation interrupted"; exit 1' HUP INT TERM

fail() {
    failure_message=$1
    printf '%s\n' "$failure_message" >&2
    exit 1
}

root_path() {
    path_value=$1
    path_kind=$2
    [ ! -L "$path_value" ] || fail 'coding profile path must not be a symbolic link'
    if [ "$path_kind" = directory ]; then
        [ -d "$path_value" ] || fail 'coding profile directory is missing'
    else
        [ -f "$path_value" ] || fail 'coding profile evidence file is missing'
    fi
    [ "$(stat -c '%u:%g' -- "$path_value")" = 0:0 ] || fail 'coding profile evidence must be owned by root'
    path_mode=$(stat -c '%a' -- "$path_value")
    [ "$((0$path_mode & 022))" -eq 0 ] || fail 'coding profile evidence must not be group or world writable'
}

root_path /var directory
root_path /var/lib directory
if [ "$mode" = provision ] && [ ! -e /var/lib/ezvm ] && [ ! -L /var/lib/ezvm ]; then
    mkdir -m 0755 /var/lib/ezvm
fi
root_path /var/lib/ezvm directory
state_safe=1
if [ "$mode" = provision ]; then
    rm -f -- /var/lib/ezvm/ready.json
fi

root_path /etc directory
root_path /etc/ezvm directory
root_path /etc/ezvm/identity.json file
root_path /etc/ezvm/profile.json file
root_path /usr directory
root_path /usr/local directory
root_path /usr/local/sbin directory
root_path /usr/local/sbin/ezvm-coding-profile file

required_commands='sshd ssh scp sudo cloud-init git gcc g++ make cmake ninja python3 pip3 curl wget jq rg unzip zip rsync tmux'
for command_name in $required_commands; do
    command -v "$command_name" >/dev/null 2>&1 || fail "missing required command: $command_name"
done

jq -e '
    type == "object" and
    (keys | sort) == (["schemaVersion", "name", "version", "user", "home", "workspace", "privilege", "requiredCommands"] | sort) and
    .schemaVersion == 1 and .name == "coding-default" and .version == 1 and
    .user == "coder" and .home == "/home/coder" and
    .workspace == "/home/coder/workspace" and .privilege == "passwordless-sudo" and
    (.requiredCommands | type) == "array" and
    (.requiredCommands | sort) == (["sshd", "ssh", "scp", "sudo", "cloud-init", "git", "gcc", "g++", "make", "cmake", "ninja", "python3", "pip3", "curl", "wget", "jq", "rg", "unzip", "zip", "rsync", "tmux"] | sort)
' /etc/ezvm/profile.json >/dev/null 2>&1 || fail 'coding profile configuration has an unsupported schema or contract'

jq -e '
    type == "object" and
    (keys | sort) == (["schemaVersion", "instanceName", "baseId", "profile", "cloudInstanceId", "provisioningProfile", "provisioningVersion", "provisioningDigest"] | sort) and
    .schemaVersion == 2 and
    (.instanceName | type) == "string" and (.instanceName | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) and
    (.baseId | type) == "string" and (.baseId | test("^base-[a-f0-9]{64}$")) and
    (.profile == "light" or .profile == "normal" or .profile == "heavy" or .profile == "custom") and
    (.cloudInstanceId | type) == "string" and (.cloudInstanceId | test("^ezvm-[a-z0-9._-]+-[a-f0-9]{12}$")) and
    .provisioningProfile == "coding-default" and .provisioningVersion == 1 and
    (.provisioningDigest | type) == "string" and (.provisioningDigest | test("^[a-f0-9]{64}$"))
' /etc/ezvm/identity.json >/dev/null 2>&1 || fail 'coding profile instance identity has an unsupported schema or profile'

if [ "$mode" = validate ]; then
    root_path /var/lib/ezvm/ready.json file
    jq -e --slurpfile identity /etc/ezvm/identity.json '
        . == ($identity[0] + {provisioningState: "complete"})
    ' /var/lib/ezvm/ready.json >/dev/null 2>&1 || fail 'coding profile readiness marker identity or completion state does not match'
fi

coder_record=$(getent passwd coder) || fail 'coder account is missing'
coder_uid=$(printf '%s\n' "$coder_record" | cut -d: -f3)
coder_gid=$(printf '%s\n' "$coder_record" | cut -d: -f4)
[ "$coder_uid" -gt 0 ] || fail 'coder must be a non-root account'
[ "$(printf '%s\n' "$coder_record" | cut -d: -f6)" = /home/coder ] || fail 'coder home must be /home/coder'
[ "$(printf '%s\n' "$coder_record" | cut -d: -f7)" = /bin/bash ] || fail 'coder shell must be /bin/bash'
[ "$(passwd -S coder | awk '{print $2}')" = L ] || fail 'coder password must remain locked'
[ "$(passwd -S root | awk '{print $2}')" = L ] || fail 'root password must remain locked'

# Root being able to find a command is insufficient when its permissions no
# longer let the coding account execute it. Check the actual coding-user PATH.
runuser -u coder -- env -i PATH="$PATH" HOME=/home/coder USER=coder LOGNAME=coder LC_ALL=C \
    timeout 10 sh -eu -c '
        for required_command in "$@"; do
            command -v "$required_command" >/dev/null 2>&1 || exit 1
        done
    ' sh $required_commands >/dev/null 2>&1 || fail 'a required coding command is unavailable to coder'

# Descriptor-relative opens avoid following a swapped home/workspace symlink.
# Only the workspace directory itself is created or repaired, never user files.
python3 - "$mode" "$coder_uid" "$coder_gid" <<'PY' || fail 'coder home or workspace path, ownership or permissions are invalid'
import os
import stat
import sys

mode, uid_text, gid_text = sys.argv[1:]
uid, gid = int(uid_text), int(gid_text)
flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
home_parent = os.open('/home', flags)
home = workspace = None
try:
    parent_info = os.fstat(home_parent)
    if parent_info.st_uid != 0 or parent_info.st_mode & 0o022:
        raise ValueError('home parent policy')
    home = os.open('coder', flags, dir_fd=home_parent)
    home_info = os.fstat(home)
    if (home_info.st_uid != uid or home_info.st_gid != gid or
            home_info.st_mode & 0o022 or home_info.st_mode & 0o700 != 0o700):
        raise ValueError('coder home policy')
    if mode == 'provision':
        try:
            os.mkdir('workspace', 0o750, dir_fd=home)
        except FileExistsError:
            pass
    workspace = os.open('workspace', flags, dir_fd=home)
    if mode == 'provision':
        os.fchown(workspace, uid, gid)
        os.fchmod(workspace, 0o750)
    info = os.fstat(workspace)
    if info.st_uid != uid or info.st_gid != gid or stat.S_IMODE(info.st_mode) != 0o750:
        raise ValueError('workspace policy')
except (OSError, ValueError):
    sys.exit(1)
finally:
    for descriptor in (workspace, home, home_parent):
        if descriptor is not None:
            os.close(descriptor)
PY

# Prove the coding account can actually traverse the home and use its workspace.
# An anonymous temporary file is removed on close, including process termination,
# so a timeout cannot leave a probe behind or alter an existing workspace file.
runuser -u coder -- env -i PATH="$PATH" HOME=/home/coder USER=coder LOGNAME=coder LC_ALL=C \
    timeout 10 python3 - <<'PYWORKSPACE' >/dev/null 2>&1 || fail 'coder cannot enter or read and write the workspace'
import os
import tempfile

os.chdir('/home/coder/workspace')
with tempfile.TemporaryFile(prefix='.ezvm-workspace-check-', dir='.') as probe:
    payload = b'ezvm-workspace-validation\n'
    probe.write(payload)
    probe.flush()
    probe.seek(0)
    if probe.read() != payload:
        raise ValueError('workspace read/write check')
PYWORKSPACE

sudo_uid=$(runuser -u coder -- env -i PATH="$PATH" HOME=/home/coder USER=coder LOGNAME=coder LC_ALL=C \
    timeout 10 sudo -n -- /usr/bin/id -u 2>/dev/null) || fail 'coder noninteractive sudo is unavailable'
[ "$sudo_uid" = 0 ] || fail 'coder noninteractive sudo did not provide guest root'

sshd_policy=$(timeout 10 /usr/sbin/sshd -T -C user=coder,host=localhost,addr=127.0.0.1 2>/dev/null) || fail 'effective SSH server policy could not be validated'
for policy_line in 'passwordauthentication no' 'kbdinteractiveauthentication no' 'pubkeyauthentication yes' 'permitrootlogin no'; do
    printf '%s\n' "$sshd_policy" | grep -Fx -- "$policy_line" >/dev/null || fail 'effective SSH policy must allow public keys and disable password, keyboard-interactive and root login'
done

# A real, disposable venv checks ensurepip and the installed wheel payload too.
# No network or package installation is involved. The directory is private to
# this invocation and cannot overwrite a workspace or retain login material.
venv_directory=$(mktemp -d /var/lib/ezvm/.venv-check.XXXXXX) || fail 'could not allocate the temporary Python validation directory'
chown "$coder_uid:$coder_gid" "$venv_directory"
if runuser -u coder -- env -i PATH="$PATH" HOME=/home/coder USER=coder LOGNAME=coder LC_ALL=C \
    timeout 90 sh -eu -c '
        printf "create\n" > "$1/stage"
        python3 -m venv "$1/env"
        printf "prefix\n" > "$1/stage"
        "$1/env/bin/python" -c "import sys; assert sys.prefix != sys.base_prefix"
        printf "pip\n" > "$1/stage"
        "$1/env/bin/python" -m pip --version >/dev/null
    ' sh "$venv_directory" >/dev/null 2>&1; then
    :
else
    validation_exit=$?
    validation_stage=$(cat "$venv_directory/stage" 2>/dev/null || true)
    case "$validation_stage" in create|prefix|pip) ;; *) validation_stage=setup ;; esac
    # Preserve the real exit (including timeout124), without exporting tool text.
    printf 'EZVM_VENV_VALIDATION_FAILURE stage=%s exit=%s\n' "$validation_stage" "$validation_exit" >&2
    fail "Python venv with pip is unavailable or exceeded its 90 second validation deadline (stage=$validation_stage exit=$validation_exit)"
fi
rm -rf -- "$venv_directory"
venv_directory=''

if [ "$mode" = provision ]; then
    ready_temporary=$(mktemp /var/lib/ezvm/.ready.XXXXXX) || fail 'could not allocate the readiness marker'
    jq '. + {provisioningState: "complete"}' /etc/ezvm/identity.json > "$ready_temporary" || fail 'could not construct the completed readiness marker'
    chmod 0644 "$ready_temporary"
    mv -f -- "$ready_temporary" /var/lib/ezvm/ready.json
    ready_temporary=''
fi
rm -f -- /var/lib/ezvm/provisioning-failed
exit 0
