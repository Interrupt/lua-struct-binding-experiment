local text = require("text")

-- print("New component script running!")

-- Components need a table returned with their lifecycle functions in it
local componentTable = {}
local time = 0.0

componentTable._update = function(self)
	time = time + 0.1
	self.text_loc = math.sin(time + 2.0) * 20
end

componentTable._draw = function(self)
	text.draw("This is from a component!", 50, 80, 7)
	text.draw(self.test_string, self.text_loc + 50, 120, 7)
end

return componentTable
