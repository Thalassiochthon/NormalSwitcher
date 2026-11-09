# Shared — cross-platform contract

Code is **not** shared between platforms (Swift on macOS, native stack on Windows).
What is shared is the *behavioural contract*:

- **`docs/`** — algorithm specifications: the layout-detection policy (two-sided
  dictionary check, veto cascade, precision-first principle), keystroke-buffer
  semantics, exception-list merge rules, punctuation splitting, Hebrew/RTL rules.
- **`testdata/`** — language-agnostic test vectors (JSON): typed input → expected
  verdict/conversion. Every platform implementation must pass the same vectors.

When changing conversion behaviour on any platform: update the spec, add vectors,
then make all platforms green.
