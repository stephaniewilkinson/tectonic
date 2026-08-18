# frozen_string_literal: true

require_relative 'db'
require_relative 'oauth_application'

class Tectonic < Roda
  class Set < Sequel::Model
    many_to_one :exercise
    many_to_one :workout
    # The OAuth client (LLM) that created this row, or nil for a human-made one.
    many_to_one :created_by_oauth_application, class: 'Tectonic::OAuthApplication',
                                               key: :created_by_oauth_application_id
  end
end

