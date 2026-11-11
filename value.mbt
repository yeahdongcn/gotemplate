///|
/// The data model templates operate on.
///
/// `Nil` is both JSON's null and what a lookup of an absent map key
/// evaluates to. An action that produces it prints `<no value>`; inside a
/// list, a map or a call to `print` it shows as `<nil>`, as in Go.
#derive(Eq)
pub(all) enum Value {
  Nil
  Bool(Bool)
  Int(Int64)
  Float(Double)
  Str(String)
  List(Array[Value])
  Dict(Map[String, Value])
}

///|
pub extend Value with Eq::{equal, not_equal}

///|
pub extend TemplateError with Show::{to_string, output}

///|
/// Errors raised while parsing or executing a template.
pub(all) suberror TemplateError {
  /// A syntax error, with the 1-based line it was found on.
  ParseError(Int32, String)
  /// An error raised while executing a template.
  ExecError(String)
}

///|
pub impl Show for TemplateError with fn output(self, logger) {
  match self {
    ParseError(line, msg) =>
      logger.write_string("template: parse error at line \{line}: \{msg}")
    ExecError(msg) => logger.write_string("template: exec error: \{msg}")
  }
}

///|
/// A function callable from templates. Arguments arrive already evaluated.
pub(all) struct Func((Array[Value]) -> Value raise TemplateError)

///|
/// Convert a JSON value. A JSON number becomes `Int` when it is written
/// without a fraction or exponent and fits in 64 bits, otherwise `Float`.
pub fn Value::from_json(json : Json) -> Value {
  match json {
    Null => Nil
    True => Bool(true)
    False => Bool(false)
    String(s) => Str(s)
    Number(d, repr~) => number_from_json(d, repr)
    Array(items) => List(items.map(Value::from_json))
    Object(members) => {
      let dict : Map[String, Value] = Map([])
      for k, v in members {
        dict[k] = Value::from_json(v)
      }
      Dict(dict)
    }
  }
}

///|
fn number_from_json(d : Double, repr : String?) -> Value {
  match repr {
    Some(text) =>
      if text.contains(".") || text.contains("e") || text.contains("E") {
        Float(d)
      } else {
        try @string.parse_int64(text) catch {
          _ => Float(d)
        } noraise {
          i => Int(i)
        }
      }
    None =>
      if d == d.trunc() && d.abs() < 9007199254740992.0 {
        Int(d.to_int64())
      } else {
        Float(d)
      }
  }
}

///|
/// Go's notion of truth: the zero value of each type is false.
fn truth(v : Value) -> Bool {
  match v {
    Nil => false
    Bool(b) => b
    Int(i) => i != 0L
    Float(f) => f != 0.0
    Str(s) => s.length() > 0
    List(items) => items.length() > 0
    Dict(d) => d.length() > 0
  }
}

///|
/// The name Go would report for the dynamic type of a value.
fn type_name(v : Value) -> String {
  match v {
    Nil => "nil"
    Bool(_) => "bool"
    Int(_) => "int"
    Float(_) => "float64"
    Str(_) => "string"
    List(_) => "[]interface {}"
    Dict(_) => "map[string]interface {}"
  }
}

///|
fn sorted_keys(d : Map[String, Value]) -> Array[String] {
  let keys : Array[String] = []
  for k, _ in d {
    keys.push(k)
  }
  keys.sort_by((a, b) => a.lexical_compare(b))
  keys
}

///|
/// Number of bytes in the UTF-8 encoding of a string, which is what Go's
/// `len` reports.
fn utf8_len(s : String) -> Int32 {
  let mut n = 0
  for c in s {
    let code = c.to_int()
    n = n +
      (if code < 0x80 {
        1
      } else if code < 0x800 {
        2
      } else if code < 0x10000 {
        3
      } else {
        4
      })
  }
  n
}

///|
/// Format the way Go's `fmt.Print` does for a single operand.
fn format_value(v : Value, out : StringBuilder) -> Unit {
  match v {
    Nil => out.write_string("<nil>")
    Bool(b) => out.write_string(if b { "true" } else { "false" })
    Int(i) => out.write_string(i.to_string())
    Float(f) => out.write_string(format_float_g(f))
    Str(s) => out.write_string(s)
    List(items) => {
      out.write_char('[')
      for i, item in items {
        if i > 0 {
          out.write_char(' ')
        }
        format_value(item, out)
      }
      out.write_char(']')
    }
    Dict(d) => {
      out.write_string("map[")
      for i, k in sorted_keys(d) {
        if i > 0 {
          out.write_char(' ')
        }
        out.write_string(k)
        out.write_char(':')
        format_value(d[k], out)
      }
      out.write_char(']')
    }
  }
}

///|
/// The shortest decimal digits that round-trip `f` (which must be finite and
/// positive), with the position of the decimal point: the value is
/// `0.d1d2d3... * 10^point`.
fn shortest_digits(f : Double) -> (String, Int32) {
  let text = f.to_string()
  let (mantissa, exp10) = match text.split_once("e") {
    Some((m, e)) => (m.to_owned(), parse_small_int(e.to_owned()))
    None => (text, 0)
  }
  let digits = StringBuilder()
  let mut point = 0
  let mut seen_dot = false
  for c in mantissa {
    if c == '.' {
      seen_dot = true
    } else if c >= '0' && c <= '9' {
      digits.write_char(c)
      if !seen_dot {
        point = point + 1
      }
    }
  }
  let all = digits.to_string().to_array()
  // drop leading zeros, moving the point left
  let mut start = 0
  while start < all.length() - 1 && all[start] == '0' {
    start = start + 1
    point = point - 1
  }
  let mut stop = all.length()
  while stop > start + 1 && all[stop - 1] == '0' {
    stop = stop - 1
  }
  (String::from_array(all[start:stop]), point + exp10)
}

///|
fn parse_small_int(s : String) -> Int32 {
  let mut n = 0
  let mut neg = false
  for c in s {
    if c == '-' {
      neg = true
    } else if c >= '0' && c <= '9' {
      n = n * 10 + (c.to_int() - '0'.to_int())
    }
  }
  if neg {
    -n
  } else {
    n
  }
}

///|
/// Go's `%v` for a float64: shortest representation, switching to exponent
/// form when the exponent is below -4 or at least 6.
fn format_float_g(f : Double) -> String {
  if f.is_nan() {
    return "NaN"
  }
  if f.is_inf() {
    return if f > 0.0 { "+Inf" } else { "-Inf" }
  }
  let negative = f < 0.0 || (f == 0.0 && 1.0 / f < 0.0)
  let sign = if negative { "-" } else { "" }
  if f == 0.0 {
    return sign + "0"
  }
  let (digits, point) = shortest_digits(f.abs())
  let exp = point - 1
  if exp < -4 || exp >= 6 {
    sign + format_exp(digits, exp, 'e')
  } else {
    sign + format_fixed(digits, point)
  }
}

///|
fn format_exp(digits : String, exp : Int32, e : Char) -> String {
  let out = StringBuilder()
  let chars = digits.to_array()
  out.write_char(chars[0])
  if chars.length() > 1 {
    out.write_char('.')
    out.write_string(String::from_array(chars[1:]))
  }
  out.write_char(e)
  out.write_char(if exp < 0 { '-' } else { '+' })
  let mag = if exp < 0 { -exp } else { exp }
  if mag < 10 {
    out.write_char('0')
  }
  out.write_string(mag.to_string())
  out.to_string()
}

///|
fn format_fixed(digits : String, point : Int32) -> String {
  let out = StringBuilder()
  let chars = digits.to_array()
  if point <= 0 {
    out.write_string("0.")
    for _ in 0..<-point {
      out.write_char('0')
    }
    out.write_string(digits)
  } else if point >= chars.length() {
    out.write_string(digits)
    for _ in 0..<(point - chars.length()) {
      out.write_char('0')
    }
  } else {
    out.write_string(String::from_array(chars[:point]))
    out.write_char('.')
    out.write_string(String::from_array(chars[point:]))
  }
  out.to_string()
}
