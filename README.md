# claude-api

Run [Claude Code](https://claude.com/claude-code) against any Anthropic-compatible
API model (DeepSeek, Moonshot Kimi, Xiaomi MiMo, local llama.cpp, …) in an isolated
tmux session — **without touching your default `claude` subscription setup.**

Each profile gets its own `CLAUDE_CODE_*`/`ANTHROPIC_*` env and its own config dir
(`configs/<profile>/`), so history, auth, and settings never collide with `~/.claude`.

## Install

```sh
git clone git@github.com:mukhayyar/claude-api.git ~/.claude-api
ln -sf ~/.claude-api/claude-api ~/.local/bin/claude-api   # ~/.local/bin must be on PATH
```

Prereqs `claude` and `tmux` are **auto-installed if missing** — the launcher detects
your package manager (brew / apt / dnf / yum / pacman / zypper / apk / pkg) and prompts
before installing. Set `CLAUDE_API_ASSUME_YES=1` to skip the prompt, or run
`claude-api doctor` to just check. Native Windows isn't supported (no tmux) — use WSL.

## Use

```sh
claude-api                    # list profiles
claude-api deepseek           # launch a profile in a tmux session
claude-api kimi -- -p "hi"    # args after -- are passed straight to `claude`
```

Detach tmux with `Ctrl-b d`; re-attach by re-running the same command.

Sessions are scoped by **profile + working directory**, so running `claude-api kimi`
from two different folders gives you two separate tmux sessions.

Permission prompts are skipped by default inside isolated profiles. Set
`CLAUDE_API_SAFE=1` to keep the normal Claude Code permission flow.

## Add a model

```sh
cp profiles/deepseek.env.example profiles/mymodel.env   # edit URL / key / model
claude-api mymodel
```

`*.env` files hold your keys and are gitignored. Only `*.env.example` templates
are tracked. Copy the example for the provider you want and paste your key in.

## Plugins

Enabled Claude Code plugins (e.g. `claude-mem`) are passed through automatically
from your main `~/.claude` installation, so they keep working inside isolated profiles.

## Local llama.cpp proxy

The `llama` profile runs a tiny local proxy (`proxy/proxy.js`) that translates
Claude Code's Anthropic `/v1/messages` calls into OpenAI-compatible
`/v1/chat/completions` calls for a local `llama-server`.

```sh
# 1. Start llama-server on an OpenAI-compatible endpoint, e.g. port 8081
# 2. claude-api llama
```

Configure the upstream in `profiles/llama.env`:

- `LLAMA_OPENAI_BASE_URL` — your `llama-server` URL (default `http://localhost:8081/v1`)
- `LLAMA_OPENAI_MODEL` — model name to send upstream (default `Qwen3.5-0.8B-Q5_K_M`)
- `LLAMA_PROXY_PORT` — port the proxy listens on (default `4000`)

The proxy auto-starts when you launch the `llama` profile and shuts down with the
session. Logs go to `proxy/llama.log` (gitignored).
