#!/usr/bin/env bash
set -xe

# period in seconds when the job re-runs (used to determine
# if any PKGBUILDS have changed since last run)
RUN_INTERVAL="186400"

# output directory for built packages. used in build_package()
OUTPUT_DIR="$(pwd)/output"

# a file containing AUR packages to build. 1 name per line
PACKAGE_LIST="$(pwd)/packagelist"

# sets up a non-root user to 'makepkg' script. also gives the newly
# created user 'rwx' permissions on the working directory.
setup_build_user() {
  useradd -m build
  gpasswd -a build wheel
  test -d "/etc/sudoers.d" || mkdir "/etc/sudoers.d"
  echo "build ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/build
  setfacl -m u:build:rwx . # permissions on current dir and stuff
}

# installs any prerequisites required for the
# build process.
install_prerequisites() {
  setup_build_user
  pacman -Sqyuu --noconfirm --noprogressbar base-devel git
}

# checks if any PKGBUILDs have been modified since this script was
# last run. This is determined based on the  schedule provided by
# the 'RUN_INTERVAL' variable
check_updates() {
  BASE_URL="https://aur.archlinux.org/rpc/?v=5&type=info"
  ARGS=""
  while read package; do
    ARGS="$ARGS&arg[]=$package"
  done < "$PACKAGE_LIST"

  URL="$BASE_URL$ARGS" # leading '&' will be present in $ARGS from the while loop
  LATEST_UPDATE=$(curl -sSL "$URL" | jq ".results[].LastModified" | sort -r | head -n1)
  NOW="$(date +%s)"

  if [ $(( NOW - LATEST_UPDATE )) -lt "$RUN_INTERVAL" ]; then
    return 1
  fi
}

# builds a given package using 'makepkg'.
# accepts following position args
# 1. packge name: name of the AUR package being built
build_package() {
  sudo -u build git clone --depth=1 "https://aur.archlinux.org/$1.git"
  cd "$1"
  sudo -u build makepkg -s --noconfirm --noprogressbar PKGDEST="$OUTPUT_DIR"
  cd ..
}

main() {
  install_prerequisites
  if ! check_updates; then
    echo "No PKGBUILD has been modified since last run"
    exit 0
  fi

  while read package; do
    build_package "$package"
  done < "$PACKAGE_LIST"
  repo-add "$OUTPUT_DIR/aura.db.tar.gz" $OUTPUT_DIR/*.pkg.tar.zst
}

main "$@"
