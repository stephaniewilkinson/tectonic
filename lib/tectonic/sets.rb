# frozen_string_literal: true

require_relative 'db'
require_relative 'api_token'

class Tectonic < Roda
  class Set < Sequel::Model
    many_to_one :exercise
    many_to_one :workout
    # The API token that created this row, or nil for a human-made one.
    many_to_one :created_by_token, class: 'Tectonic::ApiToken', key: :created_by_token_id
  end
end

