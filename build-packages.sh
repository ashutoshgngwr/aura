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
  test -d "/etc/sudoers.d" || mkdir -p "/etc/sudoers.d"
  echo "build ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/build
  setfacl -m u:build:rwx . # permissions on current dir and stuff

  # fix: dirmngr is giving TLS authentication errors when importing keys.
  # happening because the default keyservers' CA is distributed with the
  # binaries and its not present in the common CA store?
  test -d "/home/build/.gnupg" || mkdir -p "/home/build/.gnupg"
  echo "hkp-cacert /usr/share/gnupg/sks-keyservers.netCA.pem" >> /home/build/.gnupg/dirmngr.conf
  chown -R build "/home/build/.gnupg"
  chmod 700 "/home/build/.gnupg"
  chmod 600 "/home/build/.gnupg/dirmngr.conf"
}

# sets up the private PGP key passed using the environment variable. This key is used for
# generating package and repo db signatures. A few GPG conf params are needed to be set to
# pass passphrase via stdin. https://stackoverflow.com/a/59170001/2410641
setup_signing_key() {
  set +x
  echo -e "$PGP_SECRET_KEY" | gpg --import --batch
  set -x

  echo "use-agent" >> "$HOME/.gnupg/gpg.conf"
  echo "pinentry-mode loopback" >> "$HOME/.gnupg/gpg.conf"
  echo "allow-loopback-pinentry" >> "$HOME/.gnupg/gpg-agent.conf"
}

# generates a detached signature for the given file. Accepts the following positional args
# 1. file path: path of the file to sign
sign_file() {
  set +x
  echo "Signing file $1..."
  echo "$PGP_SECRET_KEY_PASSPHRASE" | gpg --batch --passphrase-fd 0 --detach-sign --no-armor -u "$PGP_KEY_ID" "$1"
  set -x
}

# installs any prerequisites required for the build process.
install_prerequisites() {
  setup_build_user
  pacman -Sqyuu --noconfirm --noprogressbar base-devel git jq
  setup_signing_key
}

# checks if any PKGBUILDs have been modified since this script was last run. This is determined
# based on the schedule provided by the 'RUN_INTERVAL' variable
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

# builds a given package using 'makepkg'. accepts the following position args
# 1. packge name: name of the AUR package being built
# 2. keys: a space seperate list of PGP keys to import for verifying source
#    signatures during the build
build_package() {
  test -z "$keys" || sudo -u build gpg --receive-keys $keys
  sudo -u build git clone --depth=1 "https://aur.archlinux.org/$1.git"
  cd "$1"
  sudo -u build makepkg -s --noconfirm --noprogressbar PKGDEST="$OUTPUT_DIR"
  sign_file $(ls "$OUTPUT_DIR/$1"-*.pkg.tar.zst)
  cd ..
  rm -rf "$1"
}

# build_repo_db runs the repo-add script to generate a new db adding all the packages
# present in the 'OUTPUT_DIR'. It also signs the resulting DB files using 'sign_file'
# while preserving the file structure mentioned in the following wiki.
# https://wiki.archlinux.org/index.php/DeveloperWiki:Repo_DB_Signing#[RFC]_Repo_DB_signing_(and_ISO's/other_artefacts)
build_repo_db() {
  REPO_BASE="$OUTPUT_DIR/aura"
  REPO_DB_BASE="$REPO_BASE.db"
  REPO_DB="$REPO_DB_BASE.tar.gz"
  REPO_FILES_BASE="$REPO_BASE.files"
  REPO_FILES="$REPO_BASE.files.tar.gz"
  repo-add "$REPO_DB" $OUTPUT_DIR/*.pkg.tar.zst
  sign_file "$REPO_DB"
  sign_file "$REPO_FILES"
  ln -rs "$REPO_DB.sig" "$REPO_DB_BASE.sig"
  ln -rs "$REPO_FILES.sig" "$REPO_FILES_BASE.sig"
}

main() {
  install_prerequisites
  check_updates
  while read package keys; do
    build_package "$package" "$keys"
  done < "$PACKAGE_LIST"
  build_repo_db
}

main "$@"
