# decimal128-text-codec-zig

Thin codec between the two IEEE 754-2019 decimal128 interchange encodings — BID
and DPD — and decimal character sequences, for Zig.

Ported from `decimal128-text-codec-c` for structure, with
`decimal128-text-codec-swift` for the boundary and `decimal128-text-codec-rust`
for the questions a language with native 128-bit integers and no garbage
collector has to answer. All descend from `decimal128-text-codec-kotlin`, the
reference implementation for the family. One file, no dependencies, no allocator.

## API

```zig
const codec = @import("decimal128_text_codec");

// bits -> text
var buf: [codec.max_len]u8 = undefined;
const s = codec.bid128ToString(&buf, bits);   // []const u8 into buf
const d = codec.dpd128ToString(&buf, bits);

// text -> bits
const bits = try codec.bid128Parse("1.23E+45");
const peer = try codec.dpd128Parse("1.23E+45");
```

An encoding is a `u128`: the sign bit is the top bit, and the rest is a
combination field and a trailing significand field laid out per IEEE 754-2019
§3.5.2. That is the entire boundary; there is no value type, no context, no
status flags.

**Nothing here allocates.** The renderers write into a buffer the caller owns and
return the slice of it that was written, so the module never sees an allocator
and the returned slice lives exactly as long as the buffer does. A caller who
needs the text to outlive the buffer copies it — `try allocator.dupe(u8, s)` —
which puts the allocation decision where the caller can see it.

The buffer parameter is `*[max_len]u8` rather than `[]u8`, so its size is part
of the
type: an undersized buffer is a compile error, not a runtime one, and rendering
keeps its cannot-fail property with no error union.

`max_len` is **42**, which is exactly the longest output, not a bound with
headroom.
Two forms tie for it: scientific `-9.999…E-6143` (1 sign + 1 digit + 1 point + 33
digits + `E` + sign + 4 exponent digits) and plain `-0.000000999…` (1 sign + 1 + 6
zeros + 1 point + 34 digits). The six leading zeros are pinned by the GDAS rule
that selects the plain form only when the adjusted exponent is at least −6, and
the exponent field cannot exceed four digits inside decimal128's range. Every
write is guarded by a `demand` against that constant, and those stay live in
release builds — sizing it exactly is what turns the guard into a real check.

Parse reports failure as a Zig error set. The sibling ports write the canonical
positive quiet NaN into an out-parameter when a parse fails, so a caller who
ignores the failure still holds a legal IEEE 754-2019 datum; an error union
enforces that statically instead, since the value cannot be read without handling
the error. `qnan` is exported for anyone who wants the sibling behaviour
explicitly: `codec.bid128Parse(text) catch codec.qnan`.

## Scope

Rounding, where required, is `roundTiesToEven` and is not configurable. Output is
the GDAS `to-scientific-string` form and is not configurable — the exponent sign
is always written (`6.02E+23`), and cohort information is preserved. No
arithmetic, no field extraction, no value type.

Accepted input matches what the full `decimal128-{lang}` ports accept. That
includes the parenthesised NaN payload: **`NaN(123)` as well as `NaN123`**,
matching the spelling C's `strtod` reads. The form is positional and balanced —
`(` immediately after the word, at least one digit, `)` last — so `NaN()`,
`NaN(1`, `NaN(1)2(3)`, `NaN[1]` and `NaN{1}` are all rejected. Rendering never
emits parentheses. The codecs had this before the ports did; the ports took it on
2026-08-23, closing the family's one grammar divergence.

For the full decimal128 implementation see `decimal128-zig` at
<https://decimal128.com>.

## Requirements

Zig 0.16. Where this port differs from its siblings, in each case because Zig
already had the answer:

- `u128` is the public boundary, as in Swift, C# and Rust. The internals still
  work in `dw1`/`dw0` `u64` pairs exactly as the reference does — split once on
  entry, joined once on exit.
- The renderers take the caller's buffer, as the C port's do. Zig has no owned
  string type and no ambient allocator, so this is the only spelling that keeps
  rendering allocation-free and infallible.
- Parse returns an error union; the finalize and parse chains return tuples
  rather than writing through out-parameters, as Swift's, Go's and Rust's do.
- The widening multiply is `u128` arithmetic. The reference decomposes it into
  four 32×32 partial products because the JVM has no unsigned 64-bit
  multiply-high; the C port carries a three-way `__int128` / `__umulh` /
  synthesize-from-limbs split, and a second build to exercise the fallback.
  Neither has an analogue here.
- Zig's `+` and `*` are checked in Debug and ReleaseSafe, so every site the
  reference relies on wrapping is spelled `+%` / `*%` — the same sites the Swift
  port spells `&+` / `&*` and Rust spells `wrapping_add` / `wrapping_mul`, each
  carrying a note saying why the wrap is the intended arithmetic. Every other
  site is left checked on purpose, so a translation error surfaces as a panic
  rather than a wrong answer. The suite runs in ReleaseSafe as well as Debug, so
  those checks are live over the whole corpus.

Internal-consistency claims — the ones unreachable for any input — are spelled
`verify` and gated on `-Dverify`, the same switch the full `decimal128-zig` port
carries, with that port's condition-first argument order. The default is off, so
a consumer never takes a panic inside a library on data they do not control.
`demand` — the buffer-sizing guards and the precision invariant that stands in
for the removed precision-truncation step — is live in every build.

## Tests

```
git submodule update --init --recursive
zig build test
zig build test -Dverify                     # the same corpus with every assertion armed
zig build test -Doptimize=ReleaseSafe       # and with the optimizer's arithmetic checks
```

| file | what it covers |
|---|---|
| `tests/corpus_vectors.zig` | the four conformance tables over the shared corpus, 2,601 rows, both directions, both formats; then the full 84,783-row canonical table. Also holds the corpus reader and the hex helpers, its only consumer. |

Seven tests, named after the Java, C#, Go and Rust ports' seven. That is the
whole suite, and the shape is deliberate: **every test vector in this repo comes
from the shared corpus.** There is no hand-written table. The suite is its own
module with the codec as an import, so it reaches only the public surface.

One assertion the siblings make is absent, and it is a consequence of the error
union: they check that a failed parse left the canonical quiet NaN in its
out-parameter. There is no out-parameter here and no stale value a caller could
read. The bits column of the `error` table is still asserted, against the
exported `qnan` constant, which validates that constant on 173 engine-authored
rows.

The repo is standalone: it depends on no decimal128 port, at runtime or in tests.
The independent oracle is the shared `text_bid_dpd` corpus, generated by the
decimal128-c engine, which reaches its answers by different algorithms than this
codec does.

The vectors are read from `resources/text_bid_dpd`, where `resources` is the
`decimal128-resources` submodule — the same mount every decimal128 port uses.
Nothing is copied into this repo. `build.zig` runs the test binary with its
working directory set to the project root, so the relative path resolves; this is
the one port with no `DECIMAL128_RESOURCES` override, because there is no runner
here that relocates the binary away from the tree it was built in.

## License

MIT.
