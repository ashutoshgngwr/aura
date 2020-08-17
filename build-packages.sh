#!/usr/bin/env bash
set -xe

# period in seconds when the job re-runs (used to determine
# if any PKGBUILDS have changed since last run)
RUN_INTERVAL="86400"

# output directory for built packages. used in build_package()
OUTPUT_DIR="$(pwd)/output"

# a file containing AUR packages to build. 1 name per line optionally with GPG keys it needs to import
# e.g. "spotify 931FF8E79F0876134EDDBDCCA87FF9DF48BF1C90 2EBF997C15BDA244B6EBF5D84773BD5E130D1D45"
PACKAGE_LIST="$(pwd)/packagelist"

# sets up a non-root user to 'makepkg' script. also gives the newly
# created user 'rwx' permissions on the working directory.
setup_build_user() {
  useradd -m build
  gpasswd -a build wheel
  test -d "/etc/sudoers.d" || mkdir "/etc/sudoers.d"
  echo "build ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/build
  setfacl -m u:build:rwx . # permissions on current dir and stuff

  # fix: dirmngr is giving TLS authentication errors when importing keys.
  # happening because the default keyservers' CA is distributed with the
  # binaries and its not present in the common CA store?
  test -d "/home/build/.gnupg" || mkdir "/home/build/.gnupg"
  echo "hkp-cacert /usr/share/gnupg/sks-keyservers.netCA.pem" >> /home/build/.gnupg/dirmngr.conf
  chown -R build "/home/build/.gnupg"
  chmod 700 "/home/build/.gnupg"
  chmod 600 "/home/build/.gnupg/dirmngr.conf"
}

# installs any prerequisites required for the
# build process.
install_prerequisites() {
  setup_build_user
  pacman -Sqyuu --noconfirm --noprogressbar base-devel git jq
}

# checks if any PKGBUILDs have been modified since this script was
# last run. This is determined based on the  schedule provided by
# the 'RUN_INTERVAL' variable
check_updates() {
  BASE_URL="https://aur.archlinux.org/rpc/?v=5&type=info"
  ARGS=""
  while read package keys; do
    ARGS="$ARGS&arg[]=$package"
  done < "$PACKAGE_LIST"

  URL="$BASE_URL$ARGS" # leading '&' will be present in $ARGS from the while loop
  LATEST_UPDATE=$(curl -sSL "$URL" | jq ".results[].LastModified" | sort -r | head -n1)
  NOW="$(date +%s)"

  if [ $(( NOW - LATEST_UPDATE )) -gt "$RUN_INTERVAL" ]; then
    echo "No PKGBUILD has been modified since last run"
    return 1
  fi
}

# builds a given package using 'makepkg'.
# accepts following position args
# 1. packge name: name of the AUR package being built
build_package() {
  test -z "$keys" || sudo -u build gpg --receive-keys $keys
  sudo -u build git clone --depth=1 "https://aur.archlinux.org/$1.git"
  cd "$1"
  sudo -u build makepkg -s --noconfirm --noprogressbar PKGDEST="$OUTPUT_DIR"
  cd ..
  rm -rf "$1"
}

main() {
  install_prerequisites
  check_updates
  while read package keys; do
    build_package "$package" "$keys"
  done < "$PACKAGE_LIST"
  repo-add "$OUTPUT_DIR/aura.db.tar.gz" $OUTPUT_DIR/*.pkg.tar.zst
}

main "$@"
