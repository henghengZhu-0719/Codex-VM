# Agent VM — Desktop design system

Adapted from the *principles*, not a copy, of [Apple](https://github.com/VoltAgent/awesome-design-md/tree/main/design-md/apple) and [Linear](https://github.com/VoltAgent/awesome-design-md/tree/main/design-md/linear.app) DESIGN.md.

## Intent
An Apple-native utility with Linear's structured density. This is not a marketing landing page. Practical, accessible, deliberately quiet.

## Tokens
- Light background: #f5f5f7; cards: #ffffff; dark ink: #1d1d1f
- Dark background: #111214; cards: #1c1e21; dark ink: #f7f8fa
- Accent: #0066cc (Apple action blue), only for actionable or selected elements
- Semantic success/warn/danger: #26835c, #b77718, #c44e4e
- SF Pro / -apple-system font, sizes 12/13/14/18/28, no display marketing headlines
- Sidebar: 224px; gutters: 24px; card grid: two columns >= 800px; gap: 14px
- Cards: radius 14px, 1px hairline, no gradient, minimal shadows
- Controls: min-height 32px, focus visible; toolbar icons 32px with labels/tooltips
- Success statuses must include text, never color only

## Interaction
- No direct browser network requests; only validated Swift host bridge methods.
- Dangerous actions require confirmation in React UI and host validation.
- All asynchronous operations expose loading/errors; status is never fabricated.
- Quota data always shows stale/unknown states rather than invented remaining values.
- Do not automatically stop a running VM or interrupt an active agent session.
- Per-VM actions remain available on hover and keyboard focus.
- UI can scroll without affecting the native macOS menu bar.
