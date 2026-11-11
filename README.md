# rex-worktrunk

Git worktree pickers for [Rex](https://www.superlogical.com/rex), driven by [worktrunk](https://github.com/max-sixty/worktrunk): switch to or create a worktree from one key, remove one from another, with a Rex session per worktree.

https://github.com/user-attachments/assets/641a09cc-0809-4ec9-9d0b-5335e44e177d


The pickers are ported from the [herdr-worktrunk](https://github.com/devashish2203/herdr-worktrunk) plugin for herdr.

## Overview

**Switch or create.** Press the key in a terminal inside a repo and a floating [fzf](https://github.com/junegunn/fzf) picker lists the repo's worktrees and local branches. Press <kbd>Enter</kbd> on a match to switch to it: Rex opens a session for the worktree, creating the worktree first when the branch has none. Type a name that matches nothing and press <kbd>Enter</kbd> to create a branch and worktree for it, from the current branch by default. When the name you want fuzzy-matches an existing branch (you want `pgx` but `pgx-bump` exists), <kbd>Alt</kbd>+<kbd>Enter</kbd> forces the typed name. Worktrunk's shortcuts work too: `^` for the default branch, `-` for the previous one, `pr:N` and `mr:N` for pull and merge requests, and PR/MR URLs.

**Remove.** The second key lists the removable worktrees, never the main checkout. Pick one and worktrunk removes it, with its own checks: it refuses unmerged branches and dirty worktrees, and asks when it needs to. The worktree's Rex session is closed afterwards; if you were in it, Rex first takes you back to the session you opened the worktree from.

Worktrunk's lifecycle hooks run as usual, with their output in the float.

## How it works

- `setup` defines four actions. `worktree` and `worktree_remove` open the pickers in a floating terminal whose working directory is that of the focused terminal, which is how the repo is chosen. `worktree_go` takes a worktree `path` and switches to its session, creating it if needed; `worktree_close` closes the session of a worktree that was removed.
- Each worktree has one session, remembered by the worktree's path in `$XDG_STATE_HOME/rex-worktrunk/sessions` (`~/.local/state` by default). Sessions are never found by label, so you, or an agent working in one, can rename them freely.
- A session the plugin creates for a worktree is opened again the next time you pick that worktree, and closed when the worktree is removed.
- The session you use a picker from is adopted for the worktree its terminal is in, unless that worktree or that session is already remembered. So when you open a worktree from the session you already had for the main checkout, picking the main checkout's branch later takes you back to that session instead of opening a second one. An adopted session is never closed, only forgotten when its worktree is removed.
- When the session you are in is closed, the app goes back to the session the worktree was opened from. If that one is gone, it goes to the main checkout's session. If there is none, the session is closed and Rex picks where you land; a session is never created just to leave one.
- The floats run `worktrunk.sh`, which runs `wt switch --no-cd` or `wt remove --foreground` and hands the result back with `rex do worktree_go` or `rex do worktree_close`. The app accepts a session switch from the CLI only when Remote Control is on. The action can't wait for the pick itself, because Rex stops taking input while a key-bound action runs.
- The app runs a key-bound action with its own `init.lua`, also in a session on a remote Rex server, so a script under your home directory is started as `$HOME/<the rest of its path>` on the host the float runs on. Clone the plugin to the same place under the home directory on each host.
- New sessions are labelled after the worktree's directory, such as `repo.feat-demo` with worktrunk's default path template, unless the `label` option says otherwise.

## Install

You need worktrunk (`wt` ≥ 0.60 on your `PATH`), fzf, and jq. Clone into Rex's configuration directory:

```sh
git clone https://github.com/haxybaxy/rex-worktrunk ~/.config/rex/rex-worktrunk
```

Add to `~/.config/rex/init.lua`:

```lua
require("rex-worktrunk").setup{ base = "@" }
rex.bind("ctrl+space>g", "worktree")
rex.bind("ctrl+space>d", "worktree_remove")
```

Turn on Remote Control in Rex → Settings → Rex Server, then reload:

```sh
rex config reload
```

Rex loads modules from beside the `init.lua` it opens, so if `init.lua` is a symlink, clone next to the link. The tools have to be on the `PATH` your login shell sets.

`ctrl+space>g` is a key sequence, like a tmux prefix. If you use one, bind the prefix pressed twice to send it to the terminal:

```lua
rex.bind("ctrl+space>ctrl+space", "pane.send_key", { key = "ctrl+space" })
```

Any keys work, and both pickers are in the command palette under "Worktree".

## Options

```lua
require("rex-worktrunk").setup{
  base    = "@",                      -- what a new branch starts from: "@" current, "^" default, a name, or false for worktrunk's default
  remotes = false,                    -- also offer remote-tracking branches (run git fetch yourself)
  slugify = false,                    -- turn a typed "Fix Login Bug" into fix-login-bug
  bounds  = { 0.15, 0.1, 0.7, 0.8 },  -- x, y, width, height of the float, as fractions of the window
  layout  = nil,                      -- function(label, path, worktree) -> layout for a new session
  label   = nil,                      -- function(path, worktree) -> label of a new session; the directory name by default
  script  = nil,                      -- the picker script; worktrunk.sh beside init.lua by default
}
```

An unknown option, or one of the wrong type, is ignored with a warning in Rex's log.

### Labels and layouts

`label` and `layout` are called once, when a session is created. Both get the worktree's directory and a `worktree` table with `path`, `branch` and `main` (the main checkout). The pickers always fill in `branch` and `main`; they are `nil` when `worktree_go` is run by hand without them.

```lua
require("rex-worktrunk").setup{
  -- "app · fix/login" instead of "app.fix-login"
  label = function(path, worktree)
    if not (worktree.branch and worktree.main) then return nil end
    return worktree.main:match("[^/]+$") .. " · " .. worktree.branch
  end,
  -- an editor beside a shell
  layout = function(label, path, worktree)
    local shell = "com.superlogical.terminal.shell"
    return rex.layout.horizontal(0.6,
      rex.layout.block{ flavor = shell, options = { cwd = path, command = { "nvim" } } },
      rex.layout.block{ flavor = shell, options = { cwd = path } })
  end,
}
```

A label only names the new session. When the function returns `nil` or an empty string, fails, or returns a label Rex refuses (more than 128 characters), the session is labelled after the directory. Labels don't have to be unique. A `layout` function builds the first window with `rex.layout`; the default is one shell started in the worktree. A failing `layout` function is reported in the picker and no session is created.

## From the CLI

```sh
rex do worktree                                     # the switch / create picker, for the terminal's repo
rex do worktree_remove                              # the remove picker
rex do worktree_go path=/path/to/repo.feature       # open a worktree's session; also takes branch= and main= for label and layout
rex do worktree_close path=/path/to/repo.feature main=/path/to/repo   # close a removed worktree's session
```

## Closing sessions when removing outside the picker

The remove picker closes the worktree's session, but `wt remove` and `wt merge` run elsewhere don't know about Rex. A worktrunk `post-remove` hook in `~/.config/worktrunk/config.toml` closes the session however the worktree is removed:

```toml
[post-remove]
rex-session = "command -v rex >/dev/null 2>&1 && rex --autostart=false do worktree_close path={{ worktree_path }} main={{ primary_worktree_path }} >/dev/null 2>&1 || true"
```

`--autostart=false` keeps it from starting a Rex server on a machine where Rex isn't running. When you remove with the picker, the picker and the hook both ask to close the session; the second finds nothing left to close.

## Test

`bash test/run.sh` runs every check, as CI does on each push and pull request:

- `test/session_test.lua` checks how sessions are created, found, remembered and closed, and `test/picker_test.lua` the floats and `setup`, both against the fake `rex` in `test/fake_rex.lua`. They need only Lua 5.1 or LuaJIT, the Lua Rex runs: `luajit test/session_test.lua`.
- `test/worktrunk_test.sh` checks `worktrunk.sh` on a throwaway repository: what the pickers list, and what a pick or a removal hands back to Rex, with stand-ins for fzf and `rex`. It needs git, jq and wt, and skips itself without them.
- `shellcheck` checks the scripts, when it is installed.

## Upgrade

```sh
git -C ~/.config/rex/rex-worktrunk pull
rex config reload
```

## Credits

The pickers, their fzf conventions, and the worktrunk handling are ported from [herdr-worktrunk](https://github.com/devashish2203/herdr-worktrunk) by Devashish Chandra (MIT). [worktrunk](https://github.com/max-sixty/worktrunk) is by Maximilian Roos.
