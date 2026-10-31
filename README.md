# rePossess

rePossess lets you read your reMarkable notes with an AI client
and send new notes, PDFs, and EPUBs to your tablet.
It runs in your Mac's menu bar, keeps a local copy of your documents,
and makes them available through MCP (Model Context Protocol).
Your client can search documents, read text, and view page images.
Optional handwriting recognition makes handwritten notes searchable too.

Version 0.1.0 is a limited preview.
Manual checks cover a reMarkable Paper Pure running software 3.29.0.153,
Claude Code, and Claude Desktop; they do not cover every workflow.
Other tablet models and Codex have not been verified.

## Install

rePossess requires an **Apple silicon Mac with macOS 27 or later**.
You need a reMarkable tablet with its USB web interface enabled,
or a reMarkable account that syncs with the tablet.

1. Download the ZIP from the
   [0.1.0 release page](https://github.com/mattt/rePossess/releases/tag/0.1.0)
   and expand it.
2. Move rePossess.app to `/Applications`, then open it.
3. Open Settings from the rePossess menu bar icon.
   The app has no Dock icon.

To install a later version, quit rePossess and replace the app in Applications.

## Connect your tablet

You can use USB, the cloud, or both.
The app refreshes when the tablet connects over USB
and every 15 minutes by default.
You can change the interval in Settings or choose **Refresh Now** from the menu.

For **USB**, connect the tablet to your Mac with a USB cable
and turn on the tablet's USB web interface.
Allow rePossess to access the local network when macOS asks:
the USB connection appears as a network.
No developer mode or SSH access is needed.
If USB access fails, check System Settings > Privacy & Security > Local Network,
then try Refresh Now again.

For **cloud access**, open Settings > Cloud.
Use **Open my.remarkable.com** to get a one-time code,
enter it in rePossess, and choose **Pair**.
Pairing adds this Mac as a device on your reMarkable account
and stores its token in the login Keychain.
Allow Keychain access when macOS asks.
To revoke access later, unpair in rePossess
and remove the device from your reMarkable account.

Refresh uses USB when available and can fall back to the cloud.
The cloud may have older content until your tablet finishes syncing.
When neither connection is available,
your client can still read the documents already copied to your Mac.

## Connect an AI client

Open Settings > MCP Clients and select your client.
For Claude Desktop, choose **Add to Claude Desktop**
and review the configuration change before saving it.
For Claude Code or Codex, copy the setup command and run it in Terminal.
Quit and reopen the client after setup.

The client starts the helper inside rePossess.app,
which reads the same library as the menu bar app.
Keep rePossess open for background refresh and USB access through the app.
For another client that supports MCP over stdio, use:

```json
{
  "mcpServers": {
    "repossess": {
      "command": "/Applications/rePossess.app/Contents/MacOS/repossess",
      "args": ["mcp"]
    }
  }
}
```

Try asking your client to "Find my notes about the garden"
or "Send a new packing checklist to my reMarkable."
Each push creates a **new document** at the top level of the tablet's library.
It never edits or replaces an existing document.
If the tablet and cloud are unavailable, the push waits in a local queue
until a later refresh or push can send it.
If a push reports a queued or unknown result, don't repeat the request:
each request creates another document.
Check its status before sending again.

Markdown becomes a native notebook with titles, subheadings, bullets,
and checkboxes.
Emphasis, links, and inline code become plain text;
code blocks and tables become lines of body text, and images are not embedded.
A notebook uses one page unless `paginate` is requested,
which starts a page at each `##` heading.
Markdown is limited to 100,000 characters and 200 pages;
PDF and EPUB uploads are limited to 100 MB.

A connected client can read document text and request page images.
It may send that content to its own model provider under the client's settings,
even when rePossess's handwriting recognition runs on your Mac or is off.

## Recognize handwriting

Handwriting recognition is off by default.
In Settings > Handwriting, turn on **Recognize handwriting**
and choose a provider.
The app caches recognition results for reading and search.
It recognizes waiting pages in the background
for providers other than MCP client sampling.
With MCP client sampling, a compatible client must call the `recognize_pages` tool.

- **MLX** runs Qwen3-VL 8B 4-bit on your Mac.
  Its model needs about **5.8 GB** of disk space.
  Choose **Download Model** to download it from Hugging Face;
  rePossess does not start the download on its own.
  It can use an existing copy at the pinned revision in the Hugging Face cache.
- **Foundation Models** uses Apple's on-device model when available.
- **Anthropic, OpenAI, Gemini, and Ollama** use the provider and model you configure.
  The settings show where page images go.
  A destination outside your Mac requires your explicit consent
  to send page images there.
  API keys entered in the app are stored in the login Keychain.
- **MCP client** asks the connected client's model through MCP sampling
  and requires consent to send page images to that client.
  This needs a client that supports sampling;
  the tested Claude Code version, 2.1.310, did not.

Recognition has been checked with MLX and Foundation Models.
External providers, Ollama, and sampling with a real client remain unverified.
Recognition can miss or misread words, especially crossed-out text and drawings.
Check the page image when the wording matters.

## Privacy and limitations

The local library is in `~/Library/Application Support/rePossess/`.
It contains document copies, a search index, cached recognition results,
queued uploads, and any downloaded recognition model.
Pairing tokens and saved provider API keys are kept in the Keychain.

rePossess connects to your tablet and reMarkable's cloud.
Other transfers require your request or configuration,
such as a model download, a file URL you ask it to send to the tablet,
or a recognition provider that receives page images.
MCP clients have access to the library as described above.

This preview has limits:

- It adds documents but cannot edit, delete, move, or rename existing ones.
  It does not manage folders or multiple tablets.
- It uses an unofficial cloud API, which can change.
- Its own page rendering may differ from the tablet's layout
  and does not draw page templates.
  For typed documents, it uses a current tablet PDF export when available over USB.
- Recognition quality varies with handwriting and provider.
  Local model checks used a Mac with 36 GB of memory;
  Macs with less memory have not been verified.

## Command-line use

The app includes a command-line helper:

```sh
/Applications/rePossess.app/Contents/MacOS/repossess help
```

Use that path in place of `repossess` below,
or use the binary from a source build:

```sh
repossess refresh
repossess list
repossess status
repossess push-markdown checklist.md --title "Packing checklist"
repossess push-file guide.pdf
repossess pushes
```

`repossess drop-push <id>` removes an unsent push from the queue.
`repossess check-token` reads the cloud token without sending it anywhere,
so you can answer a Keychain prompt in Terminal if an MCP client times out.
Use `--library <folder>` or `REPOSSESS_LIBRARY` to select another local library.

## Development

You need Xcode 27 or later and mise.
Use Xcode's Swift toolchain; an older standalone Swift installation may not
build the pinned dependencies.
The app build also needs a signing identity in your login Keychain.
Set `REPOSSESS_SIGNING_IDENTITY` to select your certificate;
the build script otherwise uses the maintainer's Apple Development identity.

```sh
mise run check
mise run build:app
open build/rePossess.app
```

The app bundle includes the `repossess` command and MLX's Metal resources.
Keep them together if you use the command outside an MCP client.
The Swift package separates document formats, USB and cloud access,
the local library, rendering, recognition, MCP tools, and the menu bar app.
The library uses SQLite for search and keeps document files on disk.
The app and MCP helper share it, with locks around refresh and recognition.
Reads use the local copy; they do not start handwriting recognition.

Tests use invented documents and fake transports.
For an isolated app check, use a separate library and disable Keychain access:

```sh
mise run run:app -- --library /tmp/repossess-check --no-keychain
```

This disables cloud access, but a connected USB tablet remains accessible.
Live write checks must create new test documents with the owner's approval.
For rendering work, `scripts/compare_layout.py` compares the helper's
`layout` output with a tablet PDF export; it needs `uv` and MuPDF's `mutool`.

## Releasing

Use Xcode 27 or later, mise, ShellCheck,
and a Developer ID Application certificate with its private key in the Keychain.
Set `REPOSSESS_SIGNING_IDENTITY` to select the release certificate.
For notarization, set `KEYCHAIN_PROFILE` to a notarytool profile,
or set `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`, and `NOTARY_KEY_FILE` together.
Keep credentials outside the repository.

Commit the release source before preparing the app:

```sh
mise run release:prepare
```

This checks the code, builds and signs the app, submits it for notarization,
staples the ticket, checks Gatekeeper acceptance,
and creates `dist/rePossess-0.1.0.zip` and its `.sha256` checksum.
It requires a clean worktree and records the source commit in the app.
It does not push or publish.
The `release:build`, `release:notarize`, `release:staple`,
`release:verify`, and `release:package` tasks can resume individual steps.
Investigate a rejected notarization through its submission log before retrying.

Expand the final ZIP and check the bundled helper and resources.
Check first launch and permissions with a downloaded copy on another Mac,
and check tablet and MCP client workflows before publishing.
Tag the packaged source commit as `0.1.0`
and attach the ZIP and checksum to the GitHub release for that tag.

## License and acknowledgments

rePossess is available under the [MIT License](LICENSE.md).
The reMarkable page reader and writer include code ported from rmscene,
Copyright (c) 2023 Rick Lupton,
under its [MIT license](Sources/RePossessFormat/RMScene/LICENSE-rmscene).
The cloud implementation follows the MIT-licensed rmapi-js protocol work.
The app uses the MCP Swift SDK and AnyLanguageModel;
see [Package.swift](Package.swift) for dependency versions and sources.
