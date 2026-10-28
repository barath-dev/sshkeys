# sshkeys

A tiny, interactive terminal tool that shows every SSH key in `~/.ssh`,
which `~/.ssh/config` hosts use each one, and lets you create, rename,
re-comment, re-passphrase, test and delete them in a couple of keystrokes.

No installer, no runtime, no dependencies — it's one bash script on top of
`ssh-keygen`, `ssh-add` and `ssh`.

## Why

After a while `~/.ssh` turns into a pile of `id_ed25519`, `id_rsa`,
`id_ed25519_other`... and nobody remembers which key is registered where.
The classic accident is running `ssh-keygen` for a new server, accepting
the default path, and silently overwriting the key GitHub knew about — at
which point every `git fetch` fails with `Permission denied (publickey)`.

Answering "which key is this, does it work, and what uses it?" normally
means juggling:

```
for f in ~/.ssh/*.pub; do ssh-keygen -lf "$f"; done
ssh-add -l
grep -i identityfile ~/.ssh/config
ssh -T -i ~/.ssh/some_key git@github.com
```

`sshkeys` puts all of that in one screen, and refuses to do the
overwriting kind of mistake in the first place.

## Install

Requires macOS (or Linux) with `bash` and OpenSSH — both are already on
your system.

```
git clone https://github.com/barath-dev/sshkeys.git
cd sshkeys
chmod +x bin/sshkeys.sh
ln -s "$(pwd)/bin/sshkeys.sh" /opt/homebrew/bin/sshkeys   # Apple Silicon
# or:
ln -s "$(pwd)/bin/sshkeys.sh" /usr/local/bin/sshkeys      # Intel Mac / Linux
```

That symlink is what makes `sshkeys` work as a plain command from any
directory. Pick whichever target directory is already on your `$PATH`
(check with `echo $PATH`); `/usr/local/bin` may need `sudo` since it's
typically root-owned.

If `sshkeys` says `command not found` right after installing, run
`hash -r` or open a new terminal tab.

## Usage

```
sshkeys          interactive view
sshkeys ls       plain table (with fingerprints), for scripts and quick checks
sshkeys help     usage
```

The interactive view lists one row per private key:

```
  NAME                     TYPE     PASS  AGENT USED BY (ssh config)     COMMENT
> id_ed25519_github        ED25519  no    yes   github.com               me@example.com github
  id_ed25519_qa            ED25519  yes   no    qaServer                 me@example.com qa
  id_rsa                   RSA      yes   no    -                        old laptop key
```

- **PASS** — whether the key is protected by a passphrase (`?` means the
  file's permissions are too open, so ssh would refuse it anyway).
- **AGENT** — whether it is currently loaded in `ssh-agent`.
- **USED BY** — the `Host` entries in `~/.ssh/config` whose `IdentityFile`
  points at the key. `-` means nothing references it.

Keys:

| Key                 | Action                                                         |
|---------------------|----------------------------------------------------------------|
| `↑`/`↓` or `j`/`k`  | move the cursor                                                |
| `enter`             | details: fingerprint, mode, date, resolved `user@host:port` per host, full public key |
| `y`                 | copy the public key to the clipboard                           |
| `t`                 | test the key against each host that uses it                    |
| `+` / `a`           | load the key into the agent (Keychain on macOS), or remove it  |
| `c`                 | create a new key                                               |
| `m`                 | rename a key (and its `.pub`, and the config entries using it) |
| `e`                 | change the key's comment                                       |
| `p`                 | add / change / remove the passphrase                           |
| `d`                 | delete a key (to a trash folder)                               |
| `r`                 | refresh                                                        |
| `q` / `esc`         | quit                                                           |

### Create

Asks for the type (ed25519 by default), what the key is for, and a
comment, then names the file `id_<type>_<purpose>` — e.g.
`id_ed25519_github` — so the file name says what it is. `ssh-keygen` runs
in the normal terminal so you can set a passphrase. Optionally it appends
a `Host` block (alias, HostName, User, IdentityFile) to your config, and
the new public key is copied to the clipboard ready to paste into GitHub
or a server's `authorized_keys`.

### Test

For every concrete `Host` that uses the key, `t` connects with
`ssh -F /dev/null -o IdentitiesOnly=yes -i <key>` to the resolved
`user@hostname:port`, so *only that key* is offered — another key in
your config or agent can't make a broken key look fine. Git hosts
(GitHub, GitLab, Bitbucket) count as OK when they greet you by name;
servers run `exit 0`. If the key isn't used by any host, it asks where to
test (default `git@github.com`).

A passphrase-protected key that isn't in the agent can't be unlocked in a
non-interactive test — press `+` first.

## Safety

- **Nothing is ever overwritten.** Create and rename refuse if the target
  file (or its `.pub`) already exists.
- **Delete is recoverable.** You must type the key's name to confirm; it
  warns which hosts will stop working, and moves the files to
  `~/.ssh/.sshkeys/trash/<timestamp>/` instead of erasing them.
- **Config edits are backed up.** Before `~/.ssh/config` is changed (new
  Host block, rename), a copy goes to `~/.ssh/.sshkeys/backups/`.

Deleting a key locally doesn't revoke it — remove its public key from
GitHub and from servers' `authorized_keys` too.

## How it works

1. **Finding keys.** Every file in `~/.ssh` whose first line is a
   `-----BEGIN ... PRIVATE KEY-----` header is a key. `ssh-keygen -lf`
   gives type, size, fingerprint and comment; `ssh-keygen -y -P ""`
   succeeding means there's no passphrase; fingerprints are matched
   against `ssh-add -l` for the agent column.
2. **Mapping to hosts.** An `awk` pass over `~/.ssh/config` records the
   current `Host` patterns for each `IdentityFile` line, resolving `~/`,
   `%d/` and relative paths the way ssh does. Rename uses the same
   resolution to rewrite matching lines in place.
3. **The interactive list.** Same approach as
   [openports](https://github.com/barath-dev/openports): raw mode with
   `stty -echo -icanon`, redraws with `tput`, and only bash 3.2 features
   (plain indexed arrays kept in sync), so it runs on the `/bin/bash`
   macOS ships with. Actions that need a passphrase hand the terminal
   back to `ssh-keygen` / `ssh-add` in normal mode.

Set `SSHKEYS_DIR` to manage a directory other than `~/.ssh`.

## Scope

Only the main `~/.ssh/config` is read — files pulled in with `Include`
aren't followed. Keys in hardware tokens or a password manager's agent
show up in `ssh-add -l` but aren't files in `~/.ssh`, so they aren't
listed.

## License

MIT — see [LICENSE](LICENSE).
