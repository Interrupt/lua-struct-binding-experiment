print("Hello from lua!")

local text = require("text")
local testUserdata = require("MyTestStruct")
local titleType = require("Title")
local luaComponent = require("LuaComponent")

-- Exercise our test types!

-- Create a new object from our userdata type
local obj = testUserdata.init()

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

local objOne = testUserdata.init()
objOne:set(100)

local objTwo = testUserdata.init()
objTwo:set(50)

local title = titleType.init()
title = objOne:getTitle()

objOne:add(objTwo)

print(objOne:getString())

print(objOne:getVal())

local objThree = objOne:copy()
print(objThree:getVal())

objThree:add(objTwo)
print(objOne:getVal())
print(objThree:getVal())

local comp = luaComponent.new("assets/test-component.lua")
comp.test_string = "This is my test string! Wow"

-- lifecycle funcs!
function _draw()
	text.draw(title:getTitle(), 40, 40, 7)

	-- Also draw our test component
	comp:_draw()
end

function _update()
	-- Update our test component
	comp:_update()
end
