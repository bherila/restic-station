#!/usr/bin/env bash
# release.sh — build, sign, package and publish a Restic Station release
# (docs/release.md §6). Two phases, so that publishing is always a separate,
# deliberate step:
#
#   scripts/release.sh build   X.Y.Z               # → dist/vX.Y.Z/, verified, nothing published
#   scripts/release.sh publish X.Y.Z --notes FILE  # signed tag + GitHub release from dist/vX.Y.Z/
#                                                  # (FILE outside the repo: publish needs a clean tree)
#
# Environment:
#   RELEASE_GPG_KEY                                 fingerprint of the OpenPGP key that signs the
#                                                   tarballs, SHA256SUMS and the tag (required)
#   RESTIC_STATION_SIGNING_KEYCHAIN[_PASSWORD_FILE] passed to scripts/sign-release.sh
#   SPARKLE_KEY_FILE                                passed to scripts/make-appcast.sh
#   PREVIOUS_APPCAST                                passed to scripts/make-appcast.sh
#   RELEASE_CI_RUN                                  CI run whose release-linux artifact to ship
#                                                   (default: the successful ci.yml run for HEAD)
#   RELEASE_NOTES_HTML                              short HTML notes for the Sparkle update window
#   RELEASE_SKIP_PRECHECKS=1                        build from a tree that is not a clean,
#                                                   pushed main (rehearsal only; publish refuses)
#
# Every step verifies its own output; the ones that went wrong when this was
# done by hand are checked explicitly: the app and helper must be universal
# (arm64 + x86_64), and the tag must be an OpenPGP signature even when git's
# default signing format is ssh.
#
# macOS only (xcodebuild, codesign, lipo, ditto); bash 3.2-compatible.
set -euo pipefail

die() { echo "release: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

[ $# -ge 2 ] || die "usage: $0 build X.Y.Z | publish X.Y.Z --notes FILE"
PHASE=$1
VERSION=$2
shift 2
case $VERSION in
    *[!0-9.]*|.*|*.|*..*|'') die "'$VERSION' is not a version like 0.1.2" ;;
esac
TAG="v$VERSION"
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_ROOT"
DIST="dist/$TAG"
APP_NAME="Restic Station.app"
REPO=bherila/restic-station
KEY=${RELEASE_GPG_KEY:-}
[ -n "$KEY" ] || die "set RELEASE_GPG_KEY to the signing key's fingerprint"

project_version() {
    sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' project.yml | head -1
}

# prechecks [allow-tag]: a clean tree at origin/main declaring $VERSION. A
# build also requires that the tag does not exist yet; publish may resume
# after it pushed the tag (see publish).
prechecks() {
    git fetch -q --tags origin
    [ -z "$(git status --porcelain)" ] \
        || die "the working tree is not clean (keep the release notes file outside the repository)"
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "HEAD is not origin/main"
    [ "$(project_version)" = "$VERSION" ] || die "project.yml says $(project_version), not $VERSION — merge the version bump first"
    if [ "${1:-}" != allow-tag ]; then
        ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || die "tag $TAG already exists"
    fi
}

# signed_by_key: reads gpg --status-fd output and succeeds only if it holds
# a VALIDSIG whose signing-key or primary-key fingerprint is $KEY.
# `gpg --verify` alone accepts any key in the keyring, and `--local-user`
# only chooses the key when signing. The comparison is forced to strings: awk
# compares numerically when both sides look numeric, and an all-digit
# "fingerprint" then matched an unrelated `0` field. awk reads everything,
# so no producer is cut off mid-pipe.
signed_by_key() {
    awk -v key="$(echo "$KEY" | tr 'abcdef' 'ABCDEF')" \
        '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && (($3 "") == (key "") || ($NF "") == (key "")) { found = 1 }
         END { exit !found }'
}

verify_signed_by() {
    gpg --batch --status-fd 1 --verify "$1" "$2" 2>/dev/null | signed_by_key
}

# The files a release ships, in a stable order (everything in $DIST except
# the build records, which start with a dot).
release_files() {
    find "$REPO_ROOT/$DIST" -maxdepth 1 -type f ! -name '.*' -exec basename {} \; | LC_ALL=C sort
}

ci_run_for_head() {
    local head
    head=$(git rev-parse HEAD)
    gh run list -R "$REPO" --workflow ci.yml --branch main --limit 20 \
        --json databaseId,headSha,conclusion \
        --jq ".[] | select(.headSha == \"$head\" and .conclusion == \"success\") | .databaseId" | head -1
}

build() {
    local rehearsal=0
    if [ "${RELEASE_SKIP_PRECHECKS:-}" = 1 ]; then
        rehearsal=1
        echo "release: RELEASE_SKIP_PRECHECKS=1 — rehearsal build, not publishable" >&2
        [ "$(project_version)" = "$VERSION" ] || die "project.yml says $(project_version), not $VERSION"
    else
        prechecks
    fi
    # Every piece of evidence below is bound to this one commit; the build
    # refuses at the end if the checkout moved underneath it.
    local commit
    commit=$(git rev-parse HEAD)
    local run=${RELEASE_CI_RUN:-$(ci_run_for_head)}
    [ -n "$run" ] || die "no successful ci.yml run on main for HEAD; wait for CI or set RELEASE_CI_RUN"
    # An override is checked like the default: the CI workflow, finished
    # successfully, for this exact commit — or the Linux binaries would come
    # from some other build while .commit records HEAD.
    local run_meta
    run_meta=$(gh run view "$run" -R "$REPO" --json workflowName,conclusion,headSha \
        --jq '"\(.workflowName) \(.conclusion) \(.headSha)"') || die "cannot read CI run $run"
    case $run_meta in
        "CI success $commit") ;;
        *) if [ "$rehearsal" = 1 ]; then
               echo "release: rehearsal using CI run $run ($run_meta), which is not this commit's" >&2
           else
               die "CI run $run is '$run_meta', not a successful CI run of $commit"
           fi ;;
    esac

    rm -rf "$DIST" "dist/linux-$TAG"
    mkdir -p "$DIST" "dist/linux-$TAG"

    step "Release build (universal)"
    ./scripts/bootstrap.sh >/dev/null
    rm -rf build/Build/Products/Release
    xcodebuild -scheme "Restic Station" -configuration Release -derivedDataPath build \
        -destination 'generic/platform=macOS' -packageAuthorizationProvider netrc \
        ONLY_ACTIVE_ARCH=NO build >"$DIST/../xcodebuild-$TAG.log" 2>&1 \
        || die "xcodebuild failed — see dist/xcodebuild-$TAG.log"
    local app="build/Build/Products/Release/$APP_NAME"
    local binary
    for binary in "$app/Contents/MacOS/Restic Station" "$app/Contents/MacOS/restic-station-helper" \
        "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"; do
        local archs
        archs=" $(lipo -archs "$binary") "
        case $archs in *" arm64 "*) ;; *) die "$binary has no arm64 slice:$archs" ;; esac
        case $archs in *" x86_64 "*) ;; *) die "$binary has no x86_64 slice:$archs" ;; esac
    done
    [ "$("$app/Contents/MacOS/restic-station-helper" version)" = "restic-station-helper $VERSION" ] \
        || die "the built helper does not report $VERSION"

    step "Code signing"
    ./scripts/sign-release.sh "$app" >/dev/null
    # One private copy, verified, from which both archives are made: the
    # shared build directory can be rewritten by another xcodebuild while
    # this runs, and each archive must contain bytes that were verified.
    local stage="dist/stage-$TAG"
    rm -rf "$stage"
    mkdir -p "$stage"
    ditto "$app" "$stage/$APP_NAME"
    app="$stage/$APP_NAME"
    ./scripts/sign-release.sh --verify "$app"

    step "Sparkle zip and signed appcast"
    ./scripts/make-appcast.sh "$app" "$DIST" ${RELEASE_NOTES_HTML:+"$RELEASE_NOTES_HTML"}

    step "macOS tarball"
    COPYFILE_DISABLE=1 tar -C "$stage" -czf "$DIST/restic-station-macos-universal-$TAG.tar.gz" "$APP_NAME"
    # Listed to a file first: `tar … | grep -q` lets grep exit at the first
    # match, tar dies of SIGPIPE, and under pipefail the negated pipeline
    # then *succeeds* — the check would pass exactly when it should fail.
    tar tzf "$DIST/restic-station-macos-universal-$TAG.tar.gz" > "$stage/listing" \
        || die "cannot list the macOS tarball"
    ! grep -q '/\._' "$stage/listing" || die "the macOS tarball contains AppleDouble files"

    step "Linux tarballs from CI run $run"
    gh run download "$run" -R "$REPO" -n restic-station-linux -D "dist/linux-$TAG"
    (cd "dist/linux-$TAG" && shasum -a 256 -c SHA256SUMS) || die "the CI artifact's SHA256SUMS does not verify"
    local arch
    for arch in x86_64 aarch64; do
        cp "dist/linux-$TAG/restic-station-linux-$arch.tar.gz" "$DIST/restic-station-linux-$arch-$TAG.tar.gz"
    done

    step "Checksums and OpenPGP signatures"
    (
        cd "$DIST"
        shasum -a 256 restic-station-linux-aarch64-"$TAG".tar.gz restic-station-linux-x86_64-"$TAG".tar.gz \
            restic-station-macos-universal-"$TAG".tar.gz "Restic-Station-$VERSION.zip" > SHA256SUMS
        local file
        for file in ./*.tar.gz SHA256SUMS; do
            gpg --batch --yes --local-user "$KEY" --armor --detach-sign "$file"
            verify_signed_by "$file.asc" "$file" || die "$file is not signed by $KEY"
        done
        gpg --armor --export "$KEY" > release-key.asc
        [ -s release-key.asc ] || die "could not export the public key for $KEY"
    )
    [ "$(git rev-parse HEAD)" = "$commit" ] || die "HEAD moved from $commit during the build — rebuild"
    rm -rf "$stage"
    echo "$run" > "$DIST/.ci-run"
    echo "$commit" > "$DIST/.commit"
    # A rehearsal (or a tree that changed during the build) can contain
    # source that HEAD does not: mark it so publish refuses it for good.
    if [ "$rehearsal" = 1 ] || [ -n "$(git status --porcelain)" ]; then
        echo "built with RELEASE_SKIP_PRECHECKS or from a modified tree" > "$DIST/.rehearsal"
    fi
    # Every shipped file's checksum, which publish re-verifies before it
    # uploads anything: the build directory is not trusted across phases.
    local shipped
    shipped=$(release_files)
    (cd "$DIST" && printf '%s\n' "$shipped" | while IFS= read -r file; do shasum -a 256 "$file"; done) \
        > "$DIST/.manifest"
    [ -s "$DIST/.manifest" ] || die "could not write $DIST/.manifest"

    step "Done"
    ls -1 "$DIST"
    echo "Built $TAG from $(git rev-parse --short HEAD). Nothing was published."
    echo "Next: scripts/release.sh publish $VERSION --notes <release-notes.md>"
}

publish() {
    [ "${1:-}" = "--notes" ] && [ -n "${2:-}" ] || die "usage: $0 publish $VERSION --notes FILE"
    local notes=$2
    [ -f "$notes" ] || die "no notes file at $notes"
    [ -f "$DIST/appcast.xml" ] || die "nothing built at $DIST — run: $0 build $VERSION"
    prechecks allow-tag
    [ ! -e "$DIST/.rehearsal" ] || die "$DIST is a rehearsal build ($(cat "$DIST/.rehearsal")) — rebuild without it"
    [ "$(cat "$DIST/.commit")" = "$(git rev-parse HEAD)" ] \
        || die "$DIST was built from $(cat "$DIST/.commit"), not HEAD — rebuild"

    step "Verify the build output"
    [ -f "$DIST/.manifest" ] || die "$DIST has no manifest — rebuild"
    (cd "$DIST" && shasum -a 256 -c .manifest >/dev/null) || die "a file in $DIST changed since it was built"
    [ "$(release_files)" = "$(sed 's/^[0-9a-f]*  //' "$DIST/.manifest")" ] \
        || die "$DIST has files that were not part of the build"
    local asc
    for asc in "$DIST"/*.asc; do
        [ "$(basename "$asc")" = release-key.asc ] && continue
        verify_signed_by "$asc" "${asc%.asc}" || die "$asc is not a good signature by $KEY"
    done

    # Resumable after this point: a tag that already exists must be ours —
    # pointing at HEAD with a good signature — and is not created again.
    step "Signed tag $TAG"
    if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
        [ "$(git rev-parse "$TAG^{commit}")" = "$(git rev-parse HEAD)" ] || die "tag $TAG exists and is not HEAD"
        echo "tag $TAG already exists at HEAD; resuming"
    else
        git -c gpg.format=openpgp -c gpg.program=gpg tag -s -u "$KEY" -m "Restic Station $TAG" "$TAG" HEAD
    fi
    git -c gpg.format=openpgp verify-tag --raw "$TAG" 2>&1 >/dev/null | signed_by_key \
        || die "tag $TAG is not a good signature by $KEY"
    git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 || git push origin "$TAG"

    step "GitHub release"
    local assets=()
    local file
    while IFS= read -r file; do assets+=("$DIST/$file"); done < <(release_files)
    if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
        echo "release $TAG already exists; re-uploading the verified assets"
        gh release upload "$TAG" -R "$REPO" --clobber "${assets[@]}"
        # An interrupted create leaves a draft, which `latest` — and so
        # Sparkle's feed — ignores. Finish it the way create would have.
        gh release edit "$TAG" -R "$REPO" --draft=false --prerelease=false --latest >/dev/null
    else
        gh release create "$TAG" -R "$REPO" --verify-tag --latest --title "Restic Station $TAG" \
            --notes-file "$notes" "${assets[@]}"
    fi

    step "What installed copies will see"
    local live
    live=$(mktemp -d)
    curl -fsSL "https://github.com/$REPO/releases/latest/download/appcast.xml" -o "$live/appcast.xml"
    cmp "$live/appcast.xml" "$DIST/appcast.xml" || die "the live appcast differs from the built one"
    curl -fsSL "https://github.com/$REPO/releases/download/$TAG/Restic-Station-$VERSION.zip" -o "$live/update.zip"
    cmp "$live/update.zip" "$DIST/Restic-Station-$VERSION.zip" || die "the live update archive differs"
    rm -rf "$live"
    echo "Published $TAG: https://github.com/$REPO/releases/tag/$TAG"
}

case $PHASE in
    build) build ;;
    publish) publish "$@" ;;
    *) die "unknown phase '$PHASE' (build | publish)" ;;
esac
