///|
const BUILTINS : String = " and or not len index slice print printf println html js urlquery eq ne lt le gt ge call "

///|
fn is_builtin(name : String) -> Bool {
  BUILTINS.contains(" " + name + " ")
}

///|
fn want_args(
  name : String,
  args : Array[Value],
  min : Int32,
  max : Int32,
) -> Unit raise TemplateError {
  let n = args.length()
  if n < min || (max >= 0 && n > max) {
    if max == min {
      exec_fail("wrong number of args for \{name}: want \{min} got \{n}")
    } else {
      exec_fail(
        "wrong number of args for \{name}: want at least \{min} got \{n}",
      )
    }
  }
}

///|
fn call_builtin(
  name : String,
  args : Array[Value],
) -> Value raise TemplateError {
  match name {
    "not" => {
      want_args(name, args, 1, 1)
      Bool(!truth(args[0]))
    }
    "len" => {
      want_args(name, args, 1, 1)
      builtin_len(args[0])
    }
    "index" => {
      want_args(name, args, 1, -1)
      builtin_index(args)
    }
    "slice" => {
      want_args(name, args, 1, -1)
      builtin_slice(args)
    }
    "print" => Str(sprint(args))
    "println" => Str(sprintln(args))
    "printf" => {
      want_args(name, args, 1, -1)
      match args[0] {
        Str(format) => Str(sprintf(format, args[1:].to_owned()))
        other =>
          exec_fail(
            "wrong type for value; expected string; got \{type_name(other)}",
          )
      }
    }
    "html" => Str(html_escape(text_of_args(args)))
    "js" => Str(js_escape(text_of_args(args)))
    "urlquery" => Str(query_escape(text_of_args(args)))
    "eq" => {
      want_args(name, args, 1, -1)
      if args.length() < 2 {
        exec_fail("missing argument for comparison")
      }
      Bool(builtin_eq(args[0], args[1:].to_owned()))
    }
    "ne" => {
      want_args(name, args, 2, 2)
      Bool(!builtin_eq(args[0], [args[1]]))
    }
    "lt" => {
      want_args(name, args, 2, 2)
      Bool(builtin_lt(args[0], args[1]))
    }
    "le" => {
      want_args(name, args, 2, 2)
      Bool(builtin_lt(args[0], args[1]) || builtin_eq(args[0], [args[1]]))
    }
    "gt" => {
      want_args(name, args, 2, 2)
      Bool(!(builtin_lt(args[0], args[1]) || builtin_eq(args[0], [args[1]])))
    }
    "ge" => {
      want_args(name, args, 2, 2)
      Bool(!builtin_lt(args[0], args[1]))
    }
    "call" => {
      want_args(name, args, 1, -1)
      exec_fail("call: values of this data model are never functions")
    }
    _ => exec_fail("function \"\{name}\" not defined")
  }
}

///|
fn builtin_len(v : Value) -> Value raise TemplateError {
  match v {
    Str(s) => Int(utf8_len(s).to_int64())
    List(items) => Int(items.length().to_int64())
    Dict(d) => Int(d.length().to_int64())
    Nil => exec_fail("len of nil pointer")
    _ => exec_fail("len of type \{type_name(v)}")
  }
}

///|
/// Check an index against a length. `inclusive` allows the index to equal
/// the length, which slicing permits and indexing does not.
fn index_arg(
  v : Value,
  length : Int32,
  inclusive : Bool,
) -> Int32 raise TemplateError {
  match v {
    Int(i) => {
      let limit = length.to_int64()
      if i < 0L || i > limit || (!inclusive && i == limit) {
        exec_fail("index out of range: \{i}")
      }
      i.to_int()
    }
    Nil => exec_fail("cannot index slice/array with nil")
    _ => exec_fail("cannot index slice/array with type \{type_name(v)}")
  }
}

///|
fn builtin_index(args : Array[Value]) -> Value raise TemplateError {
  let mut item = args[0]
  if item is Nil {
    exec_fail("index of untyped nil")
  }
  for i in 1..<args.length() {
    let idx = args[i]
    item = match item {
      List(items) => items[index_arg(idx, items.length(), false)]
      Str(s) => {
        let bytes = utf8_encode(s)
        Int(bytes[index_arg(idx, bytes.length(), false)].to_int64())
      }
      Dict(d) =>
        match idx {
          Str(key) =>
            match d.get(key) {
              Some(v) => v
              None => Nil
            }
          Nil => exec_fail("value is nil; should be of type string")
          _ => exec_fail("value has type \{type_name(idx)}; should be string")
        }
      Nil => exec_fail("index of nil pointer")
      _ => exec_fail("can't index item of type \{type_name(item)}")
    }
  }
  item
}

///|
fn builtin_slice(args : Array[Value]) -> Value raise TemplateError {
  let item = args[0]
  if item is Nil {
    exec_fail("slice of untyped nil")
  }
  let count = args.length() - 1
  if count > 3 {
    exec_fail("too many slice indexes: \{count}")
  }
  let length = match item {
    Str(s) => {
      if count == 3 {
        exec_fail("cannot 3-index slice a string")
      }
      utf8_len(s)
    }
    List(items) => items.length()
    _ => exec_fail("can't slice item of type \{type_name(item)}")
  }
  let bounds = [0, length, length]
  for i in 0..<count {
    bounds[i] = index_arg(args[i + 1], length, true)
  }
  if bounds[0] > bounds[1] {
    exec_fail("invalid slice index: \{bounds[0]} > \{bounds[1]}")
  }
  if count == 3 && bounds[1] > bounds[2] {
    exec_fail("invalid slice index: \{bounds[1]} > \{bounds[2]}")
  }
  match item {
    Str(s) => {
      let bytes = utf8_encode(s)
      Str(utf8_decode(bytes[bounds[0]:bounds[1]].to_owned()))
    }
    List(items) => List(items[bounds[0]:bounds[1]].to_owned())
    _ => item
  }
}

///|
/// 0 for values that are not of a basic kind.
fn basic_kind(v : Value) -> Int32 {
  match v {
    Bool(_) => 1
    Int(_) => 2
    Float(_) => 3
    Str(_) => 4
    _ => 0
  }
}

///|
fn is_nil(v : Value) -> Bool {
  v is Nil
}

///|
fn builtin_eq(a : Value, rest : Array[Value]) -> Bool raise TemplateError {
  let k1 = basic_kind(a)
  for b in rest {
    let k2 = basic_kind(b)
    let equal = if k1 != k2 {
      if !is_nil(a) && !is_nil(b) {
        exec_fail("incompatible types for comparison")
      }
      false
    } else if k1 != 0 {
      a == b
    } else if is_nil(a) || is_nil(b) {
      is_nil(a) == is_nil(b)
    } else {
      match (a, b) {
        (List(_), List(_)) | (Dict(_), Dict(_)) =>
          exec_fail("non-comparable type \{type_name(a)}")
        _ => exec_fail("non-comparable types \{type_name(a)}, \{type_name(b)}")
      }
    }
    if equal {
      return true
    }
  }
  false
}

///|
fn builtin_lt(a : Value, b : Value) -> Bool raise TemplateError {
  let k1 = basic_kind(a)
  let k2 = basic_kind(b)
  if k1 == 0 || k2 == 0 {
    exec_fail("invalid type for comparison")
  }
  if k1 != k2 {
    exec_fail("incompatible types for comparison")
  }
  match (a, b) {
    (Int(x), Int(y)) => x < y
    (Float(x), Float(y)) => x < y
    (Str(x), Str(y)) => x.lexical_compare(y) < 0
    _ => exec_fail("invalid type for comparison")
  }
}

///|
/// Go's `fmt.Sprint`: operands are joined with a space only where neither
/// neighbour is a string.
fn sprint(args : Array[Value]) -> String {
  let out = StringBuilder()
  for i, arg in args {
    if i > 0 && !(arg is Str(_)) && !(args[i - 1] is Str(_)) {
      out.write_char(' ')
    }
    format_value(arg, out)
  }
  out.to_string()
}

///|
fn sprintln(args : Array[Value]) -> String {
  let out = StringBuilder()
  for i, arg in args {
    if i > 0 {
      out.write_char(' ')
    }
    format_value(arg, out)
  }
  out.write_char('\n')
  out.to_string()
}

///|
/// The text an escaping function works on: a lone string as it is,
/// anything else printed the way `print` would, except that a nil shows
/// as it does in an action.
fn text_of_args(args : Array[Value]) -> String {
  if args.length() == 1 && args[0] is Str(s) {
    s
  } else {
    sprint(args.map(v => if v is Nil { Str("<no value>") } else { v }))
  }
}

///|
fn html_escape(s : String) -> String {
  let out = StringBuilder()
  for c in s {
    match c {
      '"' => out.write_string("&#34;")
      '\'' => out.write_string("&#39;")
      '&' => out.write_string("&amp;")
      '<' => out.write_string("&lt;")
      '>' => out.write_string("&gt;")
      _ =>
        if c.to_int() == 0 {
          out.write_char((0xFFFD).unsafe_to_char())
        } else {
          out.write_char(c)
        }
    }
  }
  out.to_string()
}

///|
const HEX_UPPER : String = "0123456789ABCDEF"

///|
const HEX_LOWER : String = "0123456789abcdef"

///|
fn hex_digit(digits : String, n : Int32) -> Char {
  digits.to_array()[n]
}

///|
fn js_escape(s : String) -> String {
  let out = StringBuilder()
  for c in s {
    let code = c.to_int()
    match c {
      '\\' => out.write_string("\\\\")
      '\'' => out.write_string("\\'")
      '"' => out.write_string("\\\"")
      '<' => out.write_string("\\u003C")
      '>' => out.write_string("\\u003E")
      '&' => out.write_string("\\u0026")
      '=' => out.write_string("\\u003D")
      _ =>
        if code < 0x20 {
          out.write_string("\\u00")
          out.write_char(hex_digit(HEX_UPPER, code / 16))
          out.write_char(hex_digit(HEX_UPPER, code % 16))
        } else {
          out.write_char(c)
        }
    }
  }
  out.to_string()
}

///|
fn query_escape(s : String) -> String {
  let out = StringBuilder()
  for b in utf8_encode(s) {
    let c = b.unsafe_to_char()
    if b < 0x80 &&
      (is_digit(c) || c.is_ascii_alphabetic() || "-_.~".contains_char(c)) {
      out.write_char(c)
    } else if c == ' ' {
      out.write_char('+')
    } else {
      out.write_char('%')
      out.write_char(hex_digit(HEX_UPPER, b / 16))
      out.write_char(hex_digit(HEX_UPPER, b % 16))
    }
  }
  out.to_string()
}

///|
fn utf8_encode(s : String) -> Array[Int32] {
  let bytes : Array[Int32] = []
  for c in s {
    let code = c.to_int()
    if code < 0x80 {
      bytes.push(code)
    } else if code < 0x800 {
      bytes.push(0xC0 + code / 64)
      bytes.push(0x80 + code % 64)
    } else if code < 0x10000 {
      bytes.push(0xE0 + code / 4096)
      bytes.push(0x80 + code / 64 % 64)
      bytes.push(0x80 + code % 64)
    } else {
      bytes.push(0xF0 + code / 262144)
      bytes.push(0x80 + code / 4096 % 64)
      bytes.push(0x80 + code / 64 % 64)
      bytes.push(0x80 + code % 64)
    }
  }
  bytes
}

///|
/// Decode UTF-8, turning each byte that is not part of a valid sequence
/// into U+FFFD. Slicing a string in the middle of a character produces such
/// bytes.
fn utf8_decode(bytes : Array[Int32]) -> String {
  let out = StringBuilder()
  let n = bytes.length()
  let mut i = 0
  while i < n {
    let b = bytes[i]
    let (need, init, min) = if b < 0x80 {
      (0, b, 0)
    } else if b >= 0xC2 && b < 0xE0 {
      (1, b - 0xC0, 0x80)
    } else if b >= 0xE0 && b < 0xF0 {
      (2, b - 0xE0, 0x800)
    } else if b >= 0xF0 && b < 0xF5 {
      (3, b - 0xF0, 0x10000)
    } else {
      (-1, 0, 0)
    }
    let mut code = init
    let mut ok = need >= 0 && i + need < n
    if ok {
      for j in 1..<(need + 1) {
        let cont = bytes[i + j]
        if cont < 0x80 || cont >= 0xC0 {
          ok = false
          break
        }
        code = code * 64 + (cont - 0x80)
      }
    }
    if ok &&
      code >= min &&
      code <= 0x10FFFF &&
      !(code >= 0xD800 && code <= 0xDFFF) {
      out.write_char(code.unsafe_to_char())
      i = i + need + 1
    } else {
      out.write_char((0xFFFD).unsafe_to_char())
      i = i + 1
    }
  }
  out.to_string()
}
