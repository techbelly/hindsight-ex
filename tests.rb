require("./fizzbuzz.rb")
require("test/unit")
class FizzBuzzTests < Test::Unit::TestCase
  def setup
    @fizzbuzzer = FizzBuzzer.new
  end
  def test_buzz_c
    assert_equal("Buzz", @fizzbuzzer.for_number_case(5))
  end
end