///|
test "parse_lsof_output extracts (protocol, port, addr, cmd)" {
  let raw = "p1234\n" +
    "cnginx\n" +
    "n*:80\n" +
    "n*:443\n" +
    "p5678\n" +
    "cpostgres\n" +
    "n127.0.0.1:5432\n" +
    "n[::1]:5432\n"
  let entries = parse_lsof_output(raw, "tcp")
  inspect(entries.length(), content="4")
  inspect(entries[0].protocol, content="tcp")
  inspect(entries[0].port, content="80")
  inspect(entries[0].bind_addr, content="*")
  inspect(entries[0].process_name.unwrap(), content="nginx")
  inspect(entries[3].bind_addr, content="::1")
  inspect(entries[3].port, content="5432")
  inspect(entries[3].process_name.unwrap(), content="postgres")
}

///|
test "parse_lsof_output skips established connections and invalid rows" {
  let raw = "p10\n" +
    "cbash\n" +
    "n10.0.0.1:5000->10.0.0.2:6000\n" + // established, skip
    "n*:*\n" + // wildcard port, skip
    "n[::]:8080\n" + // valid IPv6 wildcard
    "n\n" // empty n line, skip
  let entries = parse_lsof_output(raw, "tcp")
  inspect(entries.length(), content="1")
  inspect(entries[0].port, content="8080")
  inspect(entries[0].bind_addr, content="::")
}

///|
test "diff_local_ports flags additions and removals by (protocol,port,addr)" {
  let prev = [
    (
      { protocol: "tcp", bind_addr: "*", port: 80, process_name: Some("nginx") } :
      LocalPortEntry),
    {
      protocol: "tcp",
      bind_addr: "127.0.0.1",
      port: 5432,
      process_name: Some("postgres"),
    },
  ]
  let curr = [
    (
      {
        protocol: "tcp",
        bind_addr: "127.0.0.1",
        port: 5432,
        process_name: Some("postgres"),
      } : LocalPortEntry),
    { protocol: "tcp", bind_addr: "*", port: 8080, process_name: Some("app") },
  ]
  let (added, removed) = diff_local_ports(prev, curr)
  inspect(added.length(), content="1")
  inspect(added[0].port, content="8080")
  inspect(removed.length(), content="1")
  inspect(removed[0].port, content="80")
}

///|
test "diff_local_ports treats process_name change as no-op" {
  let prev = [
    (
      {
        protocol: "tcp",
        bind_addr: "127.0.0.1",
        port: 5432,
        process_name: Some("postgres"),
      } : LocalPortEntry),
  ]
  let curr = [
    (
      {
        protocol: "tcp",
        bind_addr: "127.0.0.1",
        port: 5432,
        process_name: Some("postgres-14"),
      } : LocalPortEntry),
  ]
  let (added, removed) = diff_local_ports(prev, curr)
  inspect(added.length(), content="0")
  inspect(removed.length(), content="0")
}

///|
test "is_local_port_broadcast reflects update_local_broadcast_set" {
  update_local_broadcast_set([
    { protocol: "tcp", bind_addr: "*", port: 8080, process_name: None },
    { protocol: "udp", bind_addr: "*", port: 53, process_name: None },
  ])
  inspect(is_local_port_broadcast("tcp", 8080), content="true")
  inspect(is_local_port_broadcast("udp", 53), content="true")
  inspect(is_local_port_broadcast("tcp", 53), content="false")
  inspect(is_local_port_broadcast("tcp", 9999), content="false")
  update_local_broadcast_set([])
  inspect(is_local_port_broadcast("tcp", 8080), content="false")
}
