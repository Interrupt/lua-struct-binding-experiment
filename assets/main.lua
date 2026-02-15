print("Hello from lua!")

local text = require("text")
local testUserdata = require("MyTestStruct")
local titleType = require("Title")

-- Exercise our test types!

-- Create a new object from our userdata type
local obj = testUserdata.new()

-- Get the metatable back
local mt = getmetatable(obj)

-- Iterate through the metatable to view all its methods/fields
print("Methods in metatable:")
for key, value in pairs(mt) do
	if type(value) == "function" then
		print("* Metamethod/Field:", key, " (function)")
	else
		print("* Field:", key, " (", type(value), ")")
	end
end

local objOne = testUserdata.new()
objOne:set(100)

local objTwo = testUserdata.new()
objTwo:set(50)

local title = titleType.new()
title = objOne:getTitle()

objOne:add(objTwo)

print(objOne:getString())

print(objOne:getVal())

local objThree = objOne:copy()
print(objThree:getVal())

objThree:add(objTwo)
print(objOne:getVal())
print(objThree:getVal())

-- lifecycle funcs!
function _draw()
	text.draw(title:getTitle(), 40, 40, 7)
end
