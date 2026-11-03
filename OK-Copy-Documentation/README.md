# Repository guide

**OK, Copy — Verified Copying Tool**  
Technical white paper and operating reference · v3.7, build 13 · October 30, 2026

OK, Copy is a native macOS utility for copying regular file contents from folders, camera cards, and local drives to one or more destinations, with independent SHA-256 readback, interruption recovery, and saved reports. This repository documents the delivered implementation; it is not a performance advertisement or a certification of hardware reliability.

## Read this repository

| Document | Audience | Contents |
| --- | --- | --- |
| [White paper](WHITE-PAPER.md) | Owners, reviewers, technical decision makers | Product overview, capabilities, integrity model, fair comparison with other tools |
| [Quick start](QUICK-START.md) | First-time users | Sample copy, first real copy, layouts, queue, reports, troubleshooting |
| [Engineering reference](ENGINEERING.md) | Developers and technical reviewers | Actual execution path, tool choices, algorithms, storage, recovery, ETA, build procedure |
| [Current limitations](LIMITATIONS.md) | All evaluators | Dedicated scope, recovery, security, performance and qualification boundaries |
| [Validation and limitations](VALIDATION.md) | Operators and evaluators | Evidence, unqualified scenarios, security boundaries and acceptance work |
| [Changelog](CHANGELOG.md) | All readers | Separate release history through v3.7 and reconstruction boundaries |
| [Sources and provenance](SOURCES.md) | Auditors and maintainers | Code map, primary references, comparison dates, artifact identity |

Open **index.html** for the formatted offline reader. The Markdown files remain the editable source. The diagrams are included as accessible SVG and editable Mermaid files in `assets/`. Mermaid files describe the logical graphs; the SVGs use separate presentation layouts. Keep both representations in sync when editing diagrams. The reader builder embeds SVG and does not run a Mermaid compiler.

An exact source snapshot is included in `source/OK-Copy/`; its original development notes include historical statements that are superseded by the version-specific documentation here.

## At a glance

| Attribute | Delivered state |
| --- | --- |
| App | OK, Copy 3.7, build 13 |
| Runtime | Apple silicon Mac, macOS 14 or later |
| Installation dependency | Self-contained app; Xcode is not needed to run it |
| UI | SwiftUI with AppKit and macOS services |
| Shipping engine | Custom Swift coordinator using Darwin file-descriptor I/O |
| Mandatory ingest check | SHA-256; destination readback and source reread |
| Destinations | One or more local folders; internal storage is allowed |
| Reports | HTML and JSON; optional legacy MHL and flat ASC MHL |
| Distribution | Locally/ad-hoc signed; not Developer ID notarized |
| Evidence | 67 XCTest tests and 113 generated-file checks recorded for v3.7 |

## How to interpret claims

**Implemented** means visible in the v3.7 source. **Recorded validation** means exercised in the development checks described here. **Engineering rationale** explains the tradeoff supported by the implementation; it is not proof that the chosen design is universally faster or safer than an alternative. **Unqualified** means a scenario has not been established by the available tests.

Full source inclusion does not establish an open-source license. No public hosting, external publication, licensing grant, or support contract is implied by this local repository.
