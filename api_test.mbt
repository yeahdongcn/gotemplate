///|
fn data(json : String) -> @gotemplate.Value {
  @gotemplate.Value::from_json(
    @json.parse(json, preserve_number_repr=true) catch {
      _ => Json::null()
    },
  )
}

///|
test "render parses and executes in one step" {
  let out = @gotemplate.render(
    "Hello, {{.name}}! You have {{len .items}} items.",
    data("{\"name\": \"Ada\", \"items\": [1, 2, 3]}"),
  )
  assert_eq(out, "Hello, Ada! You have 3 items.")
}

///|
test "values can be built directly" {
  let dict : Map[String, @gotemplate.Value] = Map([])
  dict["n"] = Int(41L)
  dict["tags"] = List([Str("a"), Str("b")])
  let out = @gotemplate.render(
    "{{.n}} {{range .tags}}<{{.}}>{{end}}",
    Dict(dict),
  )
  assert_eq(out, "41 <a><b>")
}

///|
test "custom functions" {
  let funcs : Map[String, @gotemplate.Func] = Map([])
  funcs["upper"] = @gotemplate.Func(args => {
    match args {
      [Str(s)] => Str(s.to_upper())
      _ => raise @gotemplate.ExecError("upper wants one string")
    }
  })
  funcs["add"] = @gotemplate.Func(args => {
    let mut sum = 0L
    for arg in args {
      match arg {
        Int(i) => sum = sum + i
        _ => raise @gotemplate.ExecError("add wants integers")
      }
    }
    Int(sum)
  })
  let t = @gotemplate.Template::new("t")
    .add_funcs(funcs)
    .parse("{{upper .}} {{add 1 2 3}} {{. | upper | printf \"%q\"}}")
  assert_eq(t.execute(Str("go")), "GO 6 \"GO\"")
  // an error raised by a function stops execution
  let failed = try t.execute(Int(1L)) catch {
    ExecError(msg) => msg
    ParseError(_, msg) => msg
  } noraise {
    _ => "no error"
  }
  assert_eq(failed, "upper wants one string")
}

///|
test "an unknown function is a parse error unless registered first" {
  let unknown = try @gotemplate.Template::new("t").parse("{{shout .}}") catch {
    ParseError(line, msg) => "\{line}: \{msg}"
    ExecError(msg) => msg
  } noraise {
    _ => "parsed"
  }
  assert_eq(unknown, "1: function \"shout\" not defined")
}

///|
test "a custom function may replace a built-in" {
  let funcs : Map[String, @gotemplate.Func] = Map([])
  funcs["len"] = @gotemplate.Func(_args => Str("mine"))
  let t = @gotemplate.Template::new("t").add_funcs(funcs).parse("{{len .}}")
  assert_eq(t.execute(Str("abc")), "mine")
}

///|
test "parse errors carry the line number" {
  let message = try
    @gotemplate.Template::new("t").parse("line one\nline two\n{{if}}\n")
  catch {
    err => err.to_string()
  } noraise {
    _ => "parsed"
  }
  assert_eq(message, "template: parse error at line 3: missing value for if")
}

///|
test "missing keys can be made an error" {
  let t = @gotemplate.Template::new("t").parse("{{.present}}{{.absent}}")
  let value = data("{\"present\": 1}")
  assert_eq(t.execute(value), "1<no value>")
  let strict = try t.error_on_missing_key(true).execute(value) catch {
    ExecError(msg) => msg
    ParseError(_, msg) => msg
  } noraise {
    out => out
  }
  assert_eq(strict, "map has no entry for key \"absent\"")
}

///|
test "templates accumulate across parse calls" {
  let t = @gotemplate.Template::new("page")
  let _ = t.parse("{{define \"header\"}}<h1>{{.}}</h1>{{end}}")
  let _ = t.parse("{{define \"footer\"}}<hr>{{end}}")
  let _ = t.parse("{{template \"header\" .title}}body{{template \"footer\"}}")
  assert_eq(t.defined_templates(), ["footer", "header", "page"])
  assert_eq(t.execute(data("{\"title\": \"Hi\"}")), "<h1>Hi</h1>body<hr>")
  assert_eq(t.execute_template("header", Str("x")), "<h1>x</h1>")
  // a later definition replaces an earlier one
  let _ = t.parse("{{define \"footer\"}}<footer/>{{end}}")
  assert_eq(t.execute_template("footer", Nil), "<footer/>")
}

///|
test "executing an unknown template is an error" {
  let t = @gotemplate.Template::new("t").parse("x")
  let result = try t.execute_template("nope", Nil) catch {
    _ => "error"
  } noraise {
    out => out
  }
  assert_eq(result, "error")
}

///|
test "runaway recursion ends in an error" {
  let t = @gotemplate.Template::new("t").parse(
    "{{define \"loop\"}}{{template \"loop\"}}{{end}}{{template \"loop\"}}",
  )
  let result = try t.execute(Nil) catch {
    ExecError(msg) => msg
    ParseError(_, msg) => msg
  } noraise {
    out => out
  }
  assert_eq(result, "exceeded maximum template depth (200)")
}

///|
test "JSON numbers keep their integer or float nature" {
  assert_eq(@gotemplate.render("{{printf \"%T\" .}}", data("3")), "int")
  assert_eq(@gotemplate.render("{{printf \"%T\" .}}", data("3.0")), "float64")
  assert_eq(@gotemplate.render("{{printf \"%T\" .}}", data("3e0")), "float64")
  // without the original text, integral values are treated as integers
  assert_eq(
    @gotemplate.render("{{printf \"%T\" .}}", @gotemplate.Value::from_json(7)),
    "int",
  )
  assert_eq(
    @gotemplate.render("{{printf \"%T\" .}}", @gotemplate.Value::from_json(7.5)),
    "float64",
  )
}
