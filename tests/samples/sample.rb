# A greeter.
class Greeter
  attr_reader :name

  def initialize(name)
    @name = name
  end

  def greet?
    puts "Hello, #{@name}" unless name.nil?
    true
  end
end
