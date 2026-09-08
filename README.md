# decimal128-text-codec-zig

A thin codec between the two IEEE 754-2019 decimal128 interchange encodings —
BID and DPD — and decimal character sequences. Nothing else: no arithmetic, no
comparison, no value type, no context, no status flags.

One file, no dependencies, no allocator. The point is that a caller who holds
interchange bits or a string, and wants the other one, can depend on this
without pulling in a full IEEE 754-2019 engine.

For the complete decimal128 implementation see `decimal128-zig` at
<https://decimal128.com>.

## API

```zig
const codec = @import("decimal128_text_codec");

// bits -> text
var buf: [codec.max_len]u8 = undefined;
const s = codec.bid128ToAscii(&buf, bits);   // []const u8 into buf
const d = codec.dpd128ToAscii(&buf, bits);

// text -> bits
var bits: u128 = undefined;
if (codec.bid128Parse(&bits, "1.23E+45")) |msg| { ... }  // null on success
var peer: u128 = undefined;
_ = codec.dpd128Parse(&peer, "1.23E+45");
```

An encoding is a `u128`: the sign bit is the top bit, and the rest is a
combination field and a trailing significand field laid out per IEEE 754-2019
§3.5.2. That is the entire boundary; there is no value type, no context, no
status flags.

Parse reports failure the way every sibling port does: it returns `null` on
success and a human-readable message on failure, and it always writes the
out-parameter — the encoding on success, the canonical positive quiet NaN on
failure. A caller who discards the message still holds a legal IEEE 754-2019
datum rather than a stale one. `qnan` is exported so that a caller can name
that pattern. The wording of the messages is not part of the contract; what is
contractual is that the two formats reject the same input with the same
message.

An error union would enforce the same guarantee statically, since the value
could not be read without handling the error. This port had that shape and gave
it up deliberately, so that the eight ports present one surface: a Zig error
value carries an identifier and not a message, and matching the siblings means
carrying the message.

**Nothing here allocates.** The renderers write into a buffer the caller owns
and return the slice of it that was written, so the module never sees an
allocator and the returned slice lives exactly as long as the buffer does. A
caller who needs the text to outlive the buffer copies it — `try
allocator.dupe(u8, s)` — which puts the allocation decision where the caller
can see it. The buffer parameter is `*[max_len]u8` rather than `[]u8`, so its
size is part of the type: an undersized buffer is a compile error, not a
runtime one, and rendering keeps its cannot-fail property with no error union.
`max_len` is 42, the exact bound on a rendered decimal128 — not a bound with
headroom.

## Behavior

**Rendering cannot fail.** Every 128-bit pattern maps to a valid decimal
character sequence. A non-canonical BID coefficient (≥ 10³⁴) renders as zero at
the encoded exponent, per IEEE 754-2019 §3.5.2, and a NaN payload ≥ 10³³
renders as no payload. Those patterns never arise from this codec's own encode
direction — they arise from network and file data, which is why the codec
handles them.

**Output is the GDAS `to-scientific-string` form, and only that.** Integer form
when the quantum exponent is zero, plain form when the quantum exponent is
negative and the adjusted exponent is at least `-6`, scientific otherwise. The
exponent sign is always written:
`6.02E+23`, never `6.02E23`. Cohort information is preserved — `1.00` and `1.0`
are distinct outputs from distinct encodings of the same numerical value, and
nothing is ever normalized or stripped.

**Accepted input** matches what the full `decimal128-{lang}` ports accept, with
one deliberate exception below, so a caller can move between this codec and the
full library without the grammar shifting under them: plain and scientific
notation with `E` or `e`, a leading `+` or `-`, `_` digit separators *between
two digits*, and the case-insensitive words `Infinity`, `Inf`, `NaN`, `qNaN`,
`sNaN` with an optional sign and an optional payload of decimal digits.

**The exception: a NaN payload may be parenthesised** — `NaN(123)` as well as
`NaN123`. C's own `strtod` reads `NAN(n-char-sequence)`, so the spelling
reaches a caller from the platform itself. The form is positional and balanced:
`(` immediately after the word, at least one digit, `)` last. So `NaN()`,
`NaN(1`, `NaN(1]`, `NaN(1)2(3)`, `NaN (1)`, `NaN[1]` and `NaN{1}` are all
rejected. The resemblance to `strtod` stops at the parentheses — its sequence
is letters, digits and underscores read as an implementation-defined integer,
so `NAN(abc)` and `NAN(0x1c8)` are legal there and rejected here. Rendering
never emits parentheses; `NaN(123)` parses and renders back as `NaN123`.

The full ports accept the same spelling — `decimal128-zig` took it on
2026-08-23, closing what had been the codecs' one grammar divergence from them.

**Rounding is ties-to-even, hardcoded**, and reachable only from the text →
bits direction: more than 34 significant digits, overflow to Infinity, or
underflow to a subnormal or zero. There is no rounding parameter and no format
selector — the premise is a four-function surface with no configuration. IEEE
754-2019 §5.4.2 places `convertFromDecimalCharacter` under the applicable
rounding-direction attribute; this codec deliberately implements only the
ties-to-even case, and is therefore a conforming **subset** of that operation.
Callers needing another rounding direction want the full library.

## Building

```
zig build
zig build test
zig build test -Dverify                     # the same corpus with every assertion armed
zig build test -Doptimize=ReleaseSafe       # and with the optimizer's arithmetic checks
```

Zig 0.16, no dependencies.

Internal-consistency claims — the ones unreachable for any input — are spelled
`verify` and gated on `-Dverify`, the same switch the full `decimal128-zig`
port carries, with that port's condition-first argument order. The default is
off, so a consumer never takes a panic inside a library on data they do not
control. `demand` — the buffer-sizing guards and the precision invariant that
stands in for the removed precision-truncation step — is live in every build.

## Tests

Seven tests in one file.

| file | what it covers |
|---|---|
| `tests/corpus_vectors.zig` | the four conformance tables over the shared corpus, 2,601 rows, both directions, both formats; then the full 84,783-row canonical table. Also holds the corpus reader and the hex helpers, its only consumer. |

That is the whole suite, and the shape is deliberate: **every test vector in
this repo comes from the shared corpus.** Nothing in the suite reaches past the
public surface.

The suite now makes the same assertions the siblings do, including the one this
port used to lack: that a failed parse left the canonical quiet NaN in its
out-parameter. Both formats are checked against the bits column of the `error`
table on all 173 engine-authored rows, and the exported `qnan` constant is
checked against that same column, so a caller naming the constant and a caller
reading a failed parse are known to see one pattern.

The repo is standalone: it depends on no decimal128 port, at runtime or in
tests. The independent oracle is the shared `text_bid_dpd` corpus, generated by
the `decimal128-c` engine through its public API; that engine reaches its
answers by different algorithms, so agreement is a cross-check rather than a
tautology.

The vectors are read from `resources/text_bid_dpd`, where `resources` is the
`decimal128-resources` submodule — the same mount every decimal128 port uses.
Nothing is copied into this repo. `build.zig` runs the test binary with its
working directory set to the project root, so the relative path resolves; this
is the one port with no `DECIMAL128_RESOURCES` override, because there is no
runner here that relocates the binary away from the tree it was built in.

Two things worth knowing if you touch the tests:

- **The corpus quotes two of its five files.** `parse` and `error` double-quote
  the text column with `\\` and `\"` escapes; the other three leave it bare. A
  naive comma split silently corrupts four rows and still passes, because a
  malformed input fails to parse either way. The reader honours the quoting,
  the row counts are asserted, and `quoted column round trips` checks those
  four rows by hand.
- **The submodule must be checked out.** With `resources/text_bid_dpd` empty
  the loader fails with a message naming the `git submodule update --init
  --recursive` that fixes it, rather than a suite that quietly tests nothing.
  Clone with `--recurse-submodules`.

## Provenance

Ported from `decimal128-text-codec-c` for structure, with
`decimal128-text-codec-swift` for the boundary and `decimal128-text-codec-rust`
for the questions a language with native 128-bit integers and no garbage
collector has to answer. All descend from `decimal128-text-codec-kotlin`, the
reference implementation for the family. The design spec is `TextCodecLayer.md`
in the `decimal128-workorder` repository.

Where this port differs from its siblings, in each case because Zig already had
the answer:

- **`u128` is the public boundary**, as in Swift, C# and Rust. The internals
  still work in `dw1`/`dw0` `u64` pairs exactly as the reference does — split
  once on entry, joined once on exit.
- **The renderers take the caller's buffer**, as the C port's do. Zig has no
  owned string type and no ambient allocator, so this is the only spelling that
  keeps rendering allocation-free and infallible.
- **Parse returns `?[]const u8` and writes through an out-parameter**, as the
  siblings do; the finalize chain still returns tuples internally, as Swift's,
  Go's and Rust's do.
- **The widening multiply is `u128` arithmetic.** The reference decomposes it
  into four 32×32 partial products because the JVM has no unsigned 64-bit
  multiply-high; the C port carries a three-way `__int128` / `__umulh` /
  synthesize-from-limbs split, and a second build to exercise the fallback.
  Neither has an analogue here.
- **Zig's `+` and `*` are checked in Debug and ReleaseSafe**, so every site the
  reference relies on wrapping is spelled `+%` / `*%` — the same sites the
  Swift port spells `&+` / `&*` and Rust spells `wrapping_add` /
  `wrapping_mul`, each carrying a note saying why the wrap is the intended
  arithmetic. Every other site is left checked on purpose, so a translation
  error surfaces as a panic rather than a wrong answer. The suite runs in
  ReleaseSafe as well as Debug, so those checks are live over the whole corpus.

The finalizer's precision-truncation step is removed, in this port and in the
reference alike. It descends from a finalizer built for an arithmetic engine,
whose multiply and FMA hand it a double-width product; a codec's only caller is
a parser that accumulates at most 19 + 15 = 34 significant digits and turns
everything past them into a residue. Measured on the C port: zero executions
across the shared corpus, 400,000 random numerals, and 76,280 finalize calls
from inputs of up to 5,000 digits. A dead path is an unverified path, so it is
replaced by an unconditional `demand`. It stays live in every full port's
`Finalize`, where multiply and FMA do reach it; a caller here that is not a
parser needs it back.

The codec stands on the interchange formats alone. It holds no intermediate
value type: parsing yields loose scalars — sign, quantum exponent, coefficient,
residue — which are finalized and written *toward* an encoding. It does not
pivot through any engine's in-memory representation, and must not be changed
to.

## License

MIT.
