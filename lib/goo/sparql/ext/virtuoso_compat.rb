require 'sparql/client'

module Goo
  module SPARQL
    module Ext
      # Backend-compatibility quirks that the NCBO fork baked into sparql-client and that
      # vanilla upstream lacks. Re-homed here as prepends so the gem stays vanilla.
      # See docs/sparql-client-defork-proposal.md Â§3.4. Output is locked by
      # test/test_sparql_write_characterization.rb.

      # 4store and Virtuoso need string literals to carry an explicit ^^xsd:string datatype.
      # Vanilla `SPARQL::Client.serialize_value` drops it for plain strings. We re-add it only
      # for literals that explicitly carry `original_datatype == xsd:string` (goo's RDF::Literal
      # monkeypatch in mixins/sparql_client.rb records that), so plain literals are unaffected.
      module SerializeXsdString
        def serialize_value(value, use_vars = false)
          serialized = super
          if value.is_a?(RDF::Literal) &&
             value.respond_to?(:original_datatype) &&
             value.original_datatype&.to_s == RDF::XSD.string.to_s
            return "#{serialized}^^<http://www.w3.org/2001/XMLSchema#string>"
          end

          serialized
        end
      end

      # Empty-binding tolerance. 4store (and others) can return an empty binding object `{}`
      # for an unbound/optional column; vanilla's `parse_json_value` then calls
      # `value['type'].to_sym` on nil and raises. Treat `{}` as nil, matching the fork.
      module EmptyBindingTolerance
        def parse_json_value(value, nodes = {})
          return nil if value == {}

          super
        end
      end

      # Virtuoso rejects `INSERT DATA` for the graphs goo writes (openlink/virtuoso-opensource
      # #126); goo passes `use_insert_data: false` for the Virtuoso backend. Vanilla
      # `Update::InsertData#to_s` always emits `INSERT DATA`; rewrite to plain `INSERT` when the
      # toggle is off. (`use_insert_data` true / unset keeps vanilla's `INSERT DATA`.)
      module InsertDataToggle
        def to_s
          rendered = super
          return rendered unless options[:use_insert_data] == false

          rendered.sub(/\AINSERT DATA\b/, 'INSERT ')
        end
      end
    end
  end
end

SPARQL::Client.singleton_class.prepend(Goo::SPARQL::Ext::SerializeXsdString)
SPARQL::Client.singleton_class.prepend(Goo::SPARQL::Ext::EmptyBindingTolerance)
SPARQL::Client::Update::InsertData.prepend(Goo::SPARQL::Ext::InsertDataToggle)
