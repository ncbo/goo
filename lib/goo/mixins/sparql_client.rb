class String
  def to_uri
    return self
  end
end

module RDF
  def self.URI(*args, &block)
    return RDF::URI.new(*args)
  end

  class URI
    # Delegate any undefined method calls to the String object
    def method_missing(method, *args, &block)
      if self.to_s.respond_to?(method)
        self.to_s.send(method, *args, &block)
      else
        super
      end
    end

    # Ensure respond_to? reflects the delegated methods
    def respond_to_missing?(method, include_private = false)
      self.to_s.respond_to?(method) || super
    end

  end

  class Writer
    def validate?
      false
    end
  end

  class Literal
    class DateTime < Temporal
      # Override RDF's default DateTime format to match what 4store accepts.
      # Remove first to avoid Ruby's "already initialized constant" warning.
      remove_const(:FORMAT) if const_defined?(:FORMAT)
      FORMAT = '%Y-%m-%dT%H:%M:%S'.freeze
    end

    def initialize(value, language: nil, datatype: nil, lexical: nil, validate: false, canonicalize: false, **options)
      @object   = value.freeze
      @string   = lexical if lexical
      @string   = value if !defined?(@string) && value.is_a?(String)
      @string   = @string.encode(Encoding::UTF_8).freeze if instance_variable_defined?(:@string)
      @object   = @string if instance_variable_defined?(:@string) && @object.is_a?(String)
      @language = language.to_s.downcase.to_sym if language
      @datatype = RDF::URI(datatype).freeze if datatype
      @datatype ||= self.class.const_get(:DATATYPE) if self.class.const_defined?(:DATATYPE)
      @datatype ||= instance_variable_defined?(:@language) && @language ? RDF.langString : RDF::URI("http://www.w3.org/2001/XMLSchema#string")
      @original_datatype = datatype
    end

    attr_reader :original_datatype
  end

end #end RDF
