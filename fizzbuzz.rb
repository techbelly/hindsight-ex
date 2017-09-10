class FizzBuzzer
  def for_number(i)
    "FizzBuzz"
  end
  def for_number_case(num)
    case
    when ((num % 15) == 0)
      "FizzBuzz"
    when ((num % 3) == 0)
      "Fizz"
    else
      "Buzz"
    end
  end
end