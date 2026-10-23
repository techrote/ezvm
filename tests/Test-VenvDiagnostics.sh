#!/bin/sh
# Exercise the actual profile block with controlled command-boundary fixtures.
set -eu
profile=$1
root=$2
if command -v cygpath >/dev/null 2>&1; then
    profile=$(cygpath -u "$profile")
    root=$(cygpath -u "$root")
fi
mkdir "$root/bin"
sed -n '/^validation_started=/,/^fi$/p' "$profile" > "$root/block.sh"
test -s "$root/block.sh"
cat > "$root/bin/python3" <<'PYTHON'
#!/bin/sh
printf 'PRIVATE_TOOL_OUTPUT_MUST_NOT_ESCAPE\n' >&2
{ printf 'PRIVATE_TOOL_OUTPUT_MUST_NOT_ESCAPE\n'; } >&3 2>/dev/null || :
test "$1" = -m && test "$2" = venv && test "$3" = --without-pip || exit 99
if [ "$TEST_CASE" = create ]; then exit 17; fi
mkdir -p "$4/bin"
cp "$TEST_ROOT/runtime-python" "$4/bin/python"
chmod +x "$4/bin/python"
PYTHON
cat > "$root/runtime-python" <<'PYTHON'
#!/bin/sh
printf 'PRIVATE_TOOL_OUTPUT_MUST_NOT_ESCAPE\n' >&2
{ printf 'PRIVATE_TOOL_OUTPUT_MUST_NOT_ESCAPE\n'; } >&3 2>/dev/null || :
case "$1" in
    -) cat >/dev/null; test "$TEST_CASE" != bootstrap || exit 21 ;;
    -c) test "$TEST_CASE" != prefix || exit 18 ;;
    -m) test "$2" = pip && test "$3" = --version || exit 99
        case "$TEST_CASE" in pip|metrics-failed-pip|broken-metrics-pip) exit 19 ;; esac ;;
    *) exit 99 ;;
esac
PYTHON
chmod +x "$root/bin/python3"
PATH="$root/bin:$PATH"
export PATH
TEST_ROOT=$root
export TEST_ROOT
for TEST_CASE in success provision metrics-failed-pip broken-metrics-pip create bootstrap prefix pip timeout setup bad-stage large-stage fifo-stage bad-clock regressing-clock; do
    export TEST_CASE
    venv_directory="$root/$TEST_CASE"
    mkdir "$venv_directory"
    started=$(date +%s)
    status=0
    (
        mode=validate
        if [ "$TEST_CASE" = provision ]; then mode=provision; fi
        fail() { printf 'FAIL=%s\n' "$1" >&2; exit 1; }
        runuser() {
            test "$1" = -u && test "$2" = coder && test "$3" = -- || exit 99
            shift 3
            test "$1" = env && test "$2" = -i || exit 99
            shift 2
            for name in PATH HOME USER LOGNAME LC_ALL; do
                case "$1" in "$name="*) ;; *) exit 99 ;; esac
                shift
            done
            test "$1" = timeout && test "$2" = 90 && test "$3" = sh && test "$4" = -eu && test "$5" = -c || exit 99
            shift 5
            inner=$1
            shift
            test "$1" = sh && test "$2" = "$venv_directory" && test "$3" = "$mode" || exit 99
            case "$TEST_CASE" in
                timeout) printf 'create\n' > "$venv_directory/stage"; return 124 ;;
                setup) return 7 ;;
                bad-clock) validation_started=bad; printf 'prefix\n' > "$venv_directory/stage"; return 26 ;;
                regressing-clock) validation_started=9999999999999; printf 'pip\n' > "$venv_directory/stage"; return 27 ;;
                bad-stage) printf 'PRIVATE_TOOL_OUTPUT_MUST_NOT_ESCAPE\n' > "$venv_directory/stage"; return 23 ;;
                large-stage) head -c 1048576 /dev/zero > "$venv_directory/stage"; return 24 ;;
                fifo-stage) mkfifo "$venv_directory/stage"; return 25 ;;
                metrics-failed-pip) sh -eu -c "$inner" sh "$venv_directory" "$mode" 3>&- ;;
                broken-metrics-pip)
                    pipe="$venv_directory/metrics-pipe"
                    mkfifo "$pipe"
                    (exec 4<"$pipe") &
                    reader=$!
                    exec 3>"$pipe"
                    wait "$reader"
                    sh -eu -c "$inner" sh "$venv_directory" "$mode" ;;
                *) sh -eu -c "$inner" sh "$venv_directory" "$mode" ;;
            esac
        }
        . "$root/block.sh"
    ) > "$root/$TEST_CASE.output" 2>&1 || status=$?
    elapsed=$(( $(date +%s) - started ))
    output=$(cat "$root/$TEST_CASE.output")
    case "$output" in *PRIVATE_TOOL_OUTPUT_MUST_NOT_ESCAPE*) exit 90 ;; esac
    if [ "$TEST_CASE" = success ] || [ "$TEST_CASE" = provision ]; then
        test "$status" = 0
        test "$(printf '%s\n' "$output" | grep -c '^EZVM_VENV_METRIC ')" -eq 8
        test "$(printf '%s\n' "$output" | grep -c '^EZVM_VENV_TIMES$')" -eq 8
        metric_mode=validate
        if [ "$TEST_CASE" = provision ]; then metric_mode=provision; fi
        printf '%s\n' "$output" | grep -q "invocation=$TEST_CASE mode=$metric_mode stage=layout edge=start uptime="
        printf '%s\n' "$output" | grep -q "invocation=$TEST_CASE mode=$metric_mode stage=pip edge=end uptime="
    else
        test "$status" = 1
        case "$TEST_CASE" in
            create) expected='create exit=17' ;;
            bootstrap) expected='create exit=21' ;;
            prefix) expected='prefix exit=18' ;;
            pip|metrics-failed-pip|broken-metrics-pip) expected='pip exit=19' ;;
            timeout) expected='create exit=124' ;;
            setup) expected='setup exit=7' ;;
            bad-stage) expected='setup exit=23' ;;
            large-stage) expected='setup exit=24' ;;
            fifo-stage) expected='setup exit=25' ;;
            bad-clock) expected='prefix exit=26' ;;
            regressing-clock) expected='pip exit=27' ;;
        esac
        case "$output" in *"EZVM_VENV_VALIDATION_FAILURE stage=$expected elapsedSeconds="*) ;; *) exit 91 ;; esac
        if [ "$TEST_CASE" = pip ]; then
            printf '%s\n' "$output" | grep -q 'mode=validate stage=pip edge=start uptime='
            if printf '%s\n' "$output" | grep -q 'stage=pip edge=end'; then exit 93; fi
        fi
        if [ "$TEST_CASE" = metrics-failed-pip ] || [ "$TEST_CASE" = broken-metrics-pip ]; then
            if printf '%s\n' "$output" | grep -q '^EZVM_VENV_METRIC '; then exit 94; fi
        fi
    fi
    case "$TEST_CASE" in bad-clock|regressing-clock) case "$output" in *elapsedSeconds=unknown*) ;; *) exit 92 ;; esac ;; esac
    test "$elapsed" -le 8
    printf 'PASS venv diagnostic %s\n' "$TEST_CASE"
done
