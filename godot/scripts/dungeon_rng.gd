class_name DungeonRng
extends RefCounted

## mulberry32 PRNG, ported bit-for-bit from the JS prototype (index.html).
## GDScript ints are 64-bit, so every step is masked back to unsigned 32-bit and
## 32-bit integer multiply is emulated with the classic 16x16 split (Math.imul).
## Given the same seed this reproduces the same stream as the web version.

var _a: int = 0

func _init(seed_value: int) -> void:
	_a = seed_value & 0xFFFFFFFF

## Low 32 bits of a 32-bit x 32-bit multiply (equivalent to JS Math.imul).
static func imul(a: int, b: int) -> int:
	a &= 0xFFFFFFFF
	b &= 0xFFFFFFFF
	var ah := (a >> 16) & 0xFFFF
	var al := a & 0xFFFF
	var bh := (b >> 16) & 0xFFFF
	var bl := b & 0xFFFF
	var lo := al * bl
	var mid := (((ah * bl + al * bh) & 0xFFFFFFFF) << 16)
	return (lo + mid) & 0xFFFFFFFF

## next float in [0, 1)
func next() -> float:
	_a = (_a + 0x6D2B79F5) & 0xFFFFFFFF
	var t := _a
	t = imul(t ^ (t >> 15), 1 | t) & 0xFFFFFFFF
	t = (((t + imul(t ^ (t >> 7), 61 | t)) & 0xFFFFFFFF) ^ t) & 0xFFFFFFFF
	t = (t ^ (t >> 14)) & 0xFFFFFFFF
	return float(t) / 4294967296.0

## float in [lo, hi)
func rf(lo: float, hi: float) -> float:
	return lo + (hi - lo) * next()

## integer in [lo, hi] inclusive
func ri(lo: int, hi: int) -> int:
	return lo + int(next() * (hi - lo + 1))

## uniform element of a non-empty array
func pick(arr: Array):
	return arr[int(next() * arr.size())]

## true with probability p
func chance(p: float) -> bool:
	return next() < p

## Box-Muller, no cached spare (always consumes exactly two draws) so the
## consumption order stays trivially deterministic.
func gaussian(mu: float, sigma: float) -> float:
	var u1: float = max(next(), 1e-12)
	var u2 := next()
	return mu + sigma * sqrt(-2.0 * log(u1)) * cos(TAU * u2)
