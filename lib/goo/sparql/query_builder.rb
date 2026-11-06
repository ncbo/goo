module Goo
  module SPARQL
    class QueryBuilder
      include Goo::SPARQL::QueryPatterns

      def initialize(options)
        @no_graphs = options[:no_graphs]
        @query_filters = options[:filters]
        @klass = options[:klass]
        @store = options[:store] || :main
        @page = options[:page]
        @count = options[:count]
        @graph_match = options[:graph_match]
        @unions = options[:unions] || []
        @aggregate = options[:aggregate]
        @collection = options[:collection]
        @enable_rules = options[:rules]
        @order_by = options[:order_by]
        @internal_variables_map = {}
        @order_by_vars = {}
        @equivalent_predicates = options[:equivalent_predicates]
        @properties_to_include = options[:properties_to_include]
        @union_with_bind = nil
        @query = get_client
      end

      def build_query(ids, variables, graphs, patterns)
        query_options = {}

        expand_equivalent_predicates(@properties_to_include, @equivalent_predicates)

        properties_to_include = @properties_to_include
        patterns = graph_match(@collection, @graph_match, graphs, @klass, patterns, query_options, @unions)
        variables, patterns = add_some_type_to_id(patterns, query_options, variables)
        aggregate_projections, aggregate_vars, variables, optional_patterns = get_aggregate_vars(@aggregate, @collection, graphs, @klass, @unions, variables)
        query_filter_str, patterns, optional_patterns, filter_variables =
          filter_query_strings(@collection, graphs, @klass, optional_patterns, patterns, @query_filters)
        @order_by, variables, optional_patterns = init_order_by(@count, @klass, @order_by, optional_patterns, variables,patterns, query_options, graphs)

        variables = [] if @count
        variables.delete :some_type

        select_distinct(variables, aggregate_projections, filter_variables)
          .from(graphs)
          .where(patterns)
          .union_bind_in_where(properties_to_include)

        optional_patterns.each do |optional|
          # An entry is either one triple pattern or a group of them (a nested order_by
          # path), which must stay together in a single OPTIONAL.
          optional_group?(optional) ? @query.optional(*optional) : @query.optional(optional)
        end

        query_filter_str&.each do |filter|
          @query.filter(filter)
        end

        Array(@unions).each do |union|
          @query.union(*union)
        end

        ids_filter(ids) if ids

        # Inject the union-with-bind block last, after every #filter call above, so it
        # renders after the real filters (matching the old fork DSL ordering).
        apply_union_with_bind

        if @order_by
          order_conditions = order_by_string
          @query.order_by(*order_conditions) unless order_conditions.empty?
        end

        put_query_aggregate_vars(aggregate_vars) if aggregate_vars
        count if @count
        paginate if @page

        [@query, aggregate_projections]
      end

      def union_bind_in_where(properties)
        binding_as = []
        if Goo.backend_4s? || Goo.backend_gb?
          properties.each do |property_attr, property|
            predicates = [property[:uri]] + (property[:equivalents] || [])
            options = {
              binds: [{ value: property_attr, as: :attributeProperty }]
            }
            subject = property[:subject] || :id
            predicates.uniq.each do |predicate_uri|
              pattern = if property[:is_inverse]
                          [:attributeObject, predicate_uri, subject]
                        else
                          [subject, predicate_uri, :attributeObject]
                        end
              binding_as << [[pattern], options]
            end
          end

        else
          direct_predicate, inverse_predicate = include_properties
          direct_filter = direct_predicate.empty? ? [] : [{ values: direct_predicate, predicate: :attributeProperty }]
          inverse_filter = inverse_predicate.empty? ? [] : [{ values: inverse_predicate, predicate: :attributeProperty }]
          binding_as << [[[:id, :attributeProperty, :attributeObject]], { filters:  direct_filter}] unless direct_filter.empty?
          binding_as << [[[:inverseAttributeObject, :attributeProperty, :id]], { filters: inverse_filter}] unless inverse_filter.empty?
        end

        @union_with_bind = Goo::SPARQL::Ext::UnionWithBind.new(binding_as) unless binding_as.empty?
        self
      end

      # Stash the union-with-bind QueryElement so Goo::SPARQL::Ext::QuerySerialization renders
      # it as the LAST thing inside the WHERE group -- after any where-pattern unions. Order
      # matters: the block is an OPTIONAL (left-join), so placing it after the unions matches
      # the original fork semantics (and result sets).
      def apply_union_with_bind
        return self if @union_with_bind.nil?

        @query.options[:goo_union_with_bind] = @union_with_bind
        self
      end

      def where(patterns)
        @query.where(*patterns)
        self
      end

      def paginate
        offset = (@page[:page_i] - 1) * @page[:page_size]
        @query.slice(offset, @page[:page_size])
        self
      end

      def count
        @query.options[:count] = [%i[id count_var count]]
        self
      end

      def put_query_aggregate_vars(aggregate_vars)
        @query.options[:group_by] = [:id]
        @query.options[:count] = aggregate_vars
        self
      end

      # ORDER BY conditions for @order_by. A nested key orders on the variable that
      # init_order_by resolved for it; a key it resolved to nil (the WHERE fixes that value
      # to a constant, so every solution has the same one) is left out.
      def order_by_string
        @order_by.filter_map do |attr, order|
          order = order.first.last if order.is_a?(Hash)
          var = @order_by_vars.fetch(attr, attr)
          "#{order.to_s.upcase}(?#{var})" if var
        end
      end

      def from(graphs)

        graphs.select! { |g| g.to_s['owl#Class'].nil? } if !graphs.nil? && !graphs.empty?

        if @no_graphs
          @query.options[:graphs] = graphs.uniq
        else
          @query.from(graphs.uniq)
        end
        self
      end

      def select_distinct(variables, aggregate_patterns, filter_variables)
        variables << :inverseAttributeObject if inverse_predicate?
        select_vars = variables.dup
        reject_aggregations_from_vars(select_vars, aggregate_patterns) if aggregate_patterns
        select_vars = (select_vars + filter_variables).uniq  if @page && Goo.backend_4s? # Fix for 4store pagination with a filter
        @query = @query.select(*select_vars).distinct(true)
        self
      end

      def ids_filter(ids)
        return self if ids.empty?

        if Goo.backend_4s?
          filter = ids.map do |id|
            "?id = #{id.to_ntriples.to_s.gsub(' ', '%20').gsub("\\u0020", '%20')}"
          end
          @query.filter filter.join(' || ')
        else
          values = ids.map do |id|
            id.is_a?(RDF::URI) ? RDF::URI(id.to_s.gsub(' ', '%20')) : id
          end
          @query.values(:id, *values)
        end
        self
      end

      private

      def include_properties
        direct_predicates = @properties_to_include.select { |_, property| !property[:is_inverse] }.map { |_, property| [property[:uri]] + (property[:equivalents] || []) }.flatten
        inverse_predicates = @properties_to_include.select { |_, property| property[:is_inverse] }.map { |_, property| [property[:uri]] + (property[:equivalents] || []) }.flatten
        [direct_predicates, inverse_predicates]
      end

      def inverse_predicate?
        @properties_to_include.any? { |_, property| property[:is_inverse] }
      end

      def patterns_for_match(klass, attr, value, graphs, patterns, unions,
                             internal_variables, subject = :id, in_union = false,
                             in_aggregate = false, query_options = {}, collection = nil)
        new_internal_var = value
        if value.respond_to?(:each) || value.instance_of?(Symbol)
          next_pattern = value.instance_of?(Array) ? value.first : value

          #for filters
          next_pattern = { next_pattern => [] } if next_pattern.instance_of?(Symbol)

          new_internal_var = "internal_join_var_#{internal_variables.length}".to_sym
          if in_aggregate
            new_internal_var = "#{attr}_agg_#{in_aggregate}".to_sym
          end
          internal_variables << new_internal_var
          @internal_variables_map[new_internal_var] = value.empty? ? attr : {attr => value}
        end


        graph, pattern =
          query_pattern(klass, attr, value: new_internal_var, subject: subject, collection: collection)
        if pattern
          if !in_union
            patterns << pattern
          else
            unions.last << pattern
          end
        end
        graphs << graph if graph
        if next_pattern
          range = klass.range(attr)
          next_pattern.each do |next_attr, next_value|
            patterns_for_match(range, next_attr, next_value, graphs,
                               patterns, unions, internal_variables, subject = new_internal_var,
                               in_union, in_aggregate, collection = collection)
          end
        end
      end

      def walk_pattern(klass, match_patterns, graphs, patterns, unions,
                       internal_variables, in_aggregate = false, query_options = {},
                       collection)
        match_patterns.each do |match, in_union|
          unions << [] if in_union
          match = match.is_a?(Symbol) ? { match => [] } : match
          match.each do |attr, value|
            patterns_for_match(klass, attr, value, graphs, patterns,
                               unions, internal_variables,
                               subject = :id, in_union = in_union,
                               in_aggregate = in_aggregate,
                               query_options = query_options,
                               collection)
          end
        end
      end

      def get_aggregate_vars(aggregate, collection, graphs, klass, unions, variables)
        # mdorf, 6/03/20 If aggregate projections (sub-SELECT within main SELECT) use an alias, that alias cannot appear in the main SELECT
        # https://github.com/ncbo/goo/issues/106
        # See last sentence in https://www.w3.org/TR/sparql11-query/#aggregateExample
        aggregate_vars = nil
        aggregate_projections = nil
        optional_patterns = []

        aggregate&.each do |agg|
          agg_patterns = []
          graph_match_iteration =
            Goo::Base::PatternIteration.new(Goo::Base::Pattern.new(agg.pattern))
          walk_pattern(klass, graph_match_iteration, graphs, agg_patterns, unions,
                       internal_variables, in_aggregate = agg.aggregate, collection)
          unless agg_patterns.empty?
            projection = "#{internal_variables.last.to_s}_projection".to_sym
            aggregate_on_attr = internal_variables.last.to_s
            aggregate_on_attr =
              aggregate_on_attr[0..aggregate_on_attr.index('_agg_') - 1].to_sym
            (aggregate_projections ||= {})[projection] = [agg.aggregate, aggregate_on_attr]
            (aggregate_vars ||= []) << [internal_variables.last,
                                        projection,
                                        agg.aggregate]
            variables << projection
            optional_patterns.concat(agg_patterns)
          end
        end
        [aggregate_projections, aggregate_vars, variables, optional_patterns]
      end

      def graph_match(collection, graph_match, graphs, klass, patterns, query_options, unions)
        if graph_match
          #make it deterministic - for caching
          graph_match_iteration = Goo::Base::PatternIteration.new(graph_match)
          walk_pattern(klass, graph_match_iteration, graphs, patterns, unions,
                       internal_variables, in_aggregate = false, query_options, collection)
          graphs.uniq!
        end
        patterns
      end

      def get_client
        Goo.sparql_query_client(@store)
      end

      def init_order_by(count, klass, order_by, optional_patterns, variables, patterns, query_options, graphs)
        order_by = nil if count
        if order_by
          order_by = order_by.first
          #simple ordering ... needs to use pattern inspection
          order_by.each do |attr, direction|

            if direction.is_a?(Hash)
              # Nested ordering, e.g. order_by(submission: {submissionId: :desc}).
              sub_attr, = direction.first
              graph_match_iteration = Goo::Base::PatternIteration.new(Goo::Base::Pattern.new({attr => [sub_attr]}))
              old_internal = internal_variables
              path_patterns = []
              walk_pattern(klass, graph_match_iteration, graphs, path_patterns, @unions, internal_variables, in_aggregate = false, query_options, @collection)
              path_variables = internal_variables - old_internal

              if (bound = required_path_term(path_patterns, patterns, path_variables))
                # The WHERE already requires this exact path: order on the variable it
                # binds, or on nothing if it fixes the value to a constant.
                term = bound.first
                @order_by_vars[attr] = term.is_a?(Symbol) ? term : nil
              else
                # The whole path goes in one OPTIONAL. With one OPTIONAL per hop, a
                # solution whose first hop is unbound joins the second hop against every
                # subject that has the attribute, and Virtuoso is slow on that shape even
                # when the first hop is always bound (old ontologies_api metrics join for
                # GO: 9.6 s split, 0.1 s grouped).
                optional_patterns << path_patterns
                @order_by_vars[attr] = path_variables.last
              end

            else
              quad = query_pattern(klass, attr)
              optional_patterns << quad[1]
              #variables << attr
            end

            #patterns << quad[1]
            #mdorf, 9/22/16 If an ORDER BY clause exists, the columns used in the ORDER BY should be present in the SPARQL select
            #variables << attr unless variables.include?(attr)
          end
        end
        [order_by, variables, optional_patterns, patterns]
      end

      # True for an optional_patterns entry that holds several triple patterns (rendered
      # as one OPTIONAL group) rather than a single [subject, predicate, object].
      def optional_group?(optional)
        optional.first.is_a?(Array)
      end

      # Follow an order_by path (one triple pattern per hop, each introducing one of
      # path_variables) through the required WHERE patterns. If every hop matches a required
      # pattern with the same predicate from the same term, returns [term] for the term the
      # last hop binds there: a variable, or a constant such as a literal. Returns nil if the
      # path is not fully required. Only `patterns` count: terms bound in OPTIONALs or UNION
      # branches may be unbound for some solutions.
      def required_path_term(path_patterns, patterns, path_variables, bindings = {})
        return [bindings[path_variables.last]] if path_patterns.empty?

        hop, *rest = path_patterns
        subject, predicate, object = hop.map { |term| bindings.fetch(term, term) }
        # A direct hop introduces its variable as the object, an inverse hop as the subject.
        new_var, known, new_pos, known_pos =
          if path_variables.include?(object) && !bindings.key?(object)
            [object, subject, 2, 0]
          else
            [subject, object, 0, 2]
          end

        patterns.each do |pattern|
          next unless pattern.is_a?(Array) && pattern.length == 3
          next unless pattern[1] == predicate && pattern[known_pos] == known

          found = required_path_term(rest, patterns, path_variables,
                                     bindings.merge(new_var => pattern[new_pos]))
          return found if found
        end
        nil
      end

      def sparql_op_string(op)
        case op
        when :or
          return '||'
        when :and
          return '&&'
        when :==
          return '='
        end
        op.to_s
      end

      def query_filter_sparql(klass, filter, filter_patterns, filter_graphs,
                              filter_operations,
                              internal_variables,
                              inspected_patterns,
                              collection)
        #create a object variable to project the value in the filter
        filter.filter_tree.each do |filter_operation|
          filter_pattern_match = {}
          if filter.pattern.instance_of?(Symbol)
            filter_pattern_match[filter.pattern] = []
          else
            filter_pattern_match = filter.pattern
          end
          unless inspected_patterns.include?(filter_pattern_match)
            attr = filter_pattern_match.keys.first
            patterns_for_match(klass, attr, filter_pattern_match[attr],
                               filter_graphs, filter_patterns,
                               [], internal_variables,
                               subject = :id, in_union = false, in_aggregate = false,
                               collection = collection)
            inspected_patterns[filter_pattern_match] = internal_variables.last
          end
          filter_var = inspected_patterns[filter_pattern_match]

          if filter_operation.value.instance_of?(Goo::Filter)
            filter_operations << "#{sparql_op_string(filter_operation.operator)}"
            query_filter_sparql(klass, filter_operation.value, filter_patterns,
                                filter_graphs, filter_operations,
                                internal_variables, inspected_patterns, collection)
          else
            case filter_operation.operator
            when  :unbound
              filter_operations << "!BOUND(?#{filter_var.to_s})"
              return :optional

            when :bound
              filter_operations << "BOUND(?#{filter_var.to_s})"
              return :optional
            when :regex
              if  filter_operation.value.is_a?(String)
                filter_operations << "REGEX(STR(?#{filter_var.to_s}) , \"#{filter_operation.value.to_s}\", \"i\")"
              end

            else
              value = RDF::Literal.new(filter_operation.value)
              if filter_operation.value.is_a? String
                value = RDF::Literal.new(filter_operation.value)
                filter_var = "str(?#{filter_var})"
              else
                filter_var = "?#{filter_var}"
              end
              filter_operations << (
                "#{filter_var.to_s} #{sparql_op_string(filter_operation.operator)} " +
                  " #{value.to_ntriples.to_s.gsub("\\u0020", "%20")}")
            end

          end
        end
      end

      def filter_query_strings(collection, graphs, klass,
                               optional_patterns, patterns,
                               query_filters)
        query_filter_str = []
        filter_graphs = []
        filter_variables = []
        inspected_patterns = {}
        query_filters&.each do |query_filter|
          filter_operations = []
          filter_patterns = []
          type = query_filter_sparql(klass, query_filter, filter_patterns, filter_graphs,
                                     filter_operations, internal_variables,
                                     inspected_patterns, collection)
          query_filter_str << filter_operations.join(' ')
          graphs.concat(filter_graphs) unless filter_graphs.empty?
          unless filter_patterns.empty?
            if type == :optional
              optional_patterns.concat(filter_patterns)
            else
              patterns.concat(filter_patterns)
            end
          end
          #filter_variables << inspected_patterns.values.last
        end
        [query_filter_str, patterns, optional_patterns, filter_variables]
      end

      def reject_aggregations_from_vars(variables, aggregate_projections)
        variables.reject! { |var| aggregate_projections.key?(var) }
      end

      def add_some_type_to_id(patterns, query_options, variables)
        #rdf:type <x> breaks the reasoner
        if query_options && !query_options.empty? && query_options[:rules] != [:NONE]
          patterns[0] = [:id, RDF[:type], :some_type]
          variables << :some_type
        end
        [variables, patterns]
      end

      def internal_variables
        @internal_variables_map.keys
      end

      def expand_equivalent_predicates(query_properties, eq_p)

        return unless eq_p && !eq_p.empty?

        query_properties&.each do |_, property|
          property_uri = property[:uri]
          property[:equivalents] = eq_p[property_uri.to_s].to_a.map { |p| RDF::URI.new(p) } if eq_p.include?(property_uri.to_s)
        end
      end
    end
  end
end
