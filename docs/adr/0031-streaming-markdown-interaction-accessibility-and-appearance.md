# ADR 0031: Streaming Markdown interaction, accessibility, and appearance hardening

## Status

Accepted

## Context

The unified Markdown and serialized geometry pipeline preserves one selectable
native view, but late attachment work could still settle after a newer semantic
render request was submitted. Project image changes had no production path into
the row render store. Resolved image and math attachments exposed AppKit's
object-replacement character to accessibility clients, Copy Response existed
only in a context menu, and link schemes were checked only during Markdown
projection. Geometry also discarded its publication lower bound when only the
outer row width changed.

## Decision

Every row owns a monotonic attachment-request epoch and an exact semantic
request signature containing source, typography, tone, appearance revision,
Project resource identity, and resource generation. Submission of a distinct
signature advances the epoch and cancels attachment work synchronously, before
the replacement parse or render can publish. Attachment resolution captures the
epoch and all existing commit/resource guards. Only one nonempty, decodable,
current batch may publish a newer attachment and render generation. An
identical phase-only submission changes neither the epoch nor the active task.

Selected-Project `file_changed` events publish a deduplicated invalidation token
containing only the event ID, Project ID, and a validated relative path. The
window Session boundary forwards that token to its render store. The store
advances the Project generation and the same attachment epoch only for rows
whose current Markdown references the changed local image. A pathless event may
refresh all local-image rows for that Project; unsafe or absolute paths are
ignored. Remote HTTPS images and unrelated local image rows are not refreshed.

Rendered attachments carry semantic accessibility replacement text in the
immutable attributed commit: resolved images use their alt label, placeholders
omit the decorative symbol while retaining visible alt text, and math uses its
source delimiters and provider text. The native text view derives its
accessibility value from the exact applied commit without mutating
`NSTextStorage`. Selection copy uses the same replacement metadata. Copy
Response remains exact raw Markdown and is available through both the context
menu and an accessibility custom action.

Links are limited to `http`, `https`, and `mailto` during projection and are
validated again by the native activation boundary. Unsafe values perform no
action. The existing native view, text storage, selection, and first responder
survive suffix growth, identical update-to-final handoff, attachment settlement,
and typography or color-scheme refresh.

Render-height acceptance retains the last publication tuple for the same item,
content revision, and Session across an outer-width-only transition. The same
tuple may publish once for the new outer width, a newer tuple may advance it,
and an older tuple is rejected. Exact current outer-width and Session provenance
remain mandatory, and the inner Markdown measurement width remains part of the
render-height identity.

## Consequences

Late image work cannot overwrite newer source or appearance state, Project image
edits refresh only affected transcript rows, and assistive technology receives
meaningful content and an exact response-copy action throughout streaming.
Width changes no longer reopen the geometry publication ordering window.

This decision adds no image transport or cache, no provider behavior, no new
Markdown syntax, no attachment-driven layout authority, and no mutable-storage
measurement path. ADR 0029 remains the immutable render/height authority and
ADR 0030 remains the sole collection transaction and viewport authority.
