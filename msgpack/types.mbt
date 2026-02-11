// MessagePack types

// Define MessagePack value types

///|
pub enum Value {
  // Null value
  Nil
  // Boolean value
  Bool(Bool)
  // 32-bit signed integer
  Int(Int)
  // 64-bit signed integer
  Int64(Int64)
  // 64-bit unsigned integer
  UInt64(UInt64)
  // Double precision floating point
  Float(Double)
  // String
  String(String)
  // Binary data
  Binary(Bytes)
  // Array
  Array(Array[Value])
  // Map/Dictionary
  Map(Map[String, Value])
} derive(Show, Debug, Eq)

///|
pub impl ToJson for Value with to_json(self) {
  match self {
    Map(m) => Json::object(m.map((_, value) => value.to_json()))
    Bool(b) => Json::boolean(b)
    Int(i) => Json::number(i.to_double())
    Float(i) => Json::number(i)
    Int64(i) => Json::number(i.to_double())
    UInt64(i) => Json::number(i.to_double())
    String(s) => Json::string(s)
    Array(arr) => Json::array(arr.map(fn(x) { x.to_json() }))
    Binary(b) => Json::array(b.to_array().map(fn(x) { x.to_json() }))
    Nil => Json::null()
  }
}

// Error types

///|
pub(all) suberror MsgPackError {
  // Type mismatch error
  TypeMismatch(String)
  // Invalid data error
  InvalidData(String)
}

// Implement to_string method for MsgPackError

///|
pub fn MsgPackError::to_string(self : MsgPackError) -> String {
  match self {
    TypeMismatch(msg) => "TypeMismatch: " + msg
    InvalidData(msg) => "InvalidData: " + msg
  }
}

// MessagePack format code constants

///|
pub const NIL_CODE : Int = 0xc0

///|
pub const FALSE_CODE : Int = 0xc2

///|
pub const TRUE_CODE : Int = 0xc3

///|
pub const INT8_CODE : Int = 0xd0

///|
pub const INT16_CODE : Int = 0xd1

///|
pub const INT32_CODE : Int = 0xd2

///|
pub const INT64_CODE : Int = 0xd3

///|
pub const UINT64_CODE : Int = 0xcf

///|
pub const UINT32_CODE : Int = 0xce

///|
pub const FLOAT32_CODE : Int = 0xca

///|
pub const FLOAT64_CODE : Int = 0xcb

///|
pub const BIN16_CODE : Int = 0xc5

///|
pub const BIN32_CODE : Int = 0xc6

///|
pub const FIXSTR_CODE : Int = 0xa0

///|
pub const STR8_CODE : Int = 0xd9

///|
pub const STR16_CODE : Int = 0xda

///|
pub const STR32_CODE : Int = 0xdb

///|
pub const BIN8_CODE : Int = 0xc4

///|
pub const FIXARRAY_CODE : Int = 0x90

///|
pub const ARRAY16_CODE : Int = 0xdc

///|
pub const ARRAY32_CODE : Int = 0xdd

///|
pub const FIXMAP_CODE : Int = 0x80

///|
pub const MAP16_CODE : Int = 0xde

///|
pub const MAP32_CODE : Int = 0xdf

// Negative fixint 0xe0 - 0xff

///|
pub const NEGATIVE_FIXINT_CODE : Int = 0xe0

// Helper functions for creating values

///|
pub fn nil() -> Value {
  Nil
}

///|
pub fn bool(b : Bool) -> Value {
  Bool(b)
}

///|
pub fn int(i : Int) -> Value {
  Int(i)
}

///|
pub fn int64(i : Int64) -> Value {
  Int64(i)
}

///|
pub fn uint64(u : UInt64) -> Value {
  UInt64(u)
}

///|
pub fn float(f : Double) -> Value {
  Float(f)
}

///|
pub fn string(s : String) -> Value {
  String(s)
}

///|
pub fn binary(b : Bytes) -> Value {
  Binary(b)
}

///|
pub fn array(arr : Array[Value]) -> Value {
  Array(arr)
}

///|
pub fn map(map : Map[String, Value]) -> Value {
  Map(map)
}

// Conversion functions

///|
pub fn Value::to_string(self : Value) -> Result[String, MsgPackError] {
  match self {
    String(s) => Ok(s)
    _ => Err(TypeMismatch("Expected string"))
  }
}

///|
pub fn Value::to_int(self : Value) -> Result[Int, MsgPackError] {
  match self {
    Int(i) => Ok(i)
    _ => Err(TypeMismatch("Expected int"))
  }
}

///|
pub fn Value::to_bool(self : Value) -> Result[Bool, MsgPackError] {
  match self {
    Bool(b) => Ok(b)
    _ => Err(TypeMismatch("Expected bool"))
  }
}
