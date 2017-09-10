require("./fizzbuzz.rb")
require("test/unit")
class FizzBuzzTests < Test::Unit::TestCase
  def setup
    @fizzbuzzer = FizzBuzzer.new
  end
  def test_fizzbuzz
    assert_equal("FizzBuzz", @fizzbuzzer.for_number(15))
  end
  def test_fizz_c
    assert_equal("Fizz", @fizzbuzzer.for_number_case(3))
  end
  def test_buzz_c
    assert_equal("Buzz", @fizzbuzzer.for_number_case(5))
  end
  def test_fizzbuzz_c
    assert_equal("FizzBuzz", @fizzbuzzer.for_number_case(15))
  end
end