// True when ACTUAL - BASE lies in [LOW, HIGH] seconds, for clocks that may lag an auto-save tick.
var delta = Number(ACTUAL) - Number(BASE)
output[KEY] = delta >= Number(LOW) && delta <= Number(HIGH)
