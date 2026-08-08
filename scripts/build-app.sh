#!/bin/zsh
set -euo pipefail
umask 077

script_dir=${0:A:h}
project_dir=${script_dir:h}
cd "$project_dir"
project_dir=${PWD:A}

binary_path=".build/release/TravelLockdown"
plist_path="App/Info.plist"
logo_path="Assets/gamechangers-ai.png"
icon_path="Assets/AppIcon.icns"
release_dir=${TRAVEL_LOCKDOWN_RELEASE_DIR:-"$HOME/Library/Application Support/TravelLockdown/Release"}
release_dir=${release_dir:a}
if [[ -L "$release_dir" ]]; then
  print -u2 -- "Release directory must not be a symbolic link: $release_dir"
  exit 73
fi
release_dir=${release_dir:A}
versions_dir="$release_dir/versions"
current_link="$release_dir/current"
current_next="$release_dir/.current.next.$$"
build_link="$project_dir/build"
build_next="$project_dir/.build.next.$$"
effective_uid=$(/usr/bin/id -u)
version_name="version-$(/bin/date -u +%Y%m%dT%H%M%SZ)-$$"
version_dir="$versions_dir/$version_name"
version_app="$version_dir/TravelLockdown.app"
staging_app="$release_dir/.TravelLockdown.app.staging.$$"

fail() {
  print -u2 -- "$1"
  exit "${2:-66}"
}

validate_ancestors() {
  local ancestor="$1" owner mode
  while [[ "$ancestor" != "/" ]]; do
    [[ -d "$ancestor" && ! -L "$ancestor" ]] || {
      fail "Release directory ancestor must be a real directory: $ancestor" 73
    }
    owner=$(/usr/bin/stat -f %u "$ancestor")
    [[ "$owner" == "$effective_uid" || "$owner" == "0" ]] || {
      fail "Release directory ancestor must be owned by the effective user or root: $ancestor" 73
    }
    mode=$(/usr/bin/stat -f %Lp "$ancestor")
    (( (8#$mode & 8#022) == 0 )) || {
      fail "Release directory ancestor must not be group- or other-writable: $ancestor" 73
    }
    ancestor=${ancestor:h}
  done
}

validate_owned_directory() {
  local directory="$1" owner mode
  [[ -d "$directory" && ! -L "$directory" ]] || {
    fail "Trusted release path must be a real directory: $directory" 73
  }
  owner=$(/usr/bin/stat -f %u "$directory")
  [[ "$owner" == "$effective_uid" ]] || {
    fail "Trusted release path must be owned by the effective user: $directory" 73
  }
  mode=$(/usr/bin/stat -f %Lp "$directory")
  (( (8#$mode & 8#022) == 0 )) || {
    fail "Trusted release path must not be group- or other-writable: $directory" 73
  }
}

validate_release_root() {
  local nearest_existing_ancestor
  [[ ! -L "$release_dir" ]] || {
    fail "Release directory must not be a symbolic link: $release_dir" 73
  }
  nearest_existing_ancestor=${release_dir:h}
  while [[ ! -e "$nearest_existing_ancestor" && "$nearest_existing_ancestor" != "/" ]]; do
    nearest_existing_ancestor=${nearest_existing_ancestor:h}
  done
  validate_ancestors "$nearest_existing_ancestor"
  if [[ ! -e "$release_dir" ]]; then
    mkdir -p -m 700 "$release_dir"
  fi
  validate_ancestors "${release_dir:h}"
  validate_owned_directory "$release_dir"
}

validate_version_target() {
  local target="$1"
  [[ "$target" == "$versions_dir"/* ]] || {
    fail "Current release must resolve beneath the trusted versions directory" 73
  }
  validate_owned_directory "$target"
  [[ -d "$target/TravelLockdown.app" && ! -L "$target/TravelLockdown.app" ]] || {
    fail "Version target must contain a real app bundle" 73
  }
  [[ -x "$target/TravelLockdown.app/Contents/MacOS/TravelLockdown" ]] || {
    fail "Version target executable is missing" 73
  }
  codesign --verify --deep --strict "$target/TravelLockdown.app"
}

[[ -f "$plist_path" ]] || fail "Missing $plist_path"
[[ -f "$logo_path" ]] || fail "Missing $logo_path"
[[ -f "$icon_path" ]] || fail "Missing $icon_path"
[[ "$release_dir" != "/" ]] || fail "Refusing to use / as the release directory" 73
if [[ "$release_dir" == "$project_dir" || "$release_dir" == "$project_dir"/* ]]; then
  fail "Release directory must be outside the project tree" 73
fi

validate_release_root
if [[ ! -e "$versions_dir" ]]; then
  mkdir -m 700 "$versions_dir"
fi
validate_owned_directory "$versions_dir"

had_current=0
previous_current_target=""
if [[ -e "$current_link" || -L "$current_link" ]]; then
  [[ -L "$current_link" ]] || fail "current must be a symbolic link" 73
  previous_current_target=$(/usr/bin/readlink "$current_link")
  previous_current_canonical=${current_link:A}
  validate_version_target "$previous_current_canonical"
  had_current=1
fi

had_build=0
previous_build_target=""
if [[ -e "$build_link" || -L "$build_link" ]]; then
  [[ -L "$build_link" ]] || {
    fail "Refusing to replace non-symlink build path: $build_link" 73
  }
  previous_build_target=$(/usr/bin/readlink "$build_link")
  [[ "$previous_build_target" == "$release_dir" \
     || "$previous_build_target" == "$current_link" ]] || {
    fail "build must point exactly to $release_dir or $current_link" 73
  }
  if [[ "$previous_build_target" == "$release_dir" ]]; then
    [[ -d "$release_dir/TravelLockdown.app" \
       && ! -L "$release_dir/TravelLockdown.app" \
       && -x "$release_dir/TravelLockdown.app/Contents/MacOS/TravelLockdown" ]] || {
      fail "Legacy build pointer has no verified recovery executable" 73
    }
    codesign --verify --deep --strict "$build_link/TravelLockdown.app"
  else
    [[ "$had_current" == "1" ]] || fail "build points to a missing current release" 73
  fi
  had_build=1
fi

[[ ! -e "$staging_app" && ! -L "$staging_app" ]] || {
  fail "Staging path already exists: $staging_app" 73
}

publication_succeeded=0
current_switched=0
build_switched=0

rollback_publication() {
  local rollback_link
  if [[ "$publication_succeeded" == "1" ]]; then
    return
  fi

  if [[ "$build_switched" == "1" ]]; then
    rollback_link="$project_dir/.build.rollback.$$"
    rm -f -- "$rollback_link"
    if [[ "$had_build" == "1" ]]; then
      ln -s "$previous_build_target" "$rollback_link"
      mv -f -h "$rollback_link" "$build_link"
    else
      [[ -L "$build_link" ]] && rm -f -- "$build_link"
    fi
    build_switched=0
  fi

  if [[ "$current_switched" == "1" ]]; then
    rollback_link="$release_dir/.current.rollback.$$"
    rm -f -- "$rollback_link"
    if [[ "$had_current" == "1" ]]; then
      ln -s "$previous_current_target" "$rollback_link"
      mv -f -h "$rollback_link" "$current_link"
    else
      [[ -L "$current_link" ]] && rm -f -- "$current_link"
    fi
    current_switched=0
  fi
}

cleanup() {
  rollback_publication
  rm -rf -- "$staging_app"
  rm -f -- "$current_next" "$build_next"
}
trap cleanup EXIT

swift build -c release
[[ -x "$binary_path" ]] || fail "Missing release executable"

mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Resources"
cp "$binary_path" "$staging_app/Contents/MacOS/TravelLockdown"
cp "$plist_path" "$staging_app/Contents/Info.plist"
cp "$logo_path" "$staging_app/Contents/Resources/gamechangers-ai.png"
cp "$icon_path" "$staging_app/Contents/Resources/AppIcon.icns"
[[ -x "$staging_app/Contents/MacOS/TravelLockdown" ]] || fail "Packaged executable is missing"
[[ -f "$staging_app/Contents/Info.plist" ]] || fail "Packaged Info.plist is missing"
[[ -f "$staging_app/Contents/Resources/gamechangers-ai.png" ]] \
  || fail "Packaged GameChangers logo is missing"
[[ -f "$staging_app/Contents/Resources/AppIcon.icns" ]] \
  || fail "Packaged app icon is missing"

xattr -cr "$staging_app"
codesign --force --sign - "$staging_app"
xattr -cr "$staging_app"
codesign --verify --deep --strict "$staging_app"

mkdir -m 700 "$version_dir"
validate_owned_directory "$version_dir"
mv "$staging_app" "$version_app"
[[ -d "$version_app" && ! -L "$version_app" ]] || fail "Published version must be a real app bundle" 73
codesign --verify --deep --strict "$version_app"

ln -s "versions/$version_name" "$current_next"
[[ -L "$current_next" ]] || fail "Unable to create candidate current pointer" 73
candidate_target=${current_next:A}
[[ "$candidate_target" == "$version_dir" ]] || fail "Candidate current pointer resolved unexpectedly" 73
validate_version_target "$candidate_target"
mv -f -h "$current_next" "$current_link"
current_switched=1

ln -s "$current_link" "$build_next"
[[ -L "$build_next" && "${build_next:A}" == "$version_dir" ]] || {
  fail "Candidate build pointer resolved unexpectedly" 73
}
mv -f -h "$build_next" "$build_link"
build_switched=1

if ! (
  validate_release_root || exit $?
  validate_owned_directory "$versions_dir" || exit $?
  validate_version_target "${current_link:A}" || exit $?
  [[ -L "$build_link" && "$(/usr/bin/readlink "$build_link")" == "$current_link" ]] || {
    fail "build must point exactly to $current_link" 73
  }
  codesign --verify --deep --strict "$build_link/TravelLockdown.app"
); then
  rollback_publication
  fail "Published release verification failed" 74
fi

publication_succeeded=1
trap - EXIT
