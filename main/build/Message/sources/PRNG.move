module Sender::PRNG {
    // Implements an XOR shift PRNG

    struct XORShift has drop {
        seed: u64,
    }

    public fun create(seed: u64): XORShift {
        XORShift { seed }
    }


    public fun generate(state: &mut XORShift): u64 {
        let x = *&state.seed;
        x = x ^ (x << 13);
        x = x ^ (x >> 7);
        x = x ^ (x << 17);
        state.seed = x;
        x
    }
}
