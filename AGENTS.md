# Agent rules for rePossess

rePossess is a local-first Mac app that reads and writes content
on a reMarkable tablet and exposes it to AI clients through MCP.
Read [README.md](README.md) for scope, setup, limitations, and release instructions.

## Layout

| Path | Contents |
| --- | --- |
| `Package.swift` | The Swift package: the app's targets, the `repossess` command, and their tests |
| `Sources/RePossessFormat/` | rmdoc archives, version 6 pages (ported from rmscene), page text, and notebooks from Markdown |
| `Sources/RePossessUSB/`, `Sources/RePossessCloud/` | The two transports, which read and add new documents; the cloud transport also pairs and paces its requests |
| `Sources/RePossessLibrary/` | The mirror and its SQLite index, the refresh from each transport, the queue of pushes, and the tablet's PDF exports |
| `Sources/RePossessRender/` | Text layout and page rendering |
| `Sources/RePossessRecognize/` | Handwriting recognition through AnyLanguageModel: strips, the prompt, providers, the configuration, the pinned model, and evaluation |
| `Sources/RePossessMCP/` | The MCP tools, the pusher, the recognizer's tools, and the server |
| `Sources/repossess/` | The command |
| `Sources/RePossessAppCore/`, `Sources/RePossessApp/` | The menu bar app: status, background refresh and recognition, settings, and MCP client setup; and its `main` |
| `App/Info.plist` | The app bundle's settings |
| `App/AppIcon.icon/` | The layered app icon: device and ghost layers in light and dark appearances, which `app.sh` compiles with `actool` |
| `Tests/` | Swift Testing tests, one target for each library; fixtures are invented |
| `scripts/` | Scripts that run outside the package: the layout comparison; and `app.sh`, which assembles, signs, opens, and quits rePossess.app |
| `mise.toml`, `.swift-format` | The `build`, `build:release`, `build:app`, `sign:app`, `run:app`, `quit:app`, `test`, `lint`, `format`, and `check` tasks and the format settings |
| `captures/` | Files copied from a real tablet; ignored by git |

## Tablet safety

- Read before you write.
  Copy the tablet's files to `captures/` before a live test writes to the tablet.
- Never delete or overwrite a document on the tablet.
  A test write creates a new document whose title starts with "rePossess test",
  in a folder made for tests when the path can choose a folder,
  and otherwise at the top level, where Mattt can find and delete it.
  Each test write needs Mattt's approval.
- Never change the tablet's settings, firmware, or system files
  without Mattt's approval for that action.
  Never enable developer mode: it erases a Paper Pro,
  and it may erase Mattt's Paper Pure.
- Pairing with the reMarkable cloud adds a device to Mattt's account.
  Pair only with his approval and a code that he supplies.
  Keep the device token in the Keychain, never in a file, a log, or a commit.

## Rules

- This repository is private for now (Mattt, 2026-10-24),
  but write it as if it may become public.
  Never commit secrets, tokens, device keys, or real tablet content.
  Test fixtures are made for the purpose, with invented text and IDs.
- rePossess sends the owner's data only to the tablet and reMarkable's cloud,
  and to another host only when the owner asks or configures it,
  such as a cloud recognizer, whose configuration must say plainly that page images go to it.
  It fetches from another host only when the owner asks,
  such as a URL in `push_file` or the recognizer model download
  (Mattt, 2026-10-25).
- Handwriting recognition is off until the owner configures a provider,
  and the recognizer's model downloads only when the owner starts the download
  (Mattt, 2026-10-25).
- Port code only from permissively licensed sources, such as rmscene and rmapi-js.
  Read AGPL and GPL projects, such as ddvk/rmapi, only to understand behavior.
- Keep the CI workflow out of the repository until the first publish;
  a separate pull request adds it.
- For Apple documentation, use [Sosumi](https://sosumi.ai/).
  To check an exact declaration, read the headers or `.swiftinterface` files
  in the installed SDK.
