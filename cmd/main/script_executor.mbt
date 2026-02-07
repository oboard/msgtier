///|
struct ScriptOutput {
  exit_code : Int
  output : String
} derive(ToJson)

///|
fn ScriptOutput::to_msgpack(self : ScriptOutput) -> @msgpack.Value {
  @msgpack.map({
    "exit_code": @msgpack.int(self.exit_code),
    "output": @msgpack.string(self.output),
  })
}

///|
pub async fn execute_script_handler(content : String) -> ScriptOutput? {
  match global_config.val {
    Some({ scripts: Some(scripts), .. }) =>
      Some(process_script_execution(content, scripts))
    _ => None
  }
}

///|
async fn execute_script_with_output(
  program : String,
  args : Array[String],
  input_data : String,
) -> ScriptOutput {
  // Create a pipe for stdin if we have input data
  let (stdin_r, stdin_w) = @pipe.pipe()
  let (stdout_r, stdout_w) = @pipe.pipe()

  // Write input data to stdin pipe in a background task
  if input_data.length() > 0 {
    // Write input and close write end
    stdin_w.write(@utf8.encode(input_data)) |> ignore
  }
  stdin_w.close()
  defer stdout_r.close()
  defer stdin_r.close()

  // Execute and capture output directly
  let exit_code = @process.run(program, args, stdin=stdin_r, stdout=stdout_w)
  stdout_w.close()
  { exit_code, output: stdout_r.read_all().text() }
}

///|
fn parse_command_args(command : String) -> Array[String] {
  let args = []
  let mut current_arg = StringBuilder::new()
  let mut in_single_quote = false
  let mut in_double_quote = false
  let mut escaped = false
  for i = 0; i < command.length(); i = i + 1 {
    let c = command[i].to_int().unsafe_to_char()
    if escaped {
      current_arg.write_char(c)
      escaped = false
    } else {
      match c {
        '\\' => escaped = true
        '\'' =>
          if !in_double_quote {
            in_single_quote = !in_single_quote
          } else {
            current_arg.write_char(c)
          }
        '"' =>
          if !in_single_quote {
            in_double_quote = !in_double_quote
          } else {
            current_arg.write_char(c)
          }
        ' ' | '\t' | '\n' | '\r' =>
          if in_single_quote || in_double_quote {
            current_arg.write_char(c)
          } else if current_arg.to_string().length() > 0 {
            args.push(current_arg.to_string())
            current_arg = StringBuilder::new()
          }
        _ => current_arg.write_char(c)
      }
    }
  }
  if current_arg.to_string().length() > 0 {
    args.push(current_arg.to_string())
  }
  args
}

///|
async fn process_script_execution(
  content_str : String,
  scripts : Map[String, String],
) -> ScriptOutput {
  let parts = content_str.split(" ").to_array()
  let (name, args) = match parts {
    [name, .. args] => (name, args)
    _ => {
      let empty : Array[StringView] = []
      (""[:], empty[:])
    }
  }
  match scripts.get(name.to_string()) {
    Some(command) => {
      // Split command string into program and args using proper parser
      let cmd_parts = parse_command_args(command)
      let (program, cmd_args) = match cmd_parts {
        [prog, .. rest] => (prog, rest)
        _ => ("", [])
      }

      // Append user-provided args to command args
      let final_args = []
      final_args.push_iter(cmd_args.iter())
      final_args.push_iter(args.iter().map(fn(s) { s.to_string() }))
      println("[script]\t\{content_str}")
      execute_script_with_output(program, final_args, "")
    }
    None => {
      println("Script not found: \{content_str}")
      { exit_code: 1, output: "Script not found: \{content_str}" }
    }
  }
}
