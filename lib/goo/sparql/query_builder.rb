module Goo
  module SPARQL
    class QueryBuilder
      include Goo::SPARQL::QueryPatterns

      def initialize(options)
        @no_graphs = options[:no_graphs]
        @query_filters = options[:filters]
        @store = options[:store] || :main
        @page = options[:page]
        @count = options[:count]
        @graph_match = options[:graph_match]
        @aggregate = options[:aggregate]
        @collection = options[:collection]
        @model_query_options = options[:query_options]
        @enable_rules = options[:rules]
        @unions = []
      end

      def build_select_query(ids, binding_as, klass, graphs, optional_patterns,
                             order_by, patterns, query_options, variables)


        internal_variables = graph_match(@collection, @graph_match, graphs, klass, patterns, query_options, @unions)
        aggregate_projections, aggregate_vars, variables, optional_patterns = get_aggregate_vars(@aggregate, @collection,
                                                                                                 graphs, internal_variables,
                                                                                                 klass, optional_patterns,
                                                                                                 @unions, variables)
        filter_id_str, query_filter_str = filter_id_query_strings(@collection, graphs, ids, internal_variables,
                                                                  klass, optional_patterns, patterns, @query_filters)


        order_by, variables, patterns = order_by(@count, klass, order_by, patterns, variables)

        query_options[:rules] = [:NONE] unless @enable_rules
        query_options = nil if query_options.empty?

        variables = [] if @count

        variables, patterns = add_some_type_to_id(patterns, query_options, variables)

        select = get_select(aggregate_projections, variables, @store)
        variables.delete :some_type
        select.where(*patterns)

        optional_patterns.each do |optional|
          select.optional(*[optional])
        end
        select.union(*@unions) if @unions.length > 0
        if order_by
          order_by_str = order_by.map { |attr, order| "#{order.to_s.upcase}(?#{attr})" }
          select.order_by(*order_by_str)
        end

        select.filter(filter_id_str)

        #if unmapped && predicates && predicates.length > 0
        #  filter_predicates = predicates.map { |p| "?predicate = #{p.to_ntriples}" }
        #  filter_predicates = filter_predicates.join " || "
        #  select.filter(filter_predicates)
        #end

        if query_filter_str.length > 0
          query_filter_str.each do |f|
            select.filter(f)
          end
        end

        if aggregate_vars
          select.options[:group_by] = [:id]
          select.options[:count] = aggregate_vars
        end

        if @count
          select.options[:count] = [[:id, :count_var, :count]]
        end

        if @page
          offset = (@page[:page_i] - 1) * @page[:page_size]
          select.slice(offset, @page[:page_size])
          # mdorf, 1/12/2023, AllegroGraph returns duplicate results across
          # different pages unless the order_by clause is explicitly specified
          # see https://github.com/ncbo/bioportal-project/issues/264
          # However, using the .order call has added a significant overhead;
          # therefore, a different solution is now being sought
          # mdorf, 7/27/2023, AllegroGraph supplied a patch (rfe17161-7.3.1.fasl.patch)
          # that enables implicit internal ordering, which addresses this issue
          # select.order(:id)
        end

        select.distinct(true)

        if query_options && !binding_as
          query_options[:rules] = query_options[:rules].map { |x| x.to_s }.join("+")
          select.options[:query_options] = query_options
        else
          query_options = { rules: ["NONE"] }
          select.options[:query_options] = query_options
        end

        if !graphs.nil? && graphs.length > 0
          graphs.select! { |g| g.to_s["owl#Class"].nil? }
        end

        unless @no_graphs
          select.from(graphs.uniq)
        else
          select.options[:graphs] = graphs.uniq
        end

        query_options.merge!(@model_query_options) if @model_query_options
        if binding_as
          select.union_with_bind_as(*binding_as)
        end
        [select, aggregate_projections]
      end



      private

      def order_by(count, klass, order_by, patterns, variables)
      order_by = nil if count
      if order_by
        order_by = order_by.first
        #simple ordering ... needs to use pattern inspection
        order_by.each do |attr, direction|
          quad = query_pattern(klass, attr)
          patterns << quad[1]
          #mdorf, 9/22/16 If an ORDER BY clause exists, the columns used in the ORDER BY should be present in the SPARQL select
          variables << attr unless variables.include?(attr)
        end
      end
      [order_by, variables, patterns]
      end
      def sparql_op_string(op)
        case op
        when :or
          return "||"
        when :and
          return "&&"
        when :==
          return "="
        end
        return op.to_s
      end

      def graph_match(collection, graph_match, graphs, klass, patterns, query_options, unions)
        internal_variables = []

        if graph_match
          #make it deterministic - for caching
          graph_match_iteration = Goo::Base::PatternIteration.new(graph_match)
          walk_pattern(klass, graph_match_iteration, graphs, patterns, unions,
                       internal_variables, in_aggregate = false, query_options, collection)
          graphs.uniq!
        end
        internal_variables
      end

      def patterns_for_match(klass,attr,value,graphs,patterns,unions,
                                  internal_variables,subject=:id,in_union=false,
                                  in_aggregate=false, query_options={}, collection=nil)
        if value.respond_to?(:each) || value.instance_of?(Symbol)
          next_pattern = value.instance_of?(Array) ? value.first : value

          #for filters
          next_pattern = { next_pattern => [] } if next_pattern.instance_of?(Symbol)

          value = "internal_join_var_#{internal_variables.length}".to_sym
          if in_aggregate
            value = "#{attr}_agg_#{in_aggregate}".to_sym
          end
          internal_variables << value
        end

        add_rules(attr,klass,query_options)
        graph, pattern =
          query_pattern(klass,attr,value: value,subject: subject, collection: collection)
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
          next_pattern.each do |next_attr,next_value|
            patterns_for_match(range, next_attr, next_value, graphs,
                               patterns, unions, internal_variables, subject=value,
                               in_union, in_aggregate, collection=collection)
          end
        end
      end
      def query_filter_sparql(klass,filter,filter_patterns,filter_graphs,
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
                               [],internal_variables,
                               subject=:id,in_union=false,in_aggregate=false,
                               collection=collection)
            inspected_patterns[filter_pattern_match] = internal_variables.last
          end
          filter_var = inspected_patterns[filter_pattern_match]
          if !filter_operation.value.instance_of?(Goo::Filter)
            case filter_operation.operator
            when :unbound
              filter_operations << "!BOUND(?#{filter_var.to_s})"
              return :optional

            when :bound
              filter_operations << "BOUND(?#{filter_var.to_s})"
              return :optional
            when :regex
              if filter_operation.value.is_a?(String)
                filter_operations << "REGEX(STR(?#{filter_var.to_s}) , \"#{filter_operation.value.to_s}\")"
              end

            else
              value = RDF::Literal.new(filter_operation.value)
              if filter_operation.value.is_a? String
                value = RDF::Literal.new(filter_operation.value, :datatype => RDF::XSD.string)
              end
              filter_operations << (
                "?#{filter_var.to_s} #{sparql_op_string(filter_operation.operator)} " +
                  " #{value.to_ntriples}")
            end
          else
            filter_operations << "#{sparql_op_string(filter_operation.operator)}"
            query_filter_sparql(klass,filter_operation.value,filter_patterns,
                                filter_graphs,filter_operations,
                                internal_variables,inspected_patterns,collection)
          end
        end
      end
      def walk_pattern(klass, match_patterns, graphs, patterns, unions,
                            internal_variables,in_aggregate=false,query_options={},
                            collection)
        match_patterns.each do |match,in_union|
          unions << [] if in_union
          match = match.is_a?(Symbol) ? { match => [] } : match
          match.each do |attr,value|
            patterns_for_match(klass, attr, value, graphs, patterns,
                               unions,internal_variables,
                               subject=:id,in_union=in_union,
                               in_aggregate=in_aggregate,
                               query_options=query_options,
                               collection)
          end
        end
      end



      def get_aggregate_vars(aggregate, collection, graphs, internal_variables, klass, optional_patterns, unions, variables)
        aggregate_vars = nil
        aggregate_projections = nil
        if aggregate
          aggregate.each do |agg|
            agg_patterns = []
            graph_match_iteration =
              Goo::Base::PatternIteration.new(Goo::Base::Pattern.new(agg.pattern))
            walk_pattern(klass, graph_match_iteration, graphs, agg_patterns, unions,
                         internal_variables, in_aggregate = agg.aggregate, collection)
            if agg_patterns.length > 0
              projection = "#{internal_variables.last.to_s}_projection".to_sym
              aggregate_on_attr = internal_variables.last.to_s
              aggregate_on_attr =
                aggregate_on_attr[0..aggregate_on_attr.index("_agg_") - 1].to_sym
              (aggregate_projections ||= {})[projection] = [agg.aggregate, aggregate_on_attr]
              (aggregate_vars ||= []) << [internal_variables.last,
                                          projection,
                                          agg.aggregate]
              variables << projection
              optional_patterns.concat(agg_patterns)
            end
          end
        end
        return aggregate_projections, aggregate_vars, variables, optional_patterns
      end

      def filter_id_query_strings(collection, graphs, ids, internal_variables, klass, optional_patterns, patterns, query_filters)
        filter_id = []
        if ids
          ids.each do |id|
            filter_id << "?id = #{id.to_ntriples.to_s}"
          end
        end
        filter_id_str = filter_id.join " || "

        query_filter_str = []
        if query_filters
          filter_patterns = []
          filter_graphs = []
          inspected_patterns = {}
          query_filters.each do |query_filter|
            filter_operations = []
            type = query_filter_sparql(klass, query_filter, filter_patterns, filter_graphs,
                                       filter_operations, internal_variables,
                                       inspected_patterns, collection)
            query_filter_str << filter_operations.join(" ")
            graphs.concat(filter_graphs) if filter_graphs.length > 0
            if filter_patterns.length > 0
              if type == :optional
                optional_patterns.concat(filter_patterns)
              else
                patterns.concat(filter_patterns)
              end
            end
          end
        end
        return filter_id_str, query_filter_str
      end


      def get_select(aggregate_projections, variables, store)
        client = Goo.sparql_query_client(store)
        # mdorf, 6/03/20 If aggregate projections (sub-SELECT within main SELECT) use an alias, that alias cannot appear in the main SELECT
        # https://github.com/ncbo/goo/issues/106
        # See last sentence in https://www.w3.org/TR/sparql11-query/#aggregateExample
        select_vars = variables.dup
        select_vars.reject! { |var| aggregate_projections.key?(var) } if aggregate_projections
        client.select(*select_vars).distinct()
      end


      def add_some_type_to_id(patterns, query_options, variables)
        #rdf:type <x> breaks the reasoner
        if query_options && query_options[:rules] != [:NONE]
          patterns[0] = [:id, RDF[:type], :some_type]
          variables << :some_type
        end
        [variables, patterns]
      end

    end
  end
end

