#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_UUID="$(uuidgen)"
TASK_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/maceven-check-install-${TASK_UUID}.XXXXXX")"
trap 'rm -rf "$TASK_FIXTURE"' EXIT

# Exercise the real install steps with disposable packages and injected signature failures.
for TASK_CASE in stage installed success first reopen; do
    TASK_DIR="$TASK_FIXTURE/$TASK_CASE"
    mkdir -p "$TASK_DIR/source.app"
    echo new > "$TASK_DIR/source.app/version"
    if [ "$TASK_CASE" != first ]; then
        mkdir -p "$TASK_DIR/MacEven.app"
        echo old > "$TASK_DIR/MacEven.app/version"
    fi
    cat > "$TASK_DIR/install.sh" <<'HEADER'
#!/bin/bash
set -euo pipefail
TASK_APP="$1/source.app"
TASK_INSTALLED="$1/MacEven.app"
TASK_CASE="$2"
codesign() {
    if [ "$TASK_CASE" = stage ]; then return 41; fi
    if { [ "$TASK_CASE" = installed ] || [ "$TASK_CASE" = first ]; } && [ "$3" = "$TASK_INSTALLED" ]; then return 42; fi
}
ps() {
    if [ "$TASK_CASE" = reopen ]; then
        printf '424242 %s/Contents/MacOS/MacEven\n' "$TASK_INSTALLED"
    fi
}
kill() {
    # Simulate a process exiting after TERM, without signalling a real process.
    [ "$1" = -TERM ]
}
lsregister() { :; }
open() {
    local version="$(cat "$TASK_INSTALLED/version")"
    echo "$version" >> "$TASK_INSTALLED/../opened"
    if [ "$TASK_CASE" = reopen ] && [ "$version" = new ]; then return 43; fi
}
HEADER
    sed -n '/^TASK_INSTALLED=/,$p' "$TASK_ROOT/scripts/build.sh" | sed '1d' >> "$TASK_DIR/install.sh"
    TASK_STATUS=0
    bash "$TASK_DIR/install.sh" "$TASK_DIR" "$TASK_CASE" > "$TASK_DIR/output" 2>&1 || TASK_STATUS=$?
    case "$TASK_CASE" in
        stage) TASK_EXPECTED_STATUS=41; TASK_EXPECTED_VERSION=old ;;
        installed) TASK_EXPECTED_STATUS=42; TASK_EXPECTED_VERSION=old ;;
        success) TASK_EXPECTED_STATUS=0; TASK_EXPECTED_VERSION=new ;;
        first) TASK_EXPECTED_STATUS=42; TASK_EXPECTED_VERSION=absent ;;
        reopen) TASK_EXPECTED_STATUS=43; TASK_EXPECTED_VERSION=old ;;
    esac
    TASK_VERSION=absent
    if [ -f "$TASK_DIR/MacEven.app/version" ]; then TASK_VERSION="$(cat "$TASK_DIR/MacEven.app/version")"; fi
    if [ "$TASK_STATUS" -ne "$TASK_EXPECTED_STATUS" ] || [ "$TASK_VERSION" != "$TASK_EXPECTED_VERSION" ]; then
        cat "$TASK_DIR/output" >&2
        echo "FAIL install $TASK_CASE" >&2
        exit 1
    fi
    if [ "$TASK_CASE" = reopen ]; then
        [ "$(cat "$TASK_DIR/opened")" = "$(printf 'new\nold')" ]
    fi
    TASK_LEFTOVERS=("$TASK_DIR"/.MacEven-install.*)
    [ ! -e "${TASK_LEFTOVERS[0]}" ]
    echo "PASS install $TASK_CASE"
done
