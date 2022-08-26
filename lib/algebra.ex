defmodule Tempo.Algebra do
  alias Tempo.Validation

  defguard is_continuation(unit, fun) when is_atom(unit) and is_function(fun)
  defguard is_unit(unit, value) when is_atom(unit) and is_list(value) or is_number(value)

  @doc """
  Get the next "odomoter reading" list of integers and ranges
  or a list of time units

  """
  def next(%Tempo{time: units, calendar: calendar} = tempo) do
    case next(units, calendar) do
      nil -> nil
      other -> %{tempo | time: other}
    end
  end

  def next(list, calendar) when is_list(list) do
    case do_next(list, calendar, []) do
      {:rollover, _list} -> nil
      # {:no_cycles, _list} -> nil
      list -> list
    end
  end

  def do_next([], _calendar, _previous) do
    []
  end

  def do_next([{unit, value} | t], calendar, previous) when is_unit(unit, value) do
    [{unit, cycle(value, unit, calendar, previous)} |
      List.wrap(do_next(t, calendar, [{unit, value} | previous]))]
  end

  # We hit a continuation at the end of a list
  def do_next([{unit, {_current, fun}}], calendar, previous) when is_continuation(unit, fun) do
    case fun.(calendar, previous) do
      {{:rollover, acc}, fun} ->
        {:rollover, [{unit, {acc, fun}}]}
      {acc, fun} ->
        [{unit, {acc, fun}}]
    end
  end

  # We hit a continuation. We need to process it in the context of previous, and then process
  # forward from there.

  # If the next unit rolled-over, and the next unit was a range
  # and this unit is a range, then when we cycle, we need to reset the tail again
  # again

  # Cycle functions need to take a `:reset` param in place of the calendar

  def do_next([{unit, {current, fun}} | t], calendar, previous) when is_continuation(unit, fun) do
    # IO.inspect {unit, current, t}, label: "Do Next"
    case do_next(t, calendar, [{unit, {current, fun}} | previous]) do
      {:rollover, list} ->
        IO.inspect list, label: "Rollover"
        case fun.(calendar, previous) do
          {{:rollover, current}, fun} ->
            {:rollover, [{unit, {current, fun}} | list]}

          {current, fun} ->
            [{unit, {current, fun}} | list]
        end

      # {:no_cycles, list} ->
      #   case fun.(calendar, previous) do
      #     {{:rollover, current}, fun} ->
      #       IO.inspect current, label: "Rollover from no_cycles"
      #       {:rollover, [{unit, {current, fun}} | list]}
      #
      #     {current, fun} ->
      #       IO.inspect current, label: "Not rollover from no_cycles"
      #       [{unit, {current, fun}} | list]
      #   end

      tail ->
        [{unit, {current, fun}} | tail]
    end
  end

  # def do_next({:no_cycles, h}, _calendar, _previous) do
  #   {:no_cycles, h}
  # end
  #
  # def do_next([{:no_cycles, h}], _calendar, _previous) do
  #   {:no_cycles, List.wrap(h)}
  # end
  #
  # def do_next([h], _calendar, _previous) do
  #   {:no_cycles, [h]}
  # end
  #
  # def do_next([h | t], calendar, previous) do
  #   case do_next(t, calendar, previous) do
  #     {:no_cycles, list} ->
  #       {:no_cycles, [h | list]}
  #
  #     {:rollover, list} ->
  #       {:rollover, [h | list]}
  #
  #     list ->
  #       [h | list]
  #   end
  # end

  @doc """
  Returns a function that when called will return
  the next cycle value in a sequence.

  When the sequence cycles back to the start
  it returns `{:rollover, value}` to signal
  the rollover.

  """
  def cycle(source, unit, calendar, previous) when is_number(source) do
    cycle([source], [source], unit, calendar, previous)
  end

  def cycle(source, unit, calendar, previous) do
    cycle(source, source, unit, calendar, previous)
  end

  def cycle(source, list, unit, calendar, previous) do
    case list do
      [] ->
        rollover(source, unit, calendar, previous)

      [%Range{step: step} = range | rest] when step < 0 ->
        range = adjusted_range(range, unit, calendar, previous)
        increment_range(source, range, unit, rest)

      [%Range{first: first, last: last} = range | rest] when first <= last ->
        increment_range(source, range, unit, rest)

      [%Range{}] ->
        rollover(source, unit, calendar, previous)

      [%Range{}, next | rest] ->
        {next, fn calendar, previous ->
          cycle(source, rest, unit, calendar, previous)
        end}

      [next | rest] ->
        {next, fn calendar, previous ->
          cycle(source, rest, unit, calendar, previous)
        end}

      value when is_number(value) ->
        value
    end
  end

  defp increment_range(source, %Range{first: first, last: last, step: step}, unit, rest) do
    {first, fn calendar, previous ->
      cycle(source, [(first + step)..last//step | rest], unit, calendar, previous)
    end}
  end


  defp rollover([h | t] = source, unit, calendar, previous) do
    case h do
      %Range{} = range ->
        %Range{first: first, last: last, step: step} = adjusted_range(range, unit, calendar, previous)
        {{:rollover, first}, fn calendar, previous ->
            cycle(source, [(first + step)..last//step | t], unit, calendar, previous)
          end}

      # {unit, value} ->
      #   IO.inspect {unit, value}, label: "Rolling over unit and value"
      #   {unit, value}

      value ->
        {{:rollover, value}, fn calendar, previous ->
          cycle(source, t, unit, calendar, previous)
        end}
    end
  end

  defp adjusted_range(%Range{step: step} = range, _unit, _calendar, _previous) when step > 0 do
    range
  end

  defp adjusted_range(range, unit, calendar, previous) do
    units = [{unit, range} | current_units(previous)] |> Enum.reverse()
    IO.inspect {range, unit, calendar, previous}, label: "Adjusting range"
    IO.inspect units, label: "   Context for adjustment"

    {_unit, range} =
      units
      |> Validation.resolve(calendar)
      |> Enum.reverse()
      |> hd

    range |> IO.inspect(label: "   Adjusted")
  end

  def current_units(units) do
    Enum.map units, fn
      {unit, list} when is_list(list) -> {unit, extract_first(list)}
      {unit, {current, _fun}} -> {unit, current}
      {:no_cycles, list} -> list
      {unit, value} -> {unit, value}
    end
  end

  def extract_first([%Range{first: first} | _rest]), do: first
  def extract_first([first | _rest]), do: first

  @doc """
  Strips the functions from return tuples to produce
  a clean structure to pass to functions

  """
  def collect(%Tempo{time: units} = tempo) do
    case collect(units) do
      nil -> nil
      other -> %{tempo | time: other}
    end
  end

  def collect([]) do
    []
  end

  def collect([{:no_cycles, list}]) do
    list
  end

  def collect([{value, fun} | t]) when is_function(fun) do
    [value | collect(t)]
  end

  def collect([{unit, {acc, fun}} | t]) when is_function(fun) do
    [{unit, acc} | collect(t)]
  end

  def collect([h | t]) do
    [h | collect(t)]
  end
end