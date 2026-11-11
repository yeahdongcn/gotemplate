///|
/// Run one conformance case and describe what happened in the oracle's
/// terms: ("ok", output), ("parse", "") or ("exec", "").
fn run_case(tmpl : String, data : String) -> (String, String) {
  let value = try @json.parse(data, preserve_number_repr=true) catch {
    _ => return ("bad-data", "")
  } noraise {
    json => @gotemplate.Value::from_json(json)
  }
  let parsed = try @gotemplate.Template::new("t").parse(tmpl) catch {
    _ => return ("parse", "")
  } noraise {
    t => t
  }
  try parsed.execute(value) catch {
    _ => ("exec", "")
  } noraise {
    out => ("ok", out)
  }
}

///|
test "conformance with Go text/template" {
  let failures : Array[String] = []
  let mut known = 0
  for entry in conformance_cases {
    let (location, tmpl, data, kind, out) = entry
    let (got_kind, got_out) = run_case(tmpl, data)
    if location.has_prefix("known-differences") {
      // documented deviations: they must still deviate
      known = known + 1
      if got_kind == kind && got_out == out {
        failures.push(
          "\{location}: \{tmpl.escape()} now matches Go; move it out of known-differences",
        )
      }
    } else if got_kind != kind || got_out != out {
      failures.push(
        "\{location}: \{tmpl.escape()} with \{data}\n    want \{kind} \{out.escape()}\n    got  \{got_kind} \{got_out.escape()}",
      )
    }
  }
  if failures.length() > 0 {
    println(
      "\{failures.length()} of \{conformance_cases.length()} cases differ from Go:",
    )
    for i, failure in failures {
      if i < 60 {
        println(failure)
      }
    }
  }
  assert_eq(failures.length(), 0)
  // guard against the generated data going missing
  assert_true(conformance_cases.length() - known >= 1000)
}
