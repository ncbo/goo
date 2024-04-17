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
        @equivalent_predicates = options[:equivalent_predicates]
        @properties_to_include = options[:properties_to_include]
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
          @query.optional(*[optional])
        end

        query_filter_str&.each do |filter|
          @query.filter(filter)
        end

        @query.union(*@unions) unless @unions.empty?

        ids_filter(ids) if ids


        @query.order_by(*order_by_string) if @order_by


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

        @query.optional_union_with_bind_as(*binding_as) unless binding_as.empty?
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

      def order_by_string
        order_variables = []
        order_str = @order_by&.map do |attr, order|
          if order.is_a?(Hash)
            sub_attr, order = order.first
            attr =  @internal_variables_map.select{ |internal_var, attr_var| attr_var.eql?({attr => sub_attr}) || attr_var.eql?(sub_attr)}.keys.last
          end
          order_variables << attr
          "#{order.to_s.upcase}(?#{attr})"
        end
        order_str
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
        filter_id = []

        ids.each do |id|
          filter_id << "?id = #{id.to_ntriples.to_s.gsub(' ', '%20')}"
        end
        filter_id_str = filter_id.join ' || '
        @query.filter filter_id_str
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
              # TODO this part can be improved/refactored, the complexity was added because order by don't work
              # if the pattern is in the mandatory ones (variable `patterns`)
              # and optional (variable `optional_patterns`) at the same time
              sub_attr, direction = direction.first
              graph_match_iteration = Goo::Base::PatternIteration.new(Goo::Base::Pattern.new({attr => [sub_attr]}))
              old_internal = internal_variables.dup
              old_patterns = optional_patterns.dup

              walk_pattern(klass, graph_match_iteration, graphs, optional_patterns, @unions, internal_variables, in_aggregate = false, query_options, @collection)
              new_variables = (internal_variables - old_internal)
              internal_variables.delete(new_variables)
              new_patterns = optional_patterns - old_patterns
              already_existent_pattern = patterns.select{|x| x[1].eql?(new_patterns.last[1])}.first

              if already_existent_pattern
                already_existent_variable = already_existent_pattern[2]
                optional_patterns = old_patterns
                key = @internal_variables_map.select{|key, value|  key.eql?(new_variables.last)}.keys.first
                @internal_variables_map[key] = (already_existent_variable || new_variables.last) if key

                #variables << already_existent_variable
              else
                #variables <<  new_variables.last
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
              end
              filter_operations << (
                "?#{filter_var.to_s} #{sparql_op_string(filter_operation.operator)} " +
                  " #{value.to_ntriples}")
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

