module Goo
  module Base

    class Where

      AGGREGATE_PATTERN = Struct.new(:pattern,:aggregate)

      attr_accessor :where_options_load

      def initialize(klass,*match_patterns)
        if Goo.queries_debug? && Thread.current[:ncbo_debug].nil?
          Thread.current[:ncbo_debug] = {}
        end
        @klass = klass
        @pattern = match_patterns.first.nil? ? nil : Pattern.new(match_patterns.first) 
        @models = nil
        @include = []
        @include_embed = {}
        @result = nil
        @filters = nil
        @ids = nil
        @aggregate = nil
        @where_options_load = nil
        @count = nil
        @page_i = nil
        @page_size = nil
        @index_key = nil
        @order_by = nil
        @indexing = false
        @read_only = false
        @rules = true
        @do_count = true
        @query_options = nil
        @no_graphs = false

        #cache of retrieved predicates for unmapped queries
        #reused across pages
        @predicates = nil
      end

      def equivalent_predicates
        @equivalent_predicates
      end

      def includes_aliasing
        @include.each do |attr|
          return true if @klass.alias?(attr)
        end
        return false
      end

      def closure(eq_has)
        begin
          changed = false
          copy = {}
          eq_has.each do |x,y|
            copy[x] = y.dup
          end
          copy.each do |p,values|
            values.each  do |y|
              next if copy[y].nil?
              copy[y].each do |z|
                unless values.include?(z)
                  eq_has[p] << z
                  changed = true
                end
              end
            end
          end
        end while(changed)
      end

      def no_graphs
        @no_graphs = true
        return self
      end

      def retrieve_equivalent_predicates()
        return @equivalent_predicates unless @equivalent_predicates.nil?

        equivalent_predicates = nil
        if @include.first == :unmapped || includes_aliasing()
          if @where_options_load && @where_options_load[:collection]
            graph = @where_options_load[:collection].map { |x| x.id }
          else
            #TODO review this case
            raise ArgumentError, "Unmapped wihout collection not tested"
          end
          equivalent_predicates = Goo::SPARQL::Queries.sub_property_predicates(graph)
          #TODO compute closure
          equivalent_predicates_hash = {}
          equivalent_predicates.each do |down,up|
            (equivalent_predicates_hash[up.to_s] ||= Set.new) << down.to_s
          end
          equivalent_predicates_hash.delete(Goo.vocabulary(:rdfs)[:label].to_s)
          closure(equivalent_predicates_hash)
          equivalent_predicates_hash.each do |k,v|
            equivalent_predicates_hash[k] << k
          end
        end
        return equivalent_predicates_hash
      end

      def unmmaped_predicates()
        return @predicates unless @predicates.nil?

        predicates = nil
        if @include.first == :unmapped
          if @where_options_load[:collection]
            graph = @where_options_load[:collection].map { |x| x.id }
          else
            #TODO review this case
            raise ArgumentError, "Unmapped wihout collection not tested"
          end
          predicates = Goo::SPARQL::Queries.graph_predicates(graph)
          if predicates.length == 0
            raise ArgumentError, "Empty graph. Unable to load predicates"
          end
        end
        return predicates
      end

      def process_query(count=false)
        if Goo.queries_debug? &&  Thread.current[:ncbo_debug]
          tstart = Time.now
          query_resp = process_query_intl(count=count)
          (Thread.current[:ncbo_debug][:goo_process_query] ||= []) << (Time.now - tstart)
          return query_resp
        end
        return process_query_intl(count=count)
      end

      def process_query_intl(count=false)

        if @order_by && !@indexing
          raise ArgumentError, "Order by support is restricted to only offline indexing"
        end

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
        if @index_key
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

        if @page_i && !@index_key
          page_options = options_load.dup
          page_options.delete(:include)
          page_options[:include_pagination] = @include
          if !@count && @do_count
            page_options[:count] = :count 
            @count = Goo::SPARQL::Queries.model_load(page_options).to_i
          end
          page_options.delete :count
          page_options[:query_options] = @query_options
          page_options[:page] = { page_i: @page_i, page_size: @page_size }
          models_by_id = Goo::SPARQL::Queries.model_load(page_options)
          options_load[:models] = models_by_id.values
          
          #models give the constraint
          options_load.delete :graph_match
        elsif count
          count_options = options_load.dup
          count_options.delete(:include)
          count_options[:count] = :count 
          return Goo::SPARQL::Queries.model_load(count_options).to_i
        end

        if @indexing
          #do not care about include values
          @result = Goo::Base::Page.new(@page_i,@page_size,@count,models_by_id.values)
          return @result
        end

        options_load[:ids] = ids if ids
        models_by_id = {}
        if (@page_i && options_load[:models].length > 0) || 
            (!@page_i && (@count.nil? || @count > 0))
          models_by_id = Goo::SPARQL::Queries.model_load(options_load)
          if @aggregate
            if models_by_id.length > 0
              options_load_agg = { models: models_by_id.values, klass: @klass,
                             filters: @filters, read_only: @read_only,
                             aggregate: @aggregate, rules: @rules }

              options_load_agg.merge!(@where_options_load) if @where_options_load
              Goo::SPARQL::Queries.model_load(options_load_agg)
            end
          end
        end
        unless @page_i
          @result = @models ? @models : models_by_id.values
        else
          @result = Goo::Base::Page.new(@page_i,@page_size,@count,models_by_id.values)
        end
        @result
      end

      def disable_rules
        @rules = false
        self
      end

      def cache_key_for_index(index_key)
        return "goo:#{@klass.name}:#{index_key}"
      end

      def index_as(index_key,max=nil)
        @indexing = true
        @read_only = true
        raise ArgumentError, "Need redis configuration to index" unless Goo.redis_client
        rclient = Goo.redis_client
        if @include.length > 0
          raise ArgumentError, "Index is performend on Where objects without attributes included"
        end
        page_i_index = 1
        page_size_index = 400 
        temporal_key = "goo:#{@klass.name}:#{index_key}:tmp"
        final_key = cache_key_for_index(index_key)
        count = 0
        start = Time.now
        stop = false
        begin
          page = self.page(page_i_index,page_size_index).all
          count += page.length
          ids = page.map { |x| x.id }
          rclient.pipelined do
            ids.each do |id|
              rclient.rpush temporal_key, id.to_s
            end
          end
          page_i_index += 1
          puts "Indexed #{count}/#{page.aggregate} - #{Time.now - start} sec."
          stop = !max.nil? && (count > max)
        end while (page.next? && !stop)
        rclient.rename temporal_key, final_key
        puts "Indexed #{rclient.llen(final_key)} at #{final_key}"
        return rclient.llen(final_key)
      end

      def all
        if @result.nil? && @klass.inmutable? && @klass.inm_instances
          if @pattern.nil? && @filters.nil? 
            @result = @klass.inm_instances.values
          end
        end
        process_query unless @result
        @result
      end
      alias_method :to_a, :all

      def each(&block)
        process_query unless @result
        @result.each do |r|
          yield r
        end
      end

      def length
        unless @result
          res = process_query(count=true)
          return res.length if res.is_a?Array
          return res
        end
        return @result.length
      end

      def count
        unless @result
          res = process_query(count=true)
          return res.length if res.is_a?Array
          return res
        end
        return @result.count
      end

      def empty?
        process_query unless @result
        return @result.empty?
      end

      def first
        process_query unless @result
        @result.first
      end

      def last
        process_query unless @result
        @result.last
      end

      def page(i,size=nil)
        @page_i = i
        if size
          @page_size = size
        elsif @page_size.nil?
          @page_size = 50
        end
        @result = nil
        self
      end

      def no_count
        @do_count = false
        self
      end

      def include(*options)
        if options.instance_of?(Array) && options.first.instance_of?(Array)
          options = options.first
        end
        options.each do |opt|
          if opt.instance_of?(Symbol)
            if @klass.handler?(opt)
              raise ArgumentError, "Method based attribute cannot be included"
            end
          end
          if opt.instance_of?(Hash)
            opt.each do |k,v|
              if @klass.handler?(k)
                raise ArgumentError, "Method based attribute cannot be included"
              end
            end
          end
          @include << opt if opt.instance_of?(Symbol)
          @include_embed.merge!(opt) if opt.instance_of?(Hash)
        end
        @include = [:unmapped] if @include.include? :unspecified
        self
      end
      
      def models(models)
        @models = models
        self
      end

      def and(*options)
        and_match = options.first
        @pattern = @pattern.join(and_match)
        self
      end

      def or(*options)
        or_match = options.first
        @pattern = @pattern.union(or_match)
        self
      end

      def order_by(*opts)
        @order_by = opts
        self
      end

      def in(*opts)
        opts = opts.flatten
        if opts && opts.length > 0
          opts = opts.select { |x| !x.nil? }
          if opts.length > 0
            (@where_options_load ||= {})[:collection] = opts
          end
        end
        self
      end

      def query_options(opts)
        @query_options = opts
        self
      end

      def ids(ids)
        if ids
          @ids = ids
        end
        self
      end

      def filter(filter)
        (@filters ||= []) << filter
        self
      end

      def aggregate(agg,pattern)
        (@aggregate ||= []) << AGGREGATE_PATTERN.new(pattern,agg) 
        self
      end

      def nil?
        self.first.nil?
      end

      def with_index(index_key)
        @index_key = index_key
        self
      end

      def read_only
        @read_only = true
        self
      end
    end
  end
end
