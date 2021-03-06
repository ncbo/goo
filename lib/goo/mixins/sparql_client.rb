class String
  def to_uri
    return self
  end
end

module RDF
  def self.URI(*args, &block)
    return args.first
  end

  class Writer
    def validate?
      false
    end
  end

  class Literal
    def to_base
      text = []
      text << %("#{escape(value)}")
      text << "@#{language}" if has_language?
      if has_datatype?
        if datatype.respond_to?:to_base
          text << "^^#{datatype.to_base}"
        else
          text << "^^<#{datatype.to_s}>"
        end
      end
      text.join ""
    end
  end

  class URI
    def initialize(uri_or_options)
      case uri_or_options
        when Hash
          @uri = Addressable::URI.new(uri_or_options)
        when Addressable::URI
          @uri = uri_or_options
        else
          @uri = uri_or_options.to_s
          #@uri = Addressable::URI.parse(uri_or_options.to_s)
      end
    rescue Addressable::URI::InvalidURIError => e
      raise ArgumentError, e.message
    end

    def method_missing(symbol, *args, &block)
      unless @uri.respond_to?(symbol)
        if (Addressable::URI.instance_methods.include?(symbol) && @uri.instance_of?(String))
          @uri = Addressable::URI.parse(@uri)
        end
      end
      if @uri.respond_to?(symbol)
        case result = @uri.send(symbol, *args, &block)
          when Addressable::URI
            self.class.new(result)
          else result
        end
      else
        super
      end
    end

    def last_part
      f = fragment
      return f if f
      return to_s.split("/")[-1]
    end

    def respond_to?(symbol,include_private = false)
      @uri.respond_to?(symbol,include_private=false) || super
    end

    def hash
      @uri.to_s.hash
    end

  end #end URI

  class Literal
    @@subclasses_by_uri = {}
    def self.datatyped_class(uri)
      return nil if uri.nil?
      if @@subclasses.length != (@@subclasses_by_uri.length + 1)
       @@subclasses.each do |child|
        if child.const_defined?(:DATATYPE)
          @@subclasses_by_uri[child.const_get(:DATATYPE).to_s] = child
        end
       end
      end
      return @@subclasses_by_uri[uri]
    end
  end
end #end RDF
