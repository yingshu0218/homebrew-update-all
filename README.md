# brew-update-all

Upgrade Homebrew formulae and casks one by one with interactive selection.
Avoids batch failure caused by network issues – if one package fails, others continue.

## Install

```bash
brew tap yingshu0218/update-all
brew install brew-update-all
```

## Usage

```bash
# Interactive mode – pick packages by number
brew ua

# Auto mode – upgrade all without prompt
brew ua auto
```

## How it works

1. **brew update** – update Homebrew taps and package info
2. **List outdated packages** – show all outdated formulae and casks with continuous numbering (separated by `---`)
3. **Upgrade one by one** – download then install each selected package individually; errors do not block others
4. **brew cleanup** – remove old versions

## Uninstall

```bash
brew uninstall brew-update-all
brew untap yingshu0218/update-all
```

## License

MIT
