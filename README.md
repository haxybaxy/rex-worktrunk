# rex-worktrunk

Git worktree pickers for [Rex](https://www.superlogical.com/rex), driven by [worktrunk](https://github.com/max-sixty/worktrunk): switch to or create a worktree from one key, remove one from another, with a Rex session per worktree.

The pickers are ported from the [herdr-worktrunk](https://github.com/devashish2203/herdr-worktrunk) plugin for herdr.

## Overview

**Switch or create.** Press the key in a terminal inside a repo and a floating [fzf](https://github.com/junegunn/fzf) picker lists the repo's worktrees and local branches. Press <kbd>Enter</kbd> on a match to switch to it: Rex opens a session for the worktree, creating the worktree first when the branch has none. Type a name that matches nothing and press <kbd>Enter</kbd> to create a branch and worktree for it, from the current branch by default. When the name you want fuzzy-matches an existing branch (you want `pgx` but `pgx-bump` exists), <kbd>Alt</kbd>+<kbd>Enter</kbd> forces the typed name. Worktrunk's shortcuts work too: `^` for the default branch, `-` for the previous one, `pr:N` and `mr:N` for pull and merge requests, and PR/MR URLs.

**Remove.** The second key lists the removable worktrees, never the main checkout. Pick one and worktrunk removes it, with its own checks: it refuses unmerged branches and dirty worktrees, and asks when it needs to. The worktree's Rex session is closed afterwards; if you were in it, Rex moves you to the main checkout's session first.

Worktrunk's lifecycle hooks run as usual, with their output in the float.

## How it works

- `setup` defines four actions. `worktree` and `worktree_remove` open the pickers in a floating terminal whose working directory is that of the focused terminal, which is how the repo is chosen. `worktree_go` takes a worktree `path` and switches to its session, creating it if needed; `worktree_close` closes the session of a worktree that was removed.
- The floats run `worktrunk.sh`, which runs `wt switch --no-cd` or `wt remove --foreground` and hands the result back with `rex do worktree_go` or `rex do worktree_close`. The app accepts a session switch from the CLI only when Remote Control is on. The action can't wait for the pick itself, because Rex stops taking input while a key-bound action runs.
- Sessions are labelled after the worktree's directory, such as `repo.feat-demo` with worktrunk's default path template. [rex-sessionizer](https://github.com/haxybaxy/rex-sessionizer) labels sessions the same way, so the two pickers share sessions.

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
  layout  = nil,                      -- function(name, path) -> layout for a new session
  script  = nil,                      -- the picker script; worktrunk.sh beside init.lua by default
}
```

A `layout` function builds the first window of a new session with `rex.layout`; the default is one shell started in the worktree.

## From the CLI

```sh
rex do worktree                                     # the switch / create picker, for the terminal's repo
rex do worktree_remove                              # the remove picker
rex do worktree_go path=/path/to/repo.feature       # open a worktree's session
```

## Test

`test/list_test.sh` checks what the pickers list, on a throwaway repository, without Rex:

```sh
bash test/list_test.sh
```

## Upgrade

```sh
git -C ~/.config/rex/rex-worktrunk pull
rex config reload
```

## Credits

The pickers, their fzf conventions, and the worktrunk handling are ported from [herdr-worktrunk](https://github.com/devashish2203/herdr-worktrunk) by Devashish Chandra (MIT). [worktrunk](https://github.com/max-sixty/worktrunk) is by Maximilian Roos.
