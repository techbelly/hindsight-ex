
class FizzBuzzer
  def for_number(i)
    if i % 5 == 0 && i % 3 == 0
      "FizzBuzz"
    elsif i % 5 == 0
      "Buzz"
    elsif i % 3 == 0
      "Fizz"
    else
      i.to_s
    end
  end

  def for_number_case(num)
    case
      when num % 15 == 0 then "FizzBuzz"
      when num % 3  == 0 then "Fizz"
      when num % 5  == 0 then "Buzz"
      else num.to_s
    end
  end

  def run
    1.upto(100) do |i|
      puts for_number_case(i)
    end
  end
end
