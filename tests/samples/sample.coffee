### A block
comment ###
greet = (name) ->
  "Hello, #{name}"  # interpolate

class Point
  constructor: (@x = 0, @y = 0) ->

console.log greet("world"), new Point(), yes, null
