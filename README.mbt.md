# gotemplate

Go's `text/template` language for MoonBit, checked case by case against the
real Go implementation.

Go 标准库 `text/template` 模板语言的 MoonBit 实现。Helm、`kubectl -o go-template`、
`docker --format` 用的都是这套语法。每个行为都拿真实的 Go 逐条对照过。

```mbt check
///|
test "readme: quick start" {
  let data = @json.parse(
    "{\"name\": \"web\", \"ports\": [80, 443], \"labels\": {\"tier\": \"front\"}}",
    preserve_number_repr=true,
  )
  let text =
    #|service {{.name | printf "%q"}}
    #|{{- range $i, $p := .ports}}
    #|  port[{{$i}}] = {{$p}}
    #|{{- end}}
    #|{{- with .labels}}
    #|  tier = {{.tier}}
    #|{{- end}}
  let out = @gotemplate.render(text, @gotemplate.Value::from_json(data))
  assert_eq(
    out,
    (
      #|service "web"
      #|  port[0] = 80
      #|  port[1] = 443
      #|  tier = front
    ),
  )
}
```

## What is covered

- Text, actions, comments, and `{{-` / `-}}` white space trimming.
- Pipelines, variables (`:=` and `=`), `$`, field chains, parenthesized
  pipelines.
- Literals: booleans, integers (decimal, hex, octal, binary, underscores),
  floats (including hex floats), character constants, quoted and raw strings,
  `nil`.
- `if` / `else if` / `else`, `with` / `else with`, `range` over lists, maps
  (in key order) and integers, with `break` and `continue`.
- `define`, `template`, `block`.
- Every built-in function: `and`, `or`, `not`, `len`, `index`, `slice`,
  `print`, `printf`, `println`, `html`, `js`, `urlquery`, `eq`, `ne`, `lt`,
  `le`, `gt`, `ge`.
- `printf` with the verbs `%v %d %s %q %t %c %U %x %X %o %O %b %e %E %f %F %g
  %G %T`, flags, width and precision. Floats are rounded exactly, as Go does.
- Custom functions, and the `missingkey=error` option.

## How it is tested

`tools/oracle` is a small Go program. It feeds every case in
`tools/oracle/cases/*.jsonl` (a template plus JSON data) to Go's own
`text/template` and records whether Go reports a parse error, an execution
error, or what it prints. The MoonBit test suite replays the same cases and
requires the same outcome.

At the moment that is 1118 cases, all matching Go 1.27, on the `wasm`,
`wasm-gc`, `js` and `native` backends. To regenerate the expectations after
adding cases:

```
cd tools/oracle && go run .
moon test
```

Error messages are written in the same spirit as Go's but are not compared
word for word; only the kind of error (parse or execution) is.

## Differences from Go

These are deliberate, and `tools/oracle/cases/known-differences.jsonl` keeps a
test for each so the list cannot go stale.

- **Data model.** Values are `Nil`, `Bool`, `Int` (64-bit), `Float`, `Str`,
  `List` and `Dict` with string keys. There are no structs, methods, pointers,
  channels or function values, so `call` always fails and a field can never
  take arguments.
- **A nil element reached through `range`.** Go refuses to look up a field on
  it; here the lookup gives no value.
- **Complex numbers** are not supported.
- **`\x` and octal escapes above `0x7f`** are rejected, because the result
  would not be valid UTF-8.
- **Template recursion** stops at a depth of 200 (Go: 100000) so that runaway
  recursion ends in an error rather than a stack overflow on WebAssembly.
- **String ordering** in `lt` and for map keys compares UTF-16 code units. It
  differs from Go's byte order only between characters outside the Basic
  Multilingual Plane and those in U+E000..U+FFFF.
- `html/template`'s contextual escaping is out of scope.

## Using it

```mbt check
///|
test "readme: template sets and custom functions" {
  let funcs : Map[String, @gotemplate.Func] = Map([])
  funcs["shout"] = @gotemplate.Func(args => {
    match args {
      [Str(s)] => Str(s.to_upper() + "!")
      _ => raise @gotemplate.ExecError("shout wants one string")
    }
  })
  let page = @gotemplate.Template::new("page").add_funcs(funcs)
  // templates defined by one parse call are visible to later ones
  let _ = page.parse("{{define \"item\"}}<li>{{html .}}</li>{{end}}")
  let _ = page.parse(
    "<h1>{{shout .title}}</h1><ul>{{range .items}}{{template \"item\" .}}{{end}}</ul>",
  )
  let dict : Map[String, @gotemplate.Value] = Map([])
  dict["title"] = Str("news")
  dict["items"] = List([Str("a < b"), Str("c & d")])
  assert_eq(
    page.execute(Dict(dict)),
    "<h1>NEWS!</h1><ul><li>a &lt; b</li><li>c &amp; d</li></ul>",
  )
}
```

Errors are raised as `TemplateError`: `ParseError(line, message)` for syntax
errors and `ExecError(message)` for failures while executing.

```mbt check
///|
test "readme: errors" {
  let result = try @gotemplate.render("{{index . 5}}", List([Int(1L)])) catch {
    ParseError(line, msg) => "parse error on line \{line}: \{msg}"
    ExecError(msg) => "exec error: \{msg}"
  } noraise {
    out => out
  }
  assert_eq(result, "exec error: index out of range: 5")
}
```

`moon run cmd/main` prints a rendered Kubernetes manifest as a larger example.

## About this project

Written for the MoonBit hackathon (November 2026). The code, tests and
documentation were produced mainly with an AI coding assistant (Claude); every
behaviour is accepted only if the differential test against Go passes.

Behaviour follows the public documentation of Go's `text/template` and the
observable output of the reference implementation. No Go source code is
included. Licensed under Apache-2.0.
