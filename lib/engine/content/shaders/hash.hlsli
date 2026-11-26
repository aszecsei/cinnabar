// Integer hashes that the shaders share. lowbias32 matches split_hash in lib/engine/render/gi_split.odin.
#ifndef HASH_HLSLI
#define HASH_HLSLI

// lowbias32 is Chris Wellons' 32-bit integer hash: a key's place in a table, or the next state of a random sequence.
uint lowbias32(uint x) {
	x ^= x >> 16;
	x *= 0x7feb352du;
	x ^= x >> 15;
	x *= 0x846ca68bu;
	x ^= x >> 16;
	return x;
}

// random_unit is a number in [0, 1) from a random sequence's state, which it moves on.
float random_unit(inout uint state) {
	state = lowbias32(state + 0x9e3779b9u);
	return float(state >> 8) * (1.0 / 16777216.0);
}

#endif
