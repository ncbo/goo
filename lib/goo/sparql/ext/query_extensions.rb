require 'sparql/client'

module Goo
  module SPARQL
    # Goo-owned extensions that used to live in the forked sparql-client gem.
    # See docs/sparql-client-defork-proposal.md.
    module Ext
      # Builds the `OPTIONAL { { ..pattern.. BIND/FILTER } UNION { .. } }` group that goo
      # uses to pull included attributes (and their inverses) in a single query.
      #
      # This replaces the forked DSL (`SPARQL::Client::Query#optional_union_with_bind_as`
      # + `#add_union_with_bind`, and the `to_s` buffer surgery that injected them). It is a
      # plain `QueryElement` whose `to_s` is the rendered block, so the gem needs no patch:
      # goo pushes it onto the query's filter list, which renders each element verbatim
      # (no `FILTER(...)` wrapper, no trailing ` .`).
      #
      # `binding_as` is the structure built by Goo::SPARQL::QueryBuilder#union_bind_in_where:
      # an Array of `[triples, opts]`, where `triples` is an Array of `[s, p, o]` (symbols
      # for variables, RDF terms otherwise) and `opts` carries `:binds` and/or `:filters`.
      #
      # Output is byte-identical to the old fork DSL; locked by
      # test/test_sparql_query_characterization.rb.
      class UnionWithBind < ::SPARQL::Client::QueryElement
        def initialize(binding_as)
          super()
          @binding_as = binding_as
        end

        def empty?
          @binding_as.nil? || @binding_as.empty?
        end

        def to_s
          groups = @binding_as.map do |triples, opts|
            buffer = serialize_triples(triples)
            buffer += serialize_filters(opts[:filters]) if opts[:filters]
            buffer += serialize_binds(opts[:binds]) if opts[:binds]
            (['{'] + buffer + ['}']).join(' ')
          end
          'OPTIONAL { ' + groups.join(' UNION  ') + ' }'
        end

        private

        # Mirrors the fork's instance `serialize_patterns`: every position goes through
        # serialize_value (so symbols render as `?var`), with `a` for rdf:type.
        def serialize_triples(triples)
          triples.map do |triple|
            triple.map do |value|
              term = value.is_a?(Symbol) ? RDF::Query::Variable.new(value) : value
              term.equal?(RDF.type) ? 'a' : ::SPARQL::Client.serialize_value(term)
            end.join(' ') + ' .'
          end
        end

        def serialize_filters(filters)
          filters.map do |filter|
            clauses = filter[:values].map { |v| "?#{filter[:predicate]} = <#{v}>" }
            "FILTER(#{clauses.join(' || ')}) "
          end
        end

        def serialize_binds(binds)
          binds.map { |bind| "BIND( \"#{bind[:value]}\" as ?#{bind[:as]})" }
        end
      end

      # goo carries two query-serialization deltas that vanilla sparql-client lacks (both
      # generic improvements, candidates to contribute upstream):
      #   * Multiple FROM: render one `FROM <g>` per graph when `options[:from]` is an Array.
      #     Vanilla stores a single URI and `to_s` mis-serializes an Array.
      #   * Nested UNION: place where-pattern unions INSIDE the WHERE group
      #     (`WHERE { P { u0 } UNION { u1 } }`). Vanilla appends them at top level
      #     (`WHERE { P } UNION { u0 }`), which is invalid SPARQL for goo's queries.
      #
      # The upstream `to_s` is monolithic, so this overrides it wholesale (a faithful copy of
      # vanilla's `to_s` plus the two deltas). Union-with-bind is handled separately as a
      # filter QueryElement (UnionWithBind), so the fork's `unions_with_bind` branches are
      # intentionally omitted. Output is locked by test/test_sparql_query_characterization.rb.
      module QuerySerialization
        def to_s
          buffer = [form.to_s.upcase]

          case form
          when :select, :describe
            only_count = values.empty? && options[:count]
            buffer << 'DISTINCT' if options[:distinct] and not only_count
            buffer << 'REDUCED'  if options[:reduced]
            buffer << ((values.empty? and not options[:count]) ? '*' : values.map { |v| ::SPARQL::Client.serialize_value(v[1]) }.join(' '))
            if options[:count]
              options[:count].each do |var, count|
                buffer << '( COUNT(' + (options[:distinct] ? 'DISTINCT ' : '') +
                  (var.is_a?(String) ? var : "?#{var}") + ') AS ' + (count.is_a?(String) ? count : "?#{count}") + ' )'
              end
            end
          when :construct
            buffer << '{'
            buffer += ::SPARQL::Client.serialize_patterns(options[:template])
            buffer << '}'
          end

          # --- delta: multiple FROM ---
          from = options[:from]
          if from
            from = from.instance_of?(Array) ? options[:from] : [options[:from]]
            from.each { |f| buffer << "FROM #{::SPARQL::Client.serialize_value(f)}" }
          end

          unless patterns.empty? && form == :describe
            buffer += self.to_s_ggp.unshift('WHERE')
          end

          # --- delta: nest where-pattern unions inside the WHERE group ---
          unless options[:unions].nil? || options[:unions].empty?
            buffer.pop # remove } of where
            options[:unions].each_with_index do |query, index|
              buffer += index.zero? ? query.to_s_ggp : query.to_s_ggp.unshift('UNION')
            end
            buffer << '}'
          end

          # --- delta: union-with-bind block, last inside WHERE (after unions) ---
          # Goo::SPARQL::Ext::UnionWithBind#to_s already renders the full `OPTIONAL { .. }`.
          if (union_with_bind = options[:goo_union_with_bind])
            buffer.pop # remove } of where
            buffer << union_with_bind.to_s
            buffer << '}'
          end

          if options[:group_by]
            buffer << 'GROUP BY'
            buffer += options[:group_by].map { |var| var.is_a?(String) ? var : "?#{var}" }
          end

          if options[:order_by]
            buffer << 'ORDER BY'
            options[:order_by].map { |elem|
              case elem
              when Hash
                elem.each { |key, val|
                  if !key.is_a?(Symbol)
                    raise ArgumentError, 'keys of hash argument must be a Symbol'
                  elsif !val.is_a?(Symbol) || (val != :asc && val != :desc)
                    raise ArgumentError, 'values of hash argument must either be `:asc` or `:desc`'
                  end
                  buffer << "#{val == :asc ? 'ASC' : 'DESC'}(?#{key})"
                }
              when Array
                if elem.length != 2
                  raise ArgumentError, 'array argument must specify two elements'
                elsif !elem[0].is_a?(Symbol)
                  raise ArgumentError, '1st element of array argument must contain a Symbol'
                elsif !elem[1].is_a?(Symbol) || (elem[1] != :asc && elem[1] != :desc)
                  raise ArgumentError, '2nd element of array argument must either be `:asc` or `:desc`'
                end
                buffer << "#{elem[1] == :asc ? 'ASC' : 'DESC'}(?#{elem[0]})"
              when Symbol
                buffer << "?#{elem}"
              when String
                buffer << elem
              else
                raise ArgumentError, 'argument provided to `order()` must either be an Array, Symbol or String'
              end
            }
          end

          buffer << "OFFSET #{options[:offset]}" if options[:offset]
          buffer << "LIMIT #{options[:limit]}"   if options[:limit]
          options[:prefixes].reverse.each { |e| buffer.unshift("PREFIX #{e}") } if options[:prefixes]

          buffer.join(' ')
        end
      end
    end
  end
end

SPARQL::Client::Query.prepend(Goo::SPARQL::Ext::QuerySerialization)
