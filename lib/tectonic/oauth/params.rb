# frozen_string_literal: true

class Tectonic < Roda
  module OAuth
    # Normalises an untrusted parameter hash before any protocol logic reads it. Rack's
    # query parser turns `code[]=x` into an Array and `code[a]=b` into a Hash, but every
    # check downstream -- the digest lookups, the string comparisons, the Sequel filters
    # -- is written for Strings.
    #
    # A non-String is a refusal, not something to drop. Dropping would read downstream as
    # "the client omitted it", and for `scope` an omission means falling back to the
    # client's whole registered scope set: `scope[]=read` would then widen the grant
    # instead of failing it. Refusing outright is the only reading that cannot escalate.
    module Params
      module_function

      # The parameters as Strings, or nil when any value is not one.
      def strings(params)
        params.to_h.each_with_object({}) do |(key, value), clean|
          return nil unless value.is_a?(String)

          clean[key.to_s] = value
        end
      end
    end
  end
end

