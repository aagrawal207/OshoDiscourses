// Converts the copied player clock ("m:ss" or "h:mm:ss") into seconds for numeric assertions.
var parts = maestro.copiedText.split(':').map(Number)
output[KEY] = parts.reduce(function (total, part) { return total * 60 + part }, 0)
