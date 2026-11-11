///|
/// Lexical tokens. Inside an action, runs of white space are tokens too,
/// because `a .b` and `a.b` mean different things.
priv enum Tok {
  TText(String)
  TLeft
  TRight
  TBool(Bool)
  TNumber(String)
  TCharConst(Int64)
  TString(String)
  TIdent(String)
  TField(String)
  TVar(String)
  TKeyword(String)
  TDot
  TNil
  TPipe
  TDeclare
  TAssign
  TLParen
  TRParen
  TComma
  TSpace
  TEOF
}

///|
priv struct Token {
  tok : Tok
  line : Int32
}

///|
priv struct Lexer {
  input : Array[Char]
  mut pos : Int32
  mut line : Int32
  mut paren : Int32
  toks : Array[Token]
}

///|
const KEYWORDS : String = " block break continue define else end if range template with "

///|
fn is_space(c : Char) -> Bool {
  c == ' ' || c == '\t' || c == '\r' || c == '\n'
}

///|
fn is_alnum(c : Char) -> Bool {
  c == '_' ||
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c.to_int() >= 0x80
}

///|
fn is_digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
fn Lexer::fail(self : Lexer, msg : String) -> Unit raise TemplateError {
  raise ParseError(self.line, msg)
}

///|
fn Lexer::at(self : Lexer, i : Int32) -> Char? {
  if i < self.input.length() {
    Some(self.input[i])
  } else {
    None
  }
}

///|
fn Lexer::starts(self : Lexer, i : Int32, s : String) -> Bool {
  let mut j = i
  for c in s {
    if j >= self.input.length() || self.input[j] != c {
      return false
    }
    j = j + 1
  }
  true
}

///|
fn Lexer::emit(self : Lexer, tok : Tok) -> Unit {
  self.toks.push({ tok, line: self.line, })
}

///|
/// Is there a closing delimiter at `i`, possibly preceded by the ` -` trim
/// marker? Returns how many characters it spans and whether it trims.
fn Lexer::right_delim(self : Lexer, i : Int32) -> (Int32, Bool)? {
  if self.at(i) is Some(c) &&
    is_space(c) &&
    self.at(i + 1) is Some('-') &&
    self.starts(i + 2, "}}") {
    Some((4, true))
  } else if self.starts(i, "}}") {
    Some((2, false))
  } else {
    None
  }
}

///|
fn Lexer::at_terminator(self : Lexer) -> Bool {
  match self.at(self.pos) {
    None => true
    Some(c) =>
      is_space(c) ||
      c == '.' ||
      c == ',' ||
      c == '|' ||
      c == ':' ||
      c == ')' ||
      c == '(' ||
      self.starts(self.pos, "}}")
  }
}

///|
fn Lexer::count_lines(self : Lexer, from : Int32, to : Int32) -> Unit {
  for i in from..<to {
    if self.input[i] == '\n' {
      self.line = self.line + 1
    }
  }
}

///|
fn lex(text : String) -> Array[Token] raise TemplateError {
  let lx : Lexer = {
    input: text.to_array(),
    pos: 0,
    line: 1,
    paren: 0,
    toks: [],
  }
  let n = lx.input.length()
  while lx.pos < n {
    // plain text up to the next action
    let mut open = lx.pos
    while open < n && !lx.starts(open, "{{") {
      open = open + 1
    }
    let trim_left = open < n &&
      lx.at(open + 2) is Some('-') &&
      lx.at(open + 3) is Some(c) &&
      is_space(c)
    let mut text_end = open
    if trim_left {
      while text_end > lx.pos && is_space(lx.input[text_end - 1]) {
        text_end = text_end - 1
      }
    }
    if text_end > lx.pos {
      lx.emit(TText(String::from_array(lx.input[lx.pos:text_end])))
    }
    lx.count_lines(lx.pos, open)
    if open >= n {
      lx.pos = n
      break
    }
    lx.pos = open + (if trim_left { 4 } else { 2 })
    if lx.starts(lx.pos, "/*") {
      lx.lex_comment()
    } else {
      lx.emit(TLeft)
      lx.paren = 0
      lx.lex_action()
    }
  }
  lx.emit(TEOF)
  lx.toks
}

///|
/// After a closing delimiter that carried a trim marker, skip the white
/// space that follows it.
fn Lexer::close(self : Lexer, width : Int32, trim : Bool) -> Unit {
  self.pos = self.pos + width
  if trim {
    let start = self.pos
    while self.pos < self.input.length() && is_space(self.input[self.pos]) {
      self.pos = self.pos + 1
    }
    self.count_lines(start, self.pos)
  }
}

///|
fn Lexer::lex_comment(self : Lexer) -> Unit raise TemplateError {
  let start = self.pos
  let n = self.input.length()
  let mut i = self.pos + 2
  while i < n && !self.starts(i, "*/") {
    i = i + 1
  }
  if i >= n {
    self.fail("unclosed comment")
  }
  self.pos = i + 2
  self.count_lines(start, self.pos)
  match self.right_delim(self.pos) {
    Some((width, trim)) => self.close(width, trim)
    None => self.fail("comment ends before closing delimiter")
  }
}

///|
fn Lexer::lex_action(self : Lexer) -> Unit raise TemplateError {
  let n = self.input.length()
  for ;; {
    if self.right_delim(self.pos) is Some((width, trim)) {
      if self.paren != 0 {
        self.fail("unclosed left paren")
      }
      // the space of a trim marker belongs to the delimiter
      self.emit(TRight)
      self.close(width, trim)
      return
    }
    if self.pos >= n {
      self.fail("unclosed action")
    }
    let c = self.input[self.pos]
    if is_space(c) {
      let start = self.pos
      while self.pos < n && is_space(self.input[self.pos]) {
        self.pos = self.pos + 1
      }
      self.count_lines(start, self.pos)
      // leave one space in place when it starts a trim marker
      if self.pos > start && self.right_delim(self.pos - 1) is Some((_, true)) {
        self.pos = self.pos - 1
        if self.pos == start {
          continue
        }
      }
      self.emit(TSpace)
      continue
    }
    match c {
      '=' => {
        self.pos = self.pos + 1
        self.emit(TAssign)
      }
      ':' => {
        if !(self.at(self.pos + 1) is Some('=')) {
          self.fail("expected :=")
        }
        self.pos = self.pos + 2
        self.emit(TDeclare)
      }
      '|' => {
        self.pos = self.pos + 1
        self.emit(TPipe)
      }
      ',' => {
        self.pos = self.pos + 1
        self.emit(TComma)
      }
      '(' => {
        self.pos = self.pos + 1
        self.paren = self.paren + 1
        self.emit(TLParen)
      }
      ')' => {
        self.pos = self.pos + 1
        self.paren = self.paren - 1
        if self.paren < 0 {
          self.fail("unexpected right paren")
        }
        self.emit(TRParen)
      }
      '"' => self.lex_quote()
      '`' => self.lex_raw_quote()
      '\'' => self.lex_char()
      '$' => {
        self.pos = self.pos + 1
        let name = self.lex_name()
        self.emit(TVar("$" + name))
      }
      '.' =>
        if self.at(self.pos + 1) is Some(d) && is_digit(d) {
          self.lex_number()
        } else {
          self.pos = self.pos + 1
          if self.at_terminator() {
            self.emit(TDot)
          } else {
            let name = self.lex_name()
            self.emit(TField(name))
          }
        }
      '+' | '-' => self.lex_number()
      _ =>
        if is_digit(c) {
          self.lex_number()
        } else if is_alnum(c) {
          let word = self.lex_name()
          if word == "true" {
            self.emit(TBool(true))
          } else if word == "false" {
            self.emit(TBool(false))
          } else if word == "nil" {
            self.emit(TNil)
          } else if KEYWORDS.contains(" " + word + " ") {
            self.emit(TKeyword(word))
          } else {
            self.emit(TIdent(word))
          }
        } else {
          self.fail("unexpected character \{c.escape(quote=true)} in action")
        }
    }
  }
}

///|
/// An alphanumeric run, which must be followed by something that can end a
/// word.
fn Lexer::lex_name(self : Lexer) -> String raise TemplateError {
  let start = self.pos
  while self.pos < self.input.length() && is_alnum(self.input[self.pos]) {
    self.pos = self.pos + 1
  }
  if !self.at_terminator() {
    let c = self.input[self.pos]
    self.fail("bad character \{c.escape(quote=true)}")
  }
  String::from_array(self.input[start:self.pos])
}

///|
fn Lexer::lex_number(self : Lexer) -> Unit raise TemplateError {
  let start = self.pos
  let n = self.input.length()
  fn accept(set : String) -> Bool {
    if self.pos < n && set.contains_char(self.input[self.pos]) {
      self.pos = self.pos + 1
      true
    } else {
      false
    }
  }
  fn accept_run(set : String) -> Unit {
    while self.pos < n && set.contains_char(self.input[self.pos]) {
      self.pos = self.pos + 1
    }
  }
  let _ = accept("+-")
  let mut digits = "0123456789_"
  let mut decimal = true
  let mut hex = false
  if accept("0") {
    if accept("xX") {
      digits = "0123456789abcdefABCDEF_"
      decimal = false
      hex = true
    } else if accept("oO") {
      digits = "01234567_"
      decimal = false
    } else if accept("bB") {
      digits = "01_"
      decimal = false
    }
  }
  accept_run(digits)
  if accept(".") {
    accept_run(digits)
  }
  if decimal && accept("eE") {
    let _ = accept("+-")
    accept_run("0123456789_")
  }
  if hex && accept("pP") {
    let _ = accept("+-")
    accept_run("0123456789_")
  }
  let _ = accept("i")
  let text = String::from_array(self.input[start:self.pos])
  if self.pos < n {
    let c = self.input[self.pos]
    if is_alnum(c) || c == '+' || c == '-' {
      self.fail("bad number syntax: \{text}\{c}")
    }
  }
  self.emit(TNumber(text))
}

///|
fn hex_value(c : Char) -> Int32? {
  if c >= '0' && c <= '9' {
    Some(c.to_int() - '0'.to_int())
  } else if c >= 'a' && c <= 'f' {
    Some(c.to_int() - 'a'.to_int() + 10)
  } else if c >= 'A' && c <= 'F' {
    Some(c.to_int() - 'A'.to_int() + 10)
  } else {
    None
  }
}

///|
/// Decode one backslash escape; `self.pos` is just past the backslash.
/// `quote` is the delimiter in use, the only quote character that may be
/// escaped.
fn Lexer::lex_escape(self : Lexer, quote : Char) -> Char raise TemplateError {
  let n = self.input.length()
  if self.pos >= n {
    self.fail("unterminated escape")
  }
  let c = self.input[self.pos]
  self.pos = self.pos + 1
  fn read_hex(count : Int32) -> Int32 raise TemplateError {
    let mut v = 0
    for _ in 0..<count {
      match self.at(self.pos) {
        Some(h) =>
          match hex_value(h) {
            Some(d) => {
              v = v * 16 + d
              self.pos = self.pos + 1
            }
            None => self.fail("invalid escape sequence")
          }
        None => self.fail("invalid escape sequence")
      }
    }
    v
  }
  fn to_char(code : Int32) -> Char raise TemplateError {
    if code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF) {
      self.fail("escape is not a valid Unicode code point")
    }
    code.unsafe_to_char()
  }
  match c {
    'a' => (7).unsafe_to_char()
    'b' => (8).unsafe_to_char()
    'f' => (12).unsafe_to_char()
    'n' => '\n'
    'r' => '\r'
    't' => '\t'
    'v' => (11).unsafe_to_char()
    '\\' => '\\'
    'x' => {
      let code = read_hex(2)
      if code >= 0x80 {
        self.fail("\\x escapes above 7f are not supported")
      }
      code.unsafe_to_char()
    }
    'u' => to_char(read_hex(4))
    'U' => to_char(read_hex(8))
    _ =>
      if c == quote {
        c
      } else if c >= '0' && c <= '7' {
        let mut v = c.to_int() - '0'.to_int()
        for _ in 0..<2 {
          match self.at(self.pos) {
            Some(d) if d >= '0' && d <= '7' => {
              v = v * 8 + (d.to_int() - '0'.to_int())
              self.pos = self.pos + 1
            }
            _ => self.fail("invalid escape sequence")
          }
        }
        if v >= 0x80 {
          self.fail("octal escapes above 177 are not supported")
        }
        v.unsafe_to_char()
      } else {
        self.fail("invalid escape sequence")
        c
      }
  }
}

///|
fn Lexer::lex_quote(self : Lexer) -> Unit raise TemplateError {
  let n = self.input.length()
  self.pos = self.pos + 1
  let out = StringBuilder()
  for ;; {
    if self.pos >= n || self.input[self.pos] == '\n' {
      self.fail("unterminated quoted string")
    }
    let c = self.input[self.pos]
    self.pos = self.pos + 1
    if c == '"' {
      break
    }
    if c == '\\' {
      out.write_char(self.lex_escape('"'))
    } else {
      out.write_char(c)
    }
  }
  self.emit(TString(out.to_string()))
}

///|
fn Lexer::lex_raw_quote(self : Lexer) -> Unit raise TemplateError {
  let n = self.input.length()
  let start = self.pos + 1
  let mut i = start
  while i < n && self.input[i] != '`' {
    i = i + 1
  }
  if i >= n {
    self.fail("unterminated raw quoted string")
  }
  let out = StringBuilder()
  for j in start..<i {
    // Go drops carriage returns from raw strings
    if self.input[j] != '\r' {
      out.write_char(self.input[j])
    }
  }
  // the token is reported on the line where the string starts
  self.emit(TString(out.to_string()))
  self.count_lines(start, i)
  self.pos = i + 1
}

///|
fn Lexer::lex_char(self : Lexer) -> Unit raise TemplateError {
  let n = self.input.length()
  self.pos = self.pos + 1
  if self.pos >= n ||
    self.input[self.pos] == '\n' ||
    self.input[self.pos] == '\'' {
    self.fail("malformed character constant")
  }
  let c = self.input[self.pos]
  self.pos = self.pos + 1
  let value = if c == '\\' { self.lex_escape('\'') } else { c }
  if !(self.at(self.pos) is Some('\'')) {
    self.fail("unterminated character constant")
  }
  self.pos = self.pos + 1
  self.emit(TCharConst(value.to_int().to_int64()))
}
