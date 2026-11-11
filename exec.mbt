///|
/// A named template together with every template defined alongside it.
struct Template {
  name : String
  trees : Map[String, Array[Node]]
  funcs : Map[String, Func]
  mut missing_key_error : Bool
}

///|
/// How deeply `{{template}}` calls may nest before execution is stopped.
/// Go allows 100000; the limit here is lower so that runaway recursion ends
/// in an error instead of exhausting the stack on WebAssembly targets.
const MAX_EXEC_DEPTH : Int32 = 200

///|
/// Create an empty template with the given name.
pub fn Template::new(name : String) -> Template {
  { name, trees: Map([]), funcs: Map([]), missing_key_error: false, }
}

///|
/// Make functions available to templates parsed afterwards. A function
/// registered under the name of a built-in replaces it.
pub fn Template::add_funcs(
  self : Template,
  funcs : Map[String, Func],
) -> Template {
  for name, f in funcs {
    self.funcs[name] = f
  }
  self
}

///|
/// Choose what happens when a map is indexed by a key it does not have:
/// `false` (the default) yields `<no value>`, `true` stops execution with an
/// error. This is Go's `missingkey=error` option.
pub fn Template::error_on_missing_key(
  self : Template,
  enabled : Bool,
) -> Template {
  self.missing_key_error = enabled
  self
}

///|
/// Parse `text` as the body of this template. Templates it defines with
/// `{{define}}` or `{{block}}` are added to the set; a later definition of a
/// name replaces an earlier one unless the new body is empty.
pub fn Template::parse(
  self : Template,
  text : String,
) -> Template raise TemplateError {
  let defs : Map[String, Array[Node]] = Map([])
  let has_func = name => self.funcs.contains(name) || is_builtin(name)
  let root = parse_text(text, has_func, defs)
  match defs.get(self.name) {
    Some(old) if !is_empty_tree(old) =>
      if !is_empty_tree(root) {
        raise ParseError(1, "multiple definition of template \"\{self.name}\"")
      }
    _ => defs[self.name] = root
  }
  for name, body in defs {
    if !(self.trees.contains(name) && is_empty_tree(body)) {
      self.trees[name] = body
    }
  }
  self
}

///|
/// Names of all templates in the set, sorted.
pub fn Template::defined_templates(self : Template) -> Array[String] {
  let names : Array[String] = []
  for name, _ in self.trees {
    names.push(name)
  }
  names.sort_by((a, b) => a.lexical_compare(b))
  names
}

///|
/// Execute this template with `data` as the initial value of dot.
pub fn Template::execute(
  self : Template,
  data : Value,
) -> String raise TemplateError {
  self.execute_template(self.name, data)
}

///|
/// Execute the template called `name` from the set.
pub fn Template::execute_template(
  self : Template,
  name : String,
  data : Value,
) -> String raise TemplateError {
  let body = match self.trees.get(name) {
    Some(body) => body
    None =>
      raise ExecError(
        "no template \"\{name}\" associated with template \"\{self.name}\"",
      )
  }
  let dot = data
  let state : State = {
    tmpl: self,
    out: StringBuilder(),
    vars: [{ name: "$", value: dot, }],
    depth: 0,
  }
  let _ = state.walk_list(dot, body)
  state.out.to_string()
}

///|
/// Parse and execute `text` in one step.
pub fn render(text : String, data : Value) -> String raise TemplateError {
  Template::new("template").parse(text).execute(data)
}

///|
priv struct Variable {
  name : String
  mut value : Value
}

///|
priv struct State {
  tmpl : Template
  out : StringBuilder
  vars : Array[Variable]
  depth : Int32
}

///|
priv enum Flow {
  Normal
  Break
  Continue
}

///|
fn[T] exec_fail(msg : String) -> T raise TemplateError {
  raise ExecError(msg)
}

///|
fn State::set_var(
  self : State,
  name : String,
  value : Value,
) -> Unit raise TemplateError {
  let mut i = self.vars.length() - 1
  while i >= 0 {
    if self.vars[i].name == name {
      self.vars[i].value = value
      return
    }
    i = i - 1
  }
  exec_fail("undefined variable: \{name}")
}

///|
fn State::var_value(self : State, name : String) -> Value raise TemplateError {
  let mut i = self.vars.length() - 1
  while i >= 0 {
    if self.vars[i].name == name {
      return self.vars[i].value
    }
    i = i - 1
  }
  exec_fail("undefined variable: \{name}")
}

///|
fn State::print_value(self : State, v : Value) -> Unit {
  match v {
    Nil => self.out.write_string("<no value>")
    _ => format_value(v, self.out)
  }
}

///|
fn State::walk_list(
  self : State,
  dot : Value,
  nodes : Array[Node],
) -> Flow raise TemplateError {
  for node in nodes {
    match self.walk(dot, node) {
      Normal => ()
      flow => return flow
    }
  }
  Normal
}

///|
fn State::walk(
  self : State,
  dot : Value,
  node : Node,
) -> Flow raise TemplateError {
  match node {
    NText(s) => {
      self.out.write_string(s)
      Normal
    }
    NAction(pipe) => {
      let v = self.eval_pipeline(dot, pipe)
      if pipe.decl.length() == 0 {
        self.print_value(v)
      }
      Normal
    }
    NIf(pipe, list, else_list) =>
      self.walk_if_or_with(dot, pipe, list, else_list, false)
    NWith(pipe, list, else_list) =>
      self.walk_if_or_with(dot, pipe, list, else_list, true)
    NRange(pipe, list, else_list) => self.walk_range(dot, pipe, list, else_list)
    NTemplate(name, pipe) => {
      let body = match self.tmpl.trees.get(name) {
        Some(body) => body
        None => exec_fail("template \"\{name}\" not defined")
      }
      if self.depth >= MAX_EXEC_DEPTH {
        exec_fail("exceeded maximum template depth (\{MAX_EXEC_DEPTH})")
      }
      let new_dot = match pipe {
        Some(p) => self.eval_pipeline(dot, p)
        None => Nil
      }
      let inner : State = {
        tmpl: self.tmpl,
        out: self.out,
        vars: [{ name: "$", value: new_dot, }],
        depth: self.depth + 1,
      }
      let _ = inner.walk_list(new_dot, body)
      Normal
    }
    NBreak => Break
    NContinue => Continue
  }
}

///|
fn State::walk_if_or_with(
  self : State,
  dot : Value,
  pipe : Pipe,
  list : Array[Node],
  else_list : Array[Node]?,
  is_with : Bool,
) -> Flow raise TemplateError {
  let mark = self.vars.length()
  let v = self.eval_pipeline(dot, pipe)
  let flow = if truth(v) {
    self.walk_list(if is_with { v } else { dot }, list)
  } else {
    match else_list {
      Some(nodes) => self.walk_list(dot, nodes)
      None => Normal
    }
  }
  self.vars.truncate(mark)
  flow
}

///|
fn State::walk_range(
  self : State,
  dot : Value,
  pipe : Pipe,
  list : Array[Node],
  else_list : Array[Node]?,
) -> Flow raise TemplateError {
  let outer = self.vars.length()
  let v = self.eval_pipeline(dot, pipe)
  let mark = self.vars.length()
  let decl = pipe.decl
  // run the body once; returns false when the loop should stop
  fn one(index : Value, elem : Value) -> Bool raise TemplateError {
    if decl.length() > 0 {
      if pipe.assign {
        if decl.length() > 1 {
          self.set_var(decl[0], index)
        } else {
          self.set_var(decl[0], elem)
        }
      } else {
        self.vars[mark - 1].value = elem
      }
    }
    if decl.length() > 1 {
      if pipe.assign {
        self.set_var(decl[1], elem)
      } else {
        self.vars[mark - 2].value = index
      }
    }
    let flow = self.walk_list(elem, list)
    self.vars.truncate(mark)
    !(flow is Break)
  }
  let mut ran = false
  match v {
    List(items) =>
      for i, item in items {
        ran = true
        if !one(Int(i.to_int64()), item) {
          break
        }
      }
    Dict(d) =>
      for key in sorted_keys(d) {
        ran = true
        if !one(Str(key), d[key]) {
          break
        }
      }
    Int(n) => {
      if decl.length() > 1 {
        exec_fail("can't use \{n} to iterate over more than one variable")
      }
      let mut i = 0L
      while i < n {
        ran = true
        if !one(Int(i), Int(i)) {
          break
        }
        i = i + 1L
      }
    }
    Nil => ()
    _ => exec_fail("range can't iterate over \{display(v)}")
  }
  let flow = if ran {
    Normal
  } else {
    match else_list {
      Some(nodes) => self.walk_list(dot, nodes)
      None => Normal
    }
  }
  self.vars.truncate(outer)
  flow
}

///|
fn display(v : Value) -> String {
  let out = StringBuilder()
  format_value(v, out)
  out.to_string()
}

///|
fn State::eval_pipeline(
  self : State,
  dot : Value,
  pipe : Pipe,
) -> Value raise TemplateError {
  let mut value : Value? = None
  for cmd in pipe.cmds {
    value = Some(self.eval_command(dot, cmd, value))
  }
  let v = match value {
    Some(v) => v
    None => Nil
  }
  for name in pipe.decl {
    if pipe.assign {
      self.set_var(name, v)
    } else {
      self.vars.push({ name, value: v, })
    }
  }
  v
}

///|
fn not_a_function(
  args : Array[Expr],
  final_arg : Value?,
) -> Unit raise TemplateError {
  if args.length() > 1 || final_arg is Some(_) {
    exec_fail("can't give argument to non-function")
  }
}

///|
fn State::eval_command(
  self : State,
  dot : Value,
  cmd : Command,
  final_arg : Value?,
) -> Value raise TemplateError {
  let args = cmd.args
  match args[0] {
    EField(fields) => self.eval_fields(dot, fields, args, final_arg)
    EChain(base, fields) => {
      let receiver = self.eval_arg(dot, base)
      self.eval_fields(receiver, fields, args, final_arg)
    }
    EIdent(name) => self.eval_function(dot, name, args, final_arg)
    EPipe(pipe) => {
      not_a_function(args, final_arg)
      self.eval_pipeline(dot, pipe)
    }
    EVar(name, fields) => {
      let v = self.var_value(name)
      if fields.length() == 0 {
        not_a_function(args, final_arg)
        v
      } else {
        self.eval_fields(v, fields, args, final_arg)
      }
    }
    first => {
      not_a_function(args, final_arg)
      match first {
        EBool(b) => Bool(b)
        EDot => dot
        EInt(i) => Int(i)
        EFloat(f) => Float(f)
        EStr(s) => Str(s)
        EOverflow(text) => exec_fail("\{text} overflows int")
        _ => exec_fail("nil is not a command")
      }
    }
  }
}

///|
/// Follow a chain of field names. Arguments, if any, belong to the last
/// field, and since map entries are never methods they are an error there.
fn State::eval_fields(
  self : State,
  receiver : Value,
  fields : Array[String],
  args : Array[Expr],
  final_arg : Value?,
) -> Value raise TemplateError {
  let mut current = receiver
  let last = fields.length() - 1
  for i, name in fields {
    let has_args = i == last && (args.length() > 1 || final_arg is Some(_))
    // Go tells an entry that holds nil apart from an absent one: stepping
    // through the former is an error, through the latter yields no value.
    if i < last && current is Dict(d) && d.get(name) is Some(Nil) {
      exec_fail("nil pointer evaluating interface {}.\{fields[i + 1]}")
    }
    current = self.eval_field(current, name, has_args)
  }
  current
}

///|
fn State::eval_field(
  self : State,
  receiver : Value,
  name : String,
  has_args : Bool,
) -> Value raise TemplateError {
  match receiver {
    // a field of nothing is nothing, unless missing keys are errors
    Nil => {
      if self.tmpl.missing_key_error {
        exec_fail("nil data; no entry for key \"\{name}\"")
      }
      Nil
    }
    Dict(d) => {
      if has_args {
        exec_fail("\{name} is not a method but has arguments")
      }
      match d.get(name) {
        Some(v) => v
        None => {
          if self.tmpl.missing_key_error {
            exec_fail("map has no entry for key \"\{name}\"")
          }
          Nil
        }
      }
    }
    _ =>
      exec_fail("can't evaluate field \{name} in type \{type_name(receiver)}")
  }
}

///|
fn State::eval_arg(
  self : State,
  dot : Value,
  expr : Expr,
) -> Value raise TemplateError {
  match expr {
    EDot => dot
    ENil => Nil
    EBool(b) => Bool(b)
    EInt(i) => Int(i)
    EFloat(f) => Float(f)
    EStr(s) => Str(s)
    EOverflow(text) => exec_fail("\{text} overflows int")
    EField(fields) => self.eval_fields(dot, fields, [expr], None)
    EVar(name, fields) =>
      self.eval_fields(self.var_value(name), fields, [expr], None)
    EPipe(pipe) => self.eval_pipeline(dot, pipe)
    EIdent(name) => self.eval_function(dot, name, [expr], None)
    EChain(base, fields) =>
      self.eval_fields(self.eval_arg(dot, base), fields, [expr], None)
  }
}

///|
fn State::eval_function(
  self : State,
  dot : Value,
  name : String,
  args : Array[Expr],
  final_arg : Value?,
) -> Value raise TemplateError {
  let user = self.tmpl.funcs.get(name)
  // "and" and "or" stop evaluating at the first argument that decides the result
  if user is None && (name == "and" || name == "or") {
    if args.length() < 2 && final_arg is None {
      exec_fail("wrong number of args for \{name}: want at least 1 got 0")
    }
    let mut v = Nil
    for i in 1..<args.length() {
      v = self.eval_arg(dot, args[i])
      if truth(v) == (name == "or") {
        return v
      }
    }
    if final_arg is Some(f) {
      v = f
    }
    return v
  }
  let argv : Array[Value] = []
  for i in 1..<args.length() {
    argv.push(self.eval_arg(dot, args[i]))
  }
  if final_arg is Some(f) {
    argv.push(f)
  }
  match user {
    Some(f) => (f.0)(argv)
    None => call_builtin(name, argv)
  }
}
