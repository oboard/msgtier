///|
test "resolve script request uses script name directly" {
  let scripts = { "deploy": "echo deploy" }
  let (name, args) = resolve_script_request("deploy --force", scripts)
  inspect(name, content="deploy")
  inspect(args.length(), content="1")
  inspect(args[0], content="--force")
}

///|
test "resolve script request accepts interpreter prefix" {
  let scripts = { "deploy": "echo deploy" }
  let (name, args) = resolve_script_request("bash deploy --force", scripts)
  inspect(name, content="deploy")
  inspect(args.length(), content="1")
  inspect(args[0], content="--force")
}

///|
test "resolve script request preserves unknown command" {
  let scripts = { "deploy": "echo deploy" }
  let (name, args) = resolve_script_request("bash --version", scripts)
  inspect(name, content="bash")
  inspect(args.length(), content="1")
  inspect(args[0], content="--version")
}
