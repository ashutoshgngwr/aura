#!/usr/bin/env bash
set -e

# output directory for built packages. used in build_package()
output_dir="$(pwd)/output"

# a file containing AUR packages to build, 1 name per line. e.g "spotify"
package_list="$(pwd)/packagelist"

# makepkg and other related commands are run as build_user
build_user="build"

# PGP keyserver used to fetch keys for package source verification
pgp_keyserver="pool.sks-keyservers.net"

# heroku app URL for current package repository
aura_base_url="https://${HEROKU_APP_NAME}.herokuapp.com"

# sets up a non-root build_user to run 'makepkg' script. also gives the newly
# created user 'rwx' permissions on the current working directory.
setup_build_user() {
  echo "Setting up '$build_user' user..."
  useradd -m "$build_user"
  test -d "/etc/sudoers.d" || mkdir -p "/etc/sudoers.d"
  echo "$build_user ALL=(ALL) NOPASSWD:ALL" >> "/etc/sudoers.d/$build_user"
  setfacl -m u:build:rwx . # permissions on current dir and stuff
}

# checks if an old repository deployment exists at the destination Heroku dyno
is_aura_repository_available() {
  echo "Waiting for Heroku dyno to wake-up..."
  local status=$(curl -sSLo /dev/null -w "%{http_code}" "$aura_base_url")
  if [ "200" != "$status" ]; then
    return 1
  fi
}

# adds the AURa repository to the '/etc/pacman.conf'.
add_aura_repository_to_pacman() {
  echo "Adding existing AURa repository to Pacman conf..."
  local pacman_repo_conf="/etc/pacman.conf"
  echo "[aura]" >> "$pacman_repo_conf"
  echo "SigLevel = Required TrustedOnly" >> "$pacman_repo_conf"
  echo "Server = $aura_base_url/aura" >> "$pacman_repo_conf"

  local public_key_file="public.asc"
  echo -e "$PGP_PUBLIC_KEY" > "$public_key_file"
  pacman-key --init
  pacman-key --add "$public_key_file"
  pacman-key --lsign-key "$PGP_KEY_ID"
  rm -f "$public_key_file"
}

# sets up the private PGP key passed using the environment variable. This key is
# used for generating package and repo db signatures. A few GPG conf params are
# needed to be set to pass passphrase via stdin.
# https://stackoverflow.com/a/59170001/2410641
setup_signing_key() {
  echo "Adding package signing key to $build_user's PGP keyring..."
  echo -e "$PGP_SECRET_KEY" | gpg --import --batch
  echo "use-agent" >> "$HOME/.gnupg/gpg.conf"
  echo "pinentry-mode loopback" >> "$HOME/.gnupg/gpg.conf"
  echo "allow-loopback-pinentry" >> "$HOME/.gnupg/gpg-agent.conf"
}

# generates a detached signature for the given file. Accepts the following
# positional args
# 1. file path: path of the file to sign
sign_file() {
  echo "Signing file $1..."
  echo "$PGP_SECRET_KEY_PASSPHRASE" | \
    gpg --batch --passphrase-fd 0 --detach-sign --no-armor -u "$PGP_KEY_ID" "$1"
}

# installs any prerequisites required for the build process.
install_prerequisites() {
  echo "Installing prerequisites..."
  setup_build_user
  if is_aura_repository_available; then
    add_aura_repository_to_pacman
  fi

  pacman -Sqyuu --noconfirm --noprogressbar base-devel git jq
  setup_signing_key

  # ensure output_dir is owned by the build_user. If builds starts with a
  # package that hasn't been updated, it will be downloaded from the old
  # repository using pacman. If pacman ends up creating the output_dir,
  # build_user won't have write access to it.
  test -d "$output_dir" || sudo -u "$build_user" mkdir -p "$output_dir"
}

# makes a RPC to the AUR API and fetches information for all the packages listed
# in 'package_list'. Prints the fetched information to 'stdout' in JSON.
get_package_infos() {
  local base_url="https://aur.archlinux.org/rpc/?v=5&type=info"
  local args=""
  while read package; do
    args="$args&arg[]=$package"
  done < "$package_list"

  curl -sSL "$base_url$args" # leading '&' will be present in 'args' from the loop
}

# builds a given package using 'makepkg'. accepts the following position args
# 1. packge name: name of the AUR package being built
# 2. package base: to clone the correct AUR git repository for building packages
# 3. aura version: latest version of the package available in current repo. can
#    be empty but the argument is required
build_package() {
  local aura_version="$(pacman -Ss ^$1$ | head -n1 | awk '{print $2}')"
  echo "package: '$1', aura version: '${aura_version:-none}', aur version: '$3'"
  if [ "$aura_version" == "$3" ]; then
    echo "Latest AUR version found in old AURa repository! Downloading..."
    pacman -Sqddw --noconfirm --noprogressbar --cachedir "$output_dir" "$1"
  else
    echo "Latest AUR version not found in old AURa repository! Building..."
    sudo -u "$build_user" git clone --depth=1 "https://aur.archlinux.org/$2.git"
    cd "$2"

    # import PGP keys to verify package integrity
    for key in $(. ./PKGBUILD; echo $validpgpkeys); do
      sudo -u "$build_user" gpg --keyserver="$pgp_keyserver" --receive-keys "$key"
    done

    sudo -u "$build_user" makepkg -f -s --noconfirm --noprogressbar PKGDEST="$output_dir"
    cd ..
    rm -rf "$2"
  fi
}

# build_repo_db runs the repo-add script to generate a new db adding all the
# packages present in the 'output_dir'. It also signs the resulting DB files
# using 'sign_file' while preserving the file structure mentioned in the
# following wiki.
# https://wiki.archlinux.org/index.php/DeveloperWiki:Repo_DB_Signing#[RFC]_Repo_DB_signing_(and_ISO's/other_artefacts)
build_repo_db() {
  echo "Building package database..."
  local repo_base="$output_dir/aura"
  local repo_db_base="$repo_base.db"
  local repo_db="$repo_db_base.tar.gz"
  local repo_files_base="$repo_base.files"
  local repo_files="$repo_base.files.tar.gz"
  repo-add "$repo_db" $output_dir/*.pkg.tar.zst
  sign_file "$repo_db"
  sign_file "$repo_files"
  ln -rs "$repo_db.sig" "$repo_db_base.sig"
  ln -rs "$repo_files.sig" "$repo_files_base.sig"
}

main() {
  install_prerequisites
  local package_infos="$(get_package_infos)"
  while read package; do
    local aur_version=$(echo "$package_infos" | jq -r ".results[] | select(.Name==\"$package\") | .Version")
    local package_base=$(echo "$package_infos" | jq -r ".results[] | select(.Name==\"$package\") | .PackageBase")
    build_package "$package" "$package_base" "$aur_version"
  done < "$package_list"

  for file in $(ls $output_dir/*.pkg.tar.zst); do
    sign_file "$file"
  done

  build_repo_db
}

main "$@"
