# To do

## Status 17 Oct
- [x] Speed: several actions per reply, screenshots only when needed, faster settle; bridge answers on the result line and keeps one pre-started Claude Code process (one request each, no shared context). Settings → About task: 41 s → 28 s → 22 s, 4 model turns
- [x] Saved logins (Keychain on the phone, owner-only file for the runner): the model sees names only; values never reach the bridge (checked with a canary)
- [x] Agent One controls other apps from inside the app in the simulator ("This iPhone", screenshot-only); Settings and Amazon add-to-cart recorded in `recordings/`
- [x] Claude Code may use web search, page reading and the person's MCP servers (`~/.config/agentone/mcp.json`) inside a step
- [x] Run reports show model turns and time only (no token count)
- [x] "This iPhone" mode, simulator: touches, Home and app launch sent straight to testmanagerd without waiting for its (never-sent) reply; on-screen text read with Vision as numbered elements. Settings task 76 s → 30–33 s; Amazon cart task 96 s (recorded)
- [x] Bridge queues overlapping requests (a resumed durable run no longer kills a new one)
- [x] In-app agent already takes several actions per reply (shared prompt, sequential tools); most taps open a new screen, so turns are usually one action
- [x] In-app: the model is told the list is text only, so it looks at the screenshot for icon-only buttons (Safari's tabs button found and tapped, 37 s)
- [x] Maps tools (Apple MapKit on the phone): place search and directions; coffee shops near Indiranagar + drive time from MG Road in 22 s
- [ ] `run_shortcut` tool built (shortcuts://run-shortcut); not proven: the simulator has no Shortcuts app
- [x] Built-in browser (WKWebView tools) removed 19 Oct at the user's request; the agent uses Safari and other apps
- [x] Steering: a message typed while the agent works joins the run (PiDurableKit whenBusy: .steer); proven: "also tell me the model name" sent 12 s in, answer had both
- [x] Connected services (MCP) set in the app: Settings > Connected services saves to the bridge (`~/.config/agentone/app-mcp.json`, 0600), tokens in the phone's Keychain; bridge drops --safe-mode only when servers exist (it switches MCP off). DeepWiki answered a question from the app in 25 s
- [x] Notification triggers researched (notes/finn-voorhees-tweets.md): iOS 27 Shortcuts "notification from an app" trigger, Deflector's self-notification trick. Build with a real iOS 27 phone: background run_shortcut via self-notification, "Ask Agent One" App Intent so a notification can start a task (simulator is iOS 18.2, no Shortcuts app)
- [x] Our version of Finn's "iPhone AGI" video (his: Ryanair app, cheapest flight to London tomorrow): `recordings/agent-one-cheapest-flight.mp4` (2 min 37 s). Agent One taps and types through ryanair.com in Safari, 20 actions, Live Activity in the Dynamic Island, answer in chat: FR 30 Dublin → Stansted 06:30, €42.99, nothing booked. Fixed on the way: bridge upload limit 8 → 64 MB (the app resends old screenshots)
- [ ] Deferred, no phone for now: real iPhone install, in-app control check, self-pairing over a local VPN (Finn's route)
- [ ] Waiting on the user: other models besides Claude (yes or no); commit/push; TestFlight (Drive upload dropped 17 Oct)
- [ ] Last: Amazon order (simulator until a phone is available), with Allow before Place order

Goal: our agent drives a real (simulated) phone end to end, with real model calls and real taps, no mocks. Then the same agent drives a real iPhone (the Pelican technique).

One protocol in the middle: Phone Harness's remote-phone protocol (`GET /ops`, `POST /op`). MobileGym gets a bridge that speaks it; later the iPhone app speaks it too. The agent, Hermes and Phone Harness all talk to either one the same way.

```
our agent (Swift)  ─┐                       ┌─ MobileGym bridge → simulated phone (now)
Hermes / Phone Harness ─┼─ GET /ops, POST /op ─┤
                    ─┘                       └─ iPhone app → real iPhone (next)
```

## Now: the six real tasks on MobileGym (before any real iPhone)
- [x] New MobileGym apps, ours, English: Expenses, Visitors, Shop (notification preferences), Gym, Lumi (light), Chats (WhatsApp stand-in)
- [x] Task: share a PDF from Files to the Family group in Chats (3/3)
- [x] Task: file yesterday's receipt in Expenses (0/3, then fixed 15 Oct: taps focus the field, covered elements left out; passed live)
- [x] Task: approve the delivery visitor in Visitors (3/3)
- [x] Task: Shop promotions off, delivery alerts on (3/3)
- [x] Task: reschedule the gym class (3/3)
- [x] Task: Lumi brightness to 30% (3/3)
- [x] Graders from app state in `eval/run_hosted.py`
- [ ] Deferred: 5 runs of all 12 tasks (needs Playwright's Chromium, or run in Chrome one at a time)
- [ ] Deferred: alarm (wheel rows now tappable, untested), dark mode slow (21–24 steps), calculator (1 pass since fixes)
- [ ] Deferred: Hermes per-app skills, measured on the 12 tasks

Fixes on 15 Oct (browser agent): tap focuses the text field under it; element list leaves out anything covered (keyboard, sheets); model can tap an element by its number; skipped extra actions are named back to the model; Clock wheel rows select on tap. The test phone is open (password gate removed on request).

## 1. MobileGym running locally
- [x] Clone MobileGym (`~/phone-use-refs/mobilegym`, commit 5fbd3f3)
- [x] Installed and built; runs locally through `local/claude-code.mjs`
- [x] Python env for its runner: venv, `pip install -r bench_env/requirements.txt`, `playwright install chromium`
- [x] English-only phone in `phone/`: China-specific apps, X and eBay removed; language defaults to English (17 apps)
- [ ] Run one task with its built-in runner in manual mode (`--agent human`) to confirm the judges work
- [ ] Skip the 1.9 GB companion dataset at first (non-commercial licence); add it only if the apps we test need it

## 2. Bridge: MobileGym speaks the phone protocol
- [x] Find how `bench_env` captures the screen and sends taps (Playwright page + its OS API)
- [x] Small Python server on top of that (`bridge/mobilegym_bridge.py`): `screen.capture`, `screen.text`, `input.tap/press/drag/scroll/text`, `nav.home/back`, `apps.launch`, `session.state`
- [x] Check it with Phone Harness's own client (the same check that passed for our Swift host)

## 2b. Local Claude Code bridge (`local/`)
- [x] Test phone at `/`, agent page at `/demo/`, model calls at `/api/step` and `/v1/chat/completions`
- [x] Actual Claude Code CLI authenticated with the user's subscription token; no other model calls or fallback
- [x] Live Chrome calculator run: 128 × 46 = 5888; graded PASS from phone state (17 Oct)
- [x] English phone build and shared prompt/tools served locally
- [ ] Better screenshots: compare the in-browser render with a real one; fix what differs

## 3. Our agent drives it, for real
- [x] Swift `RemoteDevice`: a `DeviceController` that calls a protocol endpoint
- [x] Command-line runner: `phoneuse-run --device <url> --token <t> "task"`
- [x] Live run with GLM; Claude once there is a Console API key
- [ ] Watch it on screen; save the trace

## 4. Measure
- [ ] Pick MobileGym tasks close to ours: send a message, change a setting, reply in Messages
- [ ] Run each several times with the repeat-run harness; record success rate, steps, cost
- [ ] Use MobileGym's own judges to grade, not the model's claim
- [ ] Fix what fails (prompt, coordinates, waits); re-run

## 5. Hermes on the same phone
- [ ] Point Phone Harness at the bridge (needs its direct URL + token setting; write it on a local branch)
- [ ] Run a Hermes task against MobileGym

## 5b. iPhone app (15 Oct)
- [x] Xcode 27.0 on the pendrive (`/Volumes/SANDISK/Applications/Xcode.app`)
- [x] Test phone inside the app (`ios/App/TestPhone.swift`): the local MobileGym phone in a web view, driven by the Swift agent
- [x] Model through the local bridge (`LocalModelClient`): no key on the phone; `/api/step` accepts the app's own prompt and tools
- [x] Background runs (`ios/App/BackgroundRun.swift`): iOS 26 continued-processing task with system progress and Stop
- [x] App code type-checks for the iOS simulator
- [x] Agent on PiDurableKit (`ios/App/PhoneAgent.swift`): tools, approvals hook, one conversation per task, durable; numbered element list + tap by number, settle-wait, changed-only lists
- [x] Local OpenAI-compatible `/v1/chat/completions` for the app; subscription token stays on the Mac
- [x] Run screen with live steps, Allow alert, `-task` / `-autoAllow` launch flags, state print for grading
- [x] Live Activity widget (Lock Screen + Dynamic Island, Stop)
- [x] Xcode licence accepted; full `xcodebuild` build (DerivedData on the pendrive)
- [x] iPhone 16 Pro simulator (iOS 18.2); chat run, saved threads and follow-up after restart shown in the app

## 6. Then the iPhone (the Pelican technique)
- [x] Xcode toolchain: Xcode 27.0 on the pendrive
- [ ] iPhone on iOS 26+ (pairing record from a trusted Mac, LocalDevVPN; Developer Mode not listed by TouchSynthesis, unverified)
- [ ] On-device control layer: test automation started on the phone itself (TouchSynthesis as reference)
- [ ] iPhone app serves the same protocol; the agent from step 3 drives it unchanged

## Open
- [ ] Speedrun form: refill (the tab closed) once referral, co-founder, citizenship, college, years and location are known
- [x] Claude subscription: authenticated through the actual local Claude Code CLI and verified with a real phone task
- [ ] GitHub token lacks `workflow` scope: `gh auth refresh -h github.com -s workflow`; nothing committed yet
- [ ] Decide: keep the test phone open or put a gate back; delete the old Vercel site and `site/`?
