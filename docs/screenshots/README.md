# Screenshots

App screenshots used in the top-level `README.md`. Save the PNGs here with the
exact filenames below (the README already links to them).

| File | What it shows | Source view |
| --- | --- | --- |
| `01-welcome.png` | New-agent home: online status, prompt suggestions, tool count, composer. The lead "hero" image. | `WelcomeHomeView` |
| `02-chat-execution.png` | Full window: session sidebar + chat reply with per-message stats and usage footer. | `ChatView`, `SidebarView`, `ExecutionFlowView` |
| `03-settings.png` | Settings: balance, wallet & API key, Docker config, appearance toggle, saved agents. | `SettingsView`, `BalanceView`, `AgentSettingsView` |
| `04-connect-agent.png` | Connect Agent form with `0x`/Direct URL field and validation. | `AgentSettingsView` |
| `05-file-attachment.png` | PDF attached in the composer with a multi-step tool-execution trace. | `ChatView`, `ExecutionFlowView`, `ExecutionItemRow` |

## Tips

- Capture on a Retina display; a window shot is `⌘⇧4` then `Space`.
- Keep window widths consistent so the grid lines up.
- Dark mode reads as more "native macOS" — the current set is all dark.
