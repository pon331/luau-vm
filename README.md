# luau-vm
Modern Luau VM written in Luau

# Features
- Modern `class` syntax and 64-bit integers are supported
- Uses native codegen for maximum speed
- Currently supported Luau version: `0.732` or lower

# API

## `LuauLoad(Bytecode: buffer, Env: { [string]: any }) -> (...any) -> ...any`
Loads bytecode and returns a function to start the execution

# Example Usage

```luau
const LuauLoad = require(path.to.luauvm)

const Bytecode = buffer.fromstring("\x0c\x03\x02\x05\x70\x72\x69\x6e\x74\x12\x48\x65\x6c\x6c\x6f\x20\x66\x72\x6f\x6d\x20\x4c\x75\x61\x75\x20\x76\x6d\x00\x01\x40\x02\x00\x00\x01\x0a\x00\x07\x41\x00\x00\x00\x0c\x00\x01\x00\x00\x00\x00\x40\x05\x01\x02\x00\x15\x00\x02\x01\x04\x00\x00\x00\x16\x00\x02\x00\x03\x03\x01\x04\x00\x00\x00\x40\x03\x02\x00\x01\x00\x01\x18\x00\x00\x00\x00\x00\x01\x00\x01\x00\x00\x00\x00\x00\x05\x00")
-- Example bytecode: print("Hello from Luau vm") return 0

const Execute = LuauLoad(Bytecode, getfenv())
const ReturnedValue = Execute() -- start the execution
print(ReturnedValue) -- '0'

```
