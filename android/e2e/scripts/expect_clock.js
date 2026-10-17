// Builds a regex for the player clock at BASE + DELTA seconds, one second either way, because
// MP3 seeks land on frame boundaries. assertVisible then waits for the clock to settle there.
function clock(total) {
  var m = Math.floor(total / 60), s = total % 60
  return m + ':' + (s < 10 ? '0' : '') + s
}
var target = Number(BASE) + Number(DELTA)
output[KEY] = [target - 1, target, target + 1].filter(function (t) { return t >= 0 }).map(clock).join('|')
