# Gallery cleanup screenshot fixtures

Rendered from `r4khul/ente` commit `3120b031ec5a668b60098ee1b92bed5b65521e1f` using Flutter 3.47.2.

These are **Flutter widget-harness captures**, not screenshots of a live account or proof of a successful cloud deletion. They use the production screen/widget code, bundled Inter/Outfit and icon fonts, enabled shadows, and the public Singapore sample image already in the repository. The harness injects deterministic screen state, enables the internal feature entry, replaces the favorites lookup, and makes deletion callbacks inert. No account, SQLite store, network, or personal photo library is used.

Each of the 14 states is captured in light and dark mode at 393 × 852 logical pixels, rendered at 2×: entry point, overview, month selection, completed year, expanded completed year, photo review, keep/delete swipe feedback, video review, deletion queue, deletion confirmation, completion with freed space, completion with everything kept, and empty library. These are new feature screens; there is no equivalent main-branch baseline for them.

The generator copies the three relevant production screen libraries into a temporary test library so their private state can be initialized without adding fixture hooks to the application. Shared widgets are imported from the checkout unchanged. `harness_tail.dart` contains the fixture data and screenshot runner. `capture.log` records the 28 successful captures.

## Reproduce

Use an Ente checkout at the commit above with its Flutter dependencies and generated localizations available. Download this evidence branch outside the application checkout, then run:

```sh
python3 /path/to/evidence/build_harness.py /path/to/ente
cd /path/to/ente/mobile/apps/photos
ENTE_REVIEW_EVIDENCE_DIR=/path/to/evidence flutter test --no-pub /path/to/evidence/fixture_test.dart
```

The screenshots are visual fixtures only. Separate branch validation included Photos analysis, formatting, 22 SQLite/deletion tests, 3 additional SQL boundary probes, and 21 layout checks. Live interrupted cloud deletion was not exercised.
