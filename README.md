# claude-api

Run [Claude Code](https://claude.com/claude-code) against any Anthropic-compatible
API model (DeepSeek, Moonshot Kimi, Xiaomi MiMo, local llama.cpp/Qwen, …) in an
isolated tmux session — **without touching your default `claude` subscription setup.**

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

## Quick start

```sh
claude-api                    # list profiles
claude-api deepseek           # launch a profile in a tmux session
claude-api kimi -- -p "hi"    # args after -- are passed straight to `claude`
```

Detach tmux with `Ctrl-b d`; re-attach by re-running the same command.

Sessions are scoped by **profile + working directory**, so running `claude-api kimi`
from two different folders gives you two separate tmux sessions.

## Available profiles

The repo ships with example templates under `profiles/*.env.example`. Copy one,
fill in your key, and drop it as `~/.claude-api/profiles/<name>.env`:

| Profile | Provider |
|---------|----------|
| `deepseek` | DeepSeek (Anthropic-compatible) |
| `kimi` | Moonshot Kimi |
| `mimo-api` | Xiaomi MiMo pay-per-use API |
| `mimo-tokenplan` | Xiaomi MiMo token-plan subscription |
| `llama` | Local llama.cpp via the built-in proxy |
| `qwen3-4b` | Local Qwen3 4B via llama.cpp |
| `qwen3.5-4b` | Local Qwen3.5 4B via llama.cpp |

`*.env` files hold your keys and are gitignored. Only `*.env.example` templates
are tracked.

## Add a model

```sh
cp profiles/deepseek.env.example profiles/mymodel.env   # edit URL / key / model
claude-api mymodel
```

A profile env file sets the Anthropic-compatible endpoint Claude Code talks to:

```sh
ANTHROPIC_AUTH_TOKEN=sk-...
ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
ANTHROPIC_MODEL=deepseek-v4-pro[1m]
ANTHROPIC_DEFAULT_OPUS_MODEL=deepseek-v4-pro[1m]
ANTHROPIC_DEFAULT_SONNET_MODEL=deepseek-v4-pro[1m]
ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-v4-pro[1m]
CLAUDE_CODE_SUBAGENT_MODEL=deepseek-v4-pro[1m]
```

## Passing arguments to `claude`

Everything after `--` is forwarded verbatim:

```sh
claude-api kimi -- -p "explain this file"
claude-api deepseek -- --help
```

## Resume the main/default `claude` session

By default each profile uses an isolated config dir, so `claude-api kimi -- -r`
only resumes the profile's own history. To keep using your default `~/.claude`
config (and therefore `-r` resumes your main subscription sessions), add `--main`:

```sh
claude-api kimi --main -- -r
```

This applies the profile's API env variables while using `~/.claude` for settings,
history, and auth. Permission prompts stay enabled in `--main` mode.

## Plugins

Enabled Claude Code plugins (e.g. `claude-mem`) are passed through automatically
from your main `~/.claude` installation, so they keep working inside isolated profiles.

## Permission prompts

Isolated profiles skip Claude Code permission prompts by default. To keep the
normal permission flow, set:

```sh
export CLAUDE_API_SAFE=1
claude-api deepseek
```

`--main` always uses the normal permission flow.

## Local models via llama.cpp

### Built-in llama proxy

The `llama` profile runs a tiny local proxy (`proxy/proxy.js`) that translates
Claude Code's Anthropic `/v1/messages` calls into OpenAI-compatible
`/v1/chat/completions` calls for a local `llama-server`.

```sh
# 1. Start llama-server on an OpenAI-compatible endpoint, e.g. port 8081
llama-server -m ~/.claude-api/models/Qwen3.5-4B-Q4_K_M.gguf --port 8081 -ngl 99

# 2. In another terminal
claude-api llama
```

Configure the upstream in `profiles/llama.env`:

- `LLAMA_OPENAI_BASE_URL` — your `llama-server` URL (default `http://localhost:8081/v1`)
- `LLAMA_OPENAI_MODEL` — model name to send upstream
- `LLAMA_PROXY_PORT` — port the proxy listens on

The proxy auto-starts when you launch the profile and shuts down with the
session. Logs go to `proxy/<profile>.log` (gitignored).

### Qwen3 / Qwen3.5 4B

Both models support tool calling through the proxy. Example setup:

```sh
# Download a GGUF
mkdir -p ~/.claude-api/models
hf download Qwen/Qwen3-4B-GGUF Qwen3-4B-Q4_K_M.gguf --local-dir ~/.claude-api/models
hf download unsloth/Qwen3.5-4B-GGUF Qwen3.5-4B-Q4_K_M.gguf --local-dir ~/.claude-api/models

# Copy the provided local profiles
cp ~/.claude-api/profiles/qwen3-4b.env.example ~/.claude-api/profiles/qwen3-4b.env
cp ~/.claude-api/profiles/qwen3.5-4b.env.example ~/.claude-api/profiles/qwen3.5-4b.env

# Start the server and launch
llama-server -m ~/.claude-api/models/Qwen3-4B-Q4_K_M.gguf --port 8081 -ngl 99
claude-api qwen3-4b
```

On Apple Silicon, `-ngl 99` offloads layers to Metal. Use a separate `llama-server`
port per model if you want to switch without restarting the server.

## Environment variables

| Variable | Effect |
|----------|--------|
| `CLAUDE_API_ASSUME_YES=1` | Skip install confirmations for `tmux`/`claude` |
| `CLAUDE_API_SAFE=1` | Keep normal permission prompts in isolated profiles |
| `CLAUDE_CONFIG_DIR` | **Do not set manually** — managed by the launcher |

## Files

```text
~/.claude-api/
├── claude-api              # launcher script
├── proxy/
│   ├── proxy.js            # Anthropic → OpenAI proxy for local models
│   └── *.log               # gitignored proxy logs
├── profiles/
│   ├── *.env               # gitignored real profiles (keys)
│   └── *.env.example       # tracked templates
└── configs/
    └── <profile>/          # gitignored isolated Claude Code configs
```

## Updating

```sh
cd ~/.claude-api
git pull origin main
```

Your local profiles (`profiles/*.env`) and isolated configs (`configs/`) are
gitignored and survive updates.

## Troubleshooting

**Profile not found**: make sure `~/.claude-api/profiles/<name>.env` exists.
The launcher only looks at `*.env`, not `*.env.example`.

**Proxy won't start**: check that `LLAMA_OPENAI_BASE_URL` points to a running
`llama-server` and that `node` is available.

**`-r` resumes the wrong session**: remember that isolated profiles have their own
history. Use `--main` to resume your default `claude` sessions.

## License

MIT
