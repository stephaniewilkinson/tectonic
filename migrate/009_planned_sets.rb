# frozen_string_literal: true

Sequel.migration do
  change do
    # What the generator prescribed, kept so a set lifted differently can show
    # what it was supposed to be. Null on sets entered by hand, which had no plan.
    add_column :sets, :planned_weight, Integer
    add_column :sets, :planned_reps, Integer
    # Denormalized from program_lifts: a set has to know whether it is loaded on a
    # bar to render its own plate math, and it has no route back to the program.
    add_column :sets, :is_barbell, TrueClass, { default: false, null: false }
  end
end

