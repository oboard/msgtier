name = "oboard/msgtier"

version = "0.1.0"

import {
  "moonbitlang/x@0.4.40",
  "oboard/jsonx@0.1.0",
  "moonbitlang/async@0.20.1",
  "tonyfettes/unicode@0.3.2",
  "gmlewis/flate@0.36.9",
  "gmlewis/io@0.23.12",
}

readme = "README.mbt.md"

repository = ""

license = "Apache-2.0"

keywords = [ ]

description = ""

preferred_target = "native"

options(
  "bin-deps": { "oboard/morm": "0.4.0" },
)
