# Product

<!-- impeccable:product-schema 1 -->

## Platform

macOS native desktop

## Stack

SwiftPM and SwiftUI. Built with plain `swift build`; no Xcode project required.

## Users

Mac users — especially developers and other power users — who need to understand what is consuming local storage.

## Product Purpose

SpaceMap scans a chosen local folder and turns its contents into an interactive treemap so people can find large, old, or reclaimable items and decide what to inspect or move to Trash.

## Positioning

A local-first storage inspector that makes folder structure, size, file counts, age, and cleanup candidates visible together in a zoomable treemap.

## Operating Context

A native macOS 14+ desktop utility. It starts with the home folder, supports scanning another root, and keeps useful partial results when Full Disk Access is unavailable. The system language picks the UI language (English, Spanish, Portuguese, French, German, Japanese); appearance follows the system light/dark setting.

## Capabilities and Constraints

Allocated/apparent sizing, incremental cancellable scanning, category heuristics, Size/Files/Age views, keyboard navigation, Finder reveal, and confirmation before moving anything to Trash. The app never follows symlinks and never crosses volume boundaries. Storage data is read locally; there is no network service.

## Brand Commitments

The product name is SpaceMap (`com.marcoleejr.spacemap`). The visual world is original to this product: an orbital-survey theme with its own nebula category palette, orbit-mark logo, sidebar + treemap + inspector-card composition, and floating tile labels.

## Evidence on Hand

`docs/screens/*.png` are real captures from home-folder scans, not mockups. No external user research or usage data was supplied.

## Product Principles

- Make disk structure legible before asking users to act.
- Preserve useful partial results when access is restricted.
- Treat cleanup as a reversible, explicitly confirmed action.
- Keep scans local and transparent about what was inspected.
