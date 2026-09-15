# frozen_string_literal: true

class Tectonic < Roda
  # What makes two movement names the same movement, and what makes them worth asking about.
  # #474 and #478.
  #
  # Both questions are about names alone, so they live together and away from the model: the
  # resolver, the browser form and the merge tooling all need the same answers, and a rule
  # that lives at three call sites is a rule that disagrees with itself at one of them. That is
  # the argument `barbell?` records having already lost once.
  #
  # ## Two different questions
  #
  # **Folding** asks whether two names *are* the same name. `Bench Press`, `bench press` and
  # `Benchpress` are one movement written three ways, and an app that treats them as three is
  # an app that splits a lifter's training across rows they cannot tell apart. This is a fact
  # about spelling and the app can settle it on its own.
  #
  # **Nearness** asks whether a new name might be a movement already there under a different
  # name. `Squat` is not `Back Squat` by any spelling rule, and only the lifter knows whether
  # they meant it. So this one is never decided here -- it produces candidates and somebody
  # else asks.
  module ExerciseNames
    module_function

    # A name reduced to what a reader would call the same. Case and punctuation go, because
    # those are the differences that produced every duplicate this account actually has:
    # `Benchpress` against `Bench Press`, `Overhead press` against `Overhead Press`.
    #
    # Spaces go too, which is what makes `Benchpress` and `Bench Press` fold together at all --
    # they are not the same words differently cased, they are the same letters differently
    # spaced, and a fold that kept spaces would miss the pair that prompted this.
    def fold(name)
      name.to_s.downcase.gsub(/[^a-z0-9]/, '')
    end

    # The same name reduced to its words, for the nearness question, which needs to see
    # `Back Squat` as two things rather than as `backsquat`.
    #
    # Hyphens count as spaces here and not as nothing, so `Heel-Elevated Squat` is three words.
    # Folding removes them entirely, which is right for "is this the same name" and wrong for
    # "does this name contain that one".
    def words(name)
      name.to_s.downcase.gsub(/[^a-z0-9]+/, ' ').split.uniq
    end

    # Whether one name is worth offering when somebody asks for the other: every word of the
    # shorter appears in the longer. #478.
    #
    # Subset rather than any shared word, which is the whole of why this is usable. Shared-word
    # matching offers `Band Tricep Pushdown` to somebody creating `Band Face Pull`, because
    # both are banded -- and a prompt that is usually wrong is a prompt people learn to dismiss
    # without reading, which is worse than no prompt at all.
    #
    #   Squat / Back Squat                     -> {squat} is inside {back, squat}
    #   Bench Press / Incline DB Bench Press   -> inside, and worth asking about
    #   Band Face Pull / Band Tricep Pushdown  -> neither inside the other
    #   Dead Bug / Deadlift                    -> "deadlift" is one word, so no
    #
    # Identical word sets count as near, and that is deliberate: `Back Squat` and `Squat Back`
    # fold differently and are almost certainly the same thing.
    def near?(one, other)
      first = words(one)
      second = words(other)
      return false if first.empty? || second.empty?

      first.all? { |word| second.include?(word) } || second.all? { |word| first.include?(word) }
    end
  end
end

