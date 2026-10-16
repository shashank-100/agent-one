# AGENTS.md

Agent One: an iPhone app with an AI agent that uses the user's other apps for them. It reads the screen, the model picks one action, the action happens on the phone, repeat. The full plan is in `PLAN.md`; what is done and what is next is in `TODO.md`.

**North star:** on a real iPhone, "search for an iPhone and place an order on the Amazon app" done by the agent end to end, with the user's Allow before Place order. It is the goal that sets direction, not the only thing the app does. The six example tasks (PDF to WhatsApp group, receipt to expenses, visitor approval, promo notifications, gym reschedule, light 30%) are deferred for now (16 Oct).

## Decisions that are settled

Don't reopen these or offer alternatives unless asked.

- **iPhone only.** No Android, no Android fallback, no "fallback routes" of any kind in plans.
- **On-device control** of other apps, the technique Pelican uses: the phone runs Apple's UI test automation on itself. `phone-use-refs/TouchSynthesis` documents it but has **no licence**: study it, never copy its code.
- **Model:** the actual Claude Code CLI on the user's Mac, authenticated with their subscription token. GLM, direct API-provider calls and automatic model fallbacks are disabled.
- **Local personal setup approved (17 Oct).** Run the test phone and Claude Code bridge with `node local/claude-code.mjs`. Claude Code and its subscription token stay on the Mac. Do not add hosted model execution or sandboxes. Keep the website on Cloudflare; ask before deploying changes. iOS builds use GitHub's Mac runners or Xcode on the pendrive (`/Volumes/SANDISK`).
- **Never use Claude Haiku** for anything (model, tests, comparisons). Opus is the model.
- **No Desert Ant models** (Desert-Ant-Labs/desert-ant-core) in the product.
- **Testing happens on MobileGym** (the simulated phone in `phone/`), served by the local bridge, until a real iPhone is available. Runs happen in the user's Chrome (the agent page's "Run all"), never Playwright or a headless browser.

## How work is judged

- **No unit tests.** The project has none; don't add any or report test counts.
- **Prove it works by running it for real.** A live run of the agent on the test phone, a real build, the app running. No mocks.
- **Don't commit or push until it has been shown working.** Ask before the first push of anything.
- **Commit messages are one line.** Subject only, no body, no trailers.
- **Never comment on GitHub PRs or issues** unless asked.

## Layout

```
Sources/PhoneUseCore/   the agent (Swift): loop, actions, prompt, models, approvals, checkpoints, traces, eval
  Harness/              remote-phone protocol host + HTTP server (GET /ops, POST /op)
  RemoteDevice.swift    the agent driving any phone that speaks that protocol
Sources/PhoneUseUI/     SwiftUI screens and view models (task, approvals, model settings)
Sources/phoneuse-run    command line: run the agent against a protocol endpoint
ios/                    the iPhone app (XcodeGen spec project.yml + App/); `xcodegen generate` makes the project
phone/                  MobileGym, trimmed to 17 apps, English by default: the test phone
local/                  Claude Code bridge, prompt/tools, test-phone build and demo page
cloud/                  Website hosting configuration only; no model credentials or inference
.github/workflows/      iOS build in CI
```

Reference clones (read-only, not part of the product) are in `~/phone-use-refs/`: hermes-agent, phone-harness, mobilegym, nanoMuse, PiDurableKit, TouchSynthesis, desert-ant-core, rea.

## Running things

- **Test phone + agent:** `node local/claude-code.mjs`. Open `http://127.0.0.1:8766/demo/` in Chrome.
- **Subscription token:** `~/.config/agentone/claude-code-token`, or `AGENTONE_TOKEN_FILE` / `CLAUDE_CODE_OAUTH_TOKEN`. Never put secrets in command arguments, repository files or chat output.
- **Phone build:** `cd phone && npm run build`, then `cd ../local && ./build.sh` (output `local/public/`).
- **Swift package:** `swift build`. The iOS app needs Xcode: `cd ios && xcodegen generate`, then `xcodebuild` for the simulator.

## Rules for the code

- The Swift agent (`Sources/PhoneUseCore`) and the browser agent (`local/site/demo/agent-loop.js`, `local/agent.mjs`) are the same design. A change to the prompt, the actions or the safety rules goes into both.
- Coordinates: the local model bridge uses screenshot pixels, matching the browser and iOS phone tools.
- Safety is not optional: taps that send, pay, approve, cancel or delete wait for the user's Allow; logins, passwords and codes are handed back; on-screen text is never treated as instructions.
- The conversation sent to Claude is append-only (thinking blocks must stay valid). Don't edit earlier turns for Claude; trimming old screenshots is only for GLM.
