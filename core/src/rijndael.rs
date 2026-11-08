//! Rijndael with a 256-bit block and a 256-bit key (14 rounds), the cipher the
//! game uses for its saves. This is not AES, which fixes the block at 128 bits.
//! Only decryption is needed.

const NB: usize = 8;
const NK: usize = 8;
const ROUNDS: usize = 14;
const SHIFT: [usize; 4] = [0, 1, 3, 4];

pub struct Rijndael256 {
    round_keys: Vec<u8>,
}

struct Tables {
    sbox: [u8; 256],
    inv: [u8; 256],
}

fn tables() -> &'static Tables {
    static TABLES: std::sync::OnceLock<Tables> = std::sync::OnceLock::new();
    TABLES.get_or_init(|| {
        let mut sbox = [0u8; 256];
        let (mut p, mut q) = (1u8, 1u8);
        loop {
            p = p ^ (p << 1) ^ if p & 0x80 != 0 { 0x1b } else { 0 };
            q ^= q << 1;
            q ^= q << 2;
            q ^= q << 4;
            if q & 0x80 != 0 {
                q ^= 0x09;
            }
            sbox[p as usize] = q ^ q.rotate_left(1) ^ q.rotate_left(2) ^ q.rotate_left(3) ^ q.rotate_left(4) ^ 0x63;
            if p == 1 {
                break;
            }
        }
        sbox[0] = 0x63;
        let mut inv = [0u8; 256];
        for (i, &value) in sbox.iter().enumerate() {
            inv[value as usize] = i as u8;
        }
        Tables { sbox, inv }
    })
}

fn xtime(a: u8) -> u8 {
    (a << 1) ^ if a & 0x80 != 0 { 0x1b } else { 0 }
}

fn mul(mut a: u8, mut b: u8) -> u8 {
    let mut result = 0;
    while b > 0 {
        if b & 1 != 0 {
            result ^= a;
        }
        a = xtime(a);
        b >>= 1;
    }
    result
}

impl Rijndael256 {
    pub fn new(key: &[u8; 32]) -> Self {
        let sbox = &tables().sbox;
        let words = (ROUNDS + 1) * NB;
        let mut w = vec![0u8; words * 4];
        w[..32].copy_from_slice(key);
        let mut rcon = 1u8;
        for i in NK..words {
            let mut temp = [0u8; 4];
            temp.copy_from_slice(&w[(i - 1) * 4..i * 4]);
            if i % NK == 0 {
                temp = [sbox[temp[1] as usize] ^ rcon, sbox[temp[2] as usize], sbox[temp[3] as usize], sbox[temp[0] as usize]];
                rcon = xtime(rcon);
            } else if i % NK == 4 {
                for byte in &mut temp {
                    *byte = sbox[*byte as usize];
                }
            }
            for j in 0..4 {
                w[i * 4 + j] = w[(i - NK) * 4 + j] ^ temp[j];
            }
        }
        Self { round_keys: w }
    }

    fn add_round_key(&self, state: &mut [u8; 32], round: usize) {
        let base = round * NB * 4;
        for (i, byte) in state.iter_mut().enumerate() {
            *byte ^= self.round_keys[base + i];
        }
    }

    fn inv_shift_rows(state: &mut [u8; 32]) {
        let copy = *state;
        for r in 1..4 {
            for c in 0..NB {
                state[((c + SHIFT[r]) % NB) * 4 + r] = copy[c * 4 + r];
            }
        }
    }

    fn inv_sub_bytes(state: &mut [u8; 32]) {
        let inv = &tables().inv;
        for byte in state.iter_mut() {
            *byte = inv[*byte as usize];
        }
    }

    fn inv_mix_columns(state: &mut [u8; 32]) {
        for c in 0..NB {
            let [a0, a1, a2, a3] = [state[c * 4], state[c * 4 + 1], state[c * 4 + 2], state[c * 4 + 3]];
            state[c * 4] = mul(a0, 14) ^ mul(a1, 11) ^ mul(a2, 13) ^ mul(a3, 9);
            state[c * 4 + 1] = mul(a0, 9) ^ mul(a1, 14) ^ mul(a2, 11) ^ mul(a3, 13);
            state[c * 4 + 2] = mul(a0, 13) ^ mul(a1, 9) ^ mul(a2, 14) ^ mul(a3, 11);
            state[c * 4 + 3] = mul(a0, 11) ^ mul(a1, 13) ^ mul(a2, 9) ^ mul(a3, 14);
        }
    }

    pub fn decrypt_block(&self, block: &mut [u8; 32]) {
        self.add_round_key(block, ROUNDS);
        for round in (1..ROUNDS).rev() {
            Self::inv_shift_rows(block);
            Self::inv_sub_bytes(block);
            self.add_round_key(block, round);
            Self::inv_mix_columns(block);
        }
        Self::inv_shift_rows(block);
        Self::inv_sub_bytes(block);
        self.add_round_key(block, 0);
    }

    /// CBC decryption of whole 32-byte blocks.
    pub fn decrypt_cbc(&self, data: &[u8], iv: &[u8; 32]) -> Option<Vec<u8>> {
        if data.len() % 32 != 0 {
            return None;
        }
        let mut out = Vec::with_capacity(data.len());
        let mut previous = *iv;
        for chunk in data.chunks_exact(32) {
            let mut block: [u8; 32] = chunk.try_into().ok()?;
            self.decrypt_block(&mut block);
            for i in 0..32 {
                block[i] ^= previous[i];
            }
            out.extend_from_slice(&block);
            previous.copy_from_slice(chunk);
        }
        Some(out)
    }
}
