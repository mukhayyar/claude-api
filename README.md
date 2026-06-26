# claude-api

Run [Claude Code](https://claude.com/claude-code) against any Anthropic-compatible
API model (DeepSeek, Moonshot Kimi, Xiaomi MiMo, …) in an isolated tmux session —
**without touching your default `claude` subscription setup.**

Each profile gets its own `CLAUDE_CODE_*`/`ANTHROPIC_*` env and its own config dir
(`configs/<profile>/`), so history, auth, and settings never collide with `~/.claude`.

## Install

```sh
git clone git@github.com:mukhayyar/claude-api.git ~/.claude-api
ln -sf ~/.claude-api/claude-api ~/.local/bin/claude-api   # ~/.local/bin must be on PATH
```

Requires `claude` and `tmux` on PATH.

## Use

```sh
claude-api                    # list profiles
claude-api deepseek           # launch a profile in tmux session "capi-deepseek"
claude-api kimi -- -p "hi"    # args after -- are passed straight to `claude`
```

Detach tmux with `Ctrl-b d`; re-attach by re-running the same command.

## Add a model

```sh
cp profiles/deepseek.env.example profiles/mymodel.env   # edit URL / key / model
claude-api mymodel
```

`*.env` files hold your keys and are gitignored. Only `*.env.example` templates
are tracked. Copy the example for the provider you want and paste your key in.
