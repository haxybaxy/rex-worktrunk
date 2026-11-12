# rex-worktrunk

Git worktree pickers for [Rex](https://www.superlogical.com/rex), powered by [worktrunk](https://github.com/max-sixty/worktrunk). One key switches to or creates a worktree, another removes one. Each worktree gets its own Rex session.

https://github.com/user-attachments/assets/641a09cc-0809-4ec9-9d0b-5335e44e177d

## Features

- **Switch or create**: fuzzy-pick a worktree or branch to jump to its session. Type a new name to create a branch and worktree. <kbd>Alt</kbd>+<kbd>Enter</kbd> forces the typed name. Worktrunk shortcuts work: `^` (default branch), `-` (previous), `pr:N`, `mr:N`, PR/MR URLs.
- **Remove**: pick a worktree to remove. Worktrunk still refuses unmerged or dirty ones. Its session closes and you return to the session you came from.
- **One session per worktree**: picking a worktree again reopens its session. Sessions are tracked by path, so you can rename them freely.

## Install

Requires `wt` ≥ 0.60, `fzf` and `jq` on your login shell's `PATH`.

```sh
git clone https://github.com/haxybaxy/rex-worktrunk ~/.config/rex/rex-worktrunk
```

Add to `~/.config/rex/init.lua`:

```lua
require("rex-worktrunk").setup{ base = "@" }
rex.bind("ctrl+space>g", "worktree")
rex.bind("ctrl+space>d", "worktree_remove")
```

Turn on **Rex → Settings → Rex Server → Remote Control** (required), then run `rex config reload`.

Both pickers are also in the command palette under "Worktree".

## Options

```lua
require("rex-worktrunk").setup{
  base    = "@",                      -- new branch base: "@" current, "^" default, a branch name, or false (worktrunk's default)
  remotes = false,                    -- also list remote-tracking branches
  slugify = false,                    -- "Fix Login Bug" becomes fix-login-bug
  bounds  = { 0.15, 0.1, 0.7, 0.8 },  -- float x, y, width, height as fractions of the window
  label   = nil,                      -- function(path, worktree) -> label for a new session
  layout  = nil,                      -- function(label, path, worktree) -> rex.layout for a new session
  script  = nil,                      -- picker script (default: worktrunk.sh)
}
```

`worktree` is a table with `path`, `branch` and `main` (the main checkout).

<details>
<summary>Example: custom label and layout</summary>

```lua
require("rex-worktrunk").setup{
  -- "app · fix/login" instead of "app.fix-login"
  label = function(path, wt)
    if wt.branch and wt.main then return wt.main:match("[^/]+$") .. " · " .. wt.branch end
  end,
  -- nvim beside a shell
  layout = function(label, path, wt)
    local shell = "com.superlogical.terminal.shell"
    return rex.layout.horizontal(0.6,
      rex.layout.block{ flavor = shell, options = { cwd = path, command = { "nvim" } } },
      rex.layout.block{ flavor = shell, options = { cwd = path } })
  end,
}
```

</details>

## CLI

```sh
rex do worktree                                      # switch / create picker
rex do worktree_remove                               # remove picker
rex do worktree_go path=<worktree>                   # open a worktree's session
rex do worktree_close path=<worktree> main=<repo>    # close a removed worktree's session
```

## Optional: close sessions on any `wt remove`

`wt remove` and `wt merge` run outside the picker don't close the session. This hook in `~/.config/worktrunk/config.toml` handles that:

```toml
[post-remove]
rex-session = "command -v rex >/dev/null 2>&1 && rex --autostart=false do worktree_close path={{ worktree_path }} main={{ primary_worktree_path }} >/dev/null 2>&1 || true"
```

## Gotchas

- **Remote Rex servers**: clone the plugin to the same path under `~` on every host.
- **Symlinked `init.lua`**: clone next to the symlink, not its target.
- **`ctrl+space` as a prefix**: to still send it to the terminal, add `rex.bind("ctrl+space>ctrl+space", "pane.send_key", { key = "ctrl+space" })`.

## Upgrade

```sh
git -C ~/.config/rex/rex-worktrunk pull && rex config reload
```

## Development

Run `bash test/run.sh` to run all tests (CI runs the same).

## Credits

Ported from [herdr-worktrunk](https://github.com/devashish2203/herdr-worktrunk) by Devashish Chandra (MIT). [worktrunk](https://github.com/max-sixty/worktrunk) is by Maximilian Roos.
