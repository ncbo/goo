require 'date'
require "uri"

require_relative "string_utils"
require_relative "rdf"

module Goo
  module Utils

    def self.symbol_str_equals(a,b)
      if a.class != Symbol and a.class != Symbol
        raise ArgumentError, "First param not a string or symbol"
      end
      if b.class != Symbol and b.class != Symbol
        raise ArgumentError, "Second param not a string or symbol"
      end
      (a.class == Symbol ? a.to_s : a) == (b.class == Symbol ? b.to_s : b) 
    end
 
    def self.xsd_date_time_parse(v)
      values = if v.kind_of? Array then v else [v] end
      values.each do |date|
        if date.instance_of? DateTime
          date
        elsif date.instance_of? String
          DateTime.xmlschema(date) 
        else
          raise ArgumentError, "#{date} is not a parsable object String or DateTime"
        end
      end
    end
  end
end
