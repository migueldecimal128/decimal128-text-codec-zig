// SPDX-License-Identifier: MIT
//! Thin codec between the two IEEE 754-2019 decimal128 interchange encodings —
//! BID (Binary Integer Decimal) and DPD (Densely Packed Decimal) — and decimal
//! character sequences.
//!
//! A decimal128 encoding is a `u128`: the sign bit is the top bit, and the rest
//! is a combination field and a trailing significand field laid out per
//! IEEE 754-2019 §3.5.2. That is the entire boundary; there is no value type, no
//! context, no status flags.
//!
//! This module provides no arithmetic, no comparison and no field extraction.
//! For the full IEEE 754-2019 decimal128 implementation see `decimal128-zig` at
//! https://decimal128.com.
//!
//! Rounding, where the text → bits direction requires it, is the IEEE 754-2019
//! `roundTiesToEven` attribute and is not configurable. Output form is the GDAS
//! `to-scientific-string` form and is not configurable.
//!
//! All four functions are pure and safe for concurrent use. Nothing here
//! allocates: the renderers write into a buffer the caller owns, so the module
//! never sees an allocator.

// decimal128-text-codec-zig
//
// Ported from decimal128-text-codec-c (decimal128_text_codec.c @ 3d78a7f) for
// structure, with decimal128-text-codec-swift for the boundary and
// decimal128-text-codec-rust for the questions a language with native 128-bit
// integers and no garbage collector has to answer. All descend from
// decimal128-text-codec-kotlin, which is the reference implementation for the
// family. The shape follows them closely enough to be read side by side; where
// Zig differs, the difference is noted at the point it occurs. The five
// deliberate ones:
//
//  - The public boundary is `u128`, as in Swift, C# and Rust, not the
//    reference's pair of words. The internals still work in `dw1`/`dw0` `u64`
//    pairs exactly as the reference does: the split happens once on entry, the
//    join once on exit. That is what keeps the eight files readable against
//    each other.
//
//  - The renderers write into the CALLER's buffer and return a slice of it, as
//    the C port does. Zig has no owned string type and no ambient allocator, so
//    this is the only spelling that keeps rendering allocation-free and
//    infallible. The buffer parameter is `*[max_len]u8` rather than `[]u8`: the
//    length is part of the type, so an undersized buffer is a compile error
//    rather than a runtime error, and the function needs no error union.
//
//  - Parse reports failure as a Zig error set. The family's contract is that
//    the encoding is ALWAYS written -- the canonical positive quiet NaN on
//    failure -- so a caller who ignores the error still holds a legal
//    IEEE 754-2019 datum. An error union enforces that statically instead: the
//    value cannot be read without handling the error. `qnan` is exported for a
//    caller who wants the sibling behaviour explicitly.
//
//  - The widening multiply is `u128` arithmetic. The reference decomposes it
//    into four 32x32 partial products because the JVM has no unsigned 64-bit
//    multiply-high; the C port carries a three-way __int128 / __umulh /
//    synthesize-from-limbs split plus a second build to exercise the fallback.
//    Neither has an analogue here.
//
//  - Zig's `+` and `*` are checked -- a panic in Debug and ReleaseSafe -- so
//    every site the reference relies on wrapping is spelled `+%` / `*%`, the
//    same sites the Swift port spells `&+` / `&*` and Rust spells
//    `wrapping_add` / `wrapping_mul`. Each carries a note saying why the wrap
//    is the intended arithmetic. Every other site is left checked on purpose,
//    so a translation error surfaces as a panic rather than a wrong answer.
//
// Everything reachable from outside is the four functions, `max_len`, `qnan`
// and
// `ParseError`; the rest is file-private.

const std = @import("std");
const build_options = @import("build_options");

// ---------------------------------------------------------------------------
// Internal-state assertions
//
// Two mechanisms, matching the sibling ports and spelled the way the full
// decimal128-zig port spells them -- condition first, message second, which is
// that port's deliberate divergence from the Swift reference's message-first
// closure form (Zig has no trailing closure).
//
//   verify(cond, msg)  internal-consistency claims -- unreachable for ANY
//                      input, so a failure is a codec bug rather than bad data.
//                      Evaluated only under `-Dverify`, and the default is OFF.
//                      CI runs the whole corpus with it on.
//
//   demand(cond, msg)  claims that must survive into a shipping build: the
//                      buffer-sizing guards, which are what make `max_len` a
//                      checked bound rather than a comment, and the
//                      coefficient-width invariant standing in for the removed
//                      precision-truncation step.
// ---------------------------------------------------------------------------

/// Unconditional abort marking unreachable code.
fn impossible(msg: []const u8) noreturn {
    @panic(msg);
}

inline fn demand(cond: bool, msg: []const u8) void {
    if (!cond) impossible(msg);
}

inline fn verify(cond: bool, msg: []const u8) void {
    if (build_options.verify) {
        if (!cond) impossible(msg);
    }
}

// --------------------------------------------------------------------------
// Format constants -- IEEE 754-2019 Table 3.6, decimal128
// --------------------------------------------------------------------------

const BIAS: i32 = 6176;
/// The minimum quantum exponent.
const Q_MIN: i32 = -6176;
/// The maximum quantum exponent.
const Q_MAX: i32 = 6111;
/// Trailing significand field width in bits.
const T_WIDTH: u32 = 110;
/// Combination field width in bits.
const W5: u32 = 17;

/// 10^34, one past the largest coefficient; maxx = max eXclusive.
const MAXX_COEFF_34_HI: u64 = 0x0001_ED09_BEAD_87C0;
const MAXX_COEFF_34_LO: u64 = 0x378D_8E64_0000_0000;

/// 10^33, the smallest 34-digit coefficient.
const MIN_PRECISION_34_COEFF_HI: u64 = 0x0000_314D_C644_8D93;
const MIN_PRECISION_34_COEFF_LO: u64 = 0x38C1_5B0A_0000_0000;

/// 33 nines -- the largest canonical NaN payload.
const MAX_PAYLOAD_HI: u64 = MIN_PRECISION_34_COEFF_HI;
const MAX_PAYLOAD_LO: u64 = MIN_PRECISION_34_COEFF_LO - 1;

const SIGN_BIT: u64 = 0x8000_0000_0000_0000;
const INF_PATTERN_HI: u64 = 0x7800_0000_0000_0000;
const QNAN_PATTERN_HI: u64 = 0x7C00_0000_0000_0000;
const SNAN_PATTERN_HI: u64 = 0x7E00_0000_0000_0000;

const TEN_POW_15: u64 = 1_000_000_000_000_000;
const TEN_POW_18: u64 = 1_000_000_000_000_000_000;

/// Size of the render buffer, and the EXACT longest output -- not a bound with
/// headroom. Two forms tie for longest, both at 42 bytes:
///
///   scientific  `-9.999…E-6143`      1 sign + 1 digit + 1 point + 33 digits
///                                    + 1 `E` + 1 sign + 4 exponent digits
///   plain       `-0.000000999…`      1 sign + 1 + 6 zeros + 1 point + 34 digits
///
/// The plain form's six leading zeros are pinned by the GDAS rule that selects
/// it only when the adjusted exponent is at least -6, and the exponent field
/// cannot exceed four digits inside decimal128's range, so neither number can
/// drift without the format itself changing.
///
/// Every write in the renderers is guarded by a `demand` against this constant,
/// and those stay live in release builds. Sizing it exactly rather than
/// generously is what turns that guard into a real check: with slack, an error
/// in the arithmetic above would quietly consume the slack instead of firing.
pub const max_len: usize = 42;

// --------------------------------------------------------------------------
// The 128-bit boundary
//
// Public in, public out. Everything between these and the encoders works in the
// reference's `dw1` / `dw0` word pair.
// --------------------------------------------------------------------------

inline fn hiWord(bits: u128) u64 {
    return @truncate(bits >> 64);
}

inline fn loWord(bits: u128) u64 {
    return @truncate(bits);
}

inline fn joinWords(hi: u64, lo: u64) u128 {
    return (@as(u128, hi) << 64) | @as(u128, lo);
}

// --------------------------------------------------------------------------
// Low-level unsigned arithmetic
// --------------------------------------------------------------------------

/// High 64 bits of the 128-bit product x * y.
inline fn mulhi64(x: u64, y: u64) u64 {
    return @truncate((@as(u128, x) * @as(u128, y)) >> 64);
}

/// Leading zero count, 64 for zero -- matching Kotlin's countLeadingZeroBits.
inline fn clz64(v: u64) u32 {
    return @clz(v);
}

// Powers of 10 from 10^0 through 10^34 as 128-bit values in little-endian
// order: POW10[2*i] is the low 64 bits of 10^i, POW10[2*i + 1] the high 64.
//
// Sized to the coefficient bound and indexed directly -- no mask, no padding.
// Every reachable index is <= 34: the binding case is calcDigitLen128, whose
// input is always a coefficient or NaN payload below 10^34, so bitLen <= 113 and
// (bitLen * 1233) >> 12 <= 34. It doubles as the 5^n source for the divide
// kernel, since 10^n >> n is exactly 5^n; there is no POW5 table.
const POW10 = [_]u64{
    1, 0, // 10^0
    0x0000_0000_0000_000A, 0, // 10^1
    0x0000_0000_0000_0064, 0, // 10^2
    0x0000_0000_0000_03E8, 0, // 10^3
    0x0000_0000_0000_2710, 0, // 10^4
    0x0000_0000_0001_86A0, 0, // 10^5
    0x0000_0000_000F_4240, 0, // 10^6
    0x0000_0000_0098_9680, 0, // 10^7
    0x0000_0000_05F5_E100, 0, // 10^8
    0x0000_0000_3B9A_CA00, 0, // 10^9
    0x0000_0002_540B_E400, 0, // 10^10
    0x0000_0017_4876_E800, 0, // 10^11
    0x0000_00E8_D4A5_1000, 0, // 10^12
    0x0000_0918_4E72_A000, 0, // 10^13
    0x0000_5AF3_107A_4000, 0, // 10^14
    0x0003_8D7E_A4C6_8000, 0, // 10^15
    0x0023_86F2_6FC1_0000, 0, // 10^16
    0x0163_4578_5D8A_0000, 0, // 10^17
    0x0DE0_B6B3_A764_0000, 0, // 10^18
    0x8AC7_2304_89E8_0000, 0, // 10^19
    0x6BC7_5E2D_6310_0000, 0x0000_0000_0000_0005, // 10^20
    0x35C9_ADC5_DEA0_0000, 0x0000_0000_0000_0036, // 10^21
    0x19E0_C9BA_B240_0000, 0x0000_0000_0000_021E, // 10^22
    0x02C7_E14A_F680_0000, 0x0000_0000_0000_152D, // 10^23
    0x1BCE_CCED_A100_0000, 0x0000_0000_0000_D3C2, // 10^24
    0x1614_0148_4A00_0000, 0x0000_0000_0008_4595, // 10^25
    0xDCC8_0CD2_E400_0000, 0x0000_0000_0052_B7D2, // 10^26
    0x9FD0_803C_E800_0000, 0x0000_0000_033B_2E3C, // 10^27
    0x3E25_0261_1000_0000, 0x0000_0000_204F_CE5E, // 10^28
    0x6D72_17CA_A000_0000, 0x0000_0001_431E_0FAE, // 10^29
    0x4674_EDEA_4000_0000, 0x0000_000C_9F2C_9CD0, // 10^30
    0xC091_4B26_8000_0000, 0x0000_007E_37BE_2022, // 10^31
    0x85AC_EF81_0000_0000, 0x0000_04EE_2D6D_415B, // 10^32
    0x38C1_5B0A_0000_0000, 0x0000_314D_C644_8D93, // 10^33
    0x378D_8E64_0000_0000, 0x0001_ED09_BEAD_87C0, // 10^34
};

/// Bit length of a 128-bit value: highest set bit plus one, 0 for zero.
fn calcBitLen128(dw1: u64, dw0: u64) u32 {
    if (dw1 != 0) return 128 - clz64(dw1);
    if (dw0 != 0) return 64 - clz64(dw0);
    return 0;
}

/// Decimal digit count of a 128-bit value.
///
/// (bitLen * 1233) >> 12 is floor(bitLen * log10(2)), which is either the exact
/// digit count or one too small; a single unsigned compare against the
/// next-larger power of ten resolves the off-by-one.
fn calcDigitLen128(dw1: u64, dw0: u64) usize {
    const bit_len: usize = calcBitLen128(dw1, dw0);
    const lo_digit_count = (bit_len * 1233) >> 12;
    const hi_digit_count = lo_digit_count + 1;
    const pow10_offset = lo_digit_count << 1;
    const p1 = POW10[pow10_offset + 1];
    const p0 = POW10[pow10_offset];
    if (dw1 != p1) return if (dw1 < p1) hi_digit_count - 1 else hi_digit_count;
    return if (dw0 < p0) hi_digit_count - 1 else hi_digit_count;
}

/// Multiply a 64-bit value by 10^pow10 and add a; returns { hi, lo }.
fn u128FmaPow10(x: u64, pow10: usize, a: u64) struct { u64, u64 } {
    const y = POW10[pow10 << 1];
    // The reference relies on this product wrapping past 64 bits and recovers
    // the high half separately; taking it in u128 says the same thing directly.
    const prod = @as(u128, x) * @as(u128, y);
    const prod_hi: u64 = @truncate(prod >> 64);
    const prod_lo: u64 = @truncate(prod);
    const sum_lo = prod_lo +% a;
    const carry: u64 = @intFromBool(sum_lo < prod_lo);
    return .{ prod_hi + carry, sum_lo };
}

// --------------------------------------------------------------------------
// The divide kernel
// --------------------------------------------------------------------------

/// Divide a 113-bit value by 10^pow10 for pow10 in 1..9; returns
/// { quotient hi, quotient lo, remainder }.
///
/// Table-free: 10^pow10 factors as 2^pow10 * 5^pow10, so the low pow10 bits fall
/// straight out as the low part of the remainder and the shifted value is
/// divided by 5^pow10 with two hardware 64-bit divides.
fn u113DivModPow10Max9(dw_hi: u64, dw_lo: u64, pow10: usize) struct { u64, u64, u64 } {
    verify(pow10 >= 1 and pow10 <= 9, "pow10 is in the kernel's 1..9 range");
    verify(clz64(dw_hi) >= 15, "the dividend is at most 113 bits");

    const sh: u6 = @intCast(pow10);
    const mask = (@as(u64, 1) << sh) - 1;
    const b = dw_lo & mask;
    const s_hi = dw_hi >> sh;
    const s_lo = (dw_lo >> sh) | (dw_hi << @intCast(64 - pow10));

    const k: usize = 50 - pow10;
    const ks: u6 = @intCast(k);
    const mask_k = (@as(u64, 1) << ks) - 1;
    const top: u6 = @intCast(14 + pow10);
    const hi63 = (s_hi << top) | (s_lo >> ks);
    const lo_k = s_lo & mask_k;

    // two slots per power in POW10, hence the doubled index
    const d = POW10[pow10 << 1] >> sh; // = 5^pow10
    const q1 = hi63 / d;
    const r1 = hi63 % d;
    const mid = (r1 << ks) | lo_k;
    const q0 = mid / d;
    const r0 = mid % d;

    return .{ q1 >> top, (q1 << ks) + q0, (r0 << sh) | b };
}

// --------------------------------------------------------------------------
// Residue -- how much was discarded, relative to half a ulp
// --------------------------------------------------------------------------

const EXACT: i32 = 0;
const LT_HALF: i32 = 1;
/// The reference's HALF; `HALF` alone reads as a quantity.
const TIE_HALF: i32 = 2;
const GT_HALF: i32 = 3;

/// Two bits per digit 0..9: 0 -> EXACT, 1..4 -> LT_HALF, 5 -> TIE_HALF, 6..9 -> GT_HALF
const DIGIT_MAP: u64 = 0xFF954;

fn residueFromDecimalDigit(digit: u8) i32 {
    const sh: u6 = @intCast(@as(u32, digit) << 1);
    return @intCast((DIGIT_MAP >> sh) & 0x03);
}

/// Combine a primary residue with a sticky one from less-significant digits,
/// round-bit-and-sticky-bit style: the sticky residue collapses to a single
/// nonzero bit which is OR'd into the low bit of the round residue.
fn residueMerge(round_residue: i32, sticky_residue: i32) i32 {
    const s = (sticky_residue & 1) | (sticky_residue >> 1);
    return (round_residue | s) & 0x03;
}

/// Classify a 128-bit value relative to half of 10^pow10.
fn residueFromValuePow10(dw1: u64, dw0: u64, pow10: usize) i32 {
    if ((dw1 | dw0) == 0) return EXACT;
    const pow10_index = pow10 << 1;
    const pow10_hi = POW10[pow10_index + 1];
    const pow10_lo = POW10[pow10_index];

    const half_hi = pow10_hi >> 1;
    const half_lo = (pow10_hi << 63) | (pow10_lo >> 1);
    if (dw1 != half_hi) return if (dw1 < half_hi) LT_HALF else GT_HALF;
    if (dw0 != half_lo) return if (dw0 < half_lo) LT_HALF else GT_HALF;
    return TIE_HALF;
}

/// Divide a 128-bit coefficient by 10^truncationNeeded, in chunks of at most
/// nine digits; returns { hi, lo, accumulated residue class }.
fn u128ScaleDownPow10(dw1: u64, dw0: u64, truncation_needed: usize) struct { u64, u64, i32 } {
    verify((dw1 | dw0) != 0, "the coefficient being scaled down is nonzero");
    verify(
        truncation_needed > 0 and truncation_needed < calcDigitLen128(dw1, dw0),
        "the truncation keeps at least one digit",
    );
    var scale_residue = EXACT;
    var dw1_t = dw1;
    var dw0_t = dw0;
    var digits_remaining = truncation_needed;
    while (true) {
        const step_pow10 = if (digits_remaining < 9) digits_remaining else 9;
        const rem: u64 = blk: {
            const q_hi, const q_lo, const r = u113DivModPow10Max9(dw1_t, dw0_t, step_pow10);
            dw1_t = q_hi;
            dw0_t = q_lo;
            break :blk r;
        };
        const step_residue = residueFromValuePow10(0, rem, step_pow10);
        scale_residue = residueMerge(step_residue, scale_residue);
        digits_remaining -= step_pow10;
        if (digits_remaining == 0) break;
    }
    return .{ dw1_t, dw0_t, scale_residue };
}

// --------------------------------------------------------------------------
// DPD declet conversion
//
// A declet is 10 bits holding three decimal digits, 0..999. This is the one
// place BID and DPD genuinely differ: BID stores the 34-digit coefficient as a
// binary integer, DPD as a leading digit plus eleven declets.
//
// Both directions are pure boolean arithmetic (Cowlishaw's dpd2bcd and bcd2dpd)
// rather than lookup tables, matching the reference.
// --------------------------------------------------------------------------

/// Decode a 10-bit declet (bits p q r s t u v w x y) into 0..999. Accepts the
/// 24 non-canonical declets as well as the 1000 canonical ones.
///
/// The reference's `~t` is spelled `nt` here throughout: on operands already
/// reduced to 0 or 1 the two agree, and Zig's `~` would complement 63 bits that
/// are then masked away.
fn dpdDecodeDeclet(declet: u64) u64 {
    verify(declet <= 1023, "the declet is 10 bits");

    if (declet == 0) return 0;

    const p = (declet >> 9) & 1;
    const q = (declet >> 8) & 1;
    const r = (declet >> 7) & 1;
    const s = (declet >> 6) & 1;
    const t = (declet >> 5) & 1;
    const u = (declet >> 4) & 1;
    const v = (declet >> 3) & 1;
    const w = (declet >> 2) & 1;
    const x = (declet >> 1) & 1;
    const y = declet & 1;

    const ns = s ^ 1;
    const nx = x ^ 1;
    const nv = v ^ 1;
    const nw = w ^ 1;
    const nt = t ^ 1;

    const a = (v & w) & (ns | t | nx);
    const b = p & (nv | nw | (s & nt & x));
    const c = q & (nv | nw | (s & nt & x));
    const d = r;

    const e = v & ((nw & x) | (nt & x) | (s & x));
    const f = (s & (nv | nx)) | (p & ns & t & v & w & x);
    const g = (t & (nv | nx)) | (q & ns & t & w);
    const h = u;

    const i = v & ((nw & nx) | (w & x & (s | t)));
    const j = (nv & w) | (s & v & nw & x) | (p & w & (nx | (ns & nt)));
    const k = (nv & x) | (t & nw & x) | (q & v & w & (nx | (ns & nt)));
    const m = y;

    const d2 = (a << 3) | (b << 2) | (c << 1) | d;
    const d1 = (e << 3) | (f << 2) | (g << 1) | h;
    const d0 = (i << 3) | (j << 2) | (k << 1) | m;

    return d2 * 100 + d1 * 10 + d0;
}

/// Encode 0..999 into a 10-bit declet. The inverse of dpdDecodeDeclet over the
/// canonical declets.
fn dpdEncodeDeclet(n: u64) u64 {
    verify(n <= 999, "the value fits three decimal digits");

    if (n == 0) return 0;

    const q10 = (n * 205) >> 11; // n / 10, exact for n <= 999
    const q100 = (n * 41) >> 12; // n / 100, exact for n <= 999

    const d2 = q100;
    const d1 = q10 - (q100 * 10);
    const d0 = n - (q10 * 10);

    const a = (d2 >> 3) & 1;
    const b = (d2 >> 2) & 1;
    const c = (d2 >> 1) & 1;
    const d = d2 & 1;

    const e = (d1 >> 3) & 1;
    const f = (d1 >> 2) & 1;
    const g = (d1 >> 1) & 1;
    const h = d1 & 1;

    const i = (d0 >> 3) & 1;
    const j = (d0 >> 2) & 1;
    const k = (d0 >> 1) & 1;
    const m = d0 & 1;

    const na = a ^ 1;
    const ne = e ^ 1;
    const ni = i ^ 1;

    const p = b | ((a & j) | ((a & f) & i));
    const q = c | ((a & k) | ((a & g) & i));
    const r = d;
    const s = (f & (na | ni)) | ((na & (e & j)) | (e & i));
    const t = g | ((na & (e & k)) | (a & i));
    const u = h;
    const v = a | (e | i);
    const w = a | ((e & i) | (ne & j));
    const x = e | ((a & i) | (na & k));
    const y = m;

    return (p << 9) | (q << 8) | (r << 7) | (s << 6) | (t << 5) |
        (u << 4) | (v << 3) | (w << 2) | (x << 1) | y;
}

/// Decode up to seven packed declets into a binary integer. Declets are ten bits
/// each, least significant first; the topmost may be narrower, which is how the
/// coefficient's leading digit rides along -- 0..9 encodes to itself.
fn binFromDeclets(declets: u64) u64 {
    var bin: u64 = 0;
    var rest = declets;
    var multiplier: u64 = 1;
    while (rest != 0) {
        bin += dpdDecodeDeclet(rest & 0x3FF) * multiplier;
        // The last iteration multiplies past 10^18 and the product is never
        // used, since `rest` is zero by then. The reference wraps here too.
        multiplier *%= 1000;
        rest >>= 10;
    }
    return bin;
}

/// Encode a value of at most 18 digits into six packed declets, least
/// significant first. The inverse of binFromDeclets over that range.
fn decletsFromBin(bin: u64) u64 {
    verify(bin < TEN_POW_18, "the value fits eighteen decimal digits");
    var rest = bin;
    var declets: u64 = 0;
    var shift: u6 = 0;
    while (rest != 0) {
        const q = mulhi64(rest, 0x020C_49BA_5E35_3F7D) >> 3; // rest / 1000
        declets |= dpdEncodeDeclet(rest - (q * 1000)) << shift;
        shift += 10;
        rest = q;
    }
    return declets;
}

// --------------------------------------------------------------------------
// Rendering integers into ASCII
// --------------------------------------------------------------------------

// Reciprocal-multiplication constants. The 64-bit ones fold in the 64-bit shift
// that mulhi64 already performs, so the named shift is the remainder.
const M_U64_DIV_1E8: u64 = 0x8000_0000_0000_0000 | 0x2BCC_7711_8461_CEFD;
const S_U64_DIV_1E8: u6 = 26;
const M_U32_DIV_1E1: u64 = 0xCCCC_CCCD;
const S_U32_DIV_1E1: u6 = 35;
const M_U32_DIV_1E2: u64 = 0x51EB_851F;
const S_U32_DIV_1E2: u6 = 37;
const M_U64_DIV_1E4: u64 = 0x346D_C5D6_3886_594B;
const S_U64_DIV_1E4: u6 = 11;
const MASK32: u64 = 0xFFFF_FFFF;

const MAGIC_DIV_1E8: u64 = M_U64_DIV_1E8;

inline fn asciiDigit(d: u64) u8 {
    return '0' + @as(u8, @intCast(d));
}

/// Render exactly 8 decimal digits of dw, ending at offMaxx. Zero-pads. The
/// caller guarantees dw < 10^8 and that the 8 bytes are inside the buffer.
///
/// A binary cascade: one divide by 10^4 to split into halves, two by 10^2 to
/// split those into pairs, four by 10 for the digits.
fn render8DigitsBeforeIndex(dw: u64, ascii: []u8, off_maxx: usize) void {
    const abcd = mulhi64(dw, M_U64_DIV_1E4) >> S_U64_DIV_1E4;
    const efgh = dw - (abcd * 10000);

    const ab = (abcd * M_U32_DIV_1E2) >> S_U32_DIV_1E2;
    const cd = abcd - (ab * 100);

    const ef = (efgh * M_U32_DIV_1E2) >> S_U32_DIV_1E2;
    const gh = efgh - (ef * 100);

    const a = (ab * M_U32_DIV_1E1) >> S_U32_DIV_1E1;
    const b = ab - (a * 10);

    const c = (cd * M_U32_DIV_1E1) >> S_U32_DIV_1E1;
    const d = cd - (c * 10);

    const e = (ef * M_U32_DIV_1E1) >> S_U32_DIV_1E1;
    const f = ef - (e * 10);

    const g = (gh * M_U32_DIV_1E1) >> S_U32_DIV_1E1;
    const h = gh - (g * 10);

    demand(off_maxx >= 8, "the eight digits are inside the buffer");
    ascii[off_maxx - 8] = asciiDigit(a);
    ascii[off_maxx - 7] = asciiDigit(b);
    ascii[off_maxx - 6] = asciiDigit(c);
    ascii[off_maxx - 5] = asciiDigit(d);
    ascii[off_maxx - 4] = asciiDigit(e);
    ascii[off_maxx - 3] = asciiDigit(f);
    ascii[off_maxx - 2] = asciiDigit(g);
    ascii[off_maxx - 1] = asciiDigit(h);
}

/// Render exactly renderDigitCount digits of dw, ending at offMaxx, zero-padded.
/// Four digits per iteration while at least four remain, then one at a time.
fn renderTailDigitsBeforeIndex(render_digit_count: usize, dw: u64, ascii: []u8, off_maxx: usize) void {
    var t = dw;
    var remaining_digit_count = render_digit_count;
    var ib = off_maxx;
    demand(off_maxx >= render_digit_count, "the digits are inside the buffer");
    while (remaining_digit_count >= 4) {
        const t0 = mulhi64(t, M_U64_DIV_1E4) >> S_U64_DIV_1E4;
        const abcd = t - (t0 * 10000);
        t = t0;
        const ab = (abcd * M_U32_DIV_1E2) >> S_U32_DIV_1E2;
        const cd = abcd - (ab * 100);
        const a = (ab * M_U32_DIV_1E1) >> S_U32_DIV_1E1;
        const b = ab - (a * 10);
        const c = (cd * M_U32_DIV_1E1) >> S_U32_DIV_1E1;
        const d = cd - (c * 10);
        ascii[ib - 4] = asciiDigit(a);
        ascii[ib - 3] = asciiDigit(b);
        ascii[ib - 2] = asciiDigit(c);
        ascii[ib - 1] = asciiDigit(d);
        ib -= 4;
        remaining_digit_count -= 4;
    }
    while (remaining_digit_count > 0) {
        const div_ten = (t * M_U32_DIV_1E1) >> S_U32_DIV_1E1;
        const digit = t - (div_ten * 10);
        ib -= 1;
        ascii[ib] = asciiDigit(digit);
        t = div_ten;
        remaining_digit_count -= 1;
    }
    verify(off_maxx - ib == render_digit_count, "exactly renderDigitCount bytes were written");
}

/// Render a 128-bit value as digitPrintCount decimal digits, ending at
/// off + digitPrintCount.
///
/// Three phases: while the high word is live, peel 8 digits per iteration via
/// three divides by 10^8 across rotating 96-bit chunks; once it fits in 64 bits,
/// one divide by 10^8 per 8 digits; then the 1..7 leftover digits.
fn u128ToAscii(digit_print_count: usize, dw1: u64, dw0: u64, ascii: []u8, off: usize) void {
    var dw1_t = dw1;
    var dw0_t = dw0;
    var ich = off + digit_print_count;
    var remaining_digit_count = digit_print_count;
    while (dw1_t != 0) {
        const q2 = mulhi64(dw1_t, MAGIC_DIV_1E8) >> S_U64_DIV_1E8;
        const r2 = dw1_t - (q2 * 100_000_000);
        const s2 = (r2 << 32) | (dw0_t >> 32);
        const q1 = mulhi64(s2, MAGIC_DIV_1E8) >> S_U64_DIV_1E8;
        const r1 = s2 - (q1 * 100_000_000);
        const s1 = (r1 << 32) | (dw0_t & MASK32);
        const q0 = mulhi64(s1, MAGIC_DIV_1E8) >> S_U64_DIV_1E8;
        const r0 = s1 - (q0 * 100_000_000);
        dw0_t = (q1 << 32) + q0;
        dw1_t = q2;
        render8DigitsBeforeIndex(r0, ascii, ich);
        ich -= 8;
        remaining_digit_count -= 8;
    }
    while (remaining_digit_count >= 8) {
        const t0 = mulhi64(dw0_t, MAGIC_DIV_1E8) >> S_U64_DIV_1E8;
        const r0 = dw0_t - (t0 * 100_000_000);
        dw0_t = t0;
        render8DigitsBeforeIndex(r0, ascii, ich);
        ich -= 8;
        remaining_digit_count -= 8;
    }
    if (remaining_digit_count > 0) {
        renderTailDigitsBeforeIndex(remaining_digit_count, dw0_t, ascii, ich);
    }
}

/// Write a signed decimal integer; returns the number of bytes written. Stands
/// in for the reference's Int.toString in the zero renderer, the same way the C
/// and Rust ports' appendInt does -- std.fmt.bufPrint returns an error union for
/// a case that cannot arise here, and this is the one site that needs it.
fn appendInt(out: []u8, v: i32) usize {
    var tmp: [12]u8 = undefined;
    var n: usize = 0;
    var len: usize = 0;
    var magnitude: u32 = @abs(v);
    if (v < 0) {
        out[len] = '-';
        len += 1;
    }
    while (true) {
        tmp[n] = '0' + @as(u8, @intCast(magnitude % 10));
        n += 1;
        magnitude /= 10;
        if (magnitude == 0) break;
    }
    while (n > 0) {
        n -= 1;
        out[len] = tmp[n];
        len += 1;
    }
    return len;
}

// --------------------------------------------------------------------------
// Rendering a decoded value
//
// These four know nothing about BID or DPD: both decoders reduce an encoding to
// (sign, qExp, coefficient) and hand it here.
// --------------------------------------------------------------------------

fn infString(out: []u8, sign: bool) usize {
    const s: []const u8 = if (sign) "-Infinity" else "Infinity";
    demand(s.len <= max_len, "Infinity fits the buffer");
    @memcpy(out[0..s.len], s);
    return s.len;
}

fn nanString(out: []u8, sign: bool, is_signaling: bool, payload_hi: u64, payload_lo: u64) usize {
    const base: []const u8 = if (!is_signaling)
        (if (sign) "-NaN" else "NaN")
    else
        (if (sign) "-sNaN" else "sNaN");
    const base_len = base.len;

    if ((payload_hi | payload_lo) == 0 or
        // non-canonical payload, IEEE 754-2019 3.5.2 c) 2) -- read as zero
        payload_hi > MAX_PAYLOAD_HI or
        (payload_hi == MAX_PAYLOAD_HI and payload_lo > MAX_PAYLOAD_LO))
    {
        demand(base_len <= max_len, "the bare NaN fits the buffer");
        @memcpy(out[0..base_len], base);
        return base_len;
    }
    const digit_len = calcDigitLen128(payload_hi, payload_lo);
    const total_len = base_len + digit_len;
    demand(total_len <= max_len, "the NaN payload fits the buffer");
    @memcpy(out[0..base_len], base);
    u128ToAscii(digit_len, payload_hi, payload_lo, out, base_len);
    return total_len;
}

/// Every plain-form zero is a prefix of this literal. `k = -q_exp` is the count
/// of zeros after the radix point, so `k = 0` renders `"0"` with no radix point
/// at all and `k >= 1` renders `"0."` followed by `k` zeros -- lengths 1 and
/// `k + 2`.
///
/// The sign is not in the data. It is written into `out[0]` unconditionally and
/// overwritten by the `0` when the value is positive, the same trick the finite
/// renderers use. That works because the negative spelling of every form here is
/// the positive spelling with one byte in front; a form that ever put the sign
/// anywhere else would render wrong rather than fail to compile.
const PLAIN_ZERO = "0.000000";

fn zerString(out: []u8, sign: bool, q_exp: i32) usize {
    if (q_exp <= 0 and q_exp >= -6) {
        const k: usize = @intCast(-q_exp);
        const zero_len: usize = if (k == 0) 1 else k + 2;
        const sign_len: usize = @intFromBool(sign);
        const total_len = sign_len + zero_len;
        demand(total_len <= max_len, "the plain zero fits the buffer");
        out[0] = '-'; // overwritten by the '0' when unsigned
        @memcpy(out[sign_len..total_len], PLAIN_ZERO[0..zero_len]);
        return total_len;
    }
    const base: []const u8 = if (q_exp > 0)
        (if (sign) "-0E+" else "0E+")
    else
        // q_exp is negative and prints its own sign
        (if (sign) "-0E" else "0E");
    const base_len = base.len;
    demand(base_len + 6 <= max_len, "the exponent-form zero fits the buffer");
    @memcpy(out[0..base_len], base);
    return base_len + appendInt(out[base_len..], q_exp);
}

/// qExp == 0: a plain integer, no radix point and no exponent.
fn fnzToIntegerString(out: []u8, sign: bool, digit_len: usize, dw1: u64, dw0: u64) usize {
    verify(digit_len > 0, "a finite nonzero value has at least one digit");
    const sign_len: usize = @intFromBool(sign);
    const total_len = sign_len + digit_len;
    demand(total_len <= max_len, "the integer form fits the buffer");
    out[0] = '-'; // overwritten by the first digit when unsigned
    u128ToAscii(digit_len, dw1, dw0, out, sign_len);
    return total_len;
}

/// Fixed-point form: leading zeros, then the coefficient digits shifted right by
/// one position to make room for the radix point.
fn fnzToDecimalPointString(out: []u8, sign: bool, q_exp: i32, digit_len: usize, dw1: u64, dw0: u64) usize {
    const digits_right_of_decimal: usize = @intCast(-q_exp);
    const leading_zero_signed = 1 + @as(i32, @intCast(digits_right_of_decimal)) - @as(i32, @intCast(digit_len));
    const leading_zero_count: usize = if (leading_zero_signed < 0) 0 else @intCast(leading_zero_signed);
    const sign_len: usize = @intFromBool(sign);
    const decimal_point_len: usize = 1;
    const total_len = sign_len + leading_zero_count + decimal_point_len + digit_len;
    demand(total_len <= max_len, "the fixed-point form fits the buffer");
    out[0] = '-';
    var i = sign_len;
    while (i <= leading_zero_count) : (i += 1) { // one extra, overwritten below
        out[i] = '0';
    }
    u128ToAscii(digit_len, dw1, dw0, out, sign_len + leading_zero_count);
    var j = total_len;
    while (j > total_len - digits_right_of_decimal) : (j -= 1) {
        out[j - 1] = out[j - 2];
    }
    out[total_len - digits_right_of_decimal - 1] = '.';
    return total_len;
}

/// Normalized scientific form. The exponent sign is always written, per the GDAS
/// to-scientific-string form: 1.234E+5, never 1.234E5.
fn fnzToNormalizedScientificString(out: []u8, sign: bool, q_exp: i32, digit_len: usize, dw1: u64, dw0: u64) usize {
    verify(digit_len > 0, "a finite nonzero value has at least one digit");
    const e_exp = q_exp + (@as(i32, @intCast(digit_len)) - 1);
    const e_exp_abs: u32 = @abs(e_exp);
    const sign_len: usize = @intFromBool(sign);
    const decimal_point_len: usize = @intFromBool(digit_len > 1);
    const exp_e_len: usize = 1;
    const exp_sign_len: usize = 1;
    const exp_sign_byte: u8 = if (e_exp < 0) '-' else '+';
    const exp_digit_len: usize = if (e_exp_abs >= 1000)
        4
    else if (e_exp_abs >= 100)
        3
    else if (e_exp_abs >= 10)
        2
    else
        1;
    const total_len = sign_len + decimal_point_len + digit_len + exp_e_len + exp_sign_len + exp_digit_len;
    demand(total_len <= max_len, "the scientific form fits the buffer");
    out[0] = '-';
    u128ToAscii(digit_len, dw1, dw0, out, sign_len + decimal_point_len);
    if (decimal_point_len > 0) {
        out[sign_len] = out[sign_len + 1];
        out[sign_len + 1] = '.';
    }
    const i_e = sign_len + decimal_point_len + digit_len;
    out[i_e] = 'E';
    out[i_e + 1] = exp_sign_byte;
    renderTailDigitsBeforeIndex(exp_digit_len, e_exp_abs, out, total_len);
    return total_len;
}

/// Finite non-zero: pick the form. Integer when the quantum exponent is zero,
/// fixed-point when the value sits within six leading zeros of unity, scientific
/// otherwise -- the GDAS auto-select rule.
fn fnzString(out: []u8, sign: bool, q_exp: i32, dw1: u64, dw0: u64) usize {
    const digit_len = calcDigitLen128(dw1, dw0);
    const e_exp = q_exp + (@as(i32, @intCast(digit_len)) - 1);
    if (q_exp == 0) return fnzToIntegerString(out, sign, digit_len, dw1, dw0);
    if (q_exp <= 0 and e_exp >= -6) return fnzToDecimalPointString(out, sign, q_exp, digit_len, dw1, dw0);
    return fnzToNormalizedScientificString(out, sign, q_exp, digit_len, dw1, dw0);
}

// --------------------------------------------------------------------------
// bits -> text
// --------------------------------------------------------------------------

/// Unpack a BID128 encoding, per IEEE 754-2019 3.5.2, and render it.
fn decodeBid128toString(out: []u8, bid128_hi: u64, bid128_lo: u64) usize {
    verify(1 + W5 + T_WIDTH == 128, "the field widths tile the encoding");

    const sign = (bid128_hi & SIGN_BIT) != 0;
    const combination: u32 = @intCast((bid128_hi >> @intCast(T_WIDTH - 64)) & 0x1FFFF);
    const coeff_t_hi = bid128_hi & ((@as(u64, 1) << @intCast(T_WIDTH - 64)) - 1);

    var coeff_hi: u64 = undefined;
    var q_exp: i32 = undefined;

    if ((combination >> @intCast(W5 - 2)) != 0x3) {
        // G0 G1 is 00, 01 or 10: the exponent is the top of the field and the
        // coefficient's three high bits are the bottom of it.
        const biased_exponent_e: i32 = @intCast(combination >> 3);
        q_exp = biased_exponent_e - BIAS;
        coeff_hi = combination & 0x07;
    } else if ((combination >> @intCast(W5 - 4)) != 0xF) {
        // G0 G1 is 11 and G2 G3 is not: the coefficient's high bits are
        // 8 + Gw+4, and the exponent shifts down by two.
        const biased_exponent_e: i32 = @intCast((combination >> 1) & ((@as(u32, 1) << @intCast(W5 - 5 + 2)) - 1));
        q_exp = biased_exponent_e - BIAS;
        coeff_hi = 8 + @as(u64, combination & 1);
    } else if ((combination >> @intCast(W5 - 5)) == 0x1E) {
        return infString(out, sign);
    } else {
        verify((combination >> @intCast(W5 - 5)) == 0x1F, "the remaining combination field is the NaN pattern");
        const is_signaling = ((combination >> @intCast(W5 - 6)) & 1) != 0;
        return nanString(out, sign, is_signaling, coeff_t_hi, bid128_lo);
    }

    const dw1 = (coeff_hi << @intCast(T_WIDTH - 64)) | coeff_t_hi;
    const dw0 = bid128_lo;

    // IEEE 754-2019 3.5.2: a coefficient at or above 10^34 is non-canonical and
    // the value used for it is zero, sign and exponent retained.
    if ((dw1 | dw0) == 0 or
        dw1 > MAXX_COEFF_34_HI or
        (dw1 == MAXX_COEFF_34_HI and dw0 >= MAXX_COEFF_34_LO))
    {
        return zerString(out, sign, q_exp);
    }
    return fnzString(out, sign, q_exp, dw1, dw0);
}

/// Unpack a DPD128 encoding and hand the pieces to the same renderers.
fn decodeDpd128toString(out: []u8, dpd128_hi: u64, dpd128_lo: u64) usize {
    const w: u32 = 12; // exponent continuation width

    const sign = (dpd128_hi & SIGN_BIT) != 0;
    const combination: u32 = @intCast((dpd128_hi >> @intCast(T_WIDTH - 64)) & 0x1FFFF);
    // in DPD the low w bits of the biased exponent always sit at the bottom of G
    const exp_continuation: i32 = @intCast(combination & 0x0FFF);

    var d0: u64 = undefined;
    var q_exp: i32 = undefined;
    var is_nan = false;
    var is_signaling = false;

    if ((combination >> @intCast(W5 - 2)) != 0x3) {
        // leading digit 0..7, exponent MSBs in G0 G1
        const exp_msb: i32 = @intCast(combination >> @intCast(W5 - 2));
        q_exp = ((exp_msb << @intCast(w)) | exp_continuation) - BIAS;
        d0 = (combination >> @intCast(w)) & 0x7;
    } else if ((combination >> @intCast(W5 - 4)) != 0xF) {
        // leading digit 8 or 9, exponent MSBs displaced into G2 G3
        const exp_msb: i32 = @intCast((combination >> @intCast(W5 - 4)) & 0x3);
        q_exp = ((exp_msb << @intCast(w)) | exp_continuation) - BIAS;
        d0 = 8 + @as(u64, (combination >> @intCast(w)) & 0x1);
    } else if ((combination >> @intCast(W5 - 5)) == 0x1E) {
        return infString(out, sign);
    } else {
        verify((combination >> @intCast(W5 - 5)) == 0x1F, "the remaining combination field is the NaN pattern");
        is_nan = true;
        is_signaling = ((combination >> @intCast(W5 - 6)) & 1) != 0;
        d0 = 0;
        q_exp = 0;
    }

    // Rebuild the binary coefficient from the declets. The leading digit rides
    // along as a sixth declet of the high group: 0..9 encodes to itself.
    const declets_hi = (d0 << 50) | ((dpd128_hi & 0x3FFF_FFFF_FFFF) << 4) | (dpd128_lo >> 60);
    const declets_lo = dpd128_lo & 0x0FFF_FFFF_FFFF_FFFF; // low 60 bits, six declets
    const bin_hi = binFromDeclets(declets_hi);
    const bin_lo = binFromDeclets(declets_lo);

    var dw1: u64 = undefined;
    var dw0: u64 = undefined;
    if (bin_hi == 0) {
        dw1 = 0;
        dw0 = bin_lo;
    } else {
        const prod = @as(u128, bin_hi) * @as(u128, TEN_POW_18);
        const prod_hi: u64 = @truncate(prod >> 64);
        const prod_lo: u64 = @truncate(prod);
        const sum_lo = prod_lo +% bin_lo;
        dw1 = prod_hi + @as(u64, @intFromBool(sum_lo < prod_lo));
        dw0 = sum_lo;
    }

    if (is_nan) return nanString(out, sign, is_signaling, dw1, dw0);
    if ((dw1 | dw0) == 0) return zerString(out, sign, q_exp);
    return fnzString(out, sign, q_exp, dw1, dw0);
}

// --------------------------------------------------------------------------
// Packing a finalized value into an encoding
//
// Everything upstream of these -- parsing, rounding, clamping, the underflow
// region -- is format-neutral; the two formats diverge only here.
// --------------------------------------------------------------------------

fn bid128SetFinite(sign: bool, q_exp: i32, dw1: u64, dw0: u64) struct { u64, u64 } {
    verify(q_exp >= Q_MIN and q_exp <= Q_MAX, "the quantum exponent is in range");
    verify(calcDigitLen128(dw1, dw0) <= 34, "the coefficient is at most 34 digits");
    const q_biased: u64 = @intCast(q_exp + BIAS);
    const s: u64 = if (sign) SIGN_BIT else 0;
    const g = q_biased << (3 + 46);
    return .{ s | g | dw1, dw0 };
}

/// Pack a finite value into DPD128: the same sign and the same 14-bit biased
/// exponent as BID, and a coefficient of the same 34 digits laid out as a
/// leading digit in the combination field plus eleven declets.
///
/// The leading digit cannot be packed independently of the exponent -- DPD puts
/// it in the same five-bit prefix as the exponent's top two bits -- so unlike
/// BID there is no shared sign-and-exponent step to factor out.
fn dpd128SetFinite(sign: bool, q_exp: i32, dw1: u64, dw0: u64) struct { u64, u64 } {
    verify(q_exp >= Q_MIN and q_exp <= Q_MAX, "the quantum exponent is in range");
    verify(calcDigitLen128(dw1, dw0) <= 34, "the coefficient is at most 34 digits");

    // Split the coefficient into its low 18 digits and its high 16. Two
    // divisions by 10^9 rather than one by 10^18, so the existing 128-bit kernel
    // does the work and no wider machinery is needed.
    const t1_hi, const t1_lo, const r1 = u113DivModPow10Max9(dw1, dw0, 9);
    const t2_hi, const t2_lo, const r2 = u113DivModPow10Max9(t1_hi, t1_lo, 9);
    const bin_lo = (r2 * 1_000_000_000) + r1;
    verify(t2_hi == 0, "the high 16 digits fit in one word");
    const bin_hi = t2_lo;

    // the top digit rides in the combination field; the other 15 are declets
    const d0 = bin_hi / TEN_POW_15;
    const declets5_hi = decletsFromBin(bin_hi - (d0 * TEN_POW_15));
    const declets6_lo = decletsFromBin(bin_lo);
    verify(d0 <= 9, "the leading digit is a single digit");

    const biased_q_exp = q_exp + BIAS;
    const exp_msb: u64 = @intCast((biased_q_exp >> 12) & 0x3);
    const exp_lsb: u64 = @intCast(biased_q_exp & 0x0FFF);
    const g_prefix: u64 = if (d0 <= 7)
        (exp_msb << 3) | d0 // G0G1 = exponent MSBs
    else
        0x18 | (exp_msb << 1) | (d0 & 1); // G0G1 = 11, digit is 8 or 9
    const sign_value: u64 = @intFromBool(sign);
    const sign_combo = (sign_value << 17) | (g_prefix << 12) | exp_lsb;

    return .{ (sign_combo << 46) | (declets5_hi >> 4), (declets5_hi << 60) | declets6_lo };
}

fn setFinite(format_is_bid: bool, sign: bool, q_exp: i32, dw1: u64, dw0: u64) struct { u64, u64 } {
    return if (format_is_bid)
        bid128SetFinite(sign, q_exp, dw1, dw0)
    else
        dpd128SetFinite(sign, q_exp, dw1, dw0);
}

fn bid128SetNaN(sign: bool, is_signaling: bool, payload_dw1: u64, payload_dw0: u64) struct { u64, u64 } {
    var without_payload: u64 = if (is_signaling) SNAN_PATTERN_HI else QNAN_PATTERN_HI;
    if (sign) without_payload |= SIGN_BIT;
    return .{ without_payload | payload_dw1, payload_dw0 };
}

/// Pack a NaN into DPD128. The payload occupies the whole 110-bit trailing field
/// as eleven declets -- 33 digits, with no leading digit in the combination
/// field, since G0..G4 are fixed at 11111 and G5 carries the signaling flag.
fn dpd128SetNaN(sign: bool, is_signaling: bool, payload_dw1: u64, payload_dw0: u64) struct { u64, u64 } {
    verify(calcDigitLen128(payload_dw1, payload_dw0) <= 33, "the payload is at most 33 digits");

    const t1_hi, const t1_lo, const r1 = u113DivModPow10Max9(payload_dw1, payload_dw0, 9);
    const t2_hi, const t2_lo, const r2 = u113DivModPow10Max9(t1_hi, t1_lo, 9);
    const bin_lo = (r2 * 1_000_000_000) + r1;
    verify(t2_hi == 0, "a 33-digit payload leaves 15 digits up top");
    const declets5_hi = decletsFromBin(t2_lo);
    const declets6_lo = decletsFromBin(bin_lo);

    var g_field: u64 = @as(u64, 0x1F) << 12;
    if (is_signaling) g_field |= @as(u64, 1) << 11;
    const sign_combo = (@as(u64, @intFromBool(sign)) << 17) | g_field;
    return .{ (sign_combo << 46) | (declets5_hi >> 4), (declets5_hi << 60) | declets6_lo };
}

fn setNaN(format_is_bid: bool, sign: bool, is_signaling: bool, payload_dw1: u64, payload_dw0: u64) struct { u64, u64 } {
    return if (format_is_bid)
        bid128SetNaN(sign, is_signaling, payload_dw1, payload_dw0)
    else
        dpd128SetNaN(sign, is_signaling, payload_dw1, payload_dw0);
}

fn finalizeOverflow(sign: bool) struct { u64, u64 } {
    const s: u64 = if (sign) SIGN_BIT else 0;
    return .{ s | INF_PATTERN_HI, 0 };
}

// --------------------------------------------------------------------------
// Finalize: rounding, clamping, underflow
// --------------------------------------------------------------------------

/// Does this coefficient/exponent pair fit as a canonical encoding?
fn coeffQExpFit(dw1: u64, dw0: u64, q_exp: i32) bool {
    if (q_exp < Q_MIN or q_exp > Q_MAX) return false;
    // at most 113 bits is necessarily below 10^34, since 2^113 > 10^34
    if (clz64(dw1) > 128 - 113) return true;
    return dw1 < MAXX_COEFF_34_HI or (dw1 == MAXX_COEFF_34_HI and dw0 < MAXX_COEFF_34_LO);
}

/// A finite value whose quantum exponent exceeds Q_MAX but whose coefficient has
/// leading capacity: absorb the excess into the coefficient, bringing the
/// exponent down to exactly Q_MAX without changing the value.
fn finalizeClamping(format_is_bid: bool, sign: bool, q_exp: i32, dw1: u64, dw0: u64) struct { u64, u64 } {
    const q_excess = q_exp - Q_MAX;
    verify(
        q_excess > 0 and @as(usize, @intCast(q_excess)) <= 34 - calcDigitLen128(dw1, dw0),
        "the excess exponent fits the coefficient's spare digits",
    );
    const pow10_offset: usize = @as(usize, @intCast(q_excess)) << 1;
    const y1 = POW10[pow10_offset + 1];
    const y0 = POW10[pow10_offset];
    // The three cross terms all discard their high halves and the sum wraps: the
    // reference relies on that, and the result is guaranteed in range by the
    // caller's digit-count test.
    const pp00 = @as(u128, dw0) * @as(u128, y0);
    const pp00_hi: u64 = @truncate(pp00 >> 64);
    const pp00_lo: u64 = @truncate(pp00);
    const pp10_lo = dw1 *% y0;
    const pp01_lo = dw0 *% y1;
    const dw0_scaled = pp00_lo;
    const dw1_scaled = pp00_hi +% pp10_lo +% pp01_lo;
    verify(coeffQExpFit(dw1_scaled, dw0_scaled, Q_MAX), "the scaled coefficient is representable at Q_MAX");
    return setFinite(format_is_bid, sign, Q_MAX, dw1_scaled, dw0_scaled);
}

/// The underflow boundary: the coefficient's most significant digit sits exactly
/// one position right of the representable range, so the coefficient itself
/// decides the rounding. Under ties-to-even the outcome is zero unless the total
/// residue is greater than half, zero being even.
fn finalizeUnderflowBoundary(format_is_bid: bool, sign: bool, dw1: u64, dw0: u64, residue_in: i32) struct { u64, u64 } {
    const digit_len = calcDigitLen128(dw1, dw0);
    verify(digit_len != 0, "the boundary coefficient is nonzero");
    const scale_residue = residueFromValuePow10(dw1, dw0, digit_len);
    const total_residue = residueMerge(scale_residue, residue_in);
    const coeff: u64 = @intFromBool(total_residue == GT_HALF);
    return setFinite(format_is_bid, sign, Q_MIN, 0, coeff);
}

/// Representable as a subnormal: truncate to the minimum exponent, keeping what
/// precision survives, and round what is left.
fn finalizeSubnormal(format_is_bid: bool, sign: bool, q_exp_in: i32, dw1_in: u64, dw0_in: u64, residue_in: i32) struct { u64, u64 } {
    const truncation_needed: usize = @intCast(Q_MIN - q_exp_in);
    verify(
        truncation_needed > 0 and truncation_needed < calcDigitLen128(dw1_in, dw0_in),
        "the subnormal truncation keeps at least one digit",
    );

    const scaled_hi, const scaled_lo, const scale_residue = u128ScaleDownPow10(dw1_in, dw0_in, truncation_needed);
    var dw1_t = scaled_hi;
    var dw0_t = scaled_lo;
    const total_residue = residueMerge(scale_residue, residue_in);
    var q_exp_t = Q_MIN;

    const round_up = (total_residue == GT_HALF) or (total_residue == TIE_HALF and (dw0_t & 1) != 0);
    if (round_up) {
        // The increment carries out of the low word only when it is all ones,
        // which the reference lets wrap to zero and catches with the test below.
        dw0_t +%= 1;
        if (dw0_t == 0) dw1_t += 1;
        if (dw1_t == MAXX_COEFF_34_HI and dw0_t == MAXX_COEFF_34_LO) {
            dw1_t = MIN_PRECISION_34_COEFF_HI;
            dw0_t = MIN_PRECISION_34_COEFF_LO;
            q_exp_t += 1;
        }
    }
    return setFinite(format_is_bid, sign, q_exp_t, dw1_t, dw0_t);
}

/// Dispatch the three underflow cases: swamped to zero, the exact boundary, and
/// the subnormal region.
fn finalizeUnderflowRegion(format_is_bid: bool, sign: bool, q_exp: i32, dw1: u64, dw0: u64, residue: i32) struct { u64, u64 } {
    verify(q_exp < Q_MIN, "the exponent is below the minimum");
    const truncation_needed: usize = @intCast(Q_MIN - q_exp);
    const digit_len = calcDigitLen128(dw1, dw0);
    verify(digit_len <= 34, "the coefficient is at most 34 digits");
    if (truncation_needed > digit_len) {
        // below half the smallest subnormal: zero, and always inexact
        return roundAndFinalizeFinite(format_is_bid, sign, Q_MIN, 0, 0, LT_HALF);
    } else if (truncation_needed == digit_len) {
        return finalizeUnderflowBoundary(format_is_bid, sign, dw1, dw0, residue);
    } else {
        return finalizeSubnormal(format_is_bid, sign, q_exp, dw1, dw0, residue);
    }
}

/// Round a parsed coefficient/exponent pair to a canonical encoding, under
/// ties-to-even, and pack it.
///
///  1. fast path -- already in range and no rounding to do
///  2. a zero coefficient with an out-of-range exponent clamps
///  3. (special values never arrive here)
///  4. underflow, when the exponent is below the minimum
///  5. truncate to 34 digits -- REMOVED as unreachable, see the note in the body
///  6. round, and renormalize if the coefficient rolls over to 10^34
///  7. overflow to Infinity, or clamp near Emax
fn roundAndFinalizeFinite(format_is_bid: bool, sign: bool, q_exp_in: i32, dw1_in: u64, dw0_in: u64, residue_in: i32) struct { u64, u64 } {
    // Step 1
    if (residue_in <= LT_HALF or (residue_in == TIE_HALF and (dw0_in & 1) == 0)) {
        if (coeffQExpFit(dw1_in, dw0_in, q_exp_in)) {
            return setFinite(format_is_bid, sign, q_exp_in, dw1_in, dw0_in);
        }
        // Step 2
        if ((dw1_in | dw0_in) == 0) {
            const q_clamped = std.math.clamp(q_exp_in, Q_MIN, Q_MAX);
            return setFinite(format_is_bid, sign, q_clamped, 0, 0);
        }
    }

    // Step 5 -- precision truncation -- IS NOT HERE, and this is the reason.
    //
    // The finalizer this descends from serves an arithmetic engine, whose
    // callers hand it coefficients wider than the 34-digit precision limit:
    // multiply and FMA produce a double-width product, and the engine truncates
    // it here, accumulating the discarded digits into the residue before
    // rounding. A codec has no such caller.
    //
    // The parser accumulates at most 19 + 15 = 34 significant digits and turns
    // every digit past them into a residue instead, so the coefficient it hands
    // over is never wider than the limit. The only other entry to this function
    // is the swamped-underflow branch above, which passes a zero coefficient. So
    // the truncation step is unreachable, and rather than ship a path that has
    // never once executed -- and therefore has never been verified to work -- it
    // is removed and the invariant is enforced.
    //
    // Measured in the C port: zero occurrences across the 87k-row corpus and
    // 400,000 random numerals, and across 76,280 finalizer calls driven by
    // inputs of up to 5,000 digits, where the widest coefficient ever seen was
    // 34.
    //
    // This is `demand`, not `verify`: it must survive into shipping builds,
    // because falling through would encode an out-of-range coefficient silently.
    // It cannot fire on a consumer's data -- no input reaches it -- only on a
    // future caller that breaks the invariant, which is exactly when a loud
    // failure is what you want. A port that parses differently, or a caller that
    // is not a parser, needs the truncation step back; it is in the reference
    // implementation and in every full port's Finalize.
    demand(calcDigitLen128(dw1_in, dw0_in) <= 34, "the coefficient is at most 34 digits");

    // Step 4 -- with no precision truncation to outrank it, the underflow test
    // is simply whether the exponent is below the minimum.
    if (Q_MIN - q_exp_in > 0) {
        return finalizeUnderflowRegion(format_is_bid, sign, q_exp_in, dw1_in, dw0_in, residue_in);
    }

    const total_residue = residue_in;
    var dw1 = dw1_in;
    var dw0 = dw0_in;
    var q_exp = q_exp_in;

    // Step 6 -- ties-to-even, the only rounding this codec has
    const apply_rounding = (total_residue == GT_HALF) or (total_residue == TIE_HALF and (dw0 & 1) != 0);
    if (apply_rounding) {
        // As in finalizeSubnormal: the low word wraps to zero exactly when it
        // was all ones, and the carry is taken from that.
        dw0 +%= 1;
        if (dw0 == 0) dw1 += 1;
        if (dw1 == MAXX_COEFF_34_HI and dw0 == MAXX_COEFF_34_LO) {
            dw1 = MIN_PRECISION_34_COEFF_HI;
            dw0 = MIN_PRECISION_34_COEFF_LO;
            q_exp += 1;
        }
    }

    // Step 7
    verify(q_exp >= Q_MIN, "the exponent is at or above the minimum");
    verify(calcDigitLen128(dw1, dw0) <= 34, "the rounded coefficient is at most 34 digits");
    if (q_exp > Q_MAX) {
        const q_excess: usize = @intCast(q_exp - Q_MAX);
        const digit_len = calcDigitLen128(dw1, dw0);
        if (digit_len + q_excess <= 34) {
            return finalizeClamping(format_is_bid, sign, q_exp, dw1, dw0);
        }
        return finalizeOverflow(sign);
    }
    return setFinite(format_is_bid, sign, q_exp, dw1, dw0);
}

// --------------------------------------------------------------------------
// text -> bits
// --------------------------------------------------------------------------

/// Why a decimal character sequence could not be parsed.
///
/// Zig error sets carry an identifier rather than a message, so these are the
/// sibling ports' failure strings as names. The mapping, for anyone reading the
/// eight files side by side:
///
///   EmptyString                   "empty string"
///   InvalidFormat                 "invalid format"
///   UnexpectedChar                "unexpected char"
///   DoubleRadixDot                "double radix dot"
///   NoCoefficientDigit            "no coefficient digit"
///   NoExponentDigit               "no exponent digit"
///   InvalidUnderscoreLocation     "invalid underscore location"
///   FailureParsingInfinityLetter  "failure parsing infinity"
///   FailureParsingInfinity        "failure parsing Infinity"
///   FailureParsingNaN             "failure parsing NaN"
///   NonDigitNaNPayloadCharacter   "non-digit NaN payload character"
///
/// The two Infinity spellings differ only in case in the other ports, which is
/// not a distinction an identifier can carry: the first reports a character
/// that is not part of the word, the second a word that ended too early. Which
/// input produces which is unchanged.
///
/// The names are not part of the contract and may change between versions. What
/// is contractual is that the two formats reject the same inputs with the same
/// error.
pub const ParseError = error{
    EmptyString,
    InvalidFormat,
    UnexpectedChar,
    DoubleRadixDot,
    NoCoefficientDigit,
    NoExponentDigit,
    InvalidUnderscoreLocation,
    FailureParsingInfinityLetter,
    FailureParsingInfinity,
    FailureParsingNaN,
    NonDigitNaNPayloadCharacter,
};

/// The input, read one byte at a time. `next` returns the byte at the cursor and
/// advances, except at the end -- and at an embedded NUL -- where it stays put
/// and keeps returning zero.
///
/// That is how the reference's getOrNul sentinel, which reads NUL forever past
/// the end of a Kotlin String, translates here. The C port spells the same thing
/// as a string pointer and an index. Parsing walks the bytes of the slice, as
/// the Swift and Rust ports walk UTF-8 bytes, and nothing is copied.
const TextCursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn next(self: *TextCursor) u8 {
        if (self.pos >= self.bytes.len) return 0;
        const c = self.bytes[self.pos];
        if (c != 0) self.pos += 1;
        return c;
    }
};

/// Parse a finite numeral: optional radix point, optional E exponent, any number
/// of digits.
///
/// Coefficients with more than 34 significant digits are accepted; leading zeros
/// are flushed, and the digits past 34 are tracked as residue for the
/// ties-to-even rounding that follows. Exponent magnitudes clamp to 9999, which
/// is enough for finalize to detect overflow or underflow.
///
/// The reference flushes leading zeros branchlessly, adding a comparison coerced
/// to an integer; the two counters below say the same thing with an `if`, since
/// Zig has no implicit bool-to-integer conversion either.
fn parseFiniteValueText(format_is_bid: bool, sign: bool, ch_first: u8, t: *TextCursor) ParseError!struct { u64, u64 } {
    var residue = EXACT;

    var has_coefficient_digit = false; // any digit at all, including zero
    var significant_digit_count: usize = 0; // does not count leading zeros
    var has_dot = false;
    var exp_sign = false;
    // an underscore is a digit separator: legal only between two digits, so it
    // must follow a digit and the next character must be a digit too
    var prev_was_digit = false;
    var after_underscore = false;

    verify(ch_first != 0, "the first character was already read");
    var ch = ch_first;
    var fractional_digit_count: usize = 0;
    var accum19a: u64 = 0;
    var accum19b: u64 = 0;
    var exp: i32 = 0;

    while (std.ascii.isDigit(ch) or ch == '.' or ch == '_') {
        if (std.ascii.isDigit(ch)) {
            const d = ch - '0';
            has_coefficient_digit = true;
            // count while flushing leading zeros
            if (significant_digit_count != 0 or d != 0) significant_digit_count += 1;
            if (significant_digit_count <= 19) {
                accum19a = (accum19a * 10) + d;
            } else if (significant_digit_count <= 34) {
                accum19b = (accum19b * 10) + d;
            } else if (significant_digit_count == 34 + 1) {
                residue = residueFromDecimalDigit(d);
            } else {
                residue = residueMerge(residue, residueFromDecimalDigit(d));
            }
            if (has_dot) fractional_digit_count += 1;
            prev_was_digit = true;
            after_underscore = false;
        } else if (ch == '_') {
            if (!prev_was_digit) return ParseError.InvalidUnderscoreLocation;
            prev_was_digit = false;
            after_underscore = true;
        } else { // '.'
            if (after_underscore) return ParseError.InvalidUnderscoreLocation;
            if (has_dot) return ParseError.DoubleRadixDot;
            has_dot = true;
            prev_was_digit = false;
        }
        ch = t.next();
    }
    if (after_underscore) return ParseError.InvalidUnderscoreLocation;
    if (!has_coefficient_digit) return ParseError.NoCoefficientDigit;
    // this path has at least one digit
    if (ch == 'E' or ch == 'e') {
        ch = t.next();
        if (ch == '+' or ch == '-') {
            exp_sign = (ch == '-');
            ch = t.next();
        }
        var has_exp_digit = false;
        var exp_significant_digit_count: usize = 0;
        prev_was_digit = false;
        after_underscore = false;
        while (std.ascii.isDigit(ch) or ch == '_') {
            if (ch == '_') {
                if (!prev_was_digit) return ParseError.InvalidUnderscoreLocation;
                prev_was_digit = false;
                after_underscore = true;
            } else {
                has_exp_digit = true;
                const e_digit: i32 = ch - '0';
                // count while flushing leading zeros
                if (exp_significant_digit_count != 0 or e_digit != 0) exp_significant_digit_count += 1;
                // A long exponent field runs this past the width of an i32; the
                // reference wraps here and so does this, because the value is
                // thrown away by the clamp below the moment the field is more
                // than four significant digits wide.
                exp = (exp *% 10) +% e_digit;
                prev_was_digit = true;
                after_underscore = false;
            }
            ch = t.next();
        }
        if (after_underscore) return ParseError.InvalidUnderscoreLocation;
        if (!has_exp_digit) return ParseError.NoExponentDigit;
        // clamp once after the loop
        if (exp_significant_digit_count > 4) exp = 9999;
    }
    if (ch != 0) return ParseError.UnexpectedChar;

    var dw0 = accum19a;
    var dw1: u64 = 0;
    if (significant_digit_count > 19) {
        const capped = @min(significant_digit_count, 34);
        dw1, dw0 = u128FmaPow10(accum19a, capped - 19, accum19b);
    }

    // Excess digits to the right of the radix point and excess digits beyond the
    // precision limit pull the quantum exponent in opposite directions, so both
    // corrections land here.
    const signed_exp = if (exp_sign) -exp else exp;
    const excess_digits = significant_digit_count -| 34;
    const q_exp = signed_exp - @as(i32, @intCast(fractional_digit_count)) + @as(i32, @intCast(excess_digits));
    return roundAndFinalizeFinite(format_is_bid, sign, q_exp, dw1, dw0, residue);
}

/// Parse Infinity, or its three-letter abbreviation Inf, case-insensitively.
fn parseInfinityText(sign: bool, ch_first: u8, t: *TextCursor) ParseError!struct { u64, u64 } {
    var ch = ch_first;
    var ch_prev_code: u8 = 0;
    for ("infinity") |target_code| {
        if ((ch | 0x20) != target_code) {
            if (ch == 0) break;
            return ParseError.FailureParsingInfinityLetter;
        }
        ch_prev_code = ch | 0x20;
        ch = t.next();
    }
    if (ch != 0 or (ch_prev_code != 'f' and ch_prev_code != 'y')) {
        return ParseError.FailureParsingInfinity;
    }
    const s: u64 = if (sign) SIGN_BIT else 0;
    return .{ INF_PATTERN_HI | s, 0 };
}

/// Parse NaN, qNaN or sNaN, case-insensitively, with an optional payload of
/// decimal digits. A payload of 34 or more digits AS WRITTEN is non-canonical
/// and reads as zero, per IEEE 754-2019 3.5.2.
///
/// The payload may be written bare (NaN123) or enclosed in parentheses
/// (NaN(123)). The parenthesised form is positional and balanced: the '(' must
/// follow the word immediately, at least one digit must appear, and the ')' must
/// be the last character of the input. So NaN(1)2(3), NaN(1, NaN(1] and NaN()
/// are all rejected, and NaN[1] and NaN{1} are not this form at all.
///
/// The full decimal128 ports accept the same spelling; the codecs had it first,
/// and the ports took it on 2026-08-23. It exists because C's own strtod reads
/// NAN(n-char-sequence), so the spelling reaches a caller from the platform
/// itself. The resemblance stops at the parentheses: strtod's sequence is
/// letters, digits and underscores read as an implementation-defined integer,
/// while a decimal128 payload is decimal digits.
fn parseNanText(format_is_bid: bool, sign: bool, ch_first: u8, t: *TextCursor) ParseError!struct { u64, u64 } {
    var ch = ch_first;
    const has_s = (ch | 0x20) == 's';
    const has_q = (ch | 0x20) == 'q';
    if (has_q or has_s) ch = t.next();
    if (((ch | 0x20) != 'n') or ((t.next() | 0x20) != 'a') or ((t.next() | 0x20) != 'n')) {
        return ParseError.FailureParsingNaN;
    }

    var payload_dw0: u64 = 0;
    var payload_dw1: u64 = 0;
    ch = t.next();
    const has_paren = ch == '(';
    if (has_paren) ch = t.next();
    if (has_paren or ch != 0) {
        var accum_digit_count: usize = 0;
        var accum19a: u64 = 0;
        var accum19b: u64 = 0;
        while (std.ascii.isDigit(ch)) {
            const d: u64 = ch - '0';
            // Count every digit written, leading zeros included. The 33-digit
            // limit is a limit on the payload as spelled, not on its significant
            // digits, so "NaN" followed by forty zeros and a one is over the
            // limit and reads as zero. Leading zeros contribute nothing to the
            // accumulators, so the value of a payload within the limit is
            // unaffected -- and an over-limit payload runs the second
            // accumulator past 64 bits, which the reference lets wrap and which
            // the limit test below discards.
            accum_digit_count += 1;
            if (accum_digit_count <= 19) {
                accum19a = (accum19a * 10) + d;
            } else {
                accum19b = (accum19b *% 10) +% d;
            }
            ch = t.next();
        }
        if (accum_digit_count == 0) {
            return if (has_paren) ParseError.FailureParsingNaN else ParseError.NonDigitNaNPayloadCharacter;
        }
        if (has_paren) {
            // the ')' must be present and must end the input
            if (ch != ')') {
                return if (ch == 0) ParseError.FailureParsingNaN else ParseError.NonDigitNaNPayloadCharacter;
            }
            if (t.next() != 0) return ParseError.FailureParsingNaN;
        } else if (ch != 0) {
            return ParseError.NonDigitNaNPayloadCharacter;
        }
        if (accum_digit_count > 33) {
            payload_dw0 = 0;
            payload_dw1 = 0;
        } else {
            payload_dw0 = accum19a;
            payload_dw1 = 0;
            if (accum_digit_count > 19) {
                payload_dw1, payload_dw0 = u128FmaPow10(accum19a, accum_digit_count - 19, accum19b);
            }
        }
    }
    return setNaN(format_is_bid, sign, has_s, payload_dw1, payload_dw0);
}

/// Read the optional sign, then dispatch on the leading character.
fn encodeStringOrError(format_is_bid: bool, bytes: []const u8) ParseError!struct { u64, u64 } {
    var t = TextCursor{ .bytes = bytes };
    const ch_first = t.next();
    var ch = ch_first;
    const sign = ch == '-';
    if (ch == '+' or ch == '-') ch = t.next();
    if (std.ascii.isDigit(ch) or ch == '.') {
        return parseFiniteValueText(format_is_bid, sign, ch, &t);
    }
    const ch_lower = ch | 0x20;
    if (ch_lower == 'i') return parseInfinityText(sign, ch, &t);
    if (ch_lower == 'n' or ch_lower == 's' or ch_lower == 'q') {
        return parseNanText(format_is_bid, sign, ch, &t);
    }
    if (ch_first == 0) return ParseError.EmptyString;
    return ParseError.InvalidFormat;
}

// --------------------------------------------------------------------------
// The published surface
// --------------------------------------------------------------------------

/// The canonical positive quiet NaN.
///
/// The sibling ports write this into their out-parameter when a parse fails, so
/// that a caller who ignores the failure still holds a legal IEEE 754-2019
/// datum. Here the error union makes that impossible to need -- but the constant
/// is what a caller wanting the same behaviour reaches for:
/// `bid128Parse(text) catch qnan`. It is the same bit pattern in both formats.
pub const qnan: u128 = @as(u128, QNAN_PATTERN_HI) << 64;

/// Render a BID128 encoding as a decimal character sequence.
///
/// Writes into the caller's buffer and returns the slice of it that was
/// written. Nothing is allocated, and the slice is valid for as long as `out`
/// is. The buffer is `*[max_len]u8` rather than `[]u8` so that its size is
/// checked
/// at compile time; there is no runtime failure mode and no error union.
///
/// This cannot fail. Every 128-bit pattern renders: canonical encodings produce
/// their natural form, and a non-canonical BID coefficient (>= 10^34) renders as
/// zero at the encoded exponent per IEEE 754-2019 3.5.2.
///
/// The output is the GDAS to-scientific-string form. It preserves cohort
/// information -- "1.00" and "1.0" are distinct outputs from distinct encodings
/// of the same numerical value -- and always writes the exponent sign, as in
/// "6.02E+23".
pub fn bid128ToString(out: *[max_len]u8, bits: u128) []const u8 {
    const n = decodeBid128toString(out, hiWord(bits), loWord(bits));
    return out[0..n];
}

/// Render a DPD128 encoding as a decimal character sequence.
///
/// The peer of `bid128ToString`: DPD128 carries the same sign, the same 14-bit
/// biased exponent and the same 34-digit coefficient, and differs only in
/// storing that coefficient as a leading digit plus eleven 10-bit declets rather
/// than as a binary integer. Peer encodings of the same value render to
/// identical text. This cannot fail.
pub fn dpd128ToString(out: *[max_len]u8, bits: u128) []const u8 {
    const n = decodeDpd128toString(out, hiWord(bits), loWord(bits));
    return out[0..n];
}

/// Parse a decimal character sequence into a BID128 encoding.
///
/// Accepted: plain and scientific notation with either 'E' or 'e'; a leading '+'
/// or '-'; '_' digit separators between two digits; and the case-insensitive
/// words Infinity, Inf, NaN, qNaN and sNaN, each with an optional sign and an
/// optional NaN payload of decimal digits.
///
/// A NaN payload may also be parenthesised -- NaN(123) as well as NaN123. The
/// form is positional and balanced: '(' immediately after the word, at least one
/// digit, ')' last; NaN(), NaN(1, NaN(1)2(3), NaN[1] and NaN{1} are rejected.
/// Rendering never emits parentheses. The full decimal128 ports accept the same
/// spelling.
///
/// More than 34 significant digits round to 34, ties-to-even. Magnitudes above
/// the representable range become Infinity; magnitudes below it become a
/// subnormal or zero. None of those are failures -- failures are structural: an
/// empty sequence, unrecognized characters, missing digits around the radix
/// point, a malformed exponent field.
///
/// On failure the sibling ports write the canonical positive quiet NaN so a
/// caller who ignores the failure still holds a legal datum; here the error
/// union makes that unnecessary, and `qnan` is available for a caller who wants
/// the same behaviour explicitly: `bid128Parse(text) catch qnan`.
pub fn bid128Parse(text: []const u8) ParseError!u128 {
    const hi, const lo = try encodeStringOrError(true, text);
    return joinWords(hi, lo);
}

/// Parse a decimal character sequence into a DPD128 encoding.
///
/// The peer of `bid128Parse`: identical grammar, identical rounding and
/// identical failures -- the two differ only in the encoding produced.
pub fn dpd128Parse(text: []const u8) ParseError!u128 {
    const hi, const lo = try encodeStringOrError(false, text);
    return joinWords(hi, lo);
}
