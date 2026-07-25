# ADR 0010: Native Markdown and math transcript rendering

## Status

Proposed

## Context

Agent Sessions receive provider-authored GitHub-flavored Markdown, including
headings, lists, block quotes, links, tables, fenced code, and LaTeX math. The
current native client passes each complete message through Foundation's
`AttributedString(markdown:)`. That API covers only a limited inline subset,
does not preserve the block structure needed by coding responses, and does not
typeset LaTeX.

Transcript text and thinking also change token by token. During a stream the
last Markdown construct or math delimiter is commonly incomplete. Rendering
must therefore remain readable throughout a run instead of hiding malformed or
unfinished input until the provider closes it.

## Decision

Use Foundation's native `AttributedString(markdown:)` parser and its structured
`PresentationIntent` and `InlinePresentationIntent` output. On the supported
Apple platform versions it exposes headings, paragraphs, lists, block quotes,
fenced code, links, thematic breaks, and GFM table rows and cells without an
additional parser dependency.

Use SwiftMath 1.7.3 from `https://github.com/mgriebling/SwiftMath` as the native
LaTeX math typesetter. Use that release as the upstream source baseline under
`apps/apple/Vendor` and reference it as a path package so standalone and offline
builds do not depend on a SwiftPM Git mirror. The vendored source has one
documented packaging patch: package only the Asana math font used by Kubecode
instead of the dependency's unused alternate font families, and change its
default font accessor from Latin Modern to Asana so `MTMathUILabel`
initialization cannot request an intentionally omitted font. Retain the
upstream and font license notices.

Kubecode owns a small, immutable transcript presentation model between
Foundation's structured presentation intents and SwiftUI. It projects
paragraphs, headings, emphasis, strong
text, strikethrough, links, inline code, fenced code, quotes, ordered and
unordered lists, thematic breaks, and GFM tables. It recognizes `$...$`,
`$$...$$`, `\(...\)`, and `\[...\]` in the raw provider source before
Foundation parses Markdown. Complete math regions become opaque ASCII
placeholders and are restored into native math runs after Markdown projection.
This ordering prevents Foundation paragraph boundaries, inline-intent runs, or
Markdown punctuation inside LaTeX from splitting or consuming delimiters.
The scanner tracks inline-code backticks and backtick/tilde fenced code, so code
is never interpreted as math. A single-dollar delimiter requires
non-whitespace content and does not treat ordinary currency as math. An
incomplete streaming `\[` or `\(` remains literal, including its backslash,
until the matching delimiter arrives.

SwiftMath compatibility stays inside the immutable math projection. Its
unsupported outer `\boxed{...}` command becomes a native SwiftUI border around
the typeset inner expression, and `\operatorname{...}` is normalized to the
supported semantic equivalent `\mathrm{...}`. Every math value stores the
provider source and the compatible rendering expression separately. Only the
rendering expression is normalized; attachment metadata, transcript copying,
and history retain the provider's `\boxed` and `\operatorname` commands.

AppKit TextKit renders every projected message into one non-editable,
selectable `NSTextView`. Native attributed runs preserve text styles, links,
lists, quotes, code, and tables, while SwiftMath output is inserted as native
text attachments. Display math is centered, supported boxed math is drawn with
a native border, and copying an attachment restores its original `\(...\)` or
`\[...]` source. A single text storage lets normal pointer selection and the
system Copy command cross Markdown block boundaries; per-block SwiftUI
selection overlays are not sufficient for that platform behavior. No HTML,
JavaScript, React, or WebView is used in the transcript. Unsupported
presentation intents and incomplete Markdown or LaTeX fall back to selectable
literal text. The same component renders user messages, Agent messages, and
expanded thinking. Streaming updates replace the attributed content of the
stable provider message row rather than creating new rows.

Acceptance includes an actual AppKit mouse-down/drag/up path across wrapped
visual lines and separate Markdown paragraphs, not only programmatically
setting an `NSRange` before Copy.

The parser and math typesetter receive transcript text only. They do not receive
credentials, Project paths, filenames, file contents from the workspace, or
analytics identifiers.

## Consequences

The native client gains browser-parity structured responses and mathematical
typesetting while retaining platform selection, accessibility, appearance, and
scroll behavior. The app gains one reviewed source dependency and a
Kubecode-owned projection layer that needs regression coverage for GFM,
delimiter edge cases, streaming fragments, Dynamic Type, dark appearance, and
large responses.

Upgrading SwiftMath or the minimum Apple platform requires normal dependency
review and transcript rendering tests. Release packaging must retain
SwiftMath's bundled Asana math font and the SwiftMath and font license notices.
