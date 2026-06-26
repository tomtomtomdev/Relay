# Handoff: Relay — Telegram → Claude Code bridge (macOS)

## Overview
**Relay** is a macOS menu-bar app that lets you drive Claude Code from Telegram. It listens to a configured Telegram bot, accepts messages from allowed chat IDs, forwards them into a live terminal/Claude Code session, executes commands, and streams output back to the Telegram chat. It lives in the macOS status bar when its window is closed. It also has a built-in "Archive & Distribute" flow that builds, zips, and uploads the app to Google Drive for easy install distribution.

## About the Design Files
The file in this bundle (`Relay.dc.html`) is a **design reference created in HTML** — a prototype showing intended look and behavior, **not production code to copy directly**. The task is to **recreate this design in the target environment** using its established patterns. For a native macOS app this means **SwiftUI / AppKit** (recommended: SwiftUI for windows + `NSStatusItem`/`MenuBarExtra` for the status-bar presence, AppKit bridges where needed). If you build a cross-platform shell instead (e.g. Electron/Tauri), recreate the same layouts with that stack's conventions. Do not ship the HTML.

> The HTML uses a small in-house component runtime (`<x-dc>` + `support.js`). Ignore that machinery — only the rendered UI matters.

## Fidelity
**High-fidelity.** Final colors, typography, spacing, and component states are specified below and should be matched closely. Both **dark and light** appearances are designed; support both and follow the system appearance.

## Screens / Views
The prototype is a pannable canvas containing six frames.

### 1. Main Window — Live Session (dark & light)
- **Purpose:** Primary window. Shows connection status and a live feed of commands arriving from Telegram and their terminal/Claude Code output.
- **Layout:** Standard macOS window, 12px corner radius. Title bar (46px) with traffic lights left, centered title "Relay — Session", right-aligned "Listening" status (7px green dot + label). Body is a horizontal split: fixed **204px sidebar** + flexible content. Content height in mock ≈ 560px.
- **Sidebar:** App mark (28px steel squircle + relay glyph) and "Relay" wordmark at top. Nav items (8px/10px padding, 7px radius, 13px text): **Session** (active — `rgba(240,136,62,.16)` bg), Activity, Archive, Settings — each with a 15px stroked icon. Bottom block (separated by hairline): "Bot listener" label + green toggle switch (34×20px, 11px radius, knob 16px), subtext `@relay_dev_bot · polling`.
- **Status cards (top of content):** Three equal flex cards, 10px radius, 13/14px padding, 1px hairline border. Card bg dark `#2a2a2c` / light `#F7F7F9`. Each: uppercase 11px label (letter-spacing .04em, tertiary gray), then 14px semibold value with a 7px status dot, then 12px mono detail.
  - **Telegram Bot** — Connected (green dot) — `@relay_dev_bot`
  - **Source Chat** — Allowed (green dot) — `Dewa · 7129•••842`
  - **Claude Code** — Ready (green dot) — `~/dev/payments-api`
- **Live Session panel:** Header row "Live Session" (13px semibold) + right meta `tty · bash · 80×24` (11px mono). Below: terminal area, bg `#161618` (dark in BOTH appearances), 10px radius, 16/18px padding, 12.5px mono, line-height 1.7. Sample content:
  - `14:32  Telegram ▸ Dewa` (timestamp tertiary, "Telegram ▸ Dewa" in Telegram blue `#2AABEE`)
  - `"run the test suite"` (light text)
  - `$ npm test`
  - ` PASS  src/auth.test.ts` / ` PASS  src/api.test.ts` (green `#32D74B`)
  - ` Tests: 24 passed, 24 total`
  - `↳ replied to Telegram ✓` (tertiary)
  - `14:35  Telegram ▸ Dewa` → `"deploy api to staging"`
  - `⚠ permission required: deploy` (amber `#F0883E`) + pill "Approve in Telegram ↗" (blue outline)
  - Prompt line `$` + blinking 8×15px amber caret.

### 2. Status-bar Dropdown (menu-bar popover)
- **Purpose:** Quick-glance control surface when the main window is closed. This is the always-resident UI.
- **Layout:** Translucent popover (`rgba(34,34,36,.92)` + backdrop blur 40px saturate 180%), 12px radius, 1px light border, drop shadow. A faux menu bar above it shows the Relay status icon with a 6px green dot. Width ≈ 300px.
- **Header (16px padding, hairline below):** 34px app squircle, "Relay" (14px bold) + "Listening for commands" (12px green), and a green toggle (38×23px) on the right.
- **Status rows (13px):** "Telegram bot" → green dot `@relay_dev_bot`; "Source chat" → `Dewa` (mono); "Claude Code" → green dot Ready.
- **Recent section:** uppercase 11px "Recent" label, then rows of `status icon + mono command + timestamp`:
  - ✓ `npm test` 14:32 · ⚠ `deploy staging` 14:35 · ✓ `git status` 14:20
- **Footer buttons:** **Open Relay** (filled, `rgba(255,255,255,.08)`), **Pause** (subtle), **Quit** (red text `#FF6961` on `rgba(255,105,97,.1)`).

### 3. Settings — Telegram & Claude Code
- **Layout:** Settings window, title bar + a toolbar tab row (Telegram / Claude / Distribution / General — each icon+label, active tab `rgba(240,136,62,.16)`). Content 22/26px padding. Form rows: right-aligned **140px** label column + field, 16px gap, 14px vertical rhythm.
- **Bot Connection section** (uppercase section header):
  - **Bot token** — masked mono value `7847291043:AAH•••••••••••••••••••3kQ` in a 32px field (`#1a1a1c` bg dark) with a trailing **Reveal** button.
  - **Allowed chat IDs** — token/chip input: blue chips (`rgba(42,171,238,.15)` bg, blue border) for `7129904842`, `-100488213`, each with × remove; "add id…" placeholder. Helper text: "Only messages from these chats are forwarded to the terminal."
- **Claude Code Session section:**
  - **Working directory** — `~/dev/payments-api` + **Choose…** button.
  - **Permission mode** — 3-segment control: **Ask in Telegram** (selected), Auto-accept, Plan only.
  - **Forward output** — green toggle + "Stream terminal output back to the Telegram chat".

### 4. Settings — Distribution (Google Drive)
- **Google Drive Account section:**
  - **Google email** — `dewa.relay@gmail.com` (150px label column here).
  - **App password** — masked mono `•••• •••• •••• ••••` + green "Verified" indicator.
  - **Security callout** (amber, `rgba(240,136,62,.08)` bg, amber border, 9px radius, warning icon): heading "Don't use your main password" + body "Relay never stores your account password. Use a Google **App Password** or sign in once with OAuth — tokens are kept in the macOS Keychain." Two buttons: **Sign in with Google** (filled amber) and **Create App Password ↗** (amber outline). *Implement Keychain storage; never persist plaintext passwords.*
- **Build Output section:** **Drive folder** = `/Relay Builds` + **Change…**; **Share links** toggle = "Generate a public download link after each upload".

### 5. Archive & Distribute (sheet/window)
- **Purpose:** Build → zip → upload-to-Drive → share-link pipeline.
- **Header:** 46px app squircle + "Relay.app · v1.4.0" + mono `arm64 · signed · 18.6 MB`.
- **Step list:** each row = 22px status circle + label + right meta.
  - ✓ Build & codesign — 2.4s (done, green filled check)
  - ✓ Archive to Relay-1.4.0.zip — 0.9s
  - ◉ Uploading to Google Drive — 64% (in-progress: amber ring; 6px progress bar `linear-gradient(90deg,#F0883E,#f5a55f)`; sub `11.9 / 18.6 MB · /Relay Builds`)
  - ○ Generate share link (pending, dimmed)
- **Share link field:** mono `drive.google.com/… pending` with disabled **Copy** (enable + populate when upload completes).
- **Footer:** primary **Archiving…** (amber, becomes "Archive & Upload" / "Open in Drive" by state) + **Cancel**.

## Interactions & Behavior
- **Status-bar lifecycle:** Closing the main window keeps the app running as an `NSStatusItem` / `MenuBarExtra`. Clicking the status icon opens the dropdown (frame 2). "Open Relay" reopens the main window; "Quit" terminates.
- **Listening toggle:** Master on/off for bot polling. Off = stop processing updates; status dots go gray, label "Paused".
- **Message → command flow:** Poll/long-poll the Telegram Bot API → filter by allowed chat IDs → forward message text into the Claude Code / terminal session → stream stdout/stderr lines into the Live Session panel → (if "Forward output" on) send results back to the originating Telegram chat.
- **Permission gating:** When mode = "Ask in Telegram", privileged actions (e.g. deploy) pause and send an approval prompt to Telegram with inline approve/deny buttons; reflect the pending state in the terminal (amber ⚠ + "Approve in Telegram" pill). "Auto-accept" runs without prompting; "Plan only" never executes.
- **Reveal button:** toggles masked token visibility.
- **Chip input:** type + Enter adds a chat ID chip; × removes.
- **Archive flow:** sequential steps with live progress bar; on completion enable the share-link field + Copy and switch the primary button to "Open in Drive".
- **Caret:** blinking terminal cursor (~1s steady-step blink).

## State Management
- `isListening: Bool` — bot polling on/off.
- `connection: { telegram: .connected/.error, sourceChat: .allowed, claudeCode: .ready/.busy }`.
- `config.telegram: { botToken: String (Keychain), allowedChatIds: [String] }`.
- `config.claude: { workingDir: URL, permissionMode: .askInTelegram | .autoAccept | .planOnly, forwardOutput: Bool }`.
- `config.distribution: { googleEmail: String, googleAppPassword (Keychain) OR oauthToken (Keychain), driveFolder: String, generateShareLinks: Bool }`.
- `sessionLog: [LogEntry { time, source(.telegram/.system), text, kind(.input/.stdout/.pass/.warn/.reply) }]`.
- `pendingApprovals: [Approval]`.
- `archiveJob: { version, sizeBytes, steps:[{name,status,duration}], uploadProgress: Double, shareURL: URL? }`.
- Data needs: Telegram Bot API (getUpdates/sendMessage/answerCallbackQuery), a managed Claude Code / PTY subprocess, Google Drive upload (resumable upload API; prefer OAuth), macOS Keychain for all secrets.

## Design Tokens
**Colors**
- Accent (Relay amber): `#F0883E` (hover/lighter `#f5a55f`)
- Telegram blue: `#2AABEE`  ·  Claude terracotta: `#D97757`
- Success/connected green: `#32D74B` (light traffic `#28C840`)
- Destructive: `#FF6961` / `#FF5F57`
- **Dark:** window `#202022`/`#242426`, sidebar `#191919`/`#1f1f21`, card `#2a2a2c`, field `#1a1a1c`, terminal `#161618`, titlebar `#262628`/`#2b2b2d`. Text: primary `#f5f5f7`, secondary `#98989d`, tertiary `#6e6e73`/`#7d7d82`. Borders `rgba(255,255,255,.06–.12)`.
- **Light:** window `#ffffff`, sidebar `#F2F2F4`, titlebar `#ECECEE`, card `#F7F7F9`, terminal stays `#161618`. Text: primary `#1d1d1f`, secondary `#6e6e73`, tertiary `#8a8a8f`/`#9a9a9f`. Borders `rgba(0,0,0,.07–.1)`.
- Traffic lights: `#FF5F57`, `#FEBC2E`, `#28C840`.

**Typography**
- UI: SF Pro / system (`-apple-system, system-ui`). Weights: 560 (medium controls), 600/620 semibold, 680 bold. Sizes: 11px labels (uppercase, ls .04em), 12–13px body, 14px card values, 14–15px titles.
- Mono: SF Mono / `ui-monospace` for tokens, paths, chat IDs, and the terminal (12.5px / lh 1.7).

**Spacing / shape**
- Window radius 12px; cards 10px; fields/buttons 7–8px; chips/pills 6px.
- Titlebar 46px; sidebar 204px; settings label column 140–150px; form row gap 16px / vertical 14px.
- Toggles: 34×20 (sidebar) / 38×23 (prominent), knob inset 2px.
- Shadows: windows `0 40px 80px -20px rgba(0,0,0,.5)` (dark) / `…,.3)` (light); popover `0 30px 60px -15px rgba(0,0,0,.6)`.

## Assets
- **Relay app mark:** a "broadcast/relay" glyph (center node + radiating signal arcs) on a steel squircle (`linear-gradient(150deg,#46474b,#1b1b1d)`, inset top highlight). Recreate as an asset/SF Symbol equivalent (e.g. `dot.radiowaves.left.and.right` tinted amber) and produce a proper `.icns` for the app.
- All other icons are simple stroked glyphs — map to SF Symbols where possible.
- No external images; no third-party brand assets beyond referencing Telegram/Google by name.

## Files
- `Relay.dc.html` — the high-fidelity HTML prototype containing all six frames (open in a browser; pan the canvas).
