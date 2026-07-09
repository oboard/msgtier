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

///|
test "decode_proc_net_ipv4 reverses little-endian hex" {
  inspect(decode_proc_net_ipv4("0100007F").unwrap(), content="127.0.0.1")
  inspect(decode_proc_net_ipv4("00000000").unwrap(), content="0.0.0.0")
  inspect(decode_proc_net_ipv4("0101A8C0").unwrap(), content="192.168.1.1")
}

///|
test "decode_proc_net_ipv6 handles ::, ::1 and v4-mapped" {
  // ::
  inspect(
    decode_proc_net_ipv6("00000000000000000000000000000000").unwrap(),
    content="::",
  )
  // ::1  — last 32-bit word (little-endian) is 0x01000000
  inspect(
    decode_proc_net_ipv6("00000000000000000000000001000000").unwrap(),
    content="::1",
  )
  // v4-mapped ::ffff:127.0.0.1 — network-order bytes are
  //   00 00 00 00 00 00 00 00 00 00 FF FF 7F 00 00 01, printed as four
  //   little-endian 32-bit words: 00000000 00000000 FFFF0000 0100007F.
  inspect(
    decode_proc_net_ipv6("0000000000000000FFFF00000100007F").unwrap(),
    content="127.0.0.1",
  )
}

///|
test "parse_proc_net skips header and keeps only TCP LISTEN" {
  let raw = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n" +
    "   0: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12345 1 0000000000000000 100 0 0 10 0\n" +
    "   1: 0100007F:1F91 0100007F:C000 01 00000000:00000000 00:00000000 00000000     0        0 12346 1 0000000000000000 100 0 0 10 0\n"
  let entries = parse_proc_net(raw, "tcp", is_v6=false, listen_only=true)
  inspect(entries.length(), content="1")
  inspect(entries[0].protocol, content="tcp")
  inspect(entries[0].bind_addr, content="0.0.0.0")
  inspect(entries[0].port, content="8080")
  inspect(entries[0].process_name is None, content="true")
}

///|
test "parse_proc_net for UDP does not filter by state" {
  let raw = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops\n" +
    "   0: 00000000:0035 00000000:0000 07 00000000:00000000 00:00000000 00000000     0        0 22222 2 0000000000000000 0\n"
  let entries = parse_proc_net(raw, "udp", is_v6=false, listen_only=false)
  inspect(entries.length(), content="1")
  inspect(entries[0].port, content="53")
  inspect(entries[0].bind_addr, content="0.0.0.0")
}

///|
test "parse_proc_net decodes IPv6 rows" {
  let raw = "  sl  local_address                         rem_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n" +
    "   0: 00000000000000000000000000000000:1F90 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 55555 1 0000000000000000 100 0 0 10 0\n"
  let entries = parse_proc_net(raw, "tcp", is_v6=true, listen_only=true)
  inspect(entries.length(), content="1")
  inspect(entries[0].bind_addr, content="::")
  inspect(entries[0].port, content="8080")
}
