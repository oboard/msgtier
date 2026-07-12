///|
/// I1-I2: Implicit Level Calculation
///
/// These rules adjust embedding levels based on resolved types.

///|
/// Apply implicit level rules
fn apply_implicit_levels(
  types : Array[@bidi_data.BidiClass],
  levels : Array[Int],
) -> Unit {
  for i = 0; i < types.length(); i = i + 1 {
    let bc = types[i]
    let level = levels[i]

    // Skip removed characters (BN)
    if bc == @bidi_data.BidiClass::BN {
      continue
    }

    // I1: For characters at even (LTR) levels
    // R -> level + 1
    // AN, EN -> level + 2
    if level % 2 == 0 {
      match bc {
        R => levels[i] = level + 1
        AN | EN => levels[i] = level + 2
        _ => ()
      }
    } else {
      // I2: For characters at odd (RTL) levels
      // L, EN, AN -> level + 1
      match bc {
        L | EN | AN => levels[i] = level + 1
        _ => ()
      }
    }
  }
}
