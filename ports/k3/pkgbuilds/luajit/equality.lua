-- Regression for the RISC-V runtime shipped as 2.1.1702376626-1: comparing
-- a nil variable with a table incorrectly called the table's __eq method.
local calls = 0
local mt = {
  __eq = function(a, b)
    assert(type(a) == "table" and type(b) == "table", "Invalid __eq operands")
    calls = calls + 1
    return a.value == b.value
  end,
}
local function equal(a, b)
  return a == b
end
local function unequal(a, b)
  return a ~= b
end
local function check()
  for i = 1, 10000 do
    local a = setmetatable({ value = i }, mt)
    local b = setmetatable({ value = i }, mt)
    local c = setmetatable({ value = i + 1 }, mt)
    assert(equal(a, b) and not unequal(a, b))
    assert(not equal(a, c) and unequal(a, c))
    assert(equal(a, a) and not unequal(a, a))
    assert(not equal(nil, a) and unequal(nil, a))
    assert(not equal(a, nil) and unequal(a, nil))
    for _, other in ipairs({ false, true, 0, 1.5, "table", function() end }) do
      assert(not equal(other, a) and unequal(other, a))
      assert(not equal(a, other) and unequal(a, other))
    end
  end
end
for _, enabled in ipairs({ false, true }) do
  jit.flush()
  if enabled then
    jit.on()
  else
    jit.off()
  end
  check()
end
assert(calls > 0, "Equality metamethod was never exercised")
print("LUA_EQUALITY_STRESS_OK", jit.version)
