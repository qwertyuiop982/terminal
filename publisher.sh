#!/bin/sh
# Signed, snapshot-based publication. Source after common.sh.
set -eu

rc_package_arch() {
    rc_found_arch=$(dpkg-deb -f "$1" Architecture) || rc_die "invalid .deb: $1"
    case "$rc_found_arch" in
        "$RC_ARCH"|all) ;;
        *) rc_die "wrong package architecture ($rc_found_arch, expected $RC_ARCH or all): $1" ;;
    esac
    [ "$(dpkg-deb -f "$1" X-Android-Bionic)" = yes ] &&
        [ "$(dpkg-deb -f "$1" X-Terminal-Prefix)" = /data/data/com.terminal/files/usr ] ||
        rc_die "package is not marked for the com.terminal bionic prefix: $1"
    rc_api=$(dpkg-deb -f "$1" X-Android-Min-API)
    case "$rc_api" in ''|0|*[!0-9]*) rc_die "invalid Android minimum API: $1" ;; esac
    [ "$rc_api" -le 24 ] || rc_die "package requires API $rc_api, but the app supports API 24: $1"
}

rc_import_package() {
    rc_input=$1
    [ -f "$rc_input" ] && [ ! -L "$rc_input" ] || rc_die "not a regular .deb file: $rc_input"
    rc_filename=${rc_input##*/}
    case "$rc_filename" in
        *.deb) ;;
        *) rc_die "expected a .deb file: $rc_input" ;;
    esac
    case "$rc_filename" in
        .*|*..*|*[!a-zA-Z0-9_+.-]*) rc_die "unsafe package filename: $rc_filename" ;;
    esac
    rc_package_arch "$rc_input"
    rc_target=$RC_REPO/pool/main/$rc_filename
    if [ -e "$rc_target" ] || [ -L "$rc_target" ]; then
        [ -f "$rc_target" ] && [ ! -L "$rc_target" ] && cmp -s "$rc_input" "$rc_target" ||
            rc_die "package already exists with different content: $rc_filename"
        return
    fi
    rc_copy=$(mktemp "$RC_REPO/pool/main/.upload.XXXXXXXX")
    if ! cp "$rc_input" "$rc_copy"; then rm -f "$rc_copy"; rc_die "copy failed: $rc_input"; fi
    chmod 644 "$rc_copy"
    mv -f "$rc_copy" "$rc_target"
}

rc_index_hash() {
    rc_index=$1
    rc_relative=$2
    rc_digest=$(sha256sum "$rc_index")
    rc_digest=${rc_digest%% *}
    rc_bytes=$(wc -c < "$rc_index" | tr -d '[:space:]')
    printf ' %s %s %s\n' "$rc_digest" "$rc_bytes" "$rc_relative"
    cp "$rc_index" "$rc_hash_dir/$rc_digest"
}

rc_publish() {
    rc_setup
    [ -L "$RC_DIST" ] && [ -d "$RC_DIST/main/binary-$RC_ARCH" ] || rc_die 'run the install script first'
    rc_require_publish_tools
    command -v cmp >/dev/null 2>&1 || rc_die 'cmp is required for immutable packages'
    : "${REPO_SIGNING_KEY:?set REPO_SIGNING_KEY to the secret key fingerprint}"
    case "$REPO_SIGNING_KEY" in *[!a-fA-F0-9]*) rc_die 'use a signing key fingerprint (hex)' ;; esac
    case "${#REPO_SIGNING_KEY}" in 40|64) ;; *) rc_die 'use a full signing key fingerprint' ;; esac
    if [ -n "${GNUPGHOME:-}" ]; then
        rc_path "$GNUPGHOME"
        [ -d "$GNUPGHOME" ] || rc_die "GnuPG home is missing: $GNUPGHOME"
        case "$(readlink -f "$GNUPGHOME")" in
            "$(readlink -f "$RC_REPO")"/*) rc_die 'signing keys must remain outside the public repository' ;;
        esac
    fi
    gpg --batch --list-secret-keys "$REPO_SIGNING_KEY" >/dev/null 2>&1 ||
        rc_die 'signing key is unavailable on this repository host'
    for rc_input do rc_import_package "$rc_input"; done

    rc_package_list=$(mktemp "$RC_HOME/run/packages.XXXXXXXX")
    rc_stage=
    rc_next=
    trap 'rm -f "$rc_package_list"; [ -z "$rc_next" ] || rm -f "$rc_next"; [ -z "$rc_stage" ] || rm -rf "$rc_stage"' EXIT
    trap 'exit 1' HUP INT TERM
    find "$RC_REPO/pool/main" -type l -print > "$rc_package_list.links"
    if [ -s "$rc_package_list.links" ]; then
        rm -f "$rc_package_list.links"
        rc_die 'pool/main must not contain symlinks'
    fi
    rm -f "$rc_package_list.links"
    find "$RC_REPO/pool/main" -type f -name '*.deb' -print > "$rc_package_list"
    [ -s "$rc_package_list" ] || rc_die 'add at least one compatible .deb before publishing'
    while IFS= read -r rc_package; do
        rc_path "$rc_package"
        rc_package_arch "$rc_package"
        [ -r "$rc_package" ] || rc_die "package is not readable: $rc_package"
        chmod 644 "$rc_package"
    done < "$rc_package_list"

    umask 077
    rc_stage=$(mktemp -d "$RC_RELEASES/$RC_SUITE-XXXXXXXX")
    rc_binary=$rc_stage/main/binary-$RC_ARCH
    rc_hash_dir=$rc_binary/by-hash/SHA256
    mkdir -p "$rc_hash_dir"
    (cd "$RC_REPO" && dpkg-scanpackages -a "$RC_ARCH" pool/main /dev/null) > "$rc_binary/Packages"
    grep -q '^Package: ' "$rc_binary/Packages" || rc_die 'no packages in the generated index'
    grep -q '^SHA256: ' "$rc_binary/Packages" || rc_die 'package checksums are missing'
    gzip -n -9 -c "$rc_binary/Packages" > "$rc_binary/Packages.gz"

    # Keep old by-hash indexes available if a client fetched the previous Release.
    rc_old_hash=$RC_DIST/main/binary-$RC_ARCH/by-hash/SHA256
    if [ -d "$rc_old_hash" ]; then
        for rc_old in "$rc_old_hash"/*; do
            [ -f "$rc_old" ] && [ ! -L "$rc_old" ] || continue
            cp -p "$rc_old" "$rc_hash_dir/"
        done
    fi
    {
        printf 'Origin: Terminal\nLabel: Terminal\nSuite: %s\nCodename: %s\n' "$RC_SUITE" "$RC_SUITE"
        printf 'Date: %s\nArchitectures: %s\nComponents: main\nAcquire-By-Hash: yes\nSHA256:\n' \
            "$(LC_ALL=C date -u '+%a, %d %b %Y %T +0000')" "$RC_ARCH"
        rc_index_hash "$rc_binary/Packages" "main/binary-$RC_ARCH/Packages"
        rc_index_hash "$rc_binary/Packages.gz" "main/binary-$RC_ARCH/Packages.gz"
    } > "$rc_stage/Release"
    gpg --batch --yes --digest-algo SHA256 --local-user "$REPO_SIGNING_KEY" \
        --clearsign --output "$rc_stage/InRelease" "$rc_stage/Release"
    gpg --batch --yes --digest-algo SHA256 --local-user "$REPO_SIGNING_KEY" \
        --armor --detach-sign --output "$rc_stage/Release.gpg" "$rc_stage/Release"
    gpg --batch --verify "$rc_stage/InRelease" >/dev/null 2>&1 || rc_die 'InRelease signature failed verification'
    gpg --batch --verify "$rc_stage/Release.gpg" "$rc_stage/Release" >/dev/null 2>&1 ||
        rc_die 'Release.gpg signature failed verification'

    chmod 755 "$rc_stage" "$rc_stage/main" "$rc_binary" "$rc_binary/by-hash" "$rc_hash_dir"
    chmod 644 "$rc_stage/Release" "$rc_stage/InRelease" "$rc_stage/Release.gpg" \
        "$rc_binary/Packages" "$rc_binary/Packages.gz" "$rc_hash_dir"/*
    rc_next=$(mktemp "$RC_REPO/dists/.$RC_SUITE.XXXXXXXX")
    rm -f "$rc_next"
    ln -s "../../releases/${rc_stage##*/}" "$rc_next"
    mv -Tf "$rc_next" "$RC_DIST"
    rc_stage=
    rc_next=
    printf 'repo-client: signed %s/%s release published at %s\n' "$RC_SUITE" "$RC_ARCH" "$RC_DIST"
}