///|
priv enum Node {
  NText(String)
  NAction(Pipe)
  NIf(Pipe, Array[Node], Array[Node]?)
  NWith(Pipe, Array[Node], Array[Node]?)
  NRange(Pipe, Array[Node], Array[Node]?)
  NTemplate(String, Pipe?)
  NBreak
  NContinue
}

///|
priv struct Pipe {
  mut assign : Bool
  decl : Array[String]
  cmds : Array[Command]
}

///|
priv struct Command {
  args : Array[Expr]
}

///|
priv enum Expr {
  EDot
  ENil
  EBool(Bool)
  EInt(Int64)
  EFloat(Double)
  EStr(String)
  /// An integer literal too large for a signed 64-bit value.
  EOverflow(String)
  EField(Array[String])
  EVar(String, Array[String])
  EIdent(String)
  EChain(Expr, Array[String])
  EPipe(Pipe)
}

///|
/// What ended a list of nodes.
priv enum ListEnd {
  AtEnd
  AtElse
  AtEOF
}

///|
priv enum Item {
  INode(Node)
  IEnd
  IElse
}

///|
priv struct Parser {
  toks : Array[Token]
  mut pos : Int32
  has_func : (String) -> Bool
  mut vars : Array[String]
  mut range_depth : Int32
  defs : Map[String, Array[Node]]
}

///|
fn Parser::fail(self : Parser, msg : String) -> Unit raise TemplateError {
  raise ParseError(self.line(), msg)
}

///|
fn Parser::line(self : Parser) -> Int32 {
  let i = if self.pos < self.toks.length() {
    self.pos
  } else {
    self.toks.length() - 1
  }
  self.toks[i].line
}

///|
fn Parser::peek(self : Parser) -> Tok {
  self.toks[self.pos].tok
}

///|
fn Parser::next(self : Parser) -> Tok {
  let tok = self.toks[self.pos].tok
  if self.pos < self.toks.length() - 1 {
    self.pos = self.pos + 1
  }
  tok
}

///|
fn Parser::skip_space(self : Parser) -> Unit {
  while self.peek() is TSpace {
    self.pos = self.pos + 1
  }
}

///|
fn Parser::peek_non_space(self : Parser) -> Tok {
  self.skip_space()
  self.peek()
}

///|
fn Parser::next_non_space(self : Parser) -> Tok {
  self.skip_space()
  self.next()
}

///|
fn describe(tok : Tok) -> String {
  match tok {
    TText(_) => "text"
    TLeft => "{{"
    TRight => "}}"
    TBool(b) => if b { "true" } else { "false" }
    TNumber(s) => s
    TCharConst(_) => "character constant"
    TString(_) => "string"
    TIdent(s) => s
    TField(s) => "." + s
    TVar(s) => s
    TKeyword(s) => "{{" + s + "}}"
    TDot => "."
    TNil => "nil"
    TPipe => "|"
    TDeclare => ":="
    TAssign => "="
    TLParen => "("
    TRParen => ")"
    TComma => ","
    TSpace => "space"
    TEOF => "EOF"
  }
}

///|
/// A list is empty when it holds nothing but white space.
fn is_empty_tree(nodes : Array[Node]) -> Bool {
  for node in nodes {
    match node {
      NText(s) => if !s.is_blank() { return false }
      _ => return false
    }
  }
  true
}

///|
fn Parser::add_def(
  self : Parser,
  name : String,
  body : Array[Node],
) -> Unit raise TemplateError {
  match self.defs.get(name) {
    Some(old) if !is_empty_tree(old) =>
      if !is_empty_tree(body) {
        self.fail("multiple definition of template \"\{name}\"")
      }
    _ => self.defs[name] = body
  }
}

///|
/// Parse template text. Returns the top-level body; `{{define}}` and
/// `{{block}}` bodies are stored in `defs`.
fn parse_text(
  text : String,
  has_func : (String) -> Bool,
  defs : Map[String, Array[Node]],
) -> Array[Node] raise TemplateError {
  let parser : Parser = {
    toks: lex(text),
    pos: 0,
    has_func,
    vars: ["$"],
    range_depth: 0,
    defs,
  }
  let root : Array[Node] = []
  for ;; {
    if parser.peek() is TEOF {
      break
    }
    if parser.peek() is TLeft {
      let save = parser.pos
      parser.pos = parser.pos + 1
      if parser.peek_non_space() is TKeyword("define") {
        parser.pos = parser.pos + 1
        parser.parse_define()
        continue
      }
      parser.pos = save
    }
    match parser.text_or_action() {
      INode(node) => root.push(node)
      IEnd => parser.fail("unexpected {{end}}")
      IElse => parser.fail("unexpected {{else}}")
    }
  }
  root
}

///|
fn Parser::parse_define(self : Parser) -> Unit raise TemplateError {
  let name = match self.next_non_space() {
    TString(s) => s
    tok => {
      self.fail("unexpected \{describe(tok)} in define clause")
      ""
    }
  }
  if !(self.next_non_space() is TRight) {
    self.fail("unexpected token in define clause")
  }
  let body = self.sub_template("define clause")
  self.add_def(name, body)
}

///|
/// The body of a `define` or `block`: it has its own variable scope and
/// runs up to the matching `{{end}}`.
fn Parser::sub_template(
  self : Parser,
  context : String,
) -> Array[Node] raise TemplateError {
  let saved_vars = self.vars
  let saved_depth = self.range_depth
  self.vars = ["$"]
  self.range_depth = 0
  let (body, end) = self.item_list()
  if !(end is AtEnd) {
    self.fail("unexpected {{else}} or EOF in \{context}")
  }
  self.vars = saved_vars
  self.range_depth = saved_depth
  body
}

///|
fn Parser::item_list(
  self : Parser,
) -> (Array[Node], ListEnd) raise TemplateError {
  let nodes : Array[Node] = []
  for ;; {
    if self.peek_non_space_eof() {
      return (nodes, AtEOF)
    }
    match self.text_or_action() {
      INode(node) => nodes.push(node)
      IEnd => return (nodes, AtEnd)
      IElse => return (nodes, AtElse)
    }
  }
}

///|
fn Parser::peek_non_space_eof(self : Parser) -> Bool {
  self.peek() is TEOF
}

///|
fn Parser::text_or_action(self : Parser) -> Item raise TemplateError {
  match self.next() {
    TText(s) => INode(NText(s))
    TLeft => self.action()
    tok => {
      self.fail("unexpected \{describe(tok)} in input")
      IEnd
    }
  }
}

///|
fn Parser::expect_right(
  self : Parser,
  context : String,
) -> Unit raise TemplateError {
  let tok = self.next_non_space()
  if !(tok is TRight) {
    self.fail("unexpected \{describe(tok)} in \{context}")
  }
}

///|
fn Parser::action(self : Parser) -> Item raise TemplateError {
  match self.peek_non_space() {
    TKeyword(word) => {
      self.pos = self.pos + 1
      match word {
        "end" => {
          self.expect_right("end")
          IEnd
        }
        "else" => {
          // "else if" and "else with" leave the keyword for the caller
          match self.peek_non_space() {
            TKeyword("if") | TKeyword("with") => ()
            _ => self.expect_right("else")
          }
          IElse
        }
        "if" => INode(self.control("if"))
        "with" => INode(self.control("with"))
        "range" => INode(self.control("range"))
        "break" => {
          if self.range_depth == 0 {
            self.fail("{{break}} outside {{range}}")
          }
          self.expect_right("{{break}}")
          INode(NBreak)
        }
        "continue" => {
          if self.range_depth == 0 {
            self.fail("{{continue}} outside {{range}}")
          }
          self.expect_right("{{continue}}")
          INode(NContinue)
        }
        "template" => INode(self.template_action())
        "block" => INode(self.block_action())
        _ => {
          self.fail("unexpected {{\{word}}} in command")
          IEnd
        }
      }
    }
    _ => INode(NAction(self.pipeline("command", false)))
  }
}

///|
fn Parser::control(self : Parser, context : String) -> Node raise TemplateError {
  let mark = self.vars.length()
  let pipe = self.pipeline(context, false)
  if context == "range" {
    self.range_depth = self.range_depth + 1
  }
  let (list, end) = self.item_list()
  if context == "range" {
    self.range_depth = self.range_depth - 1
  }
  let mut else_list : Array[Node]? = None
  match end {
    AtEOF => self.fail("unexpected EOF")
    AtEnd => ()
    AtElse =>
      match (context, self.peek()) {
        ("if", TKeyword("if")) => {
          self.pos = self.pos + 1
          else_list = Some([self.control("if")])
        }
        ("with", TKeyword("with")) => {
          self.pos = self.pos + 1
          else_list = Some([self.control("with")])
        }
        _ => {
          let (list2, end2) = self.item_list()
          if !(end2 is AtEnd) {
            self.fail("expected end; found {{else}} or EOF")
          }
          else_list = Some(list2)
        }
      }
  }
  self.vars.truncate(mark)
  match context {
    "if" => NIf(pipe, list, else_list)
    "with" => NWith(pipe, list, else_list)
    _ => NRange(pipe, list, else_list)
  }
}

///|
fn Parser::template_name(
  self : Parser,
  context : String,
) -> String raise TemplateError {
  match self.next_non_space() {
    TString(s) => s
    tok => {
      self.fail("unexpected \{describe(tok)} in \{context}")
      ""
    }
  }
}

///|
fn Parser::template_action(self : Parser) -> Node raise TemplateError {
  let name = self.template_name("template clause")
  if self.peek_non_space() is TRight {
    self.pos = self.pos + 1
    NTemplate(name, None)
  } else {
    NTemplate(name, Some(self.pipeline("template clause", false)))
  }
}

///|
fn Parser::block_action(self : Parser) -> Node raise TemplateError {
  let name = self.template_name("block clause")
  let pipe = self.pipeline("block clause", false)
  let body = self.sub_template("block clause")
  self.add_def(name, body)
  NTemplate(name, Some(pipe))
}

///|
fn Parser::pipeline(
  self : Parser,
  context : String,
  in_paren : Bool,
) -> Pipe raise TemplateError {
  let pipe : Pipe = { assign: false, decl: [], cmds: [], }
  // optional variable declarations
  for ;; {
    match self.peek_non_space() {
      TVar(name) => {
        let save = self.pos
        self.pos = self.pos + 1
        match self.peek_non_space() {
          TAssign | TDeclare => {
            pipe.assign = self.next() is TAssign
            pipe.decl.push(name)
            self.vars.push(name)
            break
          }
          TComma => {
            self.pos = self.pos + 1
            pipe.decl.push(name)
            self.vars.push(name)
            if context == "range" && pipe.decl.length() < 2 {
              match self.peek_non_space() {
                TVar(_) | TRight | TRParen => continue
                _ => self.fail("range can only initialize variables")
              }
            }
            self.fail("too many declarations in \{context}")
          }
          _ => {
            self.pos = save
            break
          }
        }
      }
      _ => break
    }
  }
  for ;; {
    let tok = self.next_non_space()
    match tok {
      TRight if !in_paren => break
      TRParen if in_paren => break
      TBool(_)
      | TCharConst(_)
      | TDot
      | TField(_)
      | TIdent(_)
      | TNumber(_)
      | TNil
      | TString(_)
      | TVar(_)
      | TLParen => {
        self.pos = self.pos - 1
        pipe.cmds.push(self.command())
      }
      _ => self.fail("unexpected \{describe(tok)} in \{context}")
    }
  }
  if pipe.cmds.length() == 0 {
    self.fail("missing value for \{context}")
  }
  for i in 1..<pipe.cmds.length() {
    match pipe.cmds[i].args[0] {
      EBool(_) | EDot | ENil | EInt(_) | EFloat(_) | EOverflow(_) | EStr(_) =>
        self.fail("non executable command in pipeline stage \{i + 1}")
      _ => ()
    }
  }
  pipe
}

///|
fn Parser::command(self : Parser) -> Command raise TemplateError {
  let args : Array[Expr] = []
  for ;; {
    self.skip_space()
    match self.operand() {
      Some(e) => args.push(e)
      None => ()
    }
    let tok = self.next()
    match tok {
      TSpace => continue
      TRight | TRParen => {
        self.pos = self.pos - 1
        break
      }
      TPipe => break
      _ => self.fail("unexpected \{describe(tok)} in operand")
    }
  }
  if args.length() == 0 {
    self.fail("empty command")
  }
  { args, }
}

///|
fn Parser::operand(self : Parser) -> Expr? raise TemplateError {
  let node = match self.term() {
    None => return None
    Some(node) => node
  }
  if !(self.peek() is TField(_)) {
    return Some(node)
  }
  let fields : Array[String] = []
  while self.peek() is TField(f) {
    fields.push(f)
    self.pos = self.pos + 1
  }
  match node {
    EField(prefix) => Some(EField(prefix + fields))
    EVar(name, prefix) => Some(EVar(name, prefix + fields))
    EBool(_) | EStr(_) | EInt(_) | EFloat(_) | EOverflow(_) | ENil | EDot => {
      self.fail("unexpected . after term")
      None
    }
    _ => Some(EChain(node, fields))
  }
}

///|
fn Parser::term(self : Parser) -> Expr? raise TemplateError {
  match self.next_non_space() {
    TIdent(name) => {
      if !(self.has_func)(name) {
        self.fail("function \"\{name}\" not defined")
      }
      Some(EIdent(name))
    }
    TDot => Some(EDot)
    TNil => Some(ENil)
    TVar(name) => {
      if !self.vars.contains(name) {
        self.fail("undefined variable \"\{name}\"")
      }
      Some(EVar(name, []))
    }
    TField(f) => Some(EField([f]))
    TBool(b) => Some(EBool(b))
    TCharConst(c) => Some(EInt(c))
    TNumber(text) => Some(self.number(text))
    TString(s) => Some(EStr(s))
    TLParen => Some(EPipe(self.pipeline("parenthesized pipeline", true)))
    _ => {
      self.pos = self.pos - 1
      None
    }
  }
}

///|
priv enum IntParse {
  IntOk(Int64)
  IntOverflow
  NotInt
}

///|
/// Parse an integer the way Go's `strconv.ParseInt(text, 0, 64)` does:
/// optional sign, `0x`/`0o`/`0b` prefixes, a bare leading `0` meaning octal,
/// and underscores between digits.
fn parse_go_int(text : String) -> IntParse {
  let chars = text.to_array()
  let mut i = 0
  let mut negative = false
  if chars.length() > 0 && (chars[0] == '+' || chars[0] == '-') {
    negative = chars[0] == '-'
    i = 1
  }
  let mut base = 10L
  let mut prefixed = false
  if i + 1 < chars.length() && chars[i] == '0' {
    match chars[i + 1] {
      'x' | 'X' => {
        base = 16L
        i = i + 2
      }
      'o' | 'O' => {
        base = 8L
        i = i + 2
      }
      'b' | 'B' => {
        base = 2L
        i = i + 2
      }
      _ => {
        base = 8L
        i = i + 1
      }
    }
    prefixed = true
  }
  if i >= chars.length() {
    return NotInt
  }
  let mut acc = 0UL
  let mut too_big = false
  let ubase = base.reinterpret_as_uint64()
  let mut prev_digit = prefixed
  let mut count = 0
  for j in i..<chars.length() {
    let c = chars[j]
    if c == '_' {
      if !prev_digit || j + 1 >= chars.length() || chars[j + 1] == '_' {
        return NotInt
      }
      prev_digit = false
      continue
    }
    match hex_value(c) {
      Some(d) if d.to_int64() < base => {
        let digit = d.to_int64().reinterpret_as_uint64()
        if acc > (18446744073709551615UL - digit) / ubase {
          too_big = true
        } else {
          acc = acc * ubase + digit
        }
        prev_digit = true
        count = count + 1
      }
      _ => return NotInt
    }
  }
  if count == 0 && !prefixed {
    return NotInt
  }
  if too_big {
    return NotInt
  }
  // 2^63 itself is only representable when negative
  let limit = if negative {
    9223372036854775808UL
  } else {
    9223372036854775807UL
  }
  if acc > limit {
    return IntOverflow
  }
  IntOk(
    if negative {
      (0UL - acc).reinterpret_as_int64()
    } else {
      acc.reinterpret_as_int64()
    },
  )
}

///|
/// A hexadecimal floating-point literal such as `0x1.8p3`.
fn parse_hex_float(text : String) -> Double? {
  let chars = text.to_array()
  let mut i = 0
  let mut negative = false
  if chars.length() > 0 && (chars[0] == '+' || chars[0] == '-') {
    negative = chars[0] == '-'
    i = 1
  }
  if !(i + 1 < chars.length() &&
    chars[i] == '0' &&
    (chars[i + 1] == 'x' || chars[i + 1] == 'X')) {
    return None
  }
  i = i + 2
  let mut mantissa = 0.0
  let mut scale = 0
  let mut seen_dot = false
  let mut digits = 0
  while i < chars.length() && chars[i] != 'p' && chars[i] != 'P' {
    let c = chars[i]
    if c == '.' {
      if seen_dot {
        return None
      }
      seen_dot = true
    } else if c != '_' {
      match hex_value(c) {
        Some(d) => {
          mantissa = mantissa * 16.0 + d.to_double()
          digits = digits + 1
          if seen_dot {
            scale = scale - 4
          }
        }
        None => return None
      }
    }
    i = i + 1
  }
  // the exponent is mandatory
  if digits == 0 || i >= chars.length() {
    return None
  }
  i = i + 1
  let mut exp_negative = false
  if i < chars.length() && (chars[i] == '+' || chars[i] == '-') {
    exp_negative = chars[i] == '-'
    i = i + 1
  }
  if i >= chars.length() {
    return None
  }
  let mut exp = 0
  while i < chars.length() {
    if !is_digit(chars[i]) {
      return None
    }
    if exp < 10000 {
      exp = exp * 10 + (chars[i].to_int() - '0'.to_int())
    }
    i = i + 1
  }
  let total = (if exp_negative { -exp } else { exp }) + scale
  let mut value = mantissa
  let mut steps = if total < 0 { -total } else { total }
  // beyond this the result is already zero or infinite
  if steps > 2200 {
    steps = 2200
  }
  for _ in 0..<steps {
    value = if total < 0 { value / 2.0 } else { value * 2.0 }
  }
  Some(if negative { -value } else { value })
}

///|
fn Parser::number(self : Parser, text : String) -> Expr raise TemplateError {
  if text.has_suffix("i") {
    self.fail("complex numbers are not supported: \{text}")
  }
  match parse_go_int(text) {
    IntOk(i) => return EInt(i)
    // Go accepts this as an unsigned constant and only objects when the
    // value is used, so the error has to wait until execution too.
    IntOverflow => return EOverflow(text)
    NotInt => ()
  }
  if parse_hex_float(text) is Some(value) {
    return EFloat(value)
  }
  let cleaned = StringBuilder()
  let mut looks_float = false
  let chars = text.to_array()
  for i, c in chars {
    if c == '_' {
      let ok = i > 0 &&
        i + 1 < chars.length() &&
        is_digit(chars[i - 1]) &&
        is_digit(chars[i + 1])
      if !ok {
        self.fail("illegal number syntax: \{text}")
      }
    } else if is_digit(c) || c == '+' || c == '-' {
      cleaned.write_char(c)
    } else if c == '.' || c == 'e' || c == 'E' {
      looks_float = true
      cleaned.write_char(c)
    } else {
      self.fail("illegal number syntax: \{text}")
    }
  }
  if !looks_float {
    self.fail("illegal number syntax: \{text}")
  }
  let value = @string.parse_double(cleaned.to_string()) catch {
    _ => {
      self.fail("illegal number syntax: \{text}")
      0.0
    }
  }
  EFloat(value)
}
