///|
/// X25519 Elliptic Curve Diffie-Hellman
/// Based on Curve25519 - fast and secure key exchange
/// Reference: RFC 7748

///|
/// Prime p = 2^255 - 19 (represented as 4 limbs)
/// Last limb is 0x7FFFFFFFFFFFFFFF (2^63 - 1)
fn get_p() -> FixedArray[UInt64] {
  [0xFFFFFFFFFFFFFFEDUL, 0xFFFFFFFFFFFFFFFFUL, 0xFFFFFFFFFFFFFFFFUL, 0x7FFFFFFFFFFFFFFFUL]
}

///|
/// X25519 base point (u = 9)
fn get_basepoint() -> Bytes {
  b"\x09\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
}

///|
/// Field element representation (4 x 64-bit limbs)
priv struct Fe {
  l : FixedArray[UInt64]
}

///|
fn Fe::new() -> Fe {
  { l: FixedArray::make(4, 0UL) }
}

///|
fn Fe::from_array(arr : Array[UInt64]) -> Fe {
  let fe = Fe::new()
  for i = 0; i < 4 && i < arr.length(); i = i + 1 {
    fe.l[i] = arr[i]
  }
  fe
}

///|
fn Fe::copy(self : Fe) -> Fe {
  let fe = Fe::new()
  for i = 0; i < 4; i = i + 1 {
    fe.l[i] = self.l[i]
  }
  fe
}

///|
fn Fe::set_one(self : Fe) -> Unit {
  self.l[0] = 1UL
  self.l[1] = 0UL
  self.l[2] = 0UL
  self.l[3] = 0UL
}

///|
fn Fe::set_zero(self : Fe) -> Unit {
  self.l[0] = 0UL
  self.l[1] = 0UL
  self.l[2] = 0UL
  self.l[3] = 0UL
}

///|
/// Add two field elements: r = a + b mod p
fn fe_add(a : Fe, b : Fe) -> Fe {
  let r = Fe::new()
  let mut carry = 0UL
  for i = 0; i < 4; i = i + 1 {
    let sum = a.l[i] + b.l[i] + carry
    carry = if sum < a.l[i] || (carry > 0UL && sum <= a.l[i]) { 1UL } else { 0UL }
    r.l[i] = sum
  }
  fe_reduce(r)
}

///|
/// Subtract field elements: r = a - b mod p
fn fe_sub(a : Fe, b : Fe) -> Fe {
  let r = Fe::new()
  let p = get_p()
  let mut borrow = 0UL
  for i = 0; i < 4; i = i + 1 {
    let diff = a.l[i] - b.l[i] - borrow
    borrow = if a.l[i] < b.l[i] + borrow { 1UL } else { 0UL }
    r.l[i] = diff
  }
  if borrow > 0UL {
    let mut carry = 0UL
    for i = 0; i < 4; i = i + 1 {
      let sum = r.l[i] + p[i] + carry
      carry = if sum < r.l[i] { 1UL } else { 0UL }
      r.l[i] = sum
    }
  }
  r
}

///|
/// Reduce mod p
fn fe_reduce(a : Fe) -> Fe {
  let p = get_p()
  let mut gte = true
  for i = 3; i >= 0; i = i - 1 {
    if a.l[i] < p[i] {
      gte = false
      break
    } else if a.l[i] > p[i] {
      break
    }
  }
  if gte {
    let mut borrow = 0UL
    for i = 0; i < 4; i = i + 1 {
      let diff = a.l[i] - p[i] - borrow
      borrow = if a.l[i] < p[i] + borrow { 1UL } else { 0UL }
      a.l[i] = diff
    }
  }
  a
}

///|
/// Multiply 64-bit values and return 128-bit result as (low, high)
fn mul64(a : UInt64, b : UInt64) -> (UInt64, UInt64) {
  let a_lo = a & 0xFFFFFFFFUL
  let a_hi = a >> 32
  let b_lo = b & 0xFFFFFFFFUL
  let b_hi = b >> 32
  let p0 = a_lo * b_lo
  let p1 = a_lo * b_hi
  let p2 = a_hi * b_lo
  let p3 = a_hi * b_hi
  let mid = p1 + (p0 >> 32)
  let mid2 = mid + p2
  let carry = if mid2 < mid { 1UL << 32 } else { 0UL }
  let lo = (p0 & 0xFFFFFFFFUL) | (mid2 << 32)
  let hi = p3 + (mid2 >> 32) + carry
  (lo, hi)
}

///|
/// Multiply field elements: r = a * b mod p
fn fe_mul(a : Fe, b : Fe) -> Fe {
  let t = FixedArray::make(8, 0UL)
  for i = 0; i < 4; i = i + 1 {
    let mut carry = 0UL
    for j = 0; j < 4; j = j + 1 {
      let (lo, hi) = mul64(a.l[i], b.l[j])
      let sum1 = t[i + j] + lo
      let c1 = if sum1 < t[i + j] { 1UL } else { 0UL }
      let sum2 = sum1 + carry
      let c2 = if sum2 < sum1 { 1UL } else { 0UL }
      t[i + j] = sum2
      carry = hi + c1 + c2
    }
    t[i + 4] = t[i + 4] + carry
  }

  let r = Fe::new()
  let mut carry = 0UL
  for i = 0; i < 4; i = i + 1 {
    let (lo, hi) = mul64(t[i + 4], 38UL)
    let sum1 = t[i] + lo + carry
    let c1 = if sum1 < t[i] || (carry > 0UL && sum1 <= t[i]) { 1UL } else { 0UL }
    r.l[i] = sum1
    carry = hi + c1
  }

  while carry > 0UL {
    let (lo, _) = mul64(carry, 38UL)
    carry = 0UL
    for i = 0; i < 4; i = i + 1 {
      let sum = r.l[i] + (if i == 0 { lo } else { 0UL })
      if sum < r.l[i] {
        carry = 1UL
      }
      r.l[i] = sum
      if carry == 0UL {
        break
      }
      carry = 0UL
    }
  }

  fe_reduce(r)
}

///|
/// Square a field element
fn fe_sq(a : Fe) -> Fe {
  fe_mul(a, a)
}

///|
/// Compute a^(2^n) by repeated squaring
fn fe_sq_times(a : Fe, n : Int) -> Fe {
  let mut r = a.copy()
  for i = 0; i < n; i = i + 1 {
    r = fe_sq(r)
  }
  r
}

///|
/// Compute modular inverse using Fermat's little theorem
fn fe_inv(a : Fe) -> Fe {
  let a2 = fe_sq(a)
  let a4 = fe_sq(a2)
  let a8 = fe_sq(a4)
  let a9 = fe_mul(a8, a)
  let a11 = fe_mul(a9, a2)
  let a22 = fe_sq(a11)
  let a_2_5_0 = fe_mul(a22, a9)
  let a_2_10_0 = fe_sq_times(a_2_5_0, 5)
  let a_2_10_5_0 = fe_mul(a_2_10_0, a_2_5_0)
  let a_2_20_0 = fe_sq_times(a_2_10_5_0, 10)
  let a_2_20_10_0 = fe_mul(a_2_20_0, a_2_10_5_0)
  let a_2_40_0 = fe_sq_times(a_2_20_10_0, 20)
  let a_2_40_20_0 = fe_mul(a_2_40_0, a_2_20_10_0)
  let a_2_50_0 = fe_sq_times(a_2_40_20_0, 10)
  let a_2_50_10_0 = fe_mul(a_2_50_0, a_2_10_5_0)
  let a_2_100_0 = fe_sq_times(a_2_50_10_0, 50)
  let a_2_100_50_0 = fe_mul(a_2_100_0, a_2_50_10_0)
  let a_2_200_0 = fe_sq_times(a_2_100_50_0, 100)
  let a_2_200_100_0 = fe_mul(a_2_200_0, a_2_100_50_0)
  let a_2_250_0 = fe_sq_times(a_2_200_100_0, 50)
  let a_2_250_50_0 = fe_mul(a_2_250_0, a_2_50_10_0)
  let a_2_255_5_0 = fe_sq_times(a_2_250_50_0, 5)
  fe_mul(a_2_255_5_0, a11)
}

///|
/// Convert 32 bytes to field element (little-endian)
fn fe_from_bytes(b : Bytes) -> Fe {
  let fe = Fe::new()
  for i = 0; i < 4; i = i + 1 {
    let mut v = 0UL
    for j = 0; j < 8; j = j + 1 {
      let idx = i * 8 + j
      if idx < b.length() {
        v = v | (b[idx].to_uint64() << (j * 8))
      }
    }
    fe.l[i] = v
  }
  fe.l[3] = fe.l[3] & 0x7FFFFFFFFFFFFFFFUL
  fe
}

///|
/// Convert field element to 32 bytes (little-endian)
fn fe_to_bytes(fe : Fe) -> Bytes {
  let reduced = fe_reduce(fe.copy())
  let b = FixedArray::make(32, b'\x00')
  for i = 0; i < 4; i = i + 1 {
    for j = 0; j < 8; j = j + 1 {
      b[i * 8 + j] = ((reduced.l[i] >> (j * 8)) & 0xFFUL).to_byte()
    }
  }
  Bytes::from_array(b)
}

///|
/// Montgomery ladder for scalar multiplication
fn montgomery_ladder(k : Bytes, u : Fe) -> Fe {
  let x1 = u.copy()
  let mut x2 = Fe::new()
  x2.set_one()
  let mut z2 = Fe::new()
  z2.set_zero()
  let mut x3 = u.copy()
  let mut z3 = Fe::new()
  z3.set_one()
  let mut swap = 0UL

  for t = 254; t >= 0; t = t - 1 {
    let byte_idx = t / 8
    let bit_idx = t % 8
    let kt = if byte_idx < k.length() {
      ((k[byte_idx].to_uint64() >> bit_idx) & 1UL)
    } else {
      0UL
    }

    let swap_bit = swap ^ kt
    if swap_bit != 0UL {
      let tmp = x2.copy()
      x2 = x3.copy()
      x3 = tmp
      let tmp2 = z2.copy()
      z2 = z3.copy()
      z3 = tmp2
    }
    swap = kt

    let a = fe_add(x2, z2)
    let aa = fe_sq(a)
    let b = fe_sub(x2, z2)
    let bb = fe_sq(b)
    let e = fe_sub(aa, bb)
    let c = fe_add(x3, z3)
    let d = fe_sub(x3, z3)
    let da = fe_mul(d, a)
    let cb = fe_mul(c, b)
    let sum = fe_add(da, cb)
    let diff = fe_sub(da, cb)
    x3 = fe_sq(sum)
    z3 = fe_mul(x1, fe_sq(diff))
    x2 = fe_mul(aa, bb)
    let a24 = Fe::from_array([121665UL, 0UL, 0UL, 0UL])
    z2 = fe_mul(e, fe_add(aa, fe_mul(a24, e)))
  }

  if swap != 0UL {
    let tmp = x2.copy()
    x2 = x3.copy()
    x3 = tmp
    let tmp2 = z2.copy()
    z2 = z3.copy()
    z3 = tmp2
  }

  fe_mul(x2, fe_inv(z2))
}

///|
/// Clamp a 32-byte scalar for X25519
fn clamp_scalar(k : Bytes) -> Bytes {
  let clamped = FixedArray::make(32, b'\x00')
  for i = 0; i < 32 && i < k.length(); i = i + 1 {
    clamped[i] = k[i]
  }
  clamped[0] = clamped[0] & b'\xF8'
  clamped[31] = (clamped[31] & b'\x7F') | b'\x40'
  Bytes::from_array(clamped)
}

///|
/// Generate a random 32-byte private key
pub fn generate_private_key() -> Bytes {
  let seed = FixedArray::make(32, b'\x00')
  let t = @env.now()
  for i = 0; i < 8; i = i + 1 {
    seed[i] = ((t >> (i * 8)) & 0xFFUL).to_byte()
  }
  for i = 8; i < 32; i = i + 1 {
    seed[i] = ((i * 17 + 31) % 256).to_byte()
  }
  let hash = @crypto.sha256(Bytes::from_array(seed))
  clamp_scalar(Bytes::from_array(hash))
}

///|
/// Compute public key from private key
pub fn compute_public_key(private_key : Bytes) -> Bytes {
  let k = clamp_scalar(private_key)
  let u = fe_from_bytes(get_basepoint())
  let result = montgomery_ladder(k, u)
  fe_to_bytes(result)
}

///|
/// Compute shared secret from private key and peer's public key
pub fn compute_shared_secret(private_key : Bytes, peer_public_key : Bytes) -> Bytes {
  let k = clamp_scalar(private_key)
  let u = fe_from_bytes(peer_public_key)
  let result = montgomery_ladder(k, u)
  fe_to_bytes(result)
}

///|
/// Generate a key pair (private_key, public_key)
pub fn generate_keypair() -> (Bytes, Bytes) {
  let private_key = generate_private_key()
  let public_key = compute_public_key(private_key)
  (private_key, public_key)
}
