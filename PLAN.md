# Phone Use: build plan

13 October 2026

iPhone only. An agent that takes a plain-language task ("turn off promo notifications in this shopping app"), drives the real app by reading the screen and tapping, and talks directly to the LLM with no laptop in the loop.

## Direction (14 October 2026)

Hermes Agent already has the agent side: memory, tools, many models, and a Phone Harness plugin that drives phones. What it lacks is direct control of an iPhone: Phone Harness reaches an iPhone only through iPhone Mirroring on a Mac. This app fills that gap. It runs on the iPhone, controls other apps on the device, and answers Phone Harness's remote-phone protocol (`GET /ops`, `POST /op`), so Hermes on any laptop or server drives the phone over the network with no Mac in the loop.

- Done: the protocol host and HTTP server (`Sources/PhoneUseCore/Harness/`), tested end to end against Phone Harness's own Python client on this Mac, with on-device text recognition.
- Needed on the Phone Harness side: a way to point it at a phone's URL and token. Today its remote backend is only used for its own cloud phones; this is a few lines in `transport.connect`.
- Still the hard part: the on-device control layer (phase 3) that performs the taps, which needs Xcode and an iPhone.
- The on-device agent loop (phase 4) stays, for running tasks with no computer at all.

## Time estimate

About **3 to 4 weeks of working days** to a version you can use yourself, and about **1 week** to the first demo of one task running end to end.

These are my estimates, not measured. They assume I write the code, you test on the phone the same day.

| Phase | What it proves | Time |
|---|---|---|
| 1. Toolchain | Xcode works from the terminal on this Mac | 0.5 day (mostly download and unpack on the pendrive) |
| 2. Empty app on the phone | Build, sign and install without opening Xcode | 0.5 day |
| 3. Control another app | We can read and tap in an app we don't own | 1 to 2 days |
| 4. Agent loop | The model can complete a simple task | 3 to 4 days |
| 5. Task input and stop control | You can give it a task and halt it | 1 to 2 days |
| 6. Safety | It can't do damage unprompted | 2 days |
| 7. Reliability | It survives kills, waits and odd screens | 3 to 4 days |
| 8. Testing on the six tasks | Real success rates | 4 to 5 days |
| **Total** | | **16 to 20 working days** |

What would stretch it: signing problems in phase 2 (often a lost day), a "no" in phase 3 (see Risks), and apps with poor accessibility labels in phase 8.

## Steps

Items marked **(added)** were not in the plan I gave in chat.

### 1. Toolchain
1. Turn on ownership for the pendrive: `sudo diskutil enableOwnership /Volumes/SANDISK`
2. Install Xcode 27.0 onto it: `xcodes install 27.0 --directory /Volumes/SANDISK --experimental-unxip`
3. Point the system at it, accept the licence, run first-launch setup.
4. Download the iOS platform files (about 8 GB, on the internal disk).
5. **(added)** Send build caches (DerivedData) to the pendrive so the internal disk doesn't fill up.
6. On the iPhone: enable Developer Mode, plug in, tap Trust.
7. Create an App Store Connect API key (Developer role) for signing without the Xcode window.
8. **(added)** Register the phone's device ID with the developer account.

### 2. Empty app on the phone
9. Create the repo in `~/phone-use`, private on GitHub.
10. **(added)** Add a `.gitignore` and keep the API keys out of git from the first commit.
11. Define the project in an XcodeGen text spec.
12. Build with `xcodebuild`, sign, install with `devicectl`.
13. Confirm a "hello" screen opens on the phone.
14. **(added)** Wrap build, install and launch in one script, since this loop runs hundreds of times.

### 3. Control another app
This uses the technique documented by the TouchSynthesis project (cloned in `~/phone-use-refs/TouchSynthesis`): the phone runs Apple's test framework on itself through its own developer services, with no Mac in the loop after setup.

15. Build TouchSynthesis with your signing team and install it on the phone.
16. Install LocalDevVPN on the phone and mount the developer disk image.
17. Copy the pairing record from this Mac into the app (one time).
18. Start automation, enter the passcode, and confirm a tap lands in another app (Settings, then "Bluetooth").
19. Check it still works with the cable unplugged and after the phone has been locked and unlocked.
20. **(added)** In parallel, get on Finn's TestFlight to compare how his build behaves.

### 4. Agent loop
21. Send the model a screenshot each step and have it reply with one action, using coordinates on a fixed grid so replies work on any screen size (nanoMuse's design).
22. Define the actions: `tap`, `type`, `scroll`, `back`, `open_app`, `wait`, `done`, `ask_user`.
23. **(added)** Map app names to bundle IDs so "open WhatsApp" works.
24. Add the LLM client, calling the model directly from the phone, key in the Keychain.
25. Run the loop: read screen, ask model, act, repeat, with a step limit.
26. **(added)** Wait for the screen to settle after each action (spinners, animations, slow networks) before reading it again.
27. If the test framework exposes the element tree on-device, send it alongside the screenshot as a second input.
28. **(added)** Record every step (screen text, screenshot, model reply, action) to a local trace. With no debugger from the terminal, this is how we find out why a run failed.

### 5. Task input and stop control
29. App screen: text box for the task, live step log.
30. Hand the task from the app to the runner over a local connection on the phone.
31. **(added)** A stop control that works while the agent is inside another app, where our own screen isn't visible.
32. **(added)** Show progress while it works in another app (notification or Live Activity).

### 6. Safety
33. Confirm before irreversible actions (send, approve, pay, cancel, delete).
34. Treat on-screen text as untrusted, so a message can't give the agent orders.
35. **(added)** Hand back to you at login screens, one-time codes, Face ID prompts and payment screens; never type passwords.
36. **(added)** Handle system pop-ups (permission requests, "allow notifications") with a default of deny or ask.
37. **(added)** Cap steps and spend per task, and show the cost of each run.
38. **(added)** Keep traces on the phone only, since they hold screenshots of your apps.
39. Optional: redact personal data before it goes to the model (Desert Ant's Redact).

### 7. Reliability
40. Save each step before executing it, so a killed run resumes (PiDurableKit, or the same pattern).
41. Remember successful paths per app, so repeat tasks get faster.
42. **(added)** Detect being stuck (same screen three times, repeated action) and stop with a clear reason.
43. **(added)** Handle the unhappy paths: app not installed, logged out, no network, phone locked. A locked phone can't be unlocked by the agent.

### 8. Testing and shipping
44. **(added)** Build a small test harness: run each task several times and record the success rate, steps and cost.
45. Run the six tasks, in order of risk: notification toggles first (reversible), then Bluetooth light, gym reschedule, visitor approval, expense upload, and the WhatsApp send last.
46. **(added)** Re-sign and reinstall routine: developer-signed builds expire after a year (7 days on a free account).
47. Distribution: a test-runner-based agent can't go through TestFlight or the App Store, so it stays a developer-signed install.

### Later, not in the estimate
- Voice input.
- Triggers and always-on runs ("when the visitor app notifies, approve if it's a delivery"), with Perch as the host.

## What was missing from the chat plan

- **Debugging without a debugger:** the per-step trace recorder (28) and the one-command build script (14).
- **Waiting and timing:** screen-settle detection (26) and stuck detection (42). These cause most failures in agents like this.
- **Stopping it:** a stop control and progress display while it's inside another app (31, 32).
- **Things it must not do itself:** logins, codes, Face ID, payments, system permission pop-ups (35, 36).
- **Cost:** per-task step and spend caps (37).
- **Measuring success:** a repeatable test harness (44) rather than trying each task once.
- **Housekeeping:** device registration (8), secrets out of git (10), build caches off the internal disk (5), signing expiry (46).
- **A second source of answers:** Finn's TestFlight, to compare against our build (20).

## Risks

- **Phase 3 can fail, or break later.** The control technique relies on private Apple interfaces and the phone's developer services. It needs iOS 26 or later, a local VPN app (which mounts the developer disk image) and a one-time pairing with a Mac (whether Developer Mode is also needed is unverified), takes about 60 seconds to start each session, and an iOS update can break it.
- **Licence.** TouchSynthesis has no licence file, so its code can be studied but not copied into ours without the author's permission.
- **Pendrive speed.** Xcode from a USB flash drive works but is slow. If builds take minutes each, the estimate grows; freeing 25 GB on the internal disk removes this.
- **Internal disk.** 37 GB free, and the iOS platform files take about 8 GB of it.
- **Poorly labelled apps.** The Bluetooth light and expense apps may expose almost nothing to the element tree, forcing the slower screenshot route.
- **No App Store path.** This design is personal-use only unless the control method changes.

## Open decisions

1. **Which model does it call?** I'm assuming the Claude API with your own key.
2. **Is the developer account the paid one?** Needed for the API key in step 7 and one-year signing.
