---
# https://vitepress.dev/reference/default-theme-home-page
layout: home

hero:
  name: "MsgTier"
  text: "Powered By MoonBit"
  tagline: "A decentralized, secure, RPC-enabled P2P network solution"
  actions:
    - theme: brand
      text: Get Started
      link: /get-started
    - theme: alt
      text: Download
      link: /download

features:
  - title: Auto-Discovery
    details: Nodes automatically discover peers through the network gossip protocol.
  - title: End-to-End Encryption
    details: X25519 ECDH key exchange with symmetric encryption for secure communication.
  - title: Message Relay
    details: Messages are automatically relayed through intermediate peers to reach distant nodes.
  - title: Health Checks
    details: Continuous heartbeat monitoring with automatic failure detection and reconnection.
  - title: Script Execution
    details: Execute custom scripts on message receipt using platform-specific shells.
  - title: Multi-Transport
    details: Support for UDP, TCP, and WebSocket protocols for flexible connectivity.
  - title: Cross-Platform
    details: Runs on Windows, macOS, and Linux with zero external dependencies.
---
