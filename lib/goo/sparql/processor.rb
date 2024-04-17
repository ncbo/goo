module Goo
  module SPARQL
    module Processor
      def process_query_call(count=false)
        if Goo.queries_debug? &&  Thread.current[:ncbo_debug]
          start = Time.now
          query_resp = process_query_intl(count=count)
          (Thread.current[:ncbo_debug][:goo_process_query] ||= []) << (Time.now - start)
          return query_resp
        end
         process_query_init(count=count)
      end

      private
      def process_query_init(count=false)
        if @models == []
          @result = []
          return @result
        end

        @include << @include_embed if @include_embed.length > 0

        @predicates = unmmaped_predicates()
        @equivalent_predicates = retrieve_equivalent_predicates()

        options_load = { models: @models, include: @include, ids: @ids,
                         graph_match: @pattern, klass: @klass,
                         filters: @filters, order_by: @order_by ,
                         read_only: @read_only, rules: @rules,
                         predicates: @predicates,
                         no_graphs: @no_graphs,
                         equivalent_predicates: @equivalent_predicates }

        options_load.merge!(@where_options_load) if @where_options_load

        if !@klass.collection_opts.nil? and !options_load.include?(:collection)
          raise ArgumentError, "Collection needed call `#{@klass.name}`"
        end

        ids = nil


        ids = redis_indexed_ids if use_redis_index?

        if @page_i && !use_redis_index?
          page_options = options_load.dup
          page_options.delete(:include)
          page_options[:include_pagination] = @include
          page_options[:query_options] = @query_options

          @count = run_count_query(page_options)
          page_options[:page] = { page_i: @page_i, page_size: @page_size }

          models_by_id = Goo::SPARQL::Queries.model_load(page_options)
          options_load[:models] = models_by_id.values
          #models give the constraint
          options_load.delete :graph_match
        elsif count
          count_options = options_load.dup
          count_options.delete(:include)
          return run_count_query(count_options)
        end

        if @indexing
          #do not care about include values
          @result = Goo::Base::Page.new(@page_i,@page_size,@count,models_by_id.values)
          return @result
        end

        options_load[:ids] = ids if ids
        models_by_id = {}

        if (@page_i && options_load[:models].nil?) ||
          (@page_i && options_load[:models].length > 0) ||
          (!@page_i && (@count.nil? || @count > 0))

          models_by_id = Goo::SPARQL::Queries.model_load(options_load)
          run_aggregate_query(models_by_id) if @aggregate && models_by_id.length > 0
        end

        if @page_i
          @result = Goo::Base::Page.new(@page_i, @page_size, @count, models_by_id.values)
        else
          @result = @models ? @models : models_by_id.values
        end
        @result
      end


      def use_redis_index?
        @index_key
      end

      def run_aggregate_query(models_by_id)
        options_load_agg = { models: models_by_id.values, klass: @klass,
                             filters: @filters, read_only: @read_only,
                             aggregate: @aggregate, rules: @rules }
        options_load_agg.merge!(@where_options_load) if @where_options_load
        Goo::SPARQL::Queries.model_load(options_load_agg)
      end
      def run_count_query(page_options)
        count = 0
        if @pre_count
          count = @pre_count
        elsif !@count && @do_count
          page_options[:count] = :count
          r = Goo::SPARQL::Queries.model_load(page_options)
          if r.is_a? Numeric
            count = r.to_i
          end
        elsif @count
          count = @count
        end
        page_options.delete :count
        count
      end

      def redis_indexed_ids
        raise ArgumentError, "Redis is not configured" unless Goo.redis_client
        rclient = Goo.redis_client
        cache_key = cache_key_for_index(@index_key)
        raise ArgumentError, "Index not found" unless rclient.exists(cache_key)
        if @page_i
          if !@count
            @count = rclient.llen(cache_key)
          end
          rstart = (@page_i -1) * @page_size
          rstop = (rstart + @page_size) -1
          ids = rclient.lrange(cache_key,rstart,rstop)
        else
          ids = rclient.lrange(cache_key,0,-1)
        end
        ids = ids.map { |i| RDF::URI.new(i) }
      end
    end
  end
end
