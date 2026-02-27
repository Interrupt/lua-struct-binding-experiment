local text = require("text")
local app = require("App")

-- print("New component script running!")

-- Components need a table returned with their lifecycle functions in it
local componentTable = {}
local time = 0.0

componentTable._update = function(self)
	local dt = app.getCurrentDeltaTime()
	time = time + (10.0 * dt)
	self.text_loc = math.sin(time + 2.0) * 20
end

componentTable._draw = function(self)
	text.draw("This is from my component's draw function!", 50, 80, 7)
	text.draw(self.test_string, self.text_loc + 50, 120, 7)
end

return componentTable
