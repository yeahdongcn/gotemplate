///|
/// One formatting directive: the flags, width and precision between `%`
/// and the verb. A width or precision of -1 means it was not given.
priv struct Spec {
  mut minus : Bool
  mut plus : Bool
  mut sharp : Bool
  mut space : Bool
  mut zero : Bool
  mut width : Int32
  mut prec : Int32
}

///|
/// Go's `fmt.Sprintf` for the value types templates can hold.
fn sprintf(format : String, args : Array[Value]) -> String {
  let out = StringBuilder()
  let chars = format.to_array()
  let n = chars.length()
  let mut i = 0
  let mut arg = 0
  while i < n {
    let c = chars[i]
    i = i + 1
    if c != '%' {
      out.write_char(c)
      continue
    }
    let spec : Spec = {
      minus: false,
      plus: false,
      sharp: false,
      space: false,
      zero: false,
      width: -1,
      prec: -1,
    }
    while i < n {
      match chars[i] {
        '-' => spec.minus = true
        '+' => spec.plus = true
        '#' => spec.sharp = true
        ' ' => spec.space = true
        '0' => spec.zero = true
        _ => break
      }
      i = i + 1
    }
    let mut bad = ""
    // width
    if i < n && chars[i] == '*' {
      i = i + 1
      if arg < args.length() && args[arg] is Int(w) {
        spec.width = w.to_int()
        if spec.width < 0 {
          spec.minus = true
          spec.width = -spec.width
        }
      } else {
        bad = "%!(BADWIDTH)"
      }
      arg = arg + 1
    } else {
      while i < n && is_digit(chars[i]) {
        if spec.width < 0 {
          spec.width = 0
        }
        spec.width = spec.width * 10 + (chars[i].to_int() - '0'.to_int())
        i = i + 1
      }
    }
    // precision; a dot that ends the format is taken as the verb instead
    if i + 1 < n && chars[i] == '.' {
      i = i + 1
      spec.prec = 0
      if i < n && chars[i] == '*' {
        i = i + 1
        if arg < args.length() && args[arg] is Int(p) && p >= 0L {
          spec.prec = p.to_int()
        } else {
          spec.prec = -1
          bad = "%!(BADPREC)"
        }
        arg = arg + 1
      } else {
        while i < n && is_digit(chars[i]) {
          spec.prec = spec.prec * 10 + (chars[i].to_int() - '0'.to_int())
          i = i + 1
        }
      }
    }
    out.write_string(bad)
    if i >= n {
      out.write_string("%!(NOVERB)")
      break
    }
    let verb = chars[i]
    i = i + 1
    if verb == '%' {
      out.write_char('%')
      continue
    }
    if arg >= args.length() {
      out.write_string("%!")
      out.write_char(verb)
      out.write_string("(MISSING)")
      continue
    }
    format_arg(out, spec, verb, args[arg])
    arg = arg + 1
  }
  if arg < args.length() {
    out.write_string("%!(EXTRA ")
    for j in arg..<args.length() {
      if j > arg {
        out.write_string(", ")
      }
      write_typed(out, args[j])
    }
    out.write_char(')')
  }
  out.to_string()
}

///|
/// `type=value`, as used in fmt's error annotations.
fn write_typed(out : StringBuilder, v : Value) -> Unit {
  if is_nil(v) {
    out.write_string("<nil>")
  } else {
    out.write_string(type_name(v))
    out.write_char('=')
    format_value(v, out)
  }
}

///|
fn bad_verb(out : StringBuilder, verb : Char, v : Value) -> Unit {
  out.write_string("%!")
  out.write_char(verb)
  out.write_char('(')
  write_typed(out, v)
  out.write_char(')')
}

///|
fn pad(out : StringBuilder, spec : Spec, text : String, zero_ok : Bool) -> Unit {
  let length = text.char_length()
  if spec.width <= length {
    out.write_string(text)
    return
  }
  let fill = spec.width - length
  if spec.minus {
    out.write_string(text)
    for _ in 0..<fill {
      out.write_char(' ')
    }
  } else {
    let c = if spec.zero && zero_ok { '0' } else { ' ' }
    for _ in 0..<fill {
      out.write_char(c)
    }
    out.write_string(text)
  }
}

///|
fn truncate_runes(s : String, spec : Spec) -> String {
  if spec.prec >= 0 && s.char_length() > spec.prec {
    String::from_array(s.to_array()[:spec.prec])
  } else {
    s
  }
}

///|
fn format_arg(out : StringBuilder, spec : Spec, verb : Char, v : Value) -> Unit {
  if verb == 'T' {
    pad(out, spec, if is_nil(v) { "<nil>" } else { type_name(v) }, true)
    return
  }
  match v {
    Nil =>
      if verb == 'v' {
        pad(out, spec, "<nil>", false)
      } else {
        bad_verb(out, verb, v)
      }
    Bool(b) =>
      if verb == 'v' || verb == 't' {
        pad(out, spec, if b { "true" } else { "false" }, false)
      } else {
        bad_verb(out, verb, v)
      }
    Int(i) =>
      match verb {
        'v' | 'd' => format_int(out, spec, i, 10, verb)
        'b' => format_int(out, spec, i, 2, verb)
        'o' | 'O' => format_int(out, spec, i, 8, verb)
        'x' | 'X' => format_int(out, spec, i, 16, verb)
        'c' => pad(out, spec, rune_text(i), false)
        'q' => pad(out, spec, quote_rune(i), false)
        'U' => format_unicode(out, spec, i)
        _ => bad_verb(out, verb, v)
      }
    Float(f) =>
      match verb {
        'v' | 'g' | 'G' | 'e' | 'E' | 'f' | 'F' =>
          format_float(out, spec, f, verb)
        _ => bad_verb(out, verb, v)
      }
    Str(s) =>
      match verb {
        'v' | 's' => pad(out, spec, truncate_runes(s, spec), true)
        'q' => {
          let t = truncate_runes(s, spec)
          let quoted = if spec.sharp && !t.contains_char('`') {
            "`" + t + "`"
          } else {
            quote_string(t)
          }
          pad(out, spec, quoted, true)
        }
        'x' | 'X' => {
          let digits = if verb == 'x' { HEX_LOWER } else { HEX_UPPER }
          let hex = StringBuilder()
          if spec.sharp && s.length() > 0 {
            hex.write_string(if verb == 'x' { "0x" } else { "0X" })
          }
          let bytes = utf8_encode(s)
          let count = if spec.prec >= 0 && spec.prec < bytes.length() {
            spec.prec
          } else {
            bytes.length()
          }
          for j in 0..<count {
            hex.write_char(hex_digit(digits, bytes[j] / 16))
            hex.write_char(hex_digit(digits, bytes[j] % 16))
          }
          pad(out, spec, hex.to_string(), true)
        }
        _ => bad_verb(out, verb, v)
      }
    List(items) => {
      out.write_char('[')
      for j, item in items {
        if j > 0 {
          out.write_char(' ')
        }
        format_arg(out, spec, verb, item)
      }
      out.write_char(']')
    }
    Dict(d) => {
      out.write_string("map[")
      for j, key in sorted_keys(d) {
        if j > 0 {
          out.write_char(' ')
        }
        format_arg(out, spec, verb, Str(key))
        out.write_char(':')
        format_arg(out, spec, verb, d[key])
      }
      out.write_char(']')
    }
  }
}

///|
fn rune_text(code : Int64) -> String {
  let valid = code >= 0L &&
    code <= 0x10FFFFL &&
    !(code >= 0xD800L && code <= 0xDFFFL)
  (if valid { code.to_int() } else { 0xFFFD }).unsafe_to_char().to_string()
}

///|
fn write_escaped(out : StringBuilder, c : Char, quote : Char) -> Unit {
  let code = c.to_int()
  if c == quote || c == '\\' {
    out.write_char('\\')
    out.write_char(c)
    return
  }
  match code {
    7 => out.write_string("\\a")
    8 => out.write_string("\\b")
    9 => out.write_string("\\t")
    10 => out.write_string("\\n")
    11 => out.write_string("\\v")
    12 => out.write_string("\\f")
    13 => out.write_string("\\r")
    _ =>
      if code < 0x20 || code == 0x7F {
        out.write_string("\\x")
        out.write_char(hex_digit(HEX_LOWER, code / 16))
        out.write_char(hex_digit(HEX_LOWER, code % 16))
      } else {
        out.write_char(c)
      }
  }
}

///|
fn quote_string(s : String) -> String {
  let out = StringBuilder()
  out.write_char('"')
  for c in s {
    write_escaped(out, c, '"')
  }
  out.write_char('"')
  out.to_string()
}

///|
fn quote_rune(code : Int64) -> String {
  let out = StringBuilder()
  out.write_char('\'')
  for c in rune_text(code) {
    write_escaped(out, c, '\'')
  }
  out.write_char('\'')
  out.to_string()
}

///|
fn format_unicode(out : StringBuilder, spec : Spec, code : Int64) -> Unit {
  let text = StringBuilder()
  text.write_string("U+")
  let hex = code.reinterpret_as_uint64().to_string(radix=16).to_upper()
  let min = if spec.prec > 4 { spec.prec } else { 4 }
  for _ in 0..<(min - hex.length()) {
    text.write_char('0')
  }
  text.write_string(hex)
  if spec.sharp && code >= 0x20L && code <= 0x10FFFFL {
    text.write_string(" '")
    text.write_string(rune_text(code))
    text.write_char('\'')
  }
  pad(out, spec, text.to_string(), false)
}

///|
fn format_int(
  out : StringBuilder,
  spec : Spec,
  value : Int64,
  base : Int32,
  verb : Char,
) -> Unit {
  let negative = value < 0L
  let magnitude = if negative {
    0UL - value.reinterpret_as_uint64()
  } else {
    value.reinterpret_as_uint64()
  }
  let mut digits = magnitude.to_string(radix=base)
  if verb == 'X' {
    digits = digits.to_upper()
  }
  // A zero-padded width is a minimum digit count that leaves room for the sign.
  let mut min_digits = spec.prec
  if spec.prec < 0 && spec.zero && !spec.minus && spec.width >= 0 {
    min_digits = spec.width
    if negative || spec.plus || spec.space {
      min_digits = min_digits - 1
    }
  }
  if spec.prec == 0 && value == 0L {
    digits = ""
  }
  let text = StringBuilder()
  if negative {
    text.write_char('-')
  } else if spec.plus {
    text.write_char('+')
  } else if spec.space {
    text.write_char(' ')
  }
  let mut prefix = ""
  if verb == 'O' {
    prefix = "0o"
  } else if spec.sharp {
    match base {
      2 => prefix = "0b"
      8 => if !digits.has_prefix("0") { prefix = "0" }
      16 => prefix = if verb == 'X' { "0X" } else { "0x" }
      _ => ()
    }
  }
  // the leading zero that marks octal counts as a digit
  let counted = if prefix == "0" {
    digits.length() + 1
  } else {
    digits.length()
  }
  text.write_string(prefix)
  for _ in 0..<(min_digits - counted) {
    text.write_char('0')
  }
  text.write_string(digits)
  pad(out, spec, text.to_string(), false)
}

///|
fn big(n : Int32) -> @bigint.BigInt {
  @bigint.BigInt::from_int64(n.to_int64())
}

///|
/// `|f| * 10^k` rounded to the nearest integer, ties to even, computed
/// exactly from the binary representation of `f` (finite and non-zero).
fn scaled_round(f : Double, k : Int32) -> @bigint.BigInt {
  let bits = f.abs().reinterpret_as_int64()
  let fraction = bits & 0xFFFFFFFFFFFFFL
  let biased = (bits >> 52).to_int() & 0x7FF
  let (mantissa, exp2) = if biased == 0 {
    (fraction, -1074)
  } else {
    (fraction | 0x10000000000000L, biased - 1075)
  }
  let mut num = @bigint.BigInt::from_int64(mantissa)
  let mut den = big(1)
  if k >= 0 {
    num = num * big(10).pow(big(k))
  } else {
    den = den * big(10).pow(big(-k))
  }
  if exp2 >= 0 {
    num = num << exp2
  } else {
    den = den << -exp2
  }
  let quotient = num / den
  let twice = num % den * big(2)
  let order = twice.compare(den)
  if order > 0 || (order == 0 && !(quotient % big(2)).is_zero()) {
    quotient + big(1)
  } else {
    quotient
  }
}

///|
fn zeros(n : Int32) -> String {
  String::make(if n > 0 { n } else { 0 }, '0')
}

///|
/// `|f|` in fixed notation with exactly `prec` digits after the point.
fn fixed_exact(f : Double, prec : Int32) -> String {
  let digits = if f == 0.0 { "0" } else { scaled_round(f, prec).to_string() }
  let padded = zeros(prec + 1 - digits.length()) + digits
  if prec == 0 {
    return padded
  }
  let chars = padded.to_array()
  let split = chars.length() - prec
  String::from_array(chars[:split]) + "." + String::from_array(chars[split:])
}

///|
/// `|f|` rounded to `count` significant digits, as a digit string and the
/// position of the decimal point (value = 0.digits * 10^point).
fn round_sig(f : Double, count : Int32) -> (String, Int32) {
  if f == 0.0 {
    return (zeros(count), 1)
  }
  let (_, point) = shortest_digits(f.abs())
  let exp10 = point - 1
  let digits = scaled_round(f, count - 1 - exp10).to_string()
  if digits.length() > count {
    // rounding carried into a new digit, e.g. 9.99 -> 10.0
    (String::from_array(digits.to_array()[:count]), point + 1)
  } else {
    (digits, point)
  }
}

///|
fn trim_zeros(digits : String) -> String {
  let chars = digits.to_array()
  let mut stop = chars.length()
  while stop > 1 && chars[stop - 1] == '0' {
    stop = stop - 1
  }
  String::from_array(chars[:stop])
}

///|
fn format_float(
  out : StringBuilder,
  spec : Spec,
  f : Double,
  verb : Char,
) -> Unit {
  let negative = f < 0.0 || (f == 0.0 && 1.0 / f < 0.0)
  let sign = if negative {
    "-"
  } else if spec.plus {
    "+"
  } else if spec.space {
    " "
  } else {
    ""
  }
  if f.is_nan() || f.is_inf() {
    let text = if f.is_nan() {
      (if spec.plus { "+" } else if spec.space { " " } else { "" }) + "NaN"
    } else if negative {
      "-Inf"
    } else if spec.space && !spec.plus {
      " Inf"
    } else {
      "+Inf"
    }
    pad(out, spec, text, false)
    return
  }
  let e = if verb == 'E' || verb == 'G' { 'E' } else { 'e' }
  let body = match verb {
    'f' | 'F' => fixed_exact(f, if spec.prec < 0 { 6 } else { spec.prec })
    'e' | 'E' => {
      let prec = if spec.prec < 0 { 6 } else { spec.prec }
      let (digits, point) = round_sig(f, prec + 1)
      format_exp(digits, point - 1, e)
    }
    _ => {
      let (digits, point, limit) = if spec.prec < 0 {
        if f == 0.0 {
          ("0", 1, 6)
        } else {
          let (d, p) = shortest_digits(f.abs())
          (d, p, 6)
        }
      } else {
        let count = if spec.prec == 0 { 1 } else { spec.prec }
        let (d, p) = round_sig(f, count)
        let trimmed = trim_zeros(d)
        let nd = trimmed.length()
        (trimmed, p, if count > nd && nd >= p { nd } else { count })
      }
      let exp = point - 1
      if exp < -4 || exp >= limit {
        format_exp(digits, exp, e)
      } else {
        format_fixed(digits, point)
      }
    }
  }
  if spec.zero && !spec.minus && spec.width > sign.length() + body.length() {
    out.write_string(sign)
    out.write_string(zeros(spec.width - sign.length() - body.length()))
    out.write_string(body)
  } else {
    pad(out, spec, sign + body, false)
  }
}
