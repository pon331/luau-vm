--!native
--!optimize 2
--!strict

const LBC_VERSION_MIN = 3
const LBC_VERSION_MAX = 12

const LBC_TYPE_VERSION_MIN = 1
const LBC_TYPE_VERSION_MAX = 3

@native const function ReadVarInt(B: buffer, Offset: number): (number, number)
	local Result = 0
	local Shift = 0
	local Length = 0

	while true do
		const Byte = buffer.readu8(B, Offset + Length)
		Length += 1
		Result = bit32.bor(Result, bit32.lshift(bit32.band(Byte, 0x7f), Shift))
		if bit32.band(Byte, 0x80) == 0 then
			break
		end
		Shift += 7
	end

	return Result, Length
end

local ReadVarInt64: (B: buffer, Offset: number) -> (integer, number)
if integer then
	const band_int = integer.create(0x7f)
	ReadVarInt64 = @native function(B: buffer, Offset: number): (integer, number)
		local Result = integer.create(0)
		local Shift = 0
		local Length = 0
		while true do
			const Byte = buffer.readu8(B, Offset + Length)
			Length += 1
			Result = integer.bor(Result, integer.lshift(integer.band(integer.create(Byte), band_int :: integer), integer.create(Shift)))
			if bit32.band(Byte, 0x80) == 0 then
				break
			end
			Shift += 7
		end
		return Result, Length
	end
else
	-- no integer library, using fallback
	ReadVarInt64 = ReadVarInt
end

export type Upvalue = {
	value: any,
	store: { any }?,
	index: number?
}

export type Proto = {
	read Code: buffer,
	read SizeCode: number,
	read Constants: { any },
	read Protos: { Proto },
	read NumParams: number,
	read IsVarArg: boolean,
	read MaxStackSize: number,
	read Nups: number,
	read LineDefined: number,
	read DebugName: string,
	read LineInfo: { number }?,
}

@native const function LuauExecute(MainProto: Proto, Env: { [string]: any }, Upvals: { Upvalue }, Args: { [number]: any, n: number }): ...any
	const NumArgs = Args.n
	const Code = MainProto.Code
	const Constants = MainProto.Constants
	const Protos = MainProto.Protos
	const NumParams = MainProto.NumParams
	const IsVarArg = MainProto.IsVarArg
	const MaxStackSize = MainProto.MaxStackSize
	const CodeLength = MainProto.SizeCode

	const Stack = table.create(MaxStackSize) :: { any }
	local VarArgs: { any } = {}
	local VarArgAmount: number = 0

	const ParamsAmount = if NumArgs < NumParams then NumArgs else NumParams
	table.move(Args, 1, ParamsAmount, 1, Stack)
	if IsVarArg then
		VarArgAmount = NumArgs - NumParams
		if VarArgAmount > 0 then
			VarArgs = table.create(VarArgAmount)
			table.move(Args, NumParams + 1, NumParams + VarArgAmount, 1, VarArgs)
		else
			VarArgAmount = 0
			VarArgs = {}
		end
	end

	const OpenUpvalues: { [number]: Upvalue } = {}

	local StackTop: number?

	local PC = 0
	while true do
		if PC > CodeLength then
			return
		end
		const Instruction = buffer.readu32(Code, PC * 4)
		const Opcode = bit32.band(Instruction, 0xFF)
		PC += 1
		if Opcode < 44 then
			if Opcode < 22 then
				if Opcode < 11 then
					if Opcode == 2 then -- LOADNIL
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						Stack[A] = nil
					elseif Opcode == 3 then -- LOADB
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF)
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF)
						Stack[A] = B ~= 0
						PC += C
					elseif Opcode == 4 then -- LOADN
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						local D = bit32.rshift(Instruction, 16)
						if D >= 0x8000 then
							D -= 0x10000
						end
						Stack[A] = D
					elseif Opcode == 5 then -- LOADK
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const D = bit32.rshift(Instruction, 16) + 1
						Stack[A] = Constants[D]
					elseif Opcode == 6 then -- MOVE
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						Stack[A] = Stack[B]
					elseif Opcode == 7 then -- GETGLOBAL
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const Key = Constants[buffer.readu32(Code, PC * 4) + 1]
						PC += 1
						Stack[A] = Env[Key]
					elseif Opcode == 8 then -- SETGLOBAL
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const Key = Constants[buffer.readu32(Code, PC * 4) + 1]
						PC += 1
						Env[Key] = Stack[A]
					elseif Opcode == 9 then -- GETUPVAL
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const Upvalue = Upvals[B]
						const Store = Upvalue.store
						if Store then
							Stack[A] = Store[Upvalue.index :: number]
						else
							Stack[A] = Upvalue.value
						end
					elseif Opcode == 10 then -- SETUPVAL
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const Upvalue = Upvals[B]
						const Store = Upvalue.store
						if Store then
							Store[Upvalue.index :: number] = Stack[A]
						else
							Upvalue.value = Stack[A]
						end
					end
				else
					if Opcode == 11 then -- CLOSEUPVALS
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						for reg, uv in OpenUpvalues do
							if reg >= A then
								uv.value = Stack[reg]
								uv.store = nil
								uv.index = nil
								OpenUpvalues[reg] = nil
							end
						end
					elseif Opcode == 12 then -- GETIMPORT
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const KV = Constants[bit32.rshift(Instruction, 16) + 1]
						const Aux = buffer.readu32(Code, PC * 4)
						PC += 1

						if KV ~= nil then
							Stack[A] = KV
						else
							const Count = bit32.rshift(Aux, 30)

							const Id0 = bit32.band(bit32.rshift(Aux, 20), 1023) + 1
							const Id1 = bit32.band(bit32.rshift(Aux, 10), 1023) + 1
							const Id2 = bit32.band(Aux, 1023) + 1

							local Result: any?
							const Key = Constants[Id0] :: string
							Result = Env[Key]
							if Count >= 2 and Result ~= nil then
								Result = Result[Constants[Id1]]
							end
							if Count >= 3 and Result ~= nil then
								Result = Result[Constants[Id2]]
							end
							Stack[A] = Result
						end
					elseif Opcode == 13 then -- GETTABLE
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						Stack[A] = Stack[B][Stack[C]]
					elseif Opcode == 14 then -- SETTABLE
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						Stack[B][Stack[C]] = Stack[A]
					elseif Opcode == 15 then -- GETTABLEKS
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const Aux = buffer.readu32(Code, PC * 4) + 1
						PC += 1
						Stack[A] = Stack[B][Constants[Aux]]
					elseif Opcode == 16 then -- SETTABLEKS
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const Aux = buffer.readu32(Code, PC * 4) + 1
						PC += 1
						Stack[B][Constants[Aux]] = Stack[A]
					elseif Opcode == 17 then -- GETTABLEN
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						Stack[A] = Stack[B][C]
					elseif Opcode == 18 then -- SETTABLEN
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						Stack[B][C] = Stack[A]
					elseif Opcode == 19 then -- NEWCLOSURE
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const Proto = Protos[bit32.rshift(Instruction, 16) + 1] :: Proto
						const Nups = Proto.Nups
						const ClosureUpvals = table.create(Nups) :: { Upvalue }

						Stack[A] = @native function(...: any): ...any
							return LuauExecute(Proto, Env, ClosureUpvals, table.pack(...))
						end

						for i = 1, Nups do
							const Aux = buffer.readu32(Code, PC * 4)
							PC += 1
							const CaptureType = bit32.band(bit32.rshift(Aux, 8), 0xFF)
							const CaptureIndex = bit32.band(bit32.rshift(Aux, 16), 0xFF) + 1

							if CaptureType == 0 then
								ClosureUpvals[i] = { value = Stack[CaptureIndex], store = nil, index = nil }
							elseif CaptureType == 1 then
								const ExistingUpvalue = OpenUpvalues[CaptureIndex]
								if ExistingUpvalue then
									ClosureUpvals[i] = ExistingUpvalue
									continue
								end
								const Upvalue: Upvalue = {
									value = nil,
									store = Stack,
									index = CaptureIndex,
								}
								OpenUpvalues[CaptureIndex] = Upvalue
								ClosureUpvals[i] = Upvalue
							elseif CaptureType == 2 then
								ClosureUpvals[i] = Upvals[CaptureIndex]
							end
						end
					elseif Opcode == 20 then -- NAMECALL
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const Aux = buffer.readu32(Code, PC * 4) + 1
						PC += 1
						const Object = Stack[B]
						Stack[A + 1] = Object
						Stack[A] = Object[Constants[Aux]]
					elseif Opcode == 21 then -- CALL
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						const NParams = B - 2
						const NResults = C - 2
						const Function = Stack[A]

						local CallArgs: { any }
						local ActualParams: number

						if NParams == -1 then
							local Top: number = StackTop :: number
							if Top == nil then
								Top = A
							end
							ActualParams = Top - A
							if ActualParams < 0 then
								ActualParams = 0
							end
							CallArgs = table.create(ActualParams)
							table.move(Stack, A + 1, A + ActualParams, 1, CallArgs)
						else
							ActualParams = NParams
							CallArgs = table.create(NParams)
							table.move(Stack, A + 1, A + NParams, 1, CallArgs)
						end

						const FunctionResult = table.pack(Function(table.unpack(CallArgs, 1, ActualParams)))
						const NumResults = FunctionResult.n
						const Base = A - 1
						if NResults == -1 then
							table.move(FunctionResult, 1, NumResults, Base + 1, Stack)
							for i = NumResults + 1, MaxStackSize - Base do
								Stack[Base + i] = nil
							end
							StackTop = Base + NumResults
						else
							for i = 1, NResults do
								Stack[Base + i] = if i <= NumResults then FunctionResult[i] else nil
							end
						end
					end
				end
			else
				if Opcode < 33 then
					if Opcode == 22 then -- RETURN
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF)
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const NResults = B - 2

						for reg, uv in OpenUpvalues do
							uv.value = Stack[reg]
							uv.store = nil
							uv.index = nil
							OpenUpvalues[reg] = nil
						end

						if NResults == -1 then
							local Top: number = StackTop :: number
							if Top == nil then
								Top = A
							end
							const Count = Top - A
							if Count <= 0 then
								return
							end
							const ReturnedValues = table.create(Count)
							table.move(Stack, A + 1, A + Count, 1, ReturnedValues)
							return table.unpack(ReturnedValues, 1, Count)
						elseif NResults == 0 then
							return
						else
							const ReturnedValues = table.create(NResults)
							table.move(Stack, A + 1, A + NResults, 1, ReturnedValues)
							return table.unpack(ReturnedValues, 1, NResults)
						end
					elseif Opcode == 23 then -- JUMP
						local D = bit32.rshift(Instruction, 16)
						if D >= 0x8000 then
							D -= 0x10000
						end
						PC += D
					elseif Opcode == 24 then -- JUMPBACK
						local D = bit32.rshift(Instruction, 16)
						if D >= 0x8000 then
							D -= 0x10000
						end
						PC += D
					elseif Opcode == 25 then -- JUMPIF
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						if Stack[A] then
							local D = bit32.rshift(Instruction, 16)
							if D >= 0x8000 then
								D -= 0x10000
							end
							PC += D
						end
					elseif Opcode == 26 then -- JUMPIFNOT
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						if not Stack[A] then
							local D = bit32.rshift(Instruction, 16)
							if D >= 0x8000 then
								D -= 0x10000
							end
							PC += D
						end
					elseif Opcode == 27 then -- JUMPIFEQ
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const Aux = buffer.readu32(Code, PC * 4)
						if Stack[A] == Stack[bit32.band(Aux, 0xFF) + 1] then
							local D = bit32.rshift(Instruction, 16)
							if D >= 0x8000 then
								D -= 0x10000
							end
							PC += D
						else
							PC += 1
						end
					elseif Opcode == 28 then -- JUMPIFLE
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const Aux = buffer.readu32(Code, PC * 4)
						if Stack[A] <= Stack[bit32.band(Aux, 0xFF) + 1] then
							local D = bit32.rshift(Instruction, 16)
							if D >= 0x8000 then
								D -= 0x10000
							end
							PC += D
						else
							PC += 1
						end
					elseif Opcode == 29 then -- JUMPIFLT
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const Aux = buffer.readu32(Code, PC * 4)
						if Stack[A] < Stack[bit32.band(Aux, 0xFF) + 1] then
							local D = bit32.rshift(Instruction, 16)
							if D >= 0x8000 then
								D -= 0x10000
							end
							PC += D
						else
							PC += 1
						end
					elseif Opcode == 30 then -- JUMPIFNOTEQ
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const Aux = buffer.readu32(Code, PC * 4)
						if Stack[A] ~= Stack[bit32.band(Aux, 0xFF) + 1] then
							local D = bit32.rshift(Instruction, 16)
							if D >= 0x8000 then
								D -= 0x10000
							end
							PC += D
						else
							PC += 1
						end
					elseif Opcode == 31 then -- JUMPIFNOTLE
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const Aux = buffer.readu32(Code, PC * 4)
						if not (Stack[A] <= Stack[bit32.band(Aux, 0xFF) + 1]) then
							local D = bit32.rshift(Instruction, 16)
							if D >= 0x8000 then
								D -= 0x10000
							end
							PC += D
						else
							PC += 1
						end
					elseif Opcode == 32 then -- JUMPIFNOTLT
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const Aux = buffer.readu32(Code, PC * 4)
						if not (Stack[A] < Stack[bit32.band(Aux, 0xFF) + 1]) then
							local D = bit32.rshift(Instruction, 16)
							if D >= 0x8000 then
								D -= 0x10000
							end
							PC += D
						else
							PC += 1
						end
					end
				else
					if Opcode == 33 then
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						Stack[A] = Stack[B] + Stack[C]
					elseif Opcode == 34 then
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						Stack[A] = Stack[B] - Stack[C]
					elseif Opcode == 35 then
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						Stack[A] = Stack[B] * Stack[C]
					elseif Opcode == 36 then
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						Stack[A] = Stack[B] / Stack[C]
					elseif Opcode == 37 then
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						Stack[A] = Stack[B] % Stack[C]
					elseif Opcode == 38 then
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						Stack[A] = Stack[B] ^ Stack[C]
					elseif Opcode == 39 then
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						Stack[A] = Stack[B] + Constants[C]
					elseif Opcode == 40 then
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						Stack[A] = Stack[B] - Constants[C]
					elseif Opcode == 41 then
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						Stack[A] = Stack[B] * Constants[C]
					elseif Opcode == 42 then
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						Stack[A] = Stack[B] / Constants[C]
					elseif Opcode == 43 then
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						Stack[A] = Stack[B] % Constants[C]
					end
				end
			end
		else
			if Opcode < 66 then
				if Opcode < 55 then
					if Opcode == 44 then
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						Stack[A] = Stack[B] ^ Constants[C]
					elseif Opcode == 45 then -- AND
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						const Value = Stack[B]
						Stack[A] = if not Value then Value else Stack[C]
					elseif Opcode == 46 then -- OR
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						const Value = Stack[B]
						Stack[A] = if not Value then Stack[C] else Value
					elseif Opcode == 47 then -- ANDK
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						const Value = Stack[B]
						Stack[A] = if not Value then Value else Constants[C]
					elseif Opcode == 48 then -- ORK
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						const Value = Stack[B]
						Stack[A] = if not Value then Constants[C] else Value
					elseif Opcode == 49 then -- CONCAT
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF)
						local Result = Stack[B]
						for i = B, C do
							Result ..= Stack[i + 1]
						end
						Stack[A] = Result
					elseif Opcode == 50 then -- NOT
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						Stack[A] = not Stack[B]
					elseif Opcode == 51 then -- MINUS
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						Stack[A] = -Stack[B]
					elseif Opcode == 52 then -- LENGTH
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						Stack[A] = #Stack[B]
					elseif Opcode == 53 then -- NEWTABLE
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF)
						PC += 1
						Stack[A] = table.create(if B == 0 then 0 else bit32.lshift(1, B - 1))
					elseif Opcode == 54 then -- DUPTABLE
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						local D = bit32.rshift(Instruction, 16)
						if D >= 0x8000 then
							D -= 0x10000
						end
						const Template = Constants[D + 1] :: { [any]: any }
						const Table = {} :: { [any]: any }
						for Key, Value in Template do
							Table[Key] = Value
						end
						Stack[A] = Table
					end
				else
					if Opcode == 55 then -- SETLIST
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF)
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) - 1
						const Aux = buffer.readu32(Code, PC * 4)
						PC += 1
						const T = Stack[A]

						local Count: number
						if C == -1 then
							local TOp: number = StackTop :: number
							if TOp == nil then
								TOp = B
							end
							Count = TOp - B
							if Count < 0 then Count = 0 end
						else
							Count = C
						end
						table.move(Stack, B + 1, B + Count, Aux, T)
					elseif Opcode == 56 then -- FORNPREP
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const Limit = tonumber(Stack[A]) :: number
						const Step = tonumber(Stack[A + 1]) :: number
						const Index = tonumber(Stack[A + 2]) :: number
						Stack[A] = Limit
						Stack[A + 1] = Step
						Stack[A + 2] = Index

						if not (Step > 0 and Index <= Limit or Step <= 0 and Limit <= Index) then
							local D = bit32.rshift(Instruction, 16)
							if D >= 0x8000 then
								D -= 0x10000
							end
							PC += D
						end
					elseif Opcode == 57 then -- FORNLOOP
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const Limit = Stack[A] :: number
						const Step = Stack[A + 1] :: number
						const Index = Stack[A + 2] + Step
						Stack[A + 2] = Index

						if Step > 0 and Index <= Limit or Step <= 0 and Limit <= Index then
							local D = bit32.rshift(Instruction, 16)
							if D >= 0x8000 then
								D -= 0x10000
							end
							PC += D
						end
					elseif Opcode == 58 then -- FORGLOOP
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const Aux = buffer.readu32(Code, PC * 4)
						local NumVars = bit32.band(Aux, 0xFF)
						const Iterator = Stack[A]
						const State = Stack[A + 1]
						const ControlVariable = Stack[A + 2]

						const Result = table.pack(Iterator(State, ControlVariable))

						if bit32.btest(Aux, 0x80000000) then
							NumVars = 2
						end

						if Result[1] == nil then
							PC += 1
						else
							Stack[A + 2] = Result[1]
							table.move(Result, 1, NumVars, A + 3, Stack)
							local D = bit32.rshift(Instruction, 16)
							if D >= 0x8000 then
								D -= 0x10000
							end
							PC += D
						end
					elseif Opcode == 59 then -- FORGPREP_INEXT
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						if type(Stack[A]) ~= "function" then
							error(`attempt to iterate over a {typeof(Stack[A])} value`)
						end
						local D = bit32.rshift(Instruction, 16)
						if D >= 0x8000 then
							D -= 0x10000
						end
						PC += D
					elseif Opcode == 60 then -- FASTCALL3
						PC += 1
					elseif Opcode == 61 then -- FORGPREP_NEXT
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						if type(Stack[A]) ~= "function" then
							error(`attempt to iterate over a {typeof(Stack[A])} value`)
						end
						local D = bit32.rshift(Instruction, 16)
						if D >= 0x8000 then
							D -= 0x10000
						end
						PC += D
					elseif Opcode == 62 then -- NATIVECALL
						error("NATIVECALL is not supported")
					elseif Opcode == 63 then -- GETVARARGS
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF)
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) - 1

						if B == -1 then
							table.move(VarArgs, 1, VarArgAmount, A + 1, Stack)
							for i = VarArgAmount + 1, MaxStackSize - A do
								Stack[A + i] = nil
							end
							StackTop = A + VarArgAmount
						else
							for i = 1, B do
								Stack[A + i] = if i <= VarArgAmount then VarArgs[i] else nil
							end
						end
					elseif Opcode == 64 then -- DUPCLOSURE
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						local D = bit32.rshift(Instruction, 16)
						if D >= 0x8000 then
							D -= 0x10000
						end
						const ProtoRef = Constants[D + 1]
						local Proto: Proto

						Proto = ProtoRef :: Proto

						const ProtoNups = Proto.Nups
						const ClosureUpvals = table.create(ProtoNups) :: { Upvalue }

						Stack[A] = @native function(...: any): ...any
							return LuauExecute(Proto, Env, ClosureUpvals, table.pack(...))
						end

						for i = 1, ProtoNups do
							const Aux = buffer.readu32(Code, PC * 4)
							PC += 1
							const CaptureType = bit32.band(bit32.rshift(Aux, 8), 0xFF)
							const CaptureIndex = bit32.band(bit32.rshift(Aux, 16), 0xFF) + 1
							if CaptureType == 0 then
								ClosureUpvals[i] = { value = Stack[CaptureIndex], store = nil, index = nil }
							elseif CaptureType == 1 then
								const ExistingUpvalue = OpenUpvalues[CaptureIndex]
								if ExistingUpvalue then
									ClosureUpvals[i] = ExistingUpvalue
									continue
								end
								const Upvalue: Upvalue = {
									value = nil,
									store = Stack,
									index = CaptureIndex,
								}
								OpenUpvalues[CaptureIndex] = Upvalue
								ClosureUpvals[i] = Upvalue
							elseif CaptureType == 2 then
								ClosureUpvals[i] = Upvals[CaptureIndex]
							end
						end
					elseif Opcode == 65 then -- PREPVARARGS
					end
				end
			else
				if Opcode < 77 then
					if Opcode == 66 then -- LOADKX
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const Aux = buffer.readu32(Code, PC * 4) + 1
						PC += 1
						Stack[A] = Constants[Aux]
					elseif Opcode == 67 then -- JUMPX
						local E = bit32.rshift(Instruction, 8)
						if E >= 0x800000 then
							E -= 0x1000000
						end
						PC += E
					elseif Opcode == 68 then -- FASTCALL
					elseif Opcode == 69 then -- COVERAGE
					elseif Opcode == 70 then -- CAPTURE
						error("CAPTURE executed outside of NEWCLOSURE")
					elseif Opcode == 71 then -- SUBRK
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						Stack[A] = Constants[B] - Stack[C]
					elseif Opcode == 72 then -- DIVRK
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						Stack[A] = Constants[B] / Stack[C]
					elseif Opcode == 73 then -- FASTCALL1
					elseif Opcode == 74 then -- FASTCALL2
						PC += 1
					elseif Opcode == 75 then -- FASTCALL2K
						PC += 1
					elseif Opcode == 76 then -- FORGPREP
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const Iterator = Stack[A]
						if type(Iterator) == "function" then
						elseif type(Iterator) == "table" then
							Stack[A] = next
							Stack[A + 1] = Iterator
							Stack[A + 2] = nil
						else
							error(`attempt to iterate over a {typeof(Iterator)} value`)
						end
						local D = bit32.rshift(Instruction, 16)
						if D >= 0x8000 then
							D -= 0x10000
						end
						PC += D
					end
				else
					if Opcode == 77 then -- JUMPXEQKNIL
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						local D = bit32.rshift(Instruction, 16)
						if D >= 0x8000 then
							D -= 0x10000
						end
						const Aux = buffer.readu32(Code, PC * 4)
						const NotBit = bit32.btest(Aux, 0x80000000)
						const IsNil = Stack[A] == nil

						PC += if IsNil ~= NotBit then D else 1
					elseif Opcode == 78 then -- JUMPXEQKB
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						local D = bit32.rshift(Instruction, 16)
						if D >= 0x8000 then
							D -= 0x10000
						end
						const Aux = buffer.readu32(Code, PC * 4)
						const KB = bit32.btest(Aux, 1)
						const NotBit = bit32.btest(Aux, 0x80000000)
						const Ra = Stack[A]
						const Matches = type(Ra) == "boolean" and Ra == KB

						PC += if Matches ~= NotBit then D else 1
					elseif Opcode == 79 then -- JUMPXEQKN
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						local D = bit32.rshift(Instruction, 16)
						if D >= 0x8000 then
							D -= 0x10000
						end
						const Aux = buffer.readu32(Code, PC * 4)
						const NotBit = bit32.btest(Aux, 0x80000000)
						const KV = Constants[bit32.band(Aux, 0xFFFFFF) + 1]
						const Ra = Stack[A]
						const Matches = type(Ra) == "number" and Ra == KV

						PC += if Matches ~= NotBit then D else 1
					elseif Opcode == 80 then -- JUMPXEQKS
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						local D = bit32.rshift(Instruction, 16)
						if D >= 0x8000 then
							D -= 0x10000
						end
						const Aux = buffer.readu32(Code, PC * 4)
						const KVIndex = bit32.band(Aux, 0xFFFFFF) + 1
						const NotBit = bit32.btest(Aux, 0x80000000)
						const KV = Constants[KVIndex]
						const Ra = Stack[A]
						const Matches = type(Ra) == "string" and Ra == KV

						PC += if Matches ~= NotBit then D else 1
					elseif Opcode == 81 then -- IDIV
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						Stack[A] = Stack[B] // Stack[C]
					elseif Opcode == 82 then -- IDIVK
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						Stack[A] = Stack[B] // Constants[C]
					elseif Opcode == 83 then -- GETUDATAKS
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const Aux = buffer.readu32(Code, PC * 4) + 1
						PC += 1
						Stack[A] = Stack[B][Constants[Aux]]
					elseif Opcode == 84 then -- SETUDATAKS
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const Aux = buffer.readu32(Code, PC * 4) + 1
						PC += 1
						Stack[B][Constants[Aux]] = Stack[A]
					elseif Opcode == 85 then -- NAMECALLUDATA
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const Aux = buffer.readu32(Code, PC * 4) + 1
						PC += 1
						const Object = Stack[B]
						Stack[A + 1] = Object
						Stack[A] = Object[Constants[Aux]]
					elseif Opcode == 86 then -- NEWCLASSMEMBER
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						const Aux = buffer.readu32(Code, PC * 4) + 1
						PC += 1
						Stack[A][Constants[Aux]] = Stack[C]
					elseif Opcode == 87 then -- CALLFB
						const A = bit32.band(bit32.rshift(Instruction, 8), 0xFF) + 1
						const B = bit32.band(bit32.rshift(Instruction, 16), 0xFF) + 1
						const C = bit32.band(bit32.rshift(Instruction, 24), 0xFF) + 1
						PC += 1
						const NParams = B - 2
						const NResults = C - 2
						const Function = Stack[A]

						local CallArgs: { any }
						local ActualParams: number

						if NParams == -1 then
							local Top: number = StackTop :: number
							if Top == nil then
								Top = A
							end
							ActualParams = Top - A
							if ActualParams < 0 then
								ActualParams = 0
							end
							CallArgs = table.create(ActualParams)
							table.move(Stack, A + 1, A + ActualParams, 1, CallArgs)
						else
							ActualParams = NParams
							CallArgs = table.create(NParams)
							table.move(Stack, A + 1, A + NParams, 1, CallArgs)
						end

						const FunctionResult = table.pack(Function(table.unpack(CallArgs, 1, ActualParams)))
						const NumResults = FunctionResult.n
						const Base = A - 1
						if NResults == -1 then
							table.move(FunctionResult, 1, NumResults, Base + 1, Stack)
							for i = NumResults + 1, MaxStackSize - Base do
								Stack[Base + i] = nil
							end
							StackTop = Base + NumResults
						else
							for i = 1, NResults do
								Stack[Base + i] = if i <= NumResults then FunctionResult[i] else nil
							end
						end
					elseif Opcode == 88 then -- CMPPROTO
						local D = bit32.rshift(Instruction, 16)
						if D >= 0x8000 then
							D -= 0x10000
						end
						PC += D
					else
						error("Unknown opcode")
					end
				end
			end
		end
	end
	return
end


@native const function LuauLoad(Bytecode: buffer, Env: { [string]: any }): (...any) -> ...any
	local Offset = 0
	const LuauVersion = buffer.readu8(Bytecode, Offset)
	Offset += 1
	if LuauVersion == 0 then
		error(buffer.readstring(Bytecode, Offset, buffer.len(Bytecode) - Offset))
	end
	if LuauVersion < LBC_VERSION_MIN or LuauVersion > LBC_VERSION_MAX then
		error(`Bytecode version mismatch (expected [{LBC_VERSION_MIN}..{LBC_VERSION_MAX}], got {LuauVersion})`)
	end
	local TypesVersion = 0
	if LuauVersion >= 4 then
		TypesVersion = buffer.readu8(Bytecode, Offset)
		Offset += 1
		if TypesVersion < LBC_TYPE_VERSION_MIN or TypesVersion > LBC_TYPE_VERSION_MAX then
			error(`Bytecode type version mismatch (expected [{LBC_TYPE_VERSION_MIN}..{LBC_TYPE_VERSION_MAX}], got {TypesVersion})`)
		end
	end

	const StringCount, Length = ReadVarInt(Bytecode, Offset)
	Offset += Length
	const StringTable = table.create(StringCount) :: { string }
	for i = 1, StringCount do
		const StrLength, Length = ReadVarInt(Bytecode, Offset)
		Offset += Length
		StringTable[i] = buffer.readstring(Bytecode, Offset, StrLength)
		Offset += StrLength
	end
	if TypesVersion == 3 then
		local Index = buffer.readu8(Bytecode, Offset)
		Offset += 1
		while Index ~= 0 do
			const _, Length = ReadVarInt(Bytecode, Offset)
			Offset += Length
			Index = buffer.readu8(Bytecode, Offset)
			Offset += 1
		end
	end

	const ProtoCount, Length = ReadVarInt(Bytecode, Offset)
	Offset += Length
	const ProtoTable = table.create(ProtoCount) :: { Proto }

	for i = 1, ProtoCount do
		local ProtoSize = 0
		if LuauVersion >= 12 then
			const PSize, PLength = ReadVarInt(Bytecode, Offset)
			Offset += PLength
			ProtoSize = PSize
		end
		const ProtoStartOffset = Offset

		const MaxStackSize = buffer.readu8(Bytecode, Offset)
		const NumParams = buffer.readu8(Bytecode, Offset + 1)
		const Nups = buffer.readu8(Bytecode, Offset + 2)
		const IsVarArg = buffer.readu8(Bytecode, Offset + 3) ~= 0
		Offset += 4

		local Flags: number = 0

		if LuauVersion >= 4 then
			Flags = buffer.readu8(Bytecode, Offset)
			Offset += 1
			if TypesVersion == 1 then
				const TypeSize, Length = ReadVarInt(Bytecode, Offset)
				Offset += Length + TypeSize
			elseif TypesVersion == 2 or TypesVersion == 3 then
				const TypeSize, Length = ReadVarInt(Bytecode, Offset)
				Offset += Length + TypeSize
			end
		end

		const SizeCode, Size = ReadVarInt(Bytecode, Offset)
		Offset += Size
		const Code = buffer.create(SizeCode * 4)
		buffer.copy(Code, 0, Bytecode, Offset, SizeCode * 4)
		Offset += SizeCode * 4

		const SizeK, Length = ReadVarInt(Bytecode, Offset)
		Offset += Length
		const KTable = table.create(SizeK, nil)

		for j = 1, SizeK do
			const KType = buffer.readu8(Bytecode, Offset)
			Offset += 1
			if KType == 0 then -- LBC_CONSTANT_NIL
				-- skip
			elseif KType == 1 then -- LBC_CONSTANT_BOOLEAN
				const Byte = buffer.readu8(Bytecode, Offset)
				Offset += 1
				KTable[j] = Byte ~= 0
			elseif KType == 2 then -- LBC_CONSTANT_NUMBER
				const Double = buffer.readf64(Bytecode, Offset)
				Offset += 8
				KTable[j] = Double
			elseif KType == 3 then -- LBC_CONSTANT_STRING
				const Index, Length = ReadVarInt(Bytecode, Offset)
				Offset += Length
				KTable[j] = StringTable[Index]
			elseif KType == 4 then -- LBC_CONSTANT_IMPORT
				const IId = buffer.readu32(Bytecode, Offset)
				Offset += 4
				const Count = bit32.rshift(IId, 30)

				const Id0 = bit32.band(bit32.rshift(IId, 20), 1023) + 1
				const Id1 = bit32.band(bit32.rshift(IId, 10), 1023) + 1
				const Id2 = bit32.band(IId, 1023) + 1

				local Result: any?

				const Key = KTable[Id0] :: string
				Result = Env[Key]
				if Count >= 2 and Result ~= nil then
					Result = Result[KTable[Id1]]
				end
				if Count >= 3 and Result ~= nil then
					Result = Result[KTable[Id2]]
				end
				KTable[j] = Result
			elseif KType == 5 then -- LBC_CONSTANT_TABLE
				const Keys, Length = ReadVarInt(Bytecode, Offset)
				Offset += Length
				const Table = {} :: { [any]: any }
				for _ = 1, Keys do
					const Key, KLen = ReadVarInt(Bytecode, Offset)
					Offset += KLen
					Table[KTable[Key + 1]] = 0
				end
				KTable[j] = Table
			elseif KType == 6 then -- LBC_CONSTANT_CLOSURE
				const FId, Length = ReadVarInt(Bytecode, Offset)
				Offset += Length
				KTable[j] = ProtoTable[FId + 1]
			elseif KType == 7 then -- LBC_CONSTANT_VECTOR
				const X = buffer.readf32(Bytecode, Offset)
				const Y = buffer.readf32(Bytecode, Offset + 4)
				const Z = buffer.readf32(Bytecode, Offset + 8)
				buffer.readf32(Bytecode, Offset + 12)
				Offset += 16
				KTable[j] = vector.create(X, Y, Z)
			elseif KType == 8 then -- LBC_CONSTANT_TABLE_WITH_CONSTANTS
				const Keys, Length = ReadVarInt(Bytecode, Offset)
				Offset += Length
				const Table = {} :: { [any]: any }
				for _ = 1, Keys do
					const Key, KLen = ReadVarInt(Bytecode, Offset)
					Offset += KLen
					const ConstantIdx = buffer.readi32(Bytecode, Offset)
					Offset += 4
					const KeyValue = KTable[Key + 1]
					if ConstantIdx >= 0 then
						Table[KeyValue] = KTable[ConstantIdx + 1]
					else
						Table[KeyValue] = 0
					end
				end
				KTable[j] = Table
			elseif KType == 9 then -- LBC_CONSTANT_INTEGER
				const IsNegative = buffer.readu8(Bytecode, Offset) ~= 0
				Offset += 1
				const Magnitude, Length = ReadVarInt64(Bytecode, Offset)
				Offset += Length
				if IsNegative then
					KTable[j] = if integer then integer.neg(Magnitude :: integer) else -Magnitude :: number
				else
					KTable[j] = Magnitude
				end
			elseif KType == 10 then -- LBC_CONSTANT_CLASS_SHAPE
				const ClassNameIndex, Size = ReadVarInt(Bytecode, Offset)
				Offset += Size
				const NumProperties, Size = ReadVarInt(Bytecode, Offset)
				Offset += Size
				const NumMethods, Size = ReadVarInt(Bytecode, Offset)
				Offset += Size
				const NumMembers = NumProperties + NumMethods
				const Members = table.create(NumMembers) :: { string }
				for idx = 1, NumMembers do
					const MId, Size = ReadVarInt(Bytecode, Offset)
					Offset += Size
					Members[idx] = KTable[MId + 1] :: string
				end
				KTable[j] = {
					ClassName = KTable[ClassNameIndex + 1],
					Members = Members,
					NumProperties = NumProperties,
					NumMethods = NumMethods,
				}
			else
				error("Unexpected constant kind")
			end
		end

		const SizeP, Length = ReadVarInt(Bytecode, Offset)
		Offset += Length
		const PTable = table.create(SizeP) :: { Proto }

		for j = 1, SizeP do
			const FId, Length = ReadVarInt(Bytecode, Offset)
			Offset += Length
			PTable[j] = ProtoTable[FId + 1]
		end

		const LineDefined, Length = ReadVarInt(Bytecode, Offset)
		Offset += Length
		const DebugNameIndex, Length = ReadVarInt(Bytecode, Offset)
		Offset += Length
		const DebugName: string = StringTable[DebugNameIndex] or "?"
		const HasLineInfo = buffer.readu8(Bytecode, Offset) ~= 0
		Offset += 1

		local LineInfo: { number }? = nil
		if HasLineInfo then
			const LineGapLog2 = buffer.readu8(Bytecode, Offset)
			Offset += 1

			const Intervals = bit32.rshift(SizeCode - 1, LineGapLog2) + 1

			const LineInfoBytes = table.create(SizeCode) :: { number }
			local LastOffset = 0
			for j = 1, SizeCode do
				const Delta = buffer.readu8(Bytecode, Offset)
				Offset += 1
				LastOffset = bit32.band(LastOffset + Delta, 0xFF)
				LineInfoBytes[j] = if LastOffset >= 128 then LastOffset - 256 else LastOffset
			end

			const AbsLines = table.create(Intervals) :: { number }
			local LastLine = 0
			for i = 1, Intervals do
				LastLine += buffer.readi32(Bytecode, Offset)
				Offset += 4
				AbsLines[i] = LastLine
			end

			const Lines = table.create(SizeCode) :: { number }
			for j = 1, SizeCode do
				const Baseline = AbsLines[bit32.rshift(j - 1, LineGapLog2) + 1]
				Lines[j] = Baseline + LineInfoBytes[j]
			end
			LineInfo = Lines
		end

		const HasDebugInfo = buffer.readu8(Bytecode, Offset) ~= 0
		Offset += 1
		if HasDebugInfo then
			const SizeLocVars, Size = ReadVarInt(Bytecode, Offset)
			Offset += Size

			for i = 1, SizeLocVars do
				const _, Size = ReadVarInt(Bytecode, Offset)
				Offset += Size
				const _, Size = ReadVarInt(Bytecode, Offset)
				Offset += Size
				const _, Size = ReadVarInt(Bytecode, Offset)
				Offset += Size + 1
			end

			const SizeUpvalues, Size = ReadVarInt(Bytecode, Offset)
			Offset += Size

			for i = 1, SizeUpvalues do
				const _, Size = ReadVarInt(Bytecode, Offset)
				Offset += Size
			end
		end

		if LuauVersion >= 11 then
			const FeedbackVecSize, Size = ReadVarInt(Bytecode, Offset)
			Offset += Size
			for _ = 1, FeedbackVecSize do
				Offset += 1
				const _, PCSize = ReadVarInt(Bytecode, Offset)
				Offset += PCSize
			end
		end

		if LuauVersion >= 12 then
			if bit32.band(Flags, 8) ~= 0 then -- LPF_INLINABLE
				const _, CostSize = ReadVarInt64(Bytecode, Offset)
				Offset += CostSize
			end
			Offset = ProtoStartOffset + ProtoSize
		end

		ProtoTable[i] = table.freeze({
			Code = Code,
			SizeCode = SizeCode,
			Constants = KTable,
			Protos = PTable,
			NumParams = NumParams,
			IsVarArg = IsVarArg,
			MaxStackSize = MaxStackSize,
			Nups = Nups,
			LineDefined = LineDefined,
			DebugName = DebugName,
			LineInfo = LineInfo,
		})
	end

	const MainProtoIndex, Size = ReadVarInt(Bytecode, Offset)
	Offset += Size

	const MainProto = ProtoTable[MainProtoIndex + 1]

	return @native function(...: any): ...any
		const Upvals = table.create(MainProto.Nups) :: { Upvalue }
		for i = 1, MainProto.Nups do
			Upvals[i] = {
				value = Env,
				store = nil,
				index = nil,
			}
		end
		return LuauExecute(MainProto, Env, Upvals, table.pack(...))
	end
end

return LuauLoad
