# rex-worktrunk

Git worktree pickers for [Rex](https://www.superlogical.com/rex), powered by [worktrunk](https://github.com/max-sixty/worktrunk). One key switches to or creates a worktree, another removes one. Each worktree gets its own Rex session, or a tab in its repository's session.



https://github.com/user-attachments/assets/3f925aba-0438-4f44-abb9-08d052d9a0a2



## Features

- **Switch or create**: fuzzy-pick a worktree or branch to jump to its session. Type a new name to create a branch and worktree. <kbd>Alt</kbd>+<kbd>Enter</kbd> forces the typed name. Worktrunk shortcuts work: `^` (default branch), `-` (previous), `pr:N`, `mr:N`, PR/MR URLs.
- **Remove**: pick a worktree to remove. Worktrunk still refuses unmerged or dirty ones. Its session closes and you return to the session you came from.
- **One session per worktree**: picking a worktree again reopens its session. Sessions are tracked by path, so you can rename them freely.
- **Or one session per repository**: with `group = "tab"`, each worktree is a tab in its repository's session (see [Tabs](#tabs)).

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
  picker  = "float",                  -- "native" lists in Rex's command palette instead (see below), make sure your server has API v17 or later
  group   = "session",                -- "tab" opens each worktree as a tab in its repository's session (see below)
  session = nil,                      -- with group = "tab": "current" or function(worktree, ctx) -> session ID for a new tab
  label   = nil,                      -- function(path, worktree) -> label for a new session or tab
  layout  = nil,                      -- function(label, path, worktree) -> rex.layout for a new session or tab
  on_created = nil,                   -- function(result, worktree) called after a new session or tab is created
  script  = nil,                      -- picker script (default: worktrunk.sh)
}
```

`worktree` is a table with `path`, `branch` and `main` (the main checkout).

`on_created` gets what `worktree_go` returns as `result`. Call `rex.call("session.attach", { session_id = result.session_id })` before acting on the session. With `group = "tab"`, tabs the hook opens aren't closed with the worktree.

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

## Tabs

`group = "tab"` gives each repository one session, with a tab per worktree, instead of a session per worktree:

```
app                  ← session
  main               ← tab
  fix-login          ← tab
other-repo           ← session
  main
  fix-ci
```

- **Where tabs open**: in the session your main checkout is in, if you have picked from it there. Otherwise the plugin creates a session named after the main checkout's directory.
- **Labels**: a tab is labelled with its branch. `label` and `layout` apply to the tab.
- **Remove**: closes the worktree's tab and returns you to the tab you came from, or else the main checkout's tab. The session stays open. A session the plugin created is closed with its last tab.
- **Trade-off**: a worktree is one tab, which can hold splits, rather than a session with several tabs.

Changing `group` only affects worktrees opened afterwards. A worktree that already has a session or tab keeps it until it is removed.

### Session option

`session` picks the session a new tab opens in, for those who group sessions by something other than repository:

- `"current"` opens it in the session you picked from.
- A function `function(worktree, ctx)` returns a session ID. `ctx` is the action's context, with `session_id` the session the request came from. The function may ask with `rex.ui.pick`.
- `nil`, from either, opens it in the repository's session as above.

A session chosen this way isn't remembered as the repository's. The plugin closes it with its last tab only if the plugin created it. Existing tabs stay where they are.

<details>
<summary>Example: ask which session</summary>

```lua
require("rex-worktrunk").setup{
  group = "tab",
  session = function(wt, ctx)
    local items = {}
    for _, s in ipairs(rex.call("session.list").sessions) do
      items[#items + 1] = { id = s.session_id, title = s.label }
    end
    return rex.ui.pick{ title = "Open " .. (wt.branch or wt.path) .. " in", items = items }
  end,
}
```

Cancelling the prompt returns `nil`, which opens the tab in the repository's session.

</details>

## Native picker
> [!NOTE] 
> This option will become the default once more people update.

`picker = "native"` lists worktrees and branches in Rex's command palette instead of fzf. It needs a Rex whose server and app can show palette prompts (`rex.ui`, server API revision 17 or later).

- Picking an existing worktree switches in place: no float, and no Remote Control needed.
- Creating a worktree (a new name, a branch without one, `pr:N`) and removing one still run in the float, so worktrunk's hooks and prompts stay visible.
- The fzf float is used when Rex can't ask in the palette, and for sessions on remote hosts.

## CLI

```sh
rex do worktree                                      # switch / create picker
rex do worktree_remove                               # remove picker
rex do worktree_go path=<worktree>                   # open a worktree's session or tab
rex do worktree_close path=<worktree> main=<repo>    # close a removed worktree's session or tab
```

With `group = "tab"`, also pass `main=<repo>` to `worktree_go`, so the tab opens in that repository's session.

## Optional: close sessions on any `wt remove`

`wt remove` and `wt merge` run outside the picker don't close the session or tab. This hook in `~/.config/worktrunk/config.toml` handles that:

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
