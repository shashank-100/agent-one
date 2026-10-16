# AgentOne with your Claude Code subscription

Run from the repository root:

```sh
node local/claude-code.mjs
```

Open <http://127.0.0.1:8766/demo/> in Chrome. Both the test phone and the
model bridge are local. The existing simulator assets in `local/public/`
are served without uploading or deploying anything.

The website's hosting configuration remains in `cloud/`. It uses the same built
assets, without a hosted model client or subscription token. Deployments need
the user's approval. Persistent chat-thread storage is not implemented yet.

The bridge launches the installed `claude` CLI with the token read from
`~/.config/agentone/claude-code-token`. Override that file with
`AGENTONE_TOKEN_FILE`, or provide `CLAUDE_CODE_OAUTH_TOKEN` in the environment.
The token is never sent to the browser or stored in this repository.

Claude Code returns a structured proposed phone action. It has no built-in
tools, MCP servers, project settings, plugins, or session persistence. AgentOne
executes the action through its existing phone controller and approval checks.
There is no GLM, API-key, or alternate-model fallback. Errors stop the step.

The iOS app's Model settings contain the bridge address. The simulator can use
`http://127.0.0.1:8766`. For a physical iPhone, start the bridge on your Mac's LAN
address (for example, `AGENTONE_HOST=192.168.1.10 node local/claude-code.mjs`)
and enter `http://192.168.1.10:8766` in the app. Restart the app after changing
the address. LAN mode allows devices on that network to use the bridge; it is
intended for your private network. The default binds only to loopback.

`AGENTONE_PORT` changes the port. `AGENTONE_CLAUDE_MODEL` selects the Claude
Code model (default `opus`). The Swift command-line tools use
`AGENTONE_BRIDGE_URL` (default `http://127.0.0.1:8766`).

If the simulator has not been built, run `npm run build` in `phone/`, then
`./build.sh` in `local/`. Neither command deploys anything.
