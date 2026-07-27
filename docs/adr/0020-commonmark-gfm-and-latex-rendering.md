# ADR 0020: CommonMark, GFM, and LaTeX transcript rendering

## Status

Accepted

Supersedes ADR 0010's Foundation Markdown parser and streaming rich-render
decisions. ADR 0010's native TextKit selection, SwiftMath, source-preserving
copy, and no-WebView decisions remain in force.

## Context

Foundation attributed Markdown does not expose a stable, complete block tree
for the CommonMark and GitHub-flavored structures produced by coding Agents.
The previous projection could not reliably preserve nested task lists, ordered
list starts, table alignment, images, or raw HTML. Re-parsing a growing answer
also competed with transcript scrolling and sidebar layout on the main actor.

Markdown images introduce a second boundary. An HTTPS image is untrusted
network data, while a relative image is a request for a file inside the current
registered Project. The native client must not learn or send absolute server
paths to resolve either form.

## Decision

Kubecode vendors Apple's `swift-markdown` and its matching `swift-cmark`
snapshot from the `swift-6.0.3` tag. The local package patch replaces upstream
network dependencies with the adjacent vendored `swift-cmark` package and
removes documentation-only dependencies. Release packaging retains upstream
license notices.

`KubecodeMarkdown` is a UI-independent target shared by Apple clients. It
parses provider text into an immutable, `Sendable` AST with stable source
positions and explicit blocks/inlines for:

- CommonMark headings, paragraphs, block quotes, fenced code, thematic breaks,
  nested ordered and unordered lists, emphasis, strong text, links, images,
  inline code, soft breaks, and hard breaks;
- GFM strikethrough, task-list checkboxes, and aligned tables; and
- raw HTML as selectable literal source, never executable content.

A code-aware pre-parser protects `$...$`, `$$...$$`, `\(...\)`, and `\[...\]`
before Markdown parsing. It leaves currency, incomplete delimiters, inline code,
and fenced code literal. Formula-local `\newcommand` supports at most 64
definitions, zero to two arguments, eight expansion passes, and 16 KiB of
expanded text. Built-in commands cannot be replaced. SwiftMath compatibility
normalizes only the rendering copy; selection and Copy retain provider source.
Any unsupported or malformed formula falls back to selectable delimited LaTeX.

Streaming output is bounded selectable plain text. It does not parse Markdown,
load images, or typeset math for every provider delta. When output becomes
terminal, parsing runs once off the main actor and one attributed TextKit
document is applied atomically. The coordinator preserves selection and keys
its rendered document and height cache by source, typography, tone, and Project
resource identity.

Credential-free HTTPS images use an ephemeral `URLSession`, permit at most
three HTTPS redirects, accept only `image/*`, stream at most 8 MiB, reject
decoded images over 20 megapixels, and enter a 32 MiB in-memory LRU cache.
Cookies and credential storage are disabled. Project-relative image paths are
validated by the shared resource policy and fetched through the authenticated
`GET /api/v1/projects/{project_id}/asset?path=...` API. The Runtime resolves the
Project ID and relative path only through `WorkspaceService`, rejects traversal
and escaping symlinks, and returns at most 8 MiB. Images are displayed at no
more than 640 by 480 points; unavailable images remain selectable alt text.

Footnotes, diagrams such as Mermaid, executable HTML, a browser DOM/CSS model,
and a complete TeX engine are outside this decision. Their source remains
visible rather than being executed or silently discarded.

## Consequences

Final responses have one tested parser contract across macOS, iOS, and iPadOS,
while macOS retains native selection, links, accessibility, code highlighting,
tables, and math attachments. Transcript streaming no longer performs repeated
rich parsing, which keeps provider event delivery separate from expensive
final presentation.

The repository gains two vendored upstream packages and a shared AST that must
be upgraded together. Parser, math scanner, resource policy, TextKit rendering,
binary Runtime transport, and Project path enforcement require regression
coverage. Rich extensions not listed above require a superseding ADR.
