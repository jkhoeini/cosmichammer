# Local Markdown Issue Tracker

Wayfinder issues live in `.wayfinder/issues/` as Markdown files with YAML front matter.

## Fields

- `id`: stable issue identity.
- `title`: issue name; use this linked name in human-facing text.
- `state`: `open` or `closed`.
- `labels`: includes exactly one Wayfinder label.
- `parent`: the map issue id for child tickets; empty for the map.
- `assignee`: empty means unclaimed. Claim before work by setting this field.
- `blocked_by`: issue ids that must all be closed before the ticket enters the frontier.

## Operations

- **Map query:** find the open issue labelled `wayfinder:map`.
- **Children:** find issues whose `parent` equals the map id.
- **Frontier:** open, unassigned children whose `blocked_by` issues are all closed.
- **Claim:** set `assignee` before reading beyond the map-level view or doing ticket work.
- **Resolve:** append a dated resolution under `## Resolution comments`, set `state: closed`, clear any resolved Fog, and append a one-line linked gist to the map's `## Decisions so far`.
- **Add work:** create child issue files first, then wire `blocked_by` ids in a second pass.

The issue body contains only `## Question` while open. Detailed answers belong in resolution comments or linked assets.
