class FizzBuzzer
  def for_number(i)
    if (((i % 5) == 0) && ((i % 3) == 0))
      "FizzBuzz"
    else
      if ((i % 5) == 0)
        "Buzz"
      else
        if ((i % 3) == 0)
          "Fizz"
        else
          i.to_s
        end
      end
    end
  end
  def for_number_case(num)
    case
    when ((num % 15) == 0)
      "FizzBuzz"
    when ((num % 3) == 0)
      "Fizz"
    when ((num % 5) == 0)
      "Buzz"
    else
      num.to_s
    end
  end
  def run
    1.upto(100) do |i|
      puts(for_number_case(i))
    end
  end
end