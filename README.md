# PR Desk

A native macOS dashboard for the pull requests and issues I work on in
[vllm-project/vllm](https://github.com/vllm-project/vllm), with the same desk for the iPad and
iPhone.

![PR Desk](docs/screenshot.webp)

![PR Desk on an iPad mini and an iPhone](docs/screenshot-mobile.webp)

> [!NOTE]
> This is a personal app, built around my own workflow. It's hard-wired to `vllm-project/vllm`,
> to my triage board (GitHub Project #56), and to a few other tools I use. It isn't meant to be used
> by anyone else as-is, and I don't support it. The source is here for reference.

## What it does

- One dense, keyboard-driven list of the PRs and issues I'm involved in, grouped by their status
  on the triage board, with whose turn it is, CI, diff size and age at a glance
- A detail pane with the conversation, checks and files diff, where I can comment, review and approve
- An inbox of GitHub notifications for the repository
- Badges for contributors' affiliations, and stacked PRs drawn as trees
- Sending items to Grok Bots

[`SPEC.md`](SPEC.md) is the full spec, and [`AGENTS.md`](AGENTS.md) holds notes for
coding agents.

## Building

Needs macOS 26, Xcode 26, [Tuist](https://tuist.dev), and either `gh auth login` or a personal
access token in Settings.

```sh
tuist generate --no-open
xcodebuild -workspace PRDesk.xcworkspace -scheme PRDesk -derivedDataPath .build/DerivedData build
open .build/DerivedData/Build/Products/Debug/PRDesk.app
```

`scripts/install.sh` builds a Release copy and installs it to `/Applications`.

The iPad and iPhone app is the `PRDeskMobile` scheme of the same workspace (iOS 27); it shares
most of its code with the Mac app (`Shared/`). `AGENTS.md` has how to run it in a simulator and
`scripts/setup-device.sh` installs it on a device.

## Third-party

- [GRDB.swift](https://github.com/groue/GRDB.swift) (MIT)
- [highlight.js](https://highlightjs.org) (BSD-3-Clause, `Shared/Resources/Web/highlight.LICENSE`)
- [Mermaid](https://mermaid.js.org) for diagrams in bodies (MIT, `Shared/Resources/Web/mermaid.LICENSE`)
- [Octicons](https://primer.style/octicons) for the PR state icons (MIT, `Shared/Resources/octicons.LICENSE`)
- [Lobe Icons](https://github.com/lobehub/lobe-icons) for the Cohere and Tencent badges (MIT, `Shared/Resources/lobe-icons.LICENSE`)
