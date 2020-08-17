# AURa

AURa is an automated build system to build AUR packages for Arch Linux.

## Why

Every time you run a system upgrade on Arch Linux using an AUR helper, it takes plenty
of time to build packages that you have installed from the Arch User Repository. For me,
the rest of the system can easily upgrade within 5 minutes while the AUR packages take
another 20-30 minutes to build and install.

## What

AURa is a set of scripts that use GitHub actions to periodically build specified packages
and publish them on a custom repository hosted at Heroku.

## How

AURa accepts a [packagelist](packagelist) file where you can specify what AUR packages it
needs to build. It schedules a GitHub workflow to build the given packages every day. If no
PKGBUILDs have changed in the last day, the workflow exits with a failure, to prevent
building packages at all. In a single run, it builds all packages in the
[packagelist](packagelist) and publishes a new pacman repository in an NGINX docker
container on Heroku.

## Demo

You can use my package repository for demonstrating the results.

- Append the following to your `/etc/pacman.conf`. Set the `SigLevel` to `TrustAll` or
  import my [public PGP key](public.asc) to your Pacman keyring. See
  [adding unofficial keys](https://wiki.archlinux.org/index.php/Pacman/Package_signing#Adding_unofficial_keys)
  on Arch Wiki.

  ```sh
  [aura]
  SigLevel = Optional TrustAll
  Server = https://arch-aura.herokuapp.com/aura
  ```

- Run `pacman -Sy` to sync your package databases.

- Try to install an AUR package from my [packagelist](packagelist).

## Usage

- Fork this repository

- Add AUR packages to the [packagelist](packagelist).
  
  - To find out packages that you've installed from the AUR, you can run `pacman -Qm`. It
    will list all the packages that do not belong to any Pacman repositories. Then
    you can filter this list down to the AUR packages.

  - Some packages specify trusted PGP keys to verify their sources. You can find these key
    IDs in the `validpgpkeys` variable of their PKGBUILDs.

  - Once you have the list with optional PGP key IDs, you can add one package per line in
    the [packagelist](packagelist) in the following format.

    ```plain
    <package_name> <trusted_pgp_key_id_0> ... <trusted_pgp_key_id_n>
    ```

    e.g.

    ```plain
    kubectl-bin
    tor-browser EF6E286DDA85EA2A4BA7DE684E2C6E8793298290
    ```

- Generate a PGP key to sign built packages. It is mandatory in this setup.

  ```sh
  gpg --full-gen-key # use all the defaults and add your Name and email when prompted.
  gpg --armor --export-secret-keys GENERATED_KEY_ID > private.asc
  gpg --armor --export GENERATED_KEY_ID > public.asc
  # after exporting public and private keys, you may delete the PGP key from your system.
  gpg --delete-secret-keys GENERATED_KEY_ID
  gpg --delete-keys GENERATED_KEY_ID
  ```

- Add secrets for the GitHub workflow
  
  - `PGP_KEY_ID`: Paste the ID of the key generated in the previous step.

  - `PGP_SECRET_KEY`: Paste the contents of `private.asc` file created in the previous step.

  - `PGP_SECRET_KEY_PASSPHRASE`: The password for decrypting the private key generated in
    the previous step.

  - `HEROKU_EMAIL`: Your Heroku email.

  - `HEROKU_API_KEY`: API key to access Heroku. It can be found in **Heroku > Account
    Settings > API Key**.

  - `HEROKU_APP_NAME`: Name of the Heroku app to deploy the package repository.

- To test the setup, commit changes to the default branch (`master`) and check out a new
  `test` branch afterwards. Push the `test` branch to trigger a GitHub workflow run.

- To use your new repository with Pacman

  - Edit `/etc/pacman.conf` and append the following at the bottom of the file

    ```sh
    [aura]
    SigLevel = Required TrustedOnly
    Server = https://<your_heroku_app_name>.herokuapp.com/aura
    ```

  - Add your public PGP key to the Pacman keyring.

    ```sh
    sudo pacman-key --add public.asc # file from the previous steps
    # and then locally sign the imported key to mark it as trusted
    sudo pacman-key --lsign-key <imported_key_id>
    ```

  - Resync package databases using `sudo pacman -Sy`.

### Updating build frequency

By default, build is scheduled to run every day. To change it, edit the cron schedule
specified in the [GitHub workflow](.github/workflows/build.yaml) and the
`UPDATE_INTERVAL` variable in the [build script](build-packages.sh).

## Caveats

- It builds all packages in a single workflow run and overwrites older versions when
  publishing. At any given time, the package repository will only have the latest built
  version of a package.

- Pacman requests timeout in 10 seconds so it may error out if the Heroku dyno is asleep.
  To wake it up beforehand, hit the home page of the repository which is an HTML redirect
  to the [AURa GitHub repository](https://github.com/ashutoshgngwr/aura).

- Ensure that you only include the packages that you trust. Automatically building
  untrusted packages from AUR will expose your system to severe security risks.

- Sometimes AUR packages might receive faulty PKGBUILD updates. When it happens,
  the GitHub workflow will fail immediately without publishing any new packages.

## License

All source files are licensed under [Apache License Version 2.0](LICENSE) unless stated
explicitly.
