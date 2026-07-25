# Kubecode Client Documentation

## Plans

- [Apple platform roadmap](APPLE_PLATFORM_ROADMAP.md)
- [macOS and Browser functional parity](MACOS_BROWSER_PARITY.md)

## Architecture

- [Client architecture and Runtime API boundary](ARCHITECTURE.md)

## Architecture decisions

| ADR | Status | Decision |
| --- | --- | --- |
| [0001](adr/0001-client-platform-boundary.md) | Accepted | Client platform boundary |
| [0002](adr/0002-server-connections-and-cluster-boundary.md) | Accepted | Server connections and cluster boundary |
| [0003](adr/0003-shared-apple-client-architecture.md) | Proposed | Shared Apple client architecture |
| [0004](adr/0004-macos-workstation-scope.md) | Accepted | macOS workstation scope |
| [0005](adr/0005-ios-ipados-companion-scope.md) | Proposed | iPhone and iPad companion scope |
| [0006](adr/0006-server-profiles-authentication-and-pairing.md) | Proposed | Server profiles, authentication, and pairing |
| [0007](adr/0007-event-sync-cache-and-notifications.md) | Proposed | Event synchronization, cache, and notifications |
| [0008](adr/0008-apple-distribution-and-runtime-payload.md) | Proposed | Distribution and standalone Runtime payload |
| [0009](adr/0009-sttextview-native-code-editor.md) | Proposed | STTextView native code editor |
| [0010](adr/0010-native-markdown-and-math-transcript.md) | Proposed | Native Markdown and math transcript rendering |
| [0011](adr/0011-native-navigator-toolbar-and-explorer-layout.md) | Accepted | Native Navigator toolbar and Explorer layout |
| [0012](adr/0012-full-size-native-navigator-chrome.md) | Accepted | Full-size native Navigator chrome; supersedes ADR 0011 presentation details |
| [0013](adr/0013-live-transcript-and-terminal-workbench.md) | Accepted | Live transcript and Terminal workbench |
| [0014](adr/0014-native-navigator-titlebar-placement.md) | Accepted | Native Navigator titlebar placement; supersedes ADR 0012 placement details |
| [0015](adr/0015-persistent-onboarding-navigation-shell.md) | Accepted | Persistent onboarding NavigationSplitView; supersedes ADR 0014 |

Proposed ADRs are implementation-ready recommendations. Move one to Accepted
before starting work that depends on its long-term boundary.
