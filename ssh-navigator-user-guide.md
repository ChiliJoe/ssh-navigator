# SSH Navigator User Guide

## Table of Contents

- [Overview](#overview)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Keybindings Reference](#keybindings-reference)
- [Features in Detail](#features-in-detail)
  - [Browsing Hosts](#browsing-hosts)
  - [Searching and Filtering](#searching-and-filtering)
  - [Viewing Host Details](#viewing-host-details)
  - [Connecting to Hosts](#connecting-to-hosts)
  - [Adding New Hosts](#adding-new-hosts)
  - [Editing the Launch Command](#editing-the-launch-command)
- [Configurable Launch Command](#configurable-launch-command)
  - [Default Behavior](#default-behavior)
  - [Placeholders](#placeholders)
  - [Configuration Methods](#configuration-methods)
  - [Precedence Order](#precedence-order)
  - [Real-World Examples](#real-world-examples)
- [Command-Line Options](#command-line-options)
- [Environment Variables](#environment-variables)
- [SSH Config Format](#ssh-config-format)
  - [Supported Properties](#supported-properties)
  - [Host Aliases](#host-aliases)
  - [Section Headers](#section-headers)
  - [Example Config File](#example-config-file)
- [Performance Notes](#performance-notes)
- [Troubleshooting](#troubleshooting)

---

## Overview

SSH Navigator is a Commander-like terminal user interface (TUI) for browsing, searching, and connecting to hosts defined in your SSH config file. Built entirely in Bash with no external dependencies beyond standard Unix tools (`awk`, `stty`), it provides:

- A scrollable, filterable list of all hosts in your SSH config
- Real-time search across host names, aliases, IPs, usernames, and section labels
- Support for multi-alias `Host` entries (e.g., `Host app1 app-primary`) -- each alias appears as its own row
- A detail view showing all properties of a selected host
- One-keypress connection to any host
- An in-app form for adding new hosts directly to your SSH config
- A fully configurable launch command with placeholder substitution, editable at runtime
- High-performance rendering using buffered ANSI escapes (zero process forks per render cycle)

SSH Navigator reads your `~/.ssh/config` file (or any config file you specify), parses out every `Host` entry along with its properties, and presents them in a navigable table. You never need to remember host aliases or manually grep through long config files again.

---

## Installation

SSH Navigator is a single self-contained Bash script. No package manager or build step is required.

1. **Copy the script** to a location of your choice:

   ```bash
   cp ssh-navigator.sh /usr/local/bin/ssh-navigator
   ```

   Or keep it wherever you like -- any directory works.

2. **Make it executable:**

   ```bash
   chmod +x /usr/local/bin/ssh-navigator
   ```

3. **(Optional) Add to your PATH** if you placed it outside a standard PATH directory:

   ```bash
   # Add to ~/.bashrc or ~/.zshrc
   export PATH="$PATH:/path/to/directory/containing/ssh-navigator"
   ```

4. **Verify the installation:**

   ```bash
   ssh-navigator --version
   ```

### Requirements

- Bash 4.0 or later (for `declare -a` arrays and `${var,,}` lowercase syntax)
- Standard Unix utilities: `awk`, `stty`, `grep`, `cp`, `date`, `sed`
- A terminal emulator that supports ANSI escape sequences and 256-color mode

> **Note:** SSH Navigator uses inline ANSI escape sequences for all rendering and terminal control. It does not depend on `tput` at runtime.

---

## Quick Start

1. Make sure you have an SSH config file at `~/.ssh/config` with at least one `Host` entry.

2. Run the script:

   ```bash
   ./ssh-navigator.sh
   ```

3. Use the **Up/Down** arrow keys to highlight a host.

4. Press **Enter** to connect, **v** to view details, or **/** to search.

5. Press **q** to quit.

That is all you need to get started. The rest of this guide covers every feature in depth.

---

## Keybindings Reference

### List View (Main Screen)

| Key               | Action                                      |
|-------------------|---------------------------------------------|
| `Up`              | Move cursor up one row                      |
| `Down`            | Move cursor down one row                    |
| `Page Up`         | Scroll up by one page                       |
| `Page Down`       | Scroll down by one page                     |
| `Home`            | Jump to the first host                      |
| `End`             | Jump to the last host                       |
| `Enter`           | Connect to the selected host                |
| `v` / `V`        | Open detail view for the selected host      |
| `a` / `A`        | Open the Add New Host form                  |
| `e` / `E`        | Open the Edit Launch Command editor         |
| `/`               | Enter search mode                           |
| `q` / `Q`        | Quit SSH Navigator                          |
| Any other letter  | Enter search mode with that character typed |

### Search Mode

| Key          | Action                                          |
|--------------|-------------------------------------------------|
| Any letter   | Append to the search query (filters in real time)|
| `Backspace`  | Delete the last character from the search query |
| `Enter`      | Confirm the filter and return to normal navigation |
| `Esc`        | Clear the search and return to normal navigation |
| `Up`         | Exit search mode and move cursor up             |
| `Down`       | Exit search mode and move cursor down           |

### Detail View

| Key            | Action                                    |
|----------------|-------------------------------------------|
| `c` / `Enter`  | Connect to the displayed host            |
| `e` / `E`      | Open the Edit Launch Command editor      |
| `q` / `Esc`    | Return to the list view                  |

### Add Host Form

| Key          | Action                                   |
|--------------|------------------------------------------|
| `Up`         | Move to the previous field               |
| `Down`       | Move to the next field                   |
| `Tab`        | Move to the next field                   |
| Any letter   | Type into the currently selected field   |
| `Backspace`  | Delete the last character in the current field |
| `Enter`      | Validate and save the new host           |
| `Esc`        | Cancel and return to the list view       |

### Edit Launch Command View

| Key          | Action                                          |
|--------------|-------------------------------------------------|
| Any letter   | Type into the command field                     |
| `Backspace`  | Delete the last character from the command      |
| `Enter`      | Save the new launch command                     |
| `Esc`        | Cancel and return to the previous view          |

---

## Features in Detail

### Browsing Hosts

When SSH Navigator starts, it parses your SSH config and displays all hosts in a four-column table:

| Column       | Description                                          |
|--------------|------------------------------------------------------|
| HOST         | The SSH `Host` alias (e.g., `idm-db-dev`)           |
| HOSTNAME/IP  | The `HostName` value (IP address or FQDN)           |
| USER         | The `User` property, or `--` if not set             |
| SECTION      | The section label from `### Section ###` headers    |

If a `Host` entry has multiple aliases (e.g., `Host app1 app-primary`), each alias appears as its own row in the list. Both rows share the same connection details, so you can connect using whichever alias you prefer.

The currently selected row is highlighted in bold white on blue. The header bar at the top shows the total number of hosts, the currently active filter (if any), and the active launch command template.

**Navigation:**

- **Up/Down arrows** move the cursor one row at a time.
- **Page Up/Page Down** scroll by a full page (the number of visible rows).
- **Home** jumps to the very first host; **End** jumps to the very last.
- The list automatically scrolls to keep the cursor visible at all times.

**Terminal resize:** SSH Navigator detects terminal size changes via the `SIGWINCH` signal and redraws the interface to fit the new dimensions automatically.

### Searching and Filtering

Press **`/`** to enter search mode. A search prompt appears near the top of the screen. As you type, the host list is filtered in real time to show only matching entries.

The search is **case-insensitive** and matches against five fields simultaneously:

- Host alias (the current row's name)
- All aliases (for multi-alias `Host` entries, every alias is searchable from any row)
- HostName / IP address
- User
- Section label

For example, typing `dev` will show all hosts whose name, alias, IP, user, or section contains "dev". For a multi-alias host like `Host app1 app-primary`, searching for "primary" will find both the `app1` row and the `app-primary` row.

You can also begin typing any letter while in the list view (without pressing `/` first) and the tool will automatically enter search mode with that character.

**While in search mode:**

- **Enter** locks in the current filter and returns to normal navigation within the filtered results.
- **Esc** clears the search entirely (restoring the full host list) and exits search mode.
- **Up/Down** exits search mode and begins navigating immediately.
- **Backspace** removes the last character from the query.

### Viewing Host Details

Press **`v`** on a selected host to open the detail view. This displays a bordered box showing all parsed properties:

- Host (the alias for this row)
- Aliases (shown only when the host has multiple aliases, e.g., `app1 app-primary`)
- Section
- HostName
- User
- Port
- IdentityFile
- ProxyJump
- IdentitiesOnly
- Launch cmd (the fully resolved command that would be executed)

From the detail view you can:

- Press **`c`** or **Enter** to connect to the host.
- Press **`e`** to open the launch command editor.
- Press **`q`** or **Esc** to return to the main list.

### Connecting to Hosts

Press **Enter** in the list view (or **`c`** / **Enter** in the detail view) to connect to the selected host. SSH Navigator will:

1. Exit the TUI (restore the normal terminal).
2. Display the resolved launch command being executed.
3. Run the command (by default, `ssh <host-alias>`).
4. When the SSH session ends, display a prompt: "Session ended. Press any key to return to SSH Navigator."
5. Re-enter the TUI exactly where you left off.

This means you can connect to a host, finish your work, and seamlessly return to the navigator to connect to another.

### Adding New Hosts

Press **`a`** to open the Add New Host form. The form has seven fields:

| Field        | Required | Default | Description                              |
|--------------|----------|---------|------------------------------------------|
| Host         | Yes      | (none)  | The alias for the host entry             |
| HostName     | Yes      | (none)  | IP address or fully qualified domain name|
| User         | No       | (none)  | SSH username                             |
| Port         | No       | `22`    | SSH port number                          |
| IdentityFile | No       | (none)  | Path to the private key                  |
| ProxyJump    | No       | (none)  | Proxy/bastion host alias                 |
| Section      | No       | (none)  | Section label for organization           |

**Navigating the form:**

- Use **Up/Down** or **Tab** to move between fields.
- Type to fill in the currently active field (highlighted with `>`).
- **Backspace** deletes the last character in the current field.

**Saving:**

- Press **Enter** to validate and save.
- Validation checks that Host and HostName are non-empty and that the Host alias does not already exist.
- On validation failure, an error message is displayed and you remain in the form.

**What happens on save:**

1. A timestamped backup of your SSH config is created (e.g., `~/.ssh/config.bak.1713200000`).
2. The new host entry is appended to the config file.
   - If you specified a Section that does not already exist, a new `### Section ###` header is added.
   - Port is only written if it differs from the default of `22`.
3. The config is re-parsed and the host list refreshes automatically.
4. A success message is displayed showing the backup path.

Press **Esc** at any time to cancel and return to the list without saving.

### Editing the Launch Command

Press **`e`** from either the list view or the detail view to open the launch command editor. This view shows:

- The current launch command template
- A text input field pre-populated with the current command
- A reference card of all available placeholders
- Example commands

Type your new command template, then press **Enter** to save it or **Esc** to cancel. The change takes effect immediately and is written back into the script file itself between the `#::LAUNCH_CMD_BEGIN` / `#::LAUNCH_CMD_END` sentinel markers. This means the script is fully self-contained -- you can distribute the modified script and recipients will get your custom launch command out of the box.

---

## Configurable Launch Command

The launch command is the shell command that SSH Navigator executes when you connect to a host. It supports placeholder substitution so you can customize exactly how connections are made.

### Default Behavior

By default, the launch command is:

```
ssh $H
```

This runs `ssh` with the host alias as the argument, which is the standard way to connect using SSH config entries.

### Placeholders

The following placeholders are available in the launch command template. When a connection is initiated, each placeholder is replaced with the corresponding value from the selected host entry.

| Placeholder | Description                     | Example Value              |
|-------------|---------------------------------|----------------------------|
| `$H`        | Host alias                      | `idm-db-dev`              |
| `$HN`       | HostName / IP address           | `203.0.113.42`            |
| `$U`        | User                            | `admin`                   |
| `$P`        | Port                            | `22`                      |
| `$K`        | IdentityFile path               | `~/.sshkeys/mykey`        |
| `$PJ`       | ProxyJump host                  | `bastion-host`            |

**Note on replacement order:** `$HN` is replaced before `$H` to prevent the `$H` inside `$HN` from being substituted prematurely. You do not need to worry about this; it is handled automatically.

### Configuration Methods

There are three ways to set the launch command, listed from least to most preferred:

#### 1. Environment Variable: `SSH_NAV_CMD`

Set the `SSH_NAV_CMD` environment variable before running the script:

```bash
export SSH_NAV_CMD="mosh \$U@\$HN"
ssh-navigator.sh
```

Or inline:

```bash
SSH_NAV_CMD="mosh \$U@\$HN" ssh-navigator.sh
```

Note that you must escape the `$` signs with backslashes when setting the variable in the shell, to prevent the shell from expanding them immediately.

#### 2. Command-Line Flag: `--cmd`

Pass the template directly when launching:

```bash
ssh-navigator.sh --cmd "ssh-vault \$HN"
```

The `--cmd` flag overrides the `SSH_NAV_CMD` environment variable.

#### 3. In-App Editor (`e` key)

Press **`e`** while SSH Navigator is running to modify the launch command interactively. This is the easiest method and does not require escaping. The change is written back into the script file between the `#::LAUNCH_CMD_BEGIN` / `#::LAUNCH_CMD_END` sentinel markers, so it persists across sessions and survives distribution of the script.

### Embedded Configuration

The script contains a clearly marked configuration block near the top:

```bash
#::LAUNCH_CMD_BEGIN
EMBEDDED_CMD='ssh $H'
#::LAUNCH_CMD_END
```

This value is used as the default when no `--cmd` flag or `SSH_NAV_CMD` environment variable is set. When you edit the command via the `e` key, this line is rewritten in-place. You can also edit it manually with a text editor.

### Precedence Order

When multiple configuration methods are used, the following precedence applies (highest to lowest):

1. **`--cmd` flag** -- always wins if provided
2. **`SSH_NAV_CMD` environment variable** -- used if `--cmd` is not given
3. **Embedded value** in script (`EMBEDDED_CMD`) -- the self-contained default

### Real-World Examples

| Use Case                        | Launch Command Template                          |
|---------------------------------|--------------------------------------------------|
| Standard SSH (default)          | `ssh $H`                                         |
| SSH with explicit user and host | `ssh $U@$HN`                                    |
| SSH with custom port and key    | `ssh -i $K -p $P $U@$HN`                        |
| SSH Vault                       | `ssh-vault $HN`                                  |
| Mosh (mobile shell)             | `mosh $U@$HN`                                   |
| Mosh with SSH port              | `mosh --ssh="ssh -p $P" $U@$HN`                 |
| Custom wrapper script           | `my-connect.sh --host $HN --user $U --key $K`   |
| SCP file to host                | `scp ./file.tar.gz $U@$HN:/tmp/`                |
| Open SFTP session               | `sftp -i $K $U@$HN`                             |
| ProxyJump passthrough           | `ssh -J $PJ $U@$HN`                             |
| Tmux attach after connecting    | `ssh -t $H 'tmux attach || tmux new'`            |

---

## Command-Line Options

| Flag                | Short | Description                                        |
|---------------------|-------|----------------------------------------------------|
| `--help`            | `-h`  | Display the help message and exit                  |
| `--version`         | `-v`  | Print the version number and exit                  |
| `--config PATH`     | `-c`  | Path to the SSH config file (default: `~/.ssh/config`) |
| `--cmd TEMPLATE`    |       | Set the launch command template (default: `ssh $H`)|

### Usage Examples

```bash
# Use defaults
ssh-navigator.sh

# Specify a different config file
ssh-navigator.sh --config /path/to/my/ssh_config

# Short form
ssh-navigator.sh -c /path/to/my/ssh_config

# Set a custom launch command
ssh-navigator.sh --cmd "mosh \$U@\$HN"

# Combine options
ssh-navigator.sh -c ~/work-ssh-config --cmd "ssh -i \$K \$U@\$HN -p \$P"
```

If an unknown option is passed, the tool prints an error and shows the help text.

---

## Environment Variables

| Variable       | Description                                        | Default            |
|----------------|----------------------------------------------------|--------------------|
| `SSH_CONFIG`   | Path to the SSH config file                        | `~/.ssh/config`    |
| `SSH_NAV_CMD`  | Launch command template with placeholders           | `ssh $H`           |

Both environment variables can be overridden by their corresponding command-line flags (`--config` and `--cmd` respectively).

### Setting Environment Variables Persistently

Add these to your shell profile (`~/.bashrc`, `~/.zshrc`, etc.) for persistent configuration:

```bash
# Always use a specific config file
export SSH_CONFIG="$HOME/.ssh/config_work"

# Always use mosh instead of ssh
export SSH_NAV_CMD="mosh \$U@\$HN"
```

---

## SSH Config Format

SSH Navigator reads standard OpenSSH config files. It extracts host entries and their properties using `awk`-based parsing.

### Supported Properties

The following SSH config directives are recognized and parsed:

| Directive        | Description                                          |
|------------------|------------------------------------------------------|
| `Host`           | The host alias or aliases (wildcards like `Host *` are ignored) |
| `HostName`       | The actual hostname or IP address                    |
| `User`           | The SSH username                                     |
| `Port`           | The port number (defaults to `22` if absent)         |
| `IdentityFile`   | Path to the SSH private key                          |
| `ProxyJump`      | The jump host for proxied connections                |
| `IdentitiesOnly` | Whether to use only the specified identity file      |

Other directives (e.g., `ForwardAgent`, `ServerAliveInterval`, `LocalForward`) are silently ignored. They remain in your config file and are still honored by `ssh` itself -- SSH Navigator simply does not display them.

**Note:** The `Host *` wildcard entry is intentionally excluded from the host list, as it represents global defaults rather than a connectable host.

### Host Aliases

SSH allows a single `Host` entry to define multiple aliases, separated by spaces:

```
Host app1 app-primary
    HostName 203.0.113.50
    User admin
    IdentityFile ~/.sshkeys/example_key
```

In this example, both `ssh app1` and `ssh app-primary` connect to the same server.

SSH Navigator handles multi-alias hosts by creating a **separate row for each alias** in the host list. Both rows share the same connection details (HostName, User, IdentityFile, etc.), so you can search for and connect via whichever alias you prefer.

In the detail view (`v`), an **Aliases** field is shown when a host has more than one alias, displaying the full list (e.g., `app1 app-primary`). The search index includes all aliases, so searching for any one alias will surface every row belonging to that host entry.

### Section Headers

SSH Navigator supports an optional convention for organizing hosts into named sections using specially formatted comments:

```
### Section Name ###
```

The format is:

- Starts with `###`
- Followed by whitespace
- Then the section name
- Ending with `###` (optionally followed by whitespace)

Section headers are not part of the standard SSH config specification. They are plain comments (lines starting with `#`) that SSH ignores, but SSH Navigator uses them as organizational labels. Every `Host` entry following a section header is tagged with that section name until a new section header is encountered.

### Example Config File

```
### Production Servers ###

Host prod-web-01
    HostName 10.0.1.10
    User deploy
    Port 22
    IdentityFile ~/.ssh/prod_key
    IdentitiesOnly yes

Host prod-db-01
    HostName 10.0.1.20
    User dbadmin
    IdentityFile ~/.ssh/prod_key
    ProxyJump prod-web-01

### Development Servers ###

Host dev-web-01
    HostName 192.168.1.100
    User developer

Host dev-db-01
    HostName 192.168.1.101
    User developer
    Port 2222

### Bastion Hosts ###

Host bastion-east bastion
    HostName 203.0.113.10
    User jump
    IdentityFile ~/.ssh/bastion_key
```

In the navigator, `prod-web-01` and `prod-db-01` would appear under the "Production Servers" section, `dev-web-01` and `dev-db-01` under "Development Servers", and so on. The multi-alias entry `bastion-east bastion` would appear as two rows, both pointing to the same server.

---

## Performance Notes

SSH Navigator is optimized for fast, flicker-free rendering, even on platforms where process creation is expensive (such as Windows/Git Bash/MSYS2).

**Key optimizations:**

- **Zero-fork rendering.** All screen output uses inline ANSI escape sequences and buffered writes. A full render cycle (header, host list, footer) is built in a single string buffer and flushed with one `printf` call. No external commands (`tput`, `tr`, etc.) are invoked during rendering.
- **Incremental cursor updates.** When pressing Up/Down without scrolling, only the previously selected and newly selected rows are repainted (2 rows) instead of redrawing the entire screen.
- **No-subshell key reading.** Keyboard input is read directly into a global variable rather than through a subshell (`$(...)`), eliminating one process fork per keypress and per idle timeout cycle.
- **Pre-computed assets.** Separator lines and column widths are computed once when the terminal is resized, not on every render.
- **Signal-driven resize.** Terminal size changes are detected via `SIGWINCH` and only processed when the signal fires, rather than polling on every idle cycle.

These optimizations reduce steady-state idle CPU usage to near zero and ensure that navigation feels instant regardless of host count.

---

## Troubleshooting

### Terminal Compatibility

**Problem:** The interface does not render correctly, or colors appear wrong.

SSH Navigator requires a terminal that supports:

- ANSI escape sequences (CSI sequences for cursor positioning, colors, and screen control)
- The alternate screen buffer (`\e[?1049h` / `\e[?1049l`)
- 256-color mode (`\e[38;5;Nm` / `\e[48;5;Nm` sequences)

**Solutions:**

- Make sure your `TERM` variable is set appropriately (e.g., `xterm-256color`, `screen-256color`).
- Try a different terminal emulator. Most modern terminals (iTerm2, GNOME Terminal, Windows Terminal, mintty, Alacritty, kitty) work without issues.
- If running over a remote connection, ensure your SSH client forwards the `TERM` variable correctly.

### Arrow Keys Not Working

**Problem:** Pressing arrow keys types escape sequences (like `^[[A`) instead of navigating.

This usually means the terminal is not in raw mode or the escape sequence parsing failed.

**Solutions:**

- Ensure `stty` is available and functioning. SSH Navigator uses `stty -echo -icanon` to put the terminal in raw mode.
- Some terminals send non-standard escape sequences. SSH Navigator handles the common `CSI` (`\e[`) and `SS3` (`\eO`) prefixes. If your terminal uses a different format, arrow keys may not be recognized.
- If you are running inside `tmux` or `screen`, make sure the inner terminal type is set correctly.

### Screen Flickers or Does Not Redraw

**Problem:** The interface appears garbled after resizing the terminal or switching tabs.

**Solutions:**

- SSH Navigator listens for the `SIGWINCH` signal to detect terminal resizes. On platforms that do not deliver this signal reliably (some `tmux` or `screen` configurations), you may need to press any navigation key (Up, Down, etc.) to force a redraw.
- Rendering is fully buffered (one write per frame), which should eliminate flicker on all modern terminals. If you still see flicker, check that your terminal supports the alternate screen buffer.

### "No hosts found" on Startup

**Problem:** The tool exits immediately with "No hosts found in ~/.ssh/config".

**Solutions:**

- Verify that the file exists: `ls -la ~/.ssh/config`.
- Check that the file contains at least one `Host` entry (not just `Host *`).
- If your config is in a non-standard location, pass it explicitly: `ssh-navigator.sh -c /path/to/config`.
- Ensure the `Host` keyword starts at the beginning of the line (not indented).

### Config File Not Found

**Problem:** "Error: SSH config file not found: /path/to/file".

**Solutions:**

- Double-check the path. If using `--config` or `SSH_CONFIG`, ensure the path is correct and the file exists.
- The file must be a regular file, not a directory or symlink to a missing target.

### Backup Files Accumulating

When you add a new host via the **`a`** form, SSH Navigator creates a timestamped backup (e.g., `~/.ssh/config.bak.1713200000`) before modifying the config file. Over time these may accumulate.

**Solution:** Periodically clean up old backups:

```bash
ls ~/.ssh/config.bak.*
rm ~/.ssh/config.bak.*    # remove all backups
```

### Launch Command Placeholders Not Expanding

**Problem:** The command runs with literal `$H` or `$HN` instead of the actual values.

**Solutions:**

- When setting the command via the shell (environment variable or `--cmd`), you must escape the dollar signs so the shell does not expand them:

  ```bash
  # Correct
  ssh-navigator.sh --cmd "ssh-vault \$HN"

  # Incorrect -- the shell expands $HN to empty string before the script sees it
  ssh-navigator.sh --cmd "ssh-vault $HN"
  ```

- When editing the command via the in-app editor (`e` key), type the placeholders literally (e.g., `$HN`). No escaping is needed because the in-app editor reads characters directly.

### Bash Version Too Old

**Problem:** Syntax errors on startup referencing `declare -a` or `${var,,}`.

SSH Navigator requires **Bash 4.0 or later**. Check your version:

```bash
bash --version
```

On macOS, the default `/bin/bash` is often Bash 3.2. Install a newer version via Homebrew:

```bash
brew install bash
```

Then run the script with the updated Bash:

```bash
/usr/local/bin/bash ssh-navigator.sh
```

Or update the shebang line in the script to point to the Homebrew-installed Bash.
