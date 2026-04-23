# SSH Navigator

A Commander-like terminal UI for browsing, searching, and connecting to hosts defined in your SSH config. Single self-contained Bash script, zero dependencies beyond standard Unix tools.

![shell](https://img.shields.io/badge/shell-bash%204.0%2B-brightgreen)
![deps](https://img.shields.io/badge/deps-awk%20%7C%20stty-blue)

## Features

- Scrollable, filterable list of every `Host` entry in your SSH config
- Real-time case-insensitive search across aliases, hostnames, users, and section labels
- Multi-alias `Host` entries expand to one row per alias
- Detail view, in-app Add Host form, and editable launch command template
- Configurable launch command with placeholder substitution (`$H`, `$HN`, `$U`, `$P`, `$K`, `$PJ`)
- Zero-fork buffered ANSI rendering — flicker-free and instant on any host count

## Install

```bash
chmod +x ssh-navigator.sh
cp ssh-navigator.sh /usr/local/bin/ssh-navigator
```

Requires Bash 4.0+ and a 256-color terminal.

## Usage

```bash
ssh-navigator                                # browse ~/.ssh/config
ssh-navigator -c /path/to/ssh_config         # alternate config file
ssh-navigator --cmd "mosh \$U@\$HN"          # custom launch command
```

### Keybindings

| Key            | Action                          |
|----------------|---------------------------------|
| `Up`/`Down`    | Navigate                        |
| `PgUp`/`PgDn`  | Page up/down                    |
| `Home`/`End`   | Jump to first/last              |
| `/`            | Search                          |
| `Enter`        | Connect                         |
| `v`            | View host details               |
| `a`            | Add new host                    |
| `e`            | Edit launch command             |
| `q`            | Quit                            |

### Launch command placeholders

| Placeholder | Value            |
|-------------|------------------|
| `$H`        | Host alias       |
| `$HN`       | HostName/IP      |
| `$U`        | User             |
| `$P`        | Port             |
| `$K`        | IdentityFile     |
| `$PJ`       | ProxyJump        |

## Documentation

See [ssh-navigator-user-guide.md](ssh-navigator-user-guide.md) for the full reference, including SSH config format, section headers, configuration precedence, and troubleshooting.
