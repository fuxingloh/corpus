#!/bin/sh
# Install Corpus from GitHub Releases. Usage: sh install.sh [version]
# Keep execution inside main so a truncated curl | sh download cannot install.

fail() {
    printf 'corpus installer: %s\n' "$*" >&2
    exit 1
}

download() {
    curl --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 300 --retry 3 "$@"
}

cleanup() {
    if [ -n "$staged" ]; then rm -f "$staged"; fi
    if [ -n "$temporary" ]; then rm -rf "$temporary"; fi
}

add_posix_path() {
    profile=$1
    if [ -f "$profile" ] && grep -Fqx '# Corpus CLI PATH' "$profile"; then
        return
    fi
    mkdir -p "$(dirname "$profile")"
    cat >> "$profile" <<'EOF'

# Corpus CLI PATH
case ":$PATH:" in
    *":$HOME/.corpus/bin:"*) ;;
    *) export PATH="$HOME/.corpus/bin:$PATH" ;;
esac
EOF
    printf 'Added PATH setup to %s\n' "$profile"
}

configure_path() {
    case "${SHELL:-sh}" in
        */zsh)
            add_posix_path "${ZDOTDIR:-$HOME}/.zshrc"
            ;;
        */bash)
            add_posix_path "$HOME/.bashrc"
            # Bash reads only the first existing login profile.
            if [ -f "$HOME/.bash_profile" ]; then
                add_posix_path "$HOME/.bash_profile"
            elif [ -f "$HOME/.bash_login" ]; then
                add_posix_path "$HOME/.bash_login"
            else
                add_posix_path "$HOME/.profile"
            fi
            ;;
        */fish)
            fish_dir=${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d
            mkdir -p "$fish_dir"
            if [ ! -f "$fish_dir/corpus.fish" ] || \
                ! grep -Fqx '# Corpus CLI PATH' "$fish_dir/corpus.fish"; then
                cat >> "$fish_dir/corpus.fish" <<'EOF'

# Corpus CLI PATH
if not contains -- "$HOME/.corpus/bin" $PATH
    set --global --export PATH "$HOME/.corpus/bin" $PATH
end
EOF
                printf 'Added PATH setup to %s/corpus.fish\n' "$fish_dir"
            fi
            ;;
        *) add_posix_path "$HOME/.profile" ;;
    esac
}

main() {
    set -eu
    [ "$#" -le 1 ] || fail 'Usage: sh install.sh [version]'
    case "${1:-}" in
        -h|--help)
            printf 'Usage: sh install.sh [version]\nOmit version for the latest stable release. A v prefix is optional.\n'
            return
            ;;
    esac
    [ -n "${HOME:-}" ] || fail 'HOME must be set.'
    case "$HOME" in /*) ;; *) fail 'HOME must be an absolute path.' ;; esac
    for command in curl uname tar awk grep tr mktemp chmod mkdir mv cp rm cat dirname; do
        command -v "$command" >/dev/null 2>&1 || fail "Required command not found: $command"
    done
    if command -v sha256sum >/dev/null 2>&1; then
        checksum_tool=sha256sum
    elif command -v shasum >/dev/null 2>&1; then
        checksum_tool=shasum
    else
        fail 'SHA-256 verification requires sha256sum or shasum.'
    fi

    platform=$(uname -s)
    architecture=$(uname -m)
    case "$platform/$architecture" in
        Darwin/arm64|Darwin/aarch64) target=aarch64-apple-darwin ;;
        Darwin/x86_64) target=x86_64-apple-darwin ;;
        Linux/x86_64) target=x86_64-unknown-linux-gnu ;;
        *) fail "Unsupported platform: $platform/$architecture" ;;
    esac

    repository=https://github.com/fuxingloh/corpus
    if [ "$#" -eq 1 ]; then
        version=${1#v}
    else
        # GitHub's latest-release redirect excludes drafts and prereleases.
        release_url=$(download --output /dev/null --write-out '%{url_effective}' \
            "$repository/releases/latest") || fail 'Could not resolve the latest stable release.'
        case "$release_url" in
            "$repository/releases/tag/v"*) version=${release_url##*/v} ;;
            *) fail "Unexpected latest-release URL: $release_url" ;;
        esac
    fi
    printf '%s\n' "$version" | grep -Eq \
        '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$' \
        || fail "Invalid version: $version (expected e.g. 0.1.0 or v0.1.0)."

    temporary=''
    staged=''
    trap cleanup 0
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    temporary=$(mktemp -d "${TMPDIR:-/tmp}/corpus-install.XXXXXXXX")
    archive=corpus-$version-$target.tar.gz
    base_url=$repository/releases/download/v$version
    printf 'Downloading Corpus %s for %s...\n' "$version" "$target"
    download --output "$temporary/$archive" "$base_url/$archive" \
        || fail "Could not download $archive. Check that the release and target asset exist."
    download --output "$temporary/$archive.sha256" "$base_url/$archive.sha256" \
        || fail "Could not download $archive.sha256."

    # Accept a bare digest or the standard sha256sum/shasum filename format.
    expected=$(awk -v name="$archive" '
        NF {
            count++
            if (NF != 1 && !(NF == 2 && ($2 == name || $2 == "*" name))) bad = 1
            hash = $1
        }
        END { if (count != 1 || bad) exit 1; print hash }
    ' "$temporary/$archive.sha256") || fail 'Malformed checksum file.'
    printf '%s\n' "$expected" | grep -Eq '^[0-9a-fA-F]{64}$' \
        || fail 'Malformed SHA-256 digest.'
    expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
    if [ "$checksum_tool" = sha256sum ]; then
        actual=$(sha256sum "$temporary/$archive")
    else
        actual=$(shasum -a 256 "$temporary/$archive")
    fi
    actual=${actual%% *}
    [ "$actual" = "$expected" ] || fail 'SHA-256 mismatch; existing installation was not changed.'

    tar -tzf "$temporary/$archive" > "$temporary/members" || fail 'Invalid release archive.'
    member=$(awk '
        /(^|\/)corpus$/ { count++; member = $0 }
        END { if (count != 1) exit 1; print member }
    ' "$temporary/members") || fail 'Archive must contain exactly one corpus executable.'
    case "$member" in
        /*|-*|..|../*|*/../*|*/..) fail 'Unsafe executable path in release archive.' ;;
    esac
    # Stream just the executable, without writing any archive-controlled paths.
    tar -xOzf "$temporary/$archive" "$member" > "$temporary/corpus" \
        || fail 'Could not extract corpus.'
    [ -s "$temporary/corpus" ] || fail 'Archive contains an empty executable.'
    chmod 755 "$temporary/corpus"

    install_dir=$HOME/.corpus/bin
    mkdir -p "$install_dir"
    [ ! -d "$install_dir/corpus" ] || fail "$install_dir/corpus is a directory."
    # Stage on the destination filesystem so the final rename is atomic.
    staged=$(mktemp "$install_dir/.corpus-install.XXXXXXXX")
    cp "$temporary/corpus" "$staged"
    chmod 755 "$staged"
    reported_version=$("$staged" --version) || fail 'Downloaded executable failed --version.'
    case "$reported_version" in
        "corpus $version"|"corpus $version "*) ;;
        *) fail "Version mismatch: expected corpus $version, got $reported_version" ;;
    esac
    "$staged" --help > "$temporary/help" || fail 'Downloaded executable failed --help.'
    [ -s "$temporary/help" ] || fail 'Downloaded executable returned empty --help output.'
    mv -f "$staged" "$install_dir/corpus"
    staged=''

    configure_path
    printf '\nInstalled %s at %s/corpus\n' "$reported_version" "$install_dir"
    printf 'PATH is configured for new shells. To use Corpus in this shell now, run:\n'
    case "${SHELL:-sh}" in
        */fish) printf '  set -gx PATH "$HOME/.corpus/bin" $PATH\n' ;;
        *) printf '  export PATH="$HOME/.corpus/bin:$PATH"\n' ;;
    esac
}

main "$@"
